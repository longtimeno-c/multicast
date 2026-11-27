import Foundation
import MulticastAudio
import MulticastCalibration
import MulticastHubModel
import Testing
@testable import MulticastHub

/// A microphone that hears what the fake session "plays": for every speaker that is playing and
/// not muted, the calibration sweeps at the times the session's timeline says, later by that
/// speaker's made-up delay and by its trim. No audio device, no sound.
final class FakeMicrophone: CalibrationMicrophone, @unchecked Sendable {
    let session: FakeSession
    let sampleRate = 16_000.0
    /// Speaker id → how late it is heard with no trim, seconds. Speakers not listed are out of earshot.
    let delays = Locked<[String: Double]>([:])
    /// Added to every arrival: this microphone's own, unknown delay.
    let ownDelay = Locked(0.0)
    let permission = Locked(MicrophoneAccess.granted)
    let failsToStart = Locked(false)
    let isListening = Locked(false)
    let starts = Locked(0)
    /// The most speakers ever audible in one recording (calibration must keep it to one).
    let mostAudibleAtOnce = Locked(0)
    let accessGate = Gate()

    init(session: FakeSession) { self.session = session }

    func access(ask: Bool) async -> MicrophoneAccess {
        await accessGate.wait()
        return permission.get()
    }

    func start() async throws {
        if failsToStart.get() { throw CocoaError(.featureUnsupported) }
        isListening.set(true)
        starts.update { $0 += 1 }
    }

    func stop() async { isListening.set(false) }

    func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep? {
        guard isListening.get() else { return nil }
        let i = session.inner.get()
        guard i.transport == .playing, let timeline = i.timeline else { return nil }
        let audible = i.selected.filter { !i.muted.contains($0) && i.sinks[$0]?.state == .playing }
        mostAudibleAtOnce.update { $0 = max($0, audible.count) }
        let known = delays.get(), own = ownDelay.get()
        let heard = audible.compactMap { id in known[id].map { $0 + own + Double(i.offsets[id] ?? 0) / 1000 } }
        let lead = signal.leadInSeconds, period = signal.periodSeconds
        // Seconds from the timeline's anchor (frame 0 of the source) to the recording's start.
        let origin = (Double(fromHostNanos) - Double(timeline.anchorHostNanos)) / 1e9
        var noise = SystemRandomNumberGenerator()
        let samples: [Float] = (0..<Int(seconds * sampleRate)).map { n in
            let t = origin + Double(n) / sampleRate
            var v = (Double(noise.next() % 2001) / 1000 - 1) * 0.002
            for delay in heard {
                let since = t - lead - delay
                if since >= 0 { v += 0.1 * signal.value(at: since.truncatingRemainder(dividingBy: period)) }
            }
            return Float(v)
        }
        guard let analysis = DelayEstimator(signal: signal).analyze(samples, sampleRate: sampleRate) else { return nil }
        return HeardSweep(arrivalHostNanos: analysis.arrival.map { fromHostNanos + UInt64($0.seconds * 1e9) },
                          strength: analysis.strength, trace: analysis.trace, level: analysis.level)
    }
}

@Suite("LocalHub sync calibration")
struct CalibrationHubTests {
    static let local = Fixtures.local().id
    static let bedroom = Fixtures.mainBedroom.id
    static let hall = Fixtures.hallSonos.id

    /// Short sweeps close together, so tuning a speaker takes under a second.
    static var quick: CalibrationSettings {
        var s = CalibrationSettings()
        s.signal = CalibrationSignal(sweepSeconds: 0.05, periodSeconds: 0.2, leadInSeconds: 0.1)
        s.settleSeconds = 0.02
        s.earliestSeconds = 0.03
        s.latestSeconds = 0.11
        s.microphoneMarginSeconds = 0.01
        s.startTimeoutSeconds = 1
        s.sweepsPerSpeaker = 4
        return s
    }

    final class Mic: @unchecked Sendable {
        var fake: FakeMicrophone!
    }

