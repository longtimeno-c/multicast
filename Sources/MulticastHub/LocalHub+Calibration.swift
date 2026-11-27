import Foundation
import MulticastAppleMusic
import MulticastAudio
import MulticastCalibration
import MulticastHubModel
import os

// Sync calibration: measure when a speaker is really heard, and trim it into step.
//
// The test sound (`CalibrationSource`: a short sweep every second) goes through the normal
// pipeline as the engine's source, so it takes the same road as music: same timeline, same
// sinks, same trims. Every speaker but the one being tuned is muted; a microphone listens (the
// Mac's, or a paired phone's held at the speaker); each sweep's arrival is compared with the
// moment the timeline says it was due. A few sweeps, and the speaker's lateness is known.
//
// One speaker is tuned at a time, when the person asks. What was measured is kept with the
// speaker's other settings (`HubSettings.Calibration`), and trims are worked out from every
// measurement made through the same microphone (`TrimPlanner`), so speakers tuned on different
// days, in different rooms, still line up. "All in turn" is the same thing in a loop.
//
// What the result does and doesn't contain is in docs/sync-calibration.md. In short: the
// microphone's own delay is in every measurement alike and drops out; what is lined up is the
// sound where the microphone was.

/// How a calibration measures. The defaults are what the app uses; tests shorten them.
public struct CalibrationSettings: Sendable {
    public var signal = CalibrationSignal()
    /// Sweeps listened to per speaker, and how many of them must agree.
    public var sweepsPerSpeaker = 5
    public var minimumAgreeing = 3
    /// How close to their median sweeps must lie to count as agreeing.
    public var toleranceSeconds = 0.002
    /// Wait after switching speakers before a sweep counts (mutes take a moment to land).
    public var settleSeconds = 1.0
    /// A sweep is looked for from this long before it is due…
    public var earliestSeconds = 0.15
    /// …to this long after. Together with the sweep's length this must not exceed the signal's
    /// period, or the next sweep would be in the window too.
    public var latestSeconds = 0.6
    /// Extra wait before asking the microphone for a window (its input buffering).
    public var microphoneMarginSeconds = 0.15
    /// How long the speakers get to start on the test sound, and one speaker to join (a
    /// network speaker takes a few seconds to connect).
    public var startTimeoutSeconds = 10.0

    public init() {}
}

/// A calibration in flight.
struct CalibrationRun {
    var task: Task<Void, Never>
    /// The engine is playing the test sound: nothing else may start, stop or re-source it.
    var ownsEngine = false
    /// The timeline the engine issued for the test sound.
    var timeline: StreamTimeline?
    /// Playback was paused for the calibration and goes on after it.
    var resumeAfter = false
}

private struct CalibrationProblem: Error {
    var message: String
}

extension LocalHub {
    static let microphoneRefused = "Multicast isn\u{2019}t allowed to use the microphone. Allow it in Privacy & Security, then try again."
    static let hubMicrophoneID = "hub"

    // MARK: Commands

    /// Tunes one speaker with a microphone that isn't the hub's own: a paired phone's, held
    /// next to the speaker. `microphoneID` says which microphone the measurement is kept under
    /// ("phone:" + the remote's id); `name` is shown ("Sample iPhone").
    public func tuneSpeaker(id: String, microphone: any CalibrationMicrophone, microphoneID: String, name: String) throws {
        try startCalibration(of: id, microphone: microphone, microphoneID: microphoneID, shownAs: .phone(name: name))
    }

