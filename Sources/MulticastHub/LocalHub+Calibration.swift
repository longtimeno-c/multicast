import Foundation
import MulticastAppleMusic
import MulticastAudio
import MulticastCalibration
import MulticastHubModel
import os

// Sync calibration: measure when each speaker is really heard, and trim them together.
//
// The test sound (`CalibrationSource`: a short sweep every second) goes through the normal
// pipeline as the engine's source, so it takes the same road as music: same timeline, same
// sinks, same trims. Every speaker but one is muted; the microphone records; the sweep is found
// in the recording (`DelayEstimator`) and its arrival compared with the moment the timeline
// says it was due. A few sweeps per speaker, then the next speaker. At the end `TrimPlanner`
// turns the delays into trims, which are set and remembered like trims set by hand.
//
// What the result does and doesn't contain is in docs/sync-calibration.md. In short: the
// microphone's own delay is in every measurement alike and drops out, and so does any error in
// where the sweeps sit on the timeline; what is lined up is the sound at the microphone.

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
    /// How long the speakers get to start on the test sound, and one speaker to join.
    public var startTimeoutSeconds = 6.0

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

    // MARK: Commands

    func startCalibration() throws {
        guard calibrationRun == nil else { return }
        guard let microphone = deps.microphone else {
            throw HubCommandError(.unsupported, "This hub has no microphone to measure with.")
        }
        let ids = calibrationSpeakers().map(\.id)
        guard !ids.isEmpty else { throw HubCommandError(.unavailable, Self.needsSpeaker) }
        calibrationStatus = SyncCalibrationStatus(isRunning: true, speakers: ids.map { .init(id: SpeakerID($0)) })
        publish()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCalibration(microphone, ids)
        }
        calibrationRun = CalibrationRun(task: task)
    }

    /// Stops a running calibration (nothing it measured is applied) and clears its results, or
    /// dismisses the results of a finished one. `resume: false` when something else is about to
    /// decide what plays.
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

    private func runCalibration(_ microphone: CalibrationMicrophone, _ ids: [String]) async {
        let settings = configuration.calibration
        let session = deps.session
        var problem: String?
        var cancelled = false
        var listening = false
        var measured: [(id: String, seconds: Double, trimMs: Int, isBuiltIn: Bool)] = []
        calibrationReadings = [:]

        do {
            // Ask before touching playback: the prompt can sit there for a while.
            // Not awaited directly, so a cancel doesn't have to wait for the answer.
            let answer = Locked<PermissionStatus?>(nil)
            Task { answer.set(await microphone.access(ask: true)) }
            while answer.get() == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            guard answer.get() == .granted else { throw CalibrationProblem(message: Self.microphoneRefused) }

            calibrationRun?.resumeAfter = wantsPlay
            calibrationRun?.ownsEngine = true
            calibrationRun?.timeline = nil
            if wantsPlay { await pauseForCalibration() }
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
                throw CalibrationProblem(message: "The microphone couldn\u{2019}t be used. Check that this Mac has one, then try again.")
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
                    MulticastTiming.log.debug("hub.calibration speaker \(measured.count) heard \(seconds * 1000, format: .fixed(precision: 2))ms after due, spread \(spread * 1000, format: .fixed(precision: 2))ms")
                    measured.append((id, seconds, speaker.trimMs, speaker.isBuiltIn))
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
            problem = "Calibration couldn\u{2019}t finish. Try again."
        }

        if listening { await microphone.stop() }
        if calibrationRun?.ownsEngine == true {
            // Hand the engine back: silence, every speaker unmuted, the source that was there.
            await runQueued {
                await session.stop()
                for id in session.state.selectedSpeakerIDs { session.setMuted(false, forSpeaker: id) }
            }
            calibrationRun?.ownsEngine = false
            await runQueued { [self] in await self.restoreSourceAfterCalibration() }
        }

        if !cancelled, let problem {
            // Nothing half-measured is applied.
            for i in calibrationStatus?.speakers.indices ?? 0..<0 { calibrationStatus?.speakers[i].outcome = .skipped }
            calibrationStatus?.problem = problem
        } else if !cancelled {
            let plan = TrimPlanner.plan(measured.map {
                TrimPlanner.Input(id: $0.id, delayMs: $0.seconds * 1000, currentTrimMs: $0.trimMs, isPreferredReference: $0.isBuiltIn)
            }, range: SpeakerItem.syncTrimRange)
            for (out, was) in zip(plan, measured) {
                if out.trimMs != was.trimMs { applyCalibratedTrim(out.id, out.trimMs) }
                setCalibrationOutcome(out.id, .aligned(lagMs: (out.lagMs * 10).rounded() / 10, trimMs: out.trimMs,
                                                       reachedLimit: out.isOutOfRange), publishing: false)
            }
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
    private func measure(_ id: String, microphone: CalibrationMicrophone, timeline: StreamTimeline,
                         settings: CalibrationSettings) async throws -> DelayMeasurement {
        let signal = settings.signal
        let estimator = DelayEstimator(signal: signal)
        let earliest = UInt64(settings.earliestSeconds * 1e9)
        let window = settings.earliestSeconds + settings.latestSeconds + signal.sweepSeconds
        let margin = UInt64((window + settings.microphoneMarginSeconds) * 1e9)

        // The first sweep whose listening window hasn't begun.
        let frameNow = timeline.frame(atHostNanos: HostClock.nowNanos() + earliest) - Double(timeline.anchorFrame)
        var sweep = max(0, Int(((frameNow - Double(signal.leadInFrames)) / Double(signal.periodFrames)).rounded(.up)))

        var delays: [Double?] = []
        while delays.count < settings.sweepsPerSpeaker {
            let heard = delays.compactMap { $0 }.count
            // Not enough sweeps left to reach agreement: don't keep the room waiting.
            if heard + (settings.sweepsPerSpeaker - delays.count) < settings.minimumAgreeing { break }
            soloForCalibration(id)
            let due = timeline.playoutHostNanos(forFrame: timeline.anchorFrame + signal.startFrame(ofSweep: sweep))
            let from = due > earliest ? due - earliest : 0
            let ready = from + margin
            let now = HostClock.nowNanos()
            if ready > now { try await Task.sleep(nanoseconds: ready - now) }
            try Task.checkCancellation()
            var delay: Double?
            if let recording = await microphone.recording(fromHostNanos: from, seconds: window) {
                // The correlation is a few tens of milliseconds of arithmetic: off the hub's actor.
                let arrival = await Task.detached(priority: .userInitiated) {
                    estimator.arrival(in: recording.samples, sampleRate: recording.sampleRate)
                }.value
                if let arrival {
                    delay = (Double(recording.startHostNanos) + arrival.seconds * 1e9 - Double(due)) / 1e9
                }
            }
            delays.append(delay)
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