    static func rig(delays: [String: Double], settings: InMemorySettingsStore = InMemorySettingsStore()) -> (Rig, FakeMicrophone) {
        let box = Mic()
        let rig = Rig(settings: settings, microphone: { session in
            let m = FakeMicrophone(session: session)
            m.delays.set(delays)
            box.fake = m
            return m
        }, calibration: quick)
        return (rig, box.fake)
    }

    static func turnOn(_ rig: Rig, _ ids: [String]) async throws {
        for id in ids { try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(id), enabled: true)) }
        try await rig.waitFor("speakers on") { s in ids.allSatisfy { s.speaker(SpeakerID($0))?.state == .ready } }
    }

    static func finished(_ rig: Rig) async throws {
        try await rig.waitFor("tuning finished", timeout: 15) { $0.calibration?.isRunning == false }
        await rig.hub.settle()
    }

    static func tune(_ rig: Rig, _ id: String) async throws {
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(id)))
        try await finished(rig)
    }

    static func trim(_ rig: Rig, _ d: SpeakerDescriptor) -> Int { rig.speaker(d)?.syncTrimMs ?? .min }

    // MARK: One speaker at a time

    @Test func speakersAreTunedOneAtATimeAndLineUpWithThoseTunedBefore() async throws {
        let store = InMemorySettingsStore()
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.0915], settings: store)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])

        // The first speaker tuned has nothing to line up with: it is measured, kept, and is
        // what the others will be lined up to.
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall)))
        let running = try #require(rig.state.calibration)
        #expect(running.isRunning && running.microphone == .hub && running.speakers.map(\.id.rawValue) == [Self.hall])
        try await Self.finished(rig)
        var status = try #require(rig.state.calibration)
        #expect(status.speakers[0].outcome == .aligned(lagMs: 0, trimMs: 0, reachedLimit: false, isReference: true))
        #expect(Self.trim(rig, Fixtures.hallSonos) == 0)
        #expect(rig.speaker(Fixtures.hallSonos)?.tunedAt != nil && rig.speaker(Fixtures.mainBedroom)?.tunedAt == nil)
        // Only the speaker being tuned was heard; nobody is left muted.
        #expect(mic.mostAudibleAtOnce.get() == 1)
        #expect(rig.session.inner.get().muted.isEmpty && rig.session.transport == .stopped)

        // Whenever the person is ready: the next one.
        try await rig.hub.perform(.cancelSyncCalibration)
        #expect(rig.state.calibration == nil)
        try await Self.tune(rig, Self.bedroom)
        status = try #require(rig.state.calibration)
        guard case .aligned(let lag, let trim, let limited, let isReference) = status.speakers[0].outcome else {
            Issue.record("expected the bedroom measured, got \(status.speakers)")
            return
        }
        #expect(abs(lag - 71.5) < 1 && abs(trim + 72) <= 1 && !limited && !isReference)
        #expect(status.speakers[0].previousTrimMs == 0)
        #expect(status.summary == status.speakers[0].outcome.caption)
        #expect(Self.trim(rig, Fixtures.mainBedroom) == trim && Self.trim(rig, Fixtures.hallSonos) == 0)
        #expect(rig.session.calls.contains("offset \(Self.bedroom) \(trim)"))

        // Kept on the hub with the speaker's other settings.
        let saved = store.load()
        #expect(saved.speakers[Self.bedroom]?.syncTrimMs == trim)
        #expect(saved.speakers[Self.bedroom]?.calibration?.microphone == "hub")
        #expect(abs((saved.speakers[Self.bedroom]?.calibration?.latenessMs ?? 0) - (saved.speakers[Self.hall]?.calibration?.latenessMs ?? 0) - 71.5) < 1)
    }

    @Test func theOrderDoesNotMatter() async throws {
        // The late speaker first: alone it keeps its trim. When the earlier one is measured,
        // the late one is brought forward without being measured again.
        let (rig, _) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.100])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await Self.tune(rig, Self.bedroom)
        #expect(Self.trim(rig, Fixtures.mainBedroom) == 0)
        try await rig.hub.perform(.cancelSyncCalibration)
        try await Self.tune(rig, Self.hall)
        #expect(Self.trim(rig, Fixtures.hallSonos) == 0)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) + 80) <= 1)
        #expect(rig.state.calibration?.speakers[0].outcome == .aligned(lagMs: 0, trimMs: 0, reachedLimit: false, isReference: true))
    }

    @Test func aSpeakerThatIsOffIsTurnedOnForItsMeasurementOnly() async throws {
        let store = InMemorySettingsStore()
        let (rig, _) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.060], settings: store)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await Self.tune(rig, Self.hall)
        try await rig.hub.perform(.cancelSyncCalibration)

        try await Self.tune(rig, Self.bedroom)
        #expect(rig.state.calibration?.speakers[0].outcome.isAligned == true)
        try await rig.waitFor("bedroom off again") { $0.speaker(SpeakerID(Self.bedroom))?.isEnabled == false }
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) + 40) <= 1)
        #expect(store.load().speakers[Self.bedroom]?.isEnabled == false)
        #expect(rig.speaker(Fixtures.hallSonos)?.isEnabled == true)
        #expect(!rig.session.inner.get().selected.contains(Self.bedroom))
    }

    @Test func tuningsSurviveARestartAndLaterOnesLineUpWithThem() async throws {
        let store = InMemorySettingsStore()
        do {
            let (rig, _) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.100], settings: store)
            await rig.start()
            try await Self.turnOn(rig, [Self.hall, Self.bedroom])
            try await Self.tune(rig, Self.hall)
            try await rig.hub.perform(.cancelSyncCalibration)
            try await Self.tune(rig, Self.bedroom)
            await rig.hub.shutdown()
        }
        let tuned = try #require(store.load().speakers[Self.bedroom]?.syncTrimMs)
        #expect(abs(tuned + 80) <= 1)

        // Another day: the trim is there from the start and goes to the speaker when it joins.
        let (rig, _) = Self.rig(delays: [Self.local: 0.050, Self.hall: 0.020, Self.bedroom: 0.100], settings: store)
        await rig.start()
        try await rig.waitFor("remembered speakers back on") { $0.speaker(SpeakerID(Self.bedroom))?.state == .ready }
        #expect(Self.trim(rig, Fixtures.mainBedroom) == tuned)
        #expect(rig.session.inner.get().selectOffsets[Self.bedroom] == tuned)
        #expect(rig.speaker(Fixtures.mainBedroom)?.tunedAt != nil)

        // A third speaker tuned now lines up with the two measured before the restart. It is
        // the Mac's own, so it becomes what the others line up to, and they follow it.
        try await Self.tune(rig, Self.local)
        #expect(Self.trim(rig, Fixtures.local()) == 0)
        #expect(abs(Self.trim(rig, Fixtures.hallSonos) - 30) <= 1)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) + 50) <= 1)
    }

    @Test func aTrimNudgedByHandIsKeptThroughLaterTunings() async throws {
        let (rig, _) = Self.rig(delays: [Self.local: 0.050, Self.hall: 0.020, Self.bedroom: 0.100])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await Self.tune(rig, Self.hall)
        try await rig.hub.perform(.cancelSyncCalibration)
        try await Self.tune(rig, Self.bedroom)
        try await rig.hub.perform(.cancelSyncCalibration)
        let tuned = Self.trim(rig, Fixtures.mainBedroom)
        // By ear, the person prefers the bedroom 6 ms later than measured.
        try await rig.hub.perform(.setSpeakerSyncTrim(id: SpeakerID(Self.bedroom), milliseconds: tuned + 6))
        try await Self.tune(rig, Self.local)
        #expect(abs(Self.trim(rig, Fixtures.hallSonos) - 30) <= 1)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) - (tuned + 6 + 30)) <= 1)
    }

    @Test func measuringAgainWithATrimInEffectChangesNothing() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.100])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await Self.tune(rig, Self.hall)
        try await rig.hub.perform(.cancelSyncCalibration)
        try await Self.tune(rig, Self.bedroom)
        try await rig.hub.perform(.cancelSyncCalibration)
        let first = Self.trim(rig, Fixtures.mainBedroom)
        try await Self.tune(rig, Self.bedroom)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) - first) <= 1)
        #expect(rig.state.calibration?.speakers[0].previousTrimMs == first)
    }

    @Test func aPhonesMicrophoneIsKeptApartFromTheMacs() async throws {
        // Through the phone everything arrives 8 ms "later" (its own delay): measurements made
        // through it line up among themselves and leave the Mac's alone.
        let (rig, mic) = Self.rig(delays: [Self.local: 0.010, Self.hall: 0.020, Self.bedroom: 0.100])
        let phone = FakeMicrophone(session: rig.session)
        phone.delays.set(mic.delays.get())
        phone.ownDelay.set(0.008)
        await rig.start()
        try await Self.turnOn(rig, [Self.local, Self.hall, Self.bedroom])
        try await Self.tune(rig, Self.local)
        try await rig.hub.perform(.cancelSyncCalibration)

        try await rig.hub.tuneSpeaker(id: Self.hall, microphone: phone, microphoneID: "phone:remote-a", name: "Sample iPhone")
        #expect(rig.state.calibration?.microphone == .phone(name: "Sample iPhone"))
        try await Self.finished(rig)
        // Alone under the phone's microphone: not compared with the Mac's 10 ms.
        #expect(Self.trim(rig, Fixtures.hallSonos) == 0)
        try await rig.hub.perform(.cancelSyncCalibration)
        try await rig.hub.tuneSpeaker(id: Self.bedroom, microphone: phone, microphoneID: "phone:remote-a", name: "Sample iPhone")
        try await Self.finished(rig)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) + 80) <= 1)
        #expect(Self.trim(rig, Fixtures.local()) == 0)
        #expect(!mic.isListening.get() && !phone.isListening.get() && phone.starts.get() == 2 && mic.starts.get() == 1)
    }

    @Test func theSweepsAreReportedAsTheyAreHeard() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.040])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall)))
        try await rig.waitFor("first sweep heard", timeout: 5) { ($0.calibration?.speakers[0].sweeps.count ?? 0) >= 1 }
        let during = try #require(rig.state.calibration)
        #expect(during.isRunning && during.speakers[0].sweepsBeganAt != nil)
        #expect(during.sweepPeriod == 0.2 && during.sweepsPerSpeaker == 4 && during.earliestMs == 30 && during.latestMs == 110)
        try await Self.finished(rig)
        let sweeps = try #require(rig.state.calibration?.speakers[0].sweeps)
        #expect(sweeps.count == 4)
        for sweep in sweeps {
            #expect(abs((sweep.latenessMs ?? -1) - 40) < 1 && sweep.strength > 6.5)
            #expect(sweep.trace.count == DelayEstimator.traceBins && sweep.trace.max() == 255)
            // The spike sits where 40 ms after due falls in a window from 30 ms before to 110 ms after.
            let spike = try #require(sweep.trace.firstIndex(of: 255))
            #expect(abs(Double(spike) / Double(sweep.trace.count) - 70.0 / 140.0) < 0.05)
        }
    }

    // MARK: All in turn

    @Test func allInTurnLinesUpTheSpeakersItHearsAndLeavesTheOthersAlone() async throws {
        let store = InMemorySettingsStore()
        // The Mac's own speakers 12 ms after the timeline, the bedroom 71.5 ms; the hall is out of earshot.
        let (rig, mic) = Self.rig(delays: [Self.local: 0.012, Self.bedroom: 0.0715], settings: store)
        await rig.start()
        try await Self.turnOn(rig, [Self.local, Self.bedroom, Self.hall])
        try await rig.hub.perform(.setSpeakerSyncTrim(id: SpeakerID(Self.hall), milliseconds: 25))

        try await rig.hub.perform(.calibrateSync)
        let running = try #require(rig.state.calibration)
        #expect(running.isRunning && running.speakers.map(\.id.rawValue) == [Self.local, Self.bedroom, Self.hall])
        try await rig.waitFor("measuring the first", timeout: 5) { $0.calibration?.speakers.first?.outcome == .measuring }
        #expect(!rig.state.transport.isPlaying)
        try await Self.finished(rig)

        let status = try #require(rig.state.calibration)
        #expect(status.speakers[0].outcome == .aligned(lagMs: 0, trimMs: 0, reachedLimit: false, isReference: true))
        guard case .aligned(let lag, let trim, let limited, false) = status.speakers[1].outcome else {
            Issue.record("expected the bedroom measured, got \(status.speakers)")
            return
        }
        #expect(abs(lag - 59.5) < 1 && abs(trim + 60) <= 1 && !limited)
        #expect(status.speakers[2].outcome == .notHeard)
        #expect(status.summary == "2 of 3 speakers in sync.")
        #expect(status.problem == nil)
        #expect(Self.trim(rig, Fixtures.mainBedroom) == trim)
        #expect(store.load().speakers[Self.bedroom]?.syncTrimMs == trim)
        #expect(Self.trim(rig, Fixtures.hallSonos) == 25 && store.load().speakers[Self.hall]?.calibration == nil)
        #expect(mic.mostAudibleAtOnce.get() == 1)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty && i.transport == .stopped)
        #expect(!mic.isListening.get() && mic.starts.get() == 1)
        #expect(rig.session.calls.contains("setSource Sync calibration"))
    }

    // MARK: When it can't

    @Test func needsAMicrophoneAKnownSpeakerAndOneRunAtATime() async throws {
        let bare = Rig()
        await bare.start()
        try await Self.turnOn(bare, [Self.hall])
        await #expect(throws: HubCommandError.self) { try await bare.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall))) }
        #expect(bare.state.calibration == nil)

        let (rig, _) = Self.rig(delays: [Self.hall: 0.02])
        await rig.start()
        await #expect(throws: HubCommandError(.unavailable, "Turn on a speaker first.")) { try await rig.hub.perform(.calibrateSync) }
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.calibrateSpeakerSync(id: "nope")) }
        #expect(rig.state.calibration == nil)
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall)))
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.bedroom))) }
        try await Self.finished(rig)
    }

    @Test func aSpeakerOutOfEarshotIsSaidAndItsTrimLeftAlone() async throws {
        let store = InMemorySettingsStore()
        let (rig, _) = Self.rig(delays: [:], settings: store)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.setSpeakerSyncTrim(id: SpeakerID(Self.hall), milliseconds: -40))
        try await Self.tune(rig, Self.hall)
        let status = try #require(rig.state.calibration)
        #expect(status.speakers[0].outcome == .notHeard)
        #expect(status.summary == "Couldn\u{2019}t hear it")
        #expect(status.speakers[0].outcome.nextStep(microphone: status.microphone) != nil)
        #expect(Self.trim(rig, Fixtures.hallSonos) == -40)
        #expect(store.load().speakers[Self.hall]?.calibration == nil && rig.speaker(Fixtures.hallSonos)?.tunedAt == nil)
    }

    @Test func aRefusedMicrophoneIsSaidAndNothingIsTouched() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.1])
        mic.permission.set(.denied)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await Self.tune(rig, Self.bedroom)
        let status = try #require(rig.state.calibration)
        #expect(status.problem == LocalHub.microphoneRefused)
        #expect(status.summary == LocalHub.microphoneRefused)
        #expect(status.speakers.allSatisfy { $0.outcome == .skipped })
        #expect(!rig.session.calls.contains("setSource Sync calibration"))
        #expect(!rig.session.calls.contains("play"))
        #expect(Self.trim(rig, Fixtures.mainBedroom) == 0)
    }

    @Test func aMicrophoneThatWillNotStartHandsTheSpeakersBack() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        mic.failsToStart.set(true)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await Self.tune(rig, Self.hall)
        #expect(rig.state.calibration?.problem?.hasPrefix("The microphone couldn\u{2019}t be used") == true)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty && i.transport == .stopped)
    }

    @Test func stoppingEndsItAtOnceAndChangesNoTrim() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.1])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.bedroom)))
        try await rig.waitFor("listening", timeout: 5) { ($0.calibration?.speakers[0].sweeps.count ?? 0) >= 1 }
        try await rig.hub.perform(.cancelSyncCalibration)
        #expect(rig.state.calibration == nil)
        #expect(Self.trim(rig, Fixtures.mainBedroom) == 0 && rig.speaker(Fixtures.mainBedroom)?.tunedAt == nil)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty && i.transport == .stopped)
        #expect(!mic.isListening.get())
        #expect(!rig.session.calls.contains { $0.hasPrefix("offset") })
    }

    @Test func stoppingDoesNotWaitForThePermissionPrompt() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        mic.accessGate.close()
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall)))
        try await rig.hub.perform(.cancelSyncCalibration)
        #expect(rig.state.calibration == nil)
        #expect(!rig.session.calls.contains("setSource Sync calibration"))
        mic.accessGate.open()
    }

    @Test func musicPausesForItAndGoesOnAfterwardsWhereItWas() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.05])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.playTrack(id: rig.hub.files(.first).items[0].id, context: .files))
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        await rig.hub.settle()
        rig.clock.advance(30)

        try await rig.hub.perform(.calibrateSync)
        try await rig.waitFor("paused for the test sound", timeout: 5) {
            !$0.transport.isPlaying && $0.calibration?.speakers.first?.outcome == .measuring
        }
        #expect(rig.session.currentSource?.displayName == "Sync calibration")
        try await Self.finished(rig)
        try await rig.waitFor("playing again") { $0.transport.isPlaying }
        await rig.hub.settle()
        // The file was reopened where it had got to, and is the engine's source again.
        let reopened = try #require(rig.sources.opened.get().last)
        #expect(rig.session.currentSource === reopened)
        // 30 s after play, less the 2 s the fake session takes before audio is heard.
        #expect(reopened.seeks.get().last.map { abs($0 - 28) < 0.5 } == true)
        #expect(rig.session.transport == .playing)
        #expect(rig.session.inner.get().muted.isEmpty)
        #expect(abs(Self.trim(rig, Fixtures.mainBedroom) + 30) <= 1)
    }

    @Test func pressingPlayEndsTheTuning() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.05])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.selectSource(source: .files))
        await rig.hub.settle()
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.bedroom)))
        try await rig.waitFor("measuring", timeout: 5) { $0.calibration?.speakers.first?.outcome == .measuring }
        try await rig.hub.perform(.play)
        try await rig.waitFor("playing the file") { $0.transport.isPlaying && $0.calibration == nil }
        await rig.hub.settle()
        #expect(rig.session.currentSource is FakeFileSource)
        #expect(rig.session.transport == .playing)
        #expect(rig.session.inner.get().muted.isEmpty)
        #expect(Self.trim(rig, Fixtures.mainBedroom) == 0)
    }

    @Test func inAllInTurnASpeakerTurnedOffBeforeItsTurnIsSkipped() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.05])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSync)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.bedroom), enabled: false))
        try await Self.finished(rig)
        let status = try #require(rig.state.calibration)
        #expect(status.speaker(SpeakerID(Self.bedroom))?.outcome == .skipped)
        #expect(status.speaker(SpeakerID(Self.hall))?.outcome.isAligned == true)
        #expect(Self.trim(rig, Fixtures.hallSonos) == 0)
    }

    @Test func shuttingDownMidRunEndsCleanly() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSpeakerSync(id: SpeakerID(Self.hall)))
        try await rig.waitFor("measuring", timeout: 5) { $0.calibration?.speakers.first?.outcome == .measuring }
        await rig.hub.shutdown()
        #expect(!mic.isListening.get())
    }
}