    /// `id` nil: every speaker that is on, in turn.
    func startCalibration(of id: String?, microphone: (any CalibrationMicrophone)?, microphoneID: String,
                          shownAs: SyncCalibrationStatus.Microphone) throws {
        guard calibrationRun == nil else {
            throw HubCommandError(.unavailable, "A speaker is being tuned. Wait for it to finish, or stop it.")
        }
        guard let microphone else {
            throw HubCommandError(.unsupported, "This Mac has no microphone to listen with. Tune with your iPhone instead.")
        }
        let ids: [String]
        if let id {
            guard calibrationTarget(id).isKnown else {
                throw HubCommandError(.notFound, "That speaker is no longer on the network.")
            }
            ids = [id]
        } else {
            ids = calibrationSpeakers().map(\.id)
            guard !ids.isEmpty else { throw HubCommandError(.unavailable, Self.needsSpeaker) }
        }
        let settings = configuration.calibration
        calibrationStatus = SyncCalibrationStatus(
            isRunning: true, microphone: shownAs,
            speakers: ids.map { .init(id: SpeakerID($0), previousTrimMs: calibrationTarget($0).trimMs) },
            sweepPeriod: settings.signal.periodSeconds, sweepsPerSpeaker: settings.sweepsPerSpeaker,
            earliestMs: settings.earliestSeconds * 1000, latestMs: settings.latestSeconds * 1000)
        publish()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCalibration(microphone, microphoneID: microphoneID, ids, turningOn: id != nil)
        }
        calibrationRun = CalibrationRun(task: task)
    }

    /// Stops a running calibration (speakers already measured keep their result) and clears
    /// what is shown, or dismisses a finished one. `resume: false` when something else is about
    /// to decide what plays.
    func cancelCalibration(resume: Bool = true) async {
        if let run = calibrationRun {
            if !resume { calibrationRun?.resumeAfter = false }
            run.task.cancel()
            await run.task.value
        }
        guard calibrationStatus != nil else { return }
        calibrationStatus = nil
        publish()
    }

    func endCalibrationForShutdown() async {
        guard let run = calibrationRun else { return }
        calibrationRun?.resumeAfter = false
        run.task.cancel()
        await run.task.value
    }

    // MARK: The run

    private func runCalibration(_ microphone: any CalibrationMicrophone, microphoneID: String, _ ids: [String],
                                turningOn: Bool) async {
        let settings = configuration.calibration
        let session = deps.session
        var problem: String?
        var cancelled = false
        var listening = false
        var turnedOn: [String] = []
        calibrationReadings = [:]

        do {
            // Ask before touching playback: the prompt can sit there for a while. Not awaited
            // directly, so a cancel doesn't have to wait for the answer.
            let answer = Locked<MicrophoneAccess?>(nil)
            Task { answer.set(await microphone.access(ask: true)) }
            while answer.get() == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            guard answer.get() == .granted else { throw CalibrationProblem(message: Self.microphoneRefused) }

            calibrationRun?.resumeAfter = wantsPlay
            calibrationRun?.ownsEngine = true
            calibrationRun?.timeline = nil
            if wantsPlay { await pauseForCalibration() }
            // A speaker picked to be tuned that is off is turned on for its measurement only.
            for id in ids where turningOn && !calibrationTarget(id).isOn {
                enableForCalibration(id)
                turnedOn.append(id)
            }
            let source = CalibrationSource(signal: settings.signal)
            let started = Locked(false)
            await runQueued {
                await session.stop()
                for id in session.state.selectedSpeakerIDs { session.setMuted(true, forSpeaker: id) }
                do {
                    try await session.setSource(source)
                    try await session.play()
                    started.set(true)
                } catch {}
            }
            guard started.get(), let timeline = try await calibrationTimeline(within: settings.startTimeoutSeconds) else {
                throw CalibrationProblem(message: "The speakers didn\u{2019}t start. Try again.")
            }
            do { try await microphone.start() } catch is CancellationError { throw CancellationError() } catch {
                throw CalibrationProblem(message: "The microphone couldn\u{2019}t be used. Check it isn\u{2019}t in use elsewhere, then try again.")
            }
            listening = true

            for id in ids {
                try Task.checkCancellation()
                guard let speaker = calibrationSpeakers().first(where: { $0.id == id }) else {
                    setCalibrationOutcome(id, .skipped)
                    continue
                }
                setCalibrationOutcome(id, .measuring)
                soloForCalibration(id)
                guard try await speakerJoined(id, within: settings.startTimeoutSeconds) else {
                    setCalibrationOutcome(id, .skipped)
                    continue
                }
                try await Task.sleep(nanoseconds: UInt64(settings.settleSeconds * 1e9))
                let reading = try await measure(id, microphone: microphone, timeline: timeline, settings: settings)
                calibrationReadings[id] = reading
                switch reading {
                case .measured(let seconds, let spread):
                    MulticastTiming.log.debug("hub.calibration heard \(seconds * 1000, format: .fixed(precision: 2))ms after due, spread \(spread * 1000, format: .fixed(precision: 2))ms")
                    // Kept as the lateness with no trim: the trim in effect is taken back out.
                    let plan = recordCalibration(id, latenessMs: seconds * 1000 - Double(speaker.trimMs), microphone: microphoneID)
                    for entry in calibrationStatus?.speakers ?? [] where entry.id.rawValue == id || entry.outcome.isAligned {
                        guard let out = plan[entry.id.rawValue] else { continue }
                        setCalibrationOutcome(entry.id.rawValue, .aligned(lagMs: (out.lagMs * 10).rounded() / 10, trimMs: out.trimMs,
                                                                          reachedLimit: out.isOutOfRange, isReference: out.isReference),
                                              publishing: false)
                    }
                    publish()
                case .notHeard:
                    setCalibrationOutcome(id, .notHeard)
                case .inconsistent:
                    setCalibrationOutcome(id, .unclear)
                }
            }
        } catch is CancellationError {
            cancelled = true
        } catch let p as CalibrationProblem {
            problem = p.message
        } catch {
            problem = "Tuning couldn\u{2019}t finish. Try again."
        }

        if listening { await microphone.stop() }
        if calibrationRun?.ownsEngine == true {
            // Hand the engine back: silence, every speaker unmuted, the source that was there.
            await runQueued {
                await session.stop()
                for id in session.state.selectedSpeakerIDs { session.setMuted(false, forSpeaker: id) }
            }
            for id in turnedOn { disableAfterCalibration(id) }
            calibrationRun?.ownsEngine = false
            await runQueued { [self] in await self.restoreSourceAfterCalibration() }
        }

        if !cancelled {
            for i in calibrationStatus?.speakers.indices ?? 0..<0 where calibrationStatus?.speakers[i].outcome.isFinished == false {
                calibrationStatus?.speakers[i].outcome = .skipped
            }
            calibrationStatus?.problem = problem
        }
        let resume = calibrationRun?.resumeAfter == true
        calibrationRun = nil
        calibrationStatus?.isRunning = false
        publish()
        if resume { try? await queueAwarePlay() }
    }

    private func setCalibrationOutcome(_ id: String, _ outcome: SyncCalibrationStatus.Outcome, publishing: Bool = true) {
        guard let i = calibrationStatus?.speakers.firstIndex(where: { $0.id.rawValue == id }) else { return }
        calibrationStatus?.speakers[i].outcome = outcome
        if publishing { publish() }
    }

    /// Only `id` is heard. Applied again before every sweep: a speaker turned on meanwhile
    /// joins unmuted.
    private func soloForCalibration(_ id: String) {
        let session = deps.session
        for other in session.state.selectedSpeakerIDs { session.setMuted(other != id, forSpeaker: other) }
    }

    private func calibrationTimeline(within seconds: Double) async throws -> StreamTimeline? {
        let deadline = HostClock.nowNanos() + UInt64(seconds * 1e9)
        while HostClock.nowNanos() < deadline {
            if let timeline = calibrationRun?.timeline { return timeline }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return calibrationRun?.timeline
    }

    /// Waits until the engine reports the speaker as playing (a network speaker takes a second
    /// or two to connect). False: it failed, left, or didn't make it in time.
    private func speakerJoined(_ id: String, within seconds: Double) async throws -> Bool {
        let deadline = HostClock.nowNanos() + UInt64(seconds * 1e9)
        while true {
            let state = deps.session.state
            guard state.selectedSpeakerIDs.contains(id) || calibrationSpeakers().contains(where: { $0.id == id }) else { return false }
            if let entry = state.engine.sinks.first(where: { $0.id == id }) {
                if entry.state == .playing { return true }
                if entry.state == .failed { return false }
            }
            guard HostClock.nowNanos() < deadline else { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Listens to the next few sweeps on the one speaker that is unmuted.
    private func measure(_ id: String, microphone: any CalibrationMicrophone, timeline: StreamTimeline,
                         settings: CalibrationSettings) async throws -> DelayMeasurement {
        let signal = settings.signal
        let earliest = UInt64(settings.earliestSeconds * 1e9)
        let window = settings.earliestSeconds + settings.latestSeconds + signal.sweepSeconds
        let margin = UInt64((window + settings.microphoneMarginSeconds) * 1e9)

        // The first sweep whose listening window hasn't begun.
        let nowNanos = HostClock.nowNanos()
        let frameNow = timeline.frame(atHostNanos: nowNanos + earliest) - Double(timeline.anchorFrame)
        var sweep = max(0, Int(((frameNow - Double(signal.leadInFrames)) / Double(signal.periodFrames)).rounded(.up)))
        func due(_ sweep: Int) -> UInt64 {
            timeline.playoutHostNanos(forFrame: timeline.anchorFrame + signal.startFrame(ofSweep: sweep))
        }
        // For whoever draws it: when the first of these sweeps leaves the loudspeaker.
        if let i = calibrationStatus?.speakers.firstIndex(where: { $0.id.rawValue == id }) {
            calibrationStatus?.speakers[i].sweepsBeganAt = Date().addingTimeInterval((Double(due(sweep)) - Double(nowNanos)) / 1e9)
            calibrationStatus?.speakers[i].sweeps = []
            publish()
        }

        var delays: [Double?] = []
        while delays.count < settings.sweepsPerSpeaker {
            let heardCount = delays.compactMap { $0 }.count
            // Not enough sweeps left to reach agreement: don't keep the room waiting.
            if heardCount + (settings.sweepsPerSpeaker - delays.count) < settings.minimumAgreeing { break }
            soloForCalibration(id)
            let dueNanos = due(sweep)
            let from = dueNanos > earliest ? dueNanos - earliest : 0
            let ready = from + margin
            let now = HostClock.nowNanos()
            if ready > now { try await Task.sleep(nanoseconds: ready - now) }
            try Task.checkCancellation()
            let heard = await microphone.listen(for: signal, fromHostNanos: from, seconds: window)
            try Task.checkCancellation()
            let delay = heard?.arrivalHostNanos.map { (Double($0) - Double(dueNanos)) / 1e9 }
            delays.append(delay)
            if let i = calibrationStatus?.speakers.firstIndex(where: { $0.id.rawValue == id }) {
                calibrationStatus?.speakers[i].sweeps.append(SyncCalibrationStatus.Sweep(
                    latenessMs: delay.map { ($0 * 10_000).rounded() / 10 }, strength: ((heard?.strength ?? 0) * 10).rounded() / 10,
                    trace: Data(heard?.trace ?? [])))
                publish()
            }
            sweep += 1
        }
        return DelayMeasurement.combine(delays, minimumAgreeing: settings.minimumAgreeing, toleranceSeconds: settings.toleranceSeconds)
    }
}

/// A value shared between a queued operation and the code waiting for it.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
}
