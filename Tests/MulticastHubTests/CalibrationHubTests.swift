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
    let signal: CalibrationSignal
    let sampleRate = 16_000.0
    /// Speaker id → how late it is heard with no trim, seconds. Speakers not listed are out of earshot.
    let delays = Locked<[String: Double]>([:])
    let permission = Locked(PermissionStatus.granted)
    let failsToStart = Locked(false)
    let isListening = Locked(false)
    let starts = Locked(0)
    /// The most speakers ever audible in one recording (calibration must keep it to one).
    let mostAudibleAtOnce = Locked(0)
    let accessGate = Gate()

    init(session: FakeSession, signal: CalibrationSignal) {
        self.session = session
        self.signal = signal
    }

    func access(ask: Bool) async -> PermissionStatus {
        await accessGate.wait()
        return permission.get()
    }

    func start() async throws {
        if failsToStart.get() { throw CocoaError(.featureUnsupported) }
        isListening.set(true)
        starts.update { $0 += 1 }
    }

    func stop() async { isListening.set(false) }

    func recording(fromHostNanos: UInt64, seconds: Double) async -> MicrophoneRecording? {
        guard isListening.get() else { return nil }
        let i = session.inner.get()
        guard i.transport == .playing, let timeline = i.timeline else { return nil }
        let audible = i.selected.filter { !i.muted.contains($0) && i.sinks[$0]?.state == .playing }
        mostAudibleAtOnce.update { $0 = max($0, audible.count) }
        let known = delays.get()
        let heard = audible.compactMap { id in known[id].map { $0 + Double(i.offsets[id] ?? 0) / 1000 } }
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
        return MicrophoneRecording(samples: samples, sampleRate: sampleRate, startHostNanos: fromHostNanos)
    }
}

@Suite("LocalHub sync calibration")
struct CalibrationHubTests {
    static let local = Fixtures.local().id
    static let bedroom = Fixtures.mainBedroom.id
    static let hall = Fixtures.hallSonos.id

    /// Short sweeps close together, so a run over three speakers takes a couple of seconds.
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
            let m = FakeMicrophone(session: session, signal: quick.signal)
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
        try await rig.waitFor("calibration finished", timeout: 15) { $0.calibration?.isRunning == false }
    }

    @Test func linesUpTheSpeakersItHearsAndLeavesTheOthersAlone() async throws {
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
        guard case .aligned(let macLag, let macTrim, _) = status.speakers[0].outcome,
              case .aligned(let lag, let trim, let limited) = status.speakers[1].outcome else {
            Issue.record("expected two measured speakers, got \(status.speakers)")
            return
        }
        // The Mac's own speakers are the reference and keep their trim; the bedroom comes forward.
        #expect(macLag == 0 && macTrim == 0)
        #expect(abs(lag - 59.5) < 1 && abs(trim + 60) <= 1 && !limited)
        #expect(status.speakers[2].outcome == .notHeard)
        #expect(status.summary == "2 of 3 speakers lined up.")
        #expect(status.problem == nil)

        // Set like a trim set by hand: on the session, in the state, in what is remembered.
        #expect(rig.speaker(Fixtures.mainBedroom)?.syncTrimMs == trim)
        #expect(rig.session.calls.contains("offset \(Self.bedroom) \(trim)"))
        #expect(store.load().speakers[Self.bedroom]?.syncTrimMs == trim)
        #expect(rig.speaker(Fixtures.hallSonos)?.syncTrimMs == 25)
        #expect(rig.speaker(Fixtures.local())?.syncTrimMs == 0)

        // One speaker at a time; afterwards nobody is muted, nothing plays, the microphone is off.
        #expect(mic.mostAudibleAtOnce.get() == 1)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty)
        #expect(i.transport == .stopped)
        #expect(!mic.isListening.get() && mic.starts.get() == 1)
        #expect(rig.session.calls.contains("setSource Sync calibration"))

        // The results stay until dismissed.
        try await rig.hub.perform(.cancelSyncCalibration)
        #expect(rig.state.calibration == nil)
    }

    @Test func aTrimAlreadySetIsMeasuredThroughAndCorrected() async throws {
        // The bedroom is 80 ms late by nature and was trimmed 30 ms earlier by ear.
        let (rig, _) = Self.rig(delays: [Self.hall: 0.020, Self.bedroom: 0.100])
        await rig.start()
        try await rig.hub.perform(.setSpeakerSyncTrim(id: SpeakerID(Self.bedroom), milliseconds: -30))
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSync)
        try await Self.finished(rig)
        // No Mac speaker measured: the earliest (the hall) is the reference.
        #expect(rig.speaker(Fixtures.hallSonos)?.syncTrimMs == 0)
        let trim = try #require(rig.speaker(Fixtures.mainBedroom)?.syncTrimMs)
        #expect(abs(trim + 80) <= 1)

        // Measuring again finds them lined up and changes nothing.
        try await rig.hub.perform(.calibrateSync)
        try await rig.waitFor("second run started") { $0.calibration?.isRunning == true }
        try await Self.finished(rig)
        let again = try #require(rig.state.calibration?.speaker(SpeakerID(Self.bedroom))?.outcome)
        guard case .aligned(_, let second, _) = again else { Issue.record("expected a measurement, got \(again)"); return }
        #expect(abs(second - trim) <= 1)
    }

    @Test func needsAMicrophoneAndASpeaker() async throws {
        let bare = Rig()
        await bare.start()
        try await Self.turnOn(bare, [Self.hall])
        await #expect(throws: HubCommandError.self) { try await bare.hub.perform(.calibrateSync) }
        #expect(bare.state.calibration == nil)

        let (rig, _) = Self.rig(delays: [:])
        await rig.start()
        await #expect(throws: HubCommandError(.unavailable, "Turn on a speaker first.")) { try await rig.hub.perform(.calibrateSync) }
        #expect(rig.state.calibration == nil)
    }

    @Test func aRefusedMicrophoneIsSaidAndNothingIsTouched() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.1])
        mic.permission.set(.denied)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSync)
        try await Self.finished(rig)
        let status = try #require(rig.state.calibration)
        #expect(status.problem == LocalHub.microphoneRefused)
        #expect(status.summary == LocalHub.microphoneRefused)
        #expect(status.speakers.allSatisfy { $0.outcome == .skipped })
        #expect(!rig.session.calls.contains("setSource Sync calibration"))
        #expect(!rig.session.calls.contains("play"))
        #expect(rig.speaker(Fixtures.mainBedroom)?.syncTrimMs == 0)
    }

    @Test func aMicrophoneThatWillNotStartHandsTheSpeakersBack() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        mic.failsToStart.set(true)
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSync)
        try await Self.finished(rig)
        #expect(rig.state.calibration?.problem?.hasPrefix("The microphone couldn\u{2019}t be used") == true)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty && i.transport == .stopped)
    }

    @Test func cancellingStopsAtOnceAndChangesNoTrim() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.1])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSync)
        try await rig.waitFor("measuring the second", timeout: 5) { $0.calibration?.speakers.last?.outcome == .measuring }
        try await rig.hub.perform(.cancelSyncCalibration)
        #expect(rig.state.calibration == nil)
        #expect(rig.speaker(Fixtures.mainBedroom)?.syncTrimMs == 0 && rig.speaker(Fixtures.hallSonos)?.syncTrimMs == 0)
        let i = rig.session.inner.get()
        #expect(i.muted.isEmpty && i.transport == .stopped)
        #expect(!mic.isListening.get())
        #expect(!rig.session.calls.contains { $0.hasPrefix("offset") })
    }

    @Test func cancellingDoesNotWaitForThePermissionPrompt() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        mic.accessGate.close()
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSync)
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
        #expect(abs((rig.speaker(Fixtures.mainBedroom)?.syncTrimMs ?? 0) + 30) <= 1)
    }

    @Test func pressingPlayEndsTheCalibration() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.05])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.selectSource(source: .files))
        await rig.hub.settle()
        try await rig.hub.perform(.calibrateSync)
        try await rig.waitFor("measuring", timeout: 5) { $0.calibration?.speakers.first?.outcome == .measuring }
        try await rig.hub.perform(.play)
        try await rig.waitFor("playing the file") { $0.transport.isPlaying && $0.calibration == nil }
        await rig.hub.settle()
        #expect(rig.session.currentSource is FakeFileSource)
        #expect(rig.session.transport == .playing)
        #expect(rig.session.inner.get().muted.isEmpty)
        #expect(rig.speaker(Fixtures.mainBedroom)?.syncTrimMs == 0)
    }

    @Test func aSpeakerTurnedOffBeforeItsTurnIsSkipped() async throws {
        let (rig, _) = Self.rig(delays: [Self.hall: 0.02, Self.bedroom: 0.05])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall, Self.bedroom])
        try await rig.hub.perform(.calibrateSync)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.bedroom), enabled: false))
        try await Self.finished(rig)
        let status = try #require(rig.state.calibration)
        #expect(status.speaker(SpeakerID(Self.bedroom))?.outcome == .skipped)
        guard case .aligned = status.speaker(SpeakerID(Self.hall))?.outcome else {
            Issue.record("expected the hall measured, got \(status.speakers)")
            return
        }
        #expect(rig.speaker(Fixtures.hallSonos)?.syncTrimMs == 0)
    }

    @Test func shuttingDownMidRunEndsCleanly() async throws {
        let (rig, mic) = Self.rig(delays: [Self.hall: 0.02])
        await rig.start()
        try await Self.turnOn(rig, [Self.hall])
        try await rig.hub.perform(.calibrateSync)
        try await rig.waitFor("measuring", timeout: 5) { $0.calibration?.speakers.first?.outcome == .measuring }
        await rig.hub.shutdown()
        #expect(!mic.isListening.get())
    }
}
