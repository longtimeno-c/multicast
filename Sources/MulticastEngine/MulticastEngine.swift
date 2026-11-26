import Foundation
import MulticastAudio
import os

/// The conductor: pulls from ONE `AudioSource` and fans timeline-stamped packets out to MANY `AudioSink`s.
///
/// ## Why a final class with internal locking rather than an actor
/// The packet clock runs on a dedicated time-constraint thread that must never `await`, block or
/// hop executors; an actor's state is unreachable from such a thread without blocking. So:
/// - the pacer thread (`PacerRun`) only ever *try-locks* a tiny shared struct to pick up an
///   immutable `RenderPlan` (the active sink list) and a stop flag;
/// - quick engine state lives behind an unfair lock that is never held across an `await`;
/// - transport/membership commands (play, pause, stop, setSource, add/remove) are serialized
///   through an async FIFO so they never interleave, and each sink has its own FIFO so device
///   commands (flush → prepare → setVolume …) arrive in order without one slow speaker holding
///   up another.
/// Volume/mute/offset setters are synchronous and cheap so a UI slider can call them directly.
public final class MulticastEngine: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {
        /// Distance between delivery and playout (the group buffer). Applies from the next anchor.
        public var latencyNanos: UInt64 = StreamTimeline.defaultLatencyNanos
        /// A sink whose `prepare` takes longer than this is marked failed (its prepare keeps running).
        public var prepareTimeoutNanos: UInt64 = 10_000_000_000
        /// Bound on how long transport commands wait for sinks' flush/stop.
        public var sinkCommandTimeoutNanos: UInt64 = 3_000_000_000
        /// Minimum spacing of `setVolume` pushes per sink; intermediate values are coalesced away.
        public var volumeCoalesceNanos: UInt64 = 100_000_000
        /// Max packets emitted back to back when catching up after a stall.
        public var maxBurstPackets: Int = 8
        /// Packets are never delivered less than this before their playout (catch-up skips instead),
        /// and late joiners are backfilled only with packets due at least this far in the future.
        public var minDeliveryLeadNanos: UInt64 = 250_000_000
        /// Late joiners first receive the already-emitted packets still far enough in the future,
        /// so a speaker that connects within the latency window starts with everyone else.
        public var lateJoinBackfill: Bool = true
        public var meterRateHz: Double = 25
        public var initialMasterVolume: Float = 1.0
        /// Volume for sinks added without an explicit one.
        public var defaultSinkVolume: Float = 0.5
        /// Request the Mach time-constraint policy for the pacer thread.
        public var realtimeThread: Bool = true

        public init() {}
    }

    // MARK: Internal per-sink bookkeeping (guarded by `lock`)

    final class Entry: @unchecked Sendable {
        let id: String
        let sink: AudioSink
        let name: String
        let queue = SerialAsyncQueue()
        var volume: Float
        var muted = false
        var enabled = true
        var offsetMillis = 0
        var failure: String?
        var reported: SinkState = .idle
        /// Generation of the prepare in flight, if any.
        var preparingGeneration: UInt64?
        /// Generation of the timeline this sink is prepared on and receiving, if any.
        var activeGeneration: UInt64?
        var joinVersion: UInt64 = 0
        var hasBeenPrepared = false
        var removed = false
        var observer: Task<Void, Never>?
        var volumePushScheduled = false
        var lastVolumePushNanos: UInt64 = 0
        var lastPushedVolume: Float?

        init(sink: AudioSink, volume: Float) {
            id = sink.id
            name = sink.displayName
            self.sink = sink
            self.volume = volume
        }
    }

    public let configuration: Configuration

    private let lock = OSAllocatedUnfairLock()
    private let control = SerialAsyncQueue()
    private let snapshotHub = Broadcaster<EngineSnapshot>(replayLatest: true, bufferSize: 16)
    private let eventHub = Broadcaster<EngineEvent>(replayLatest: false, bufferSize: 64)
    private let meterHub = Broadcaster<MeterReading>(replayLatest: false, bufferSize: 2)
    private let meterQueue = DispatchQueue(label: "multicast.engine.meters", qos: .userInitiated)

    // Guarded by `lock`.
    private var transport: EngineSnapshot.TransportState = .stopped
    private var source: AudioSource?
    private var sourceStarted = false
    private var masterVolume: Float
    private var latencyNanos: UInt64
    private var entries: [Entry] = []
    private var timeline: StreamTimeline?
    private var generation: UInt64 = 0
    private var nextFrame: UInt64 = 0
    /// Audio that sinks had been sent but had not played when the stream was paused (they
    /// flushed it). Re-emitted first on resume, so a pause loses nothing. Finite sources only.
    private var retained: [Data] = []
    private var run: PacerRun?
    private var discardRun: PacerRun?
    private var planVersion: UInt64 = 0
    private var revision: UInt64 = 0
    private var lastStatistics = PacerStatistics()
    private var meterTimer: DispatchSourceTimer?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        masterVolume = VolumeMath.clamp(configuration.initialMasterVolume)
        latencyNanos = configuration.latencyNanos
        lock.withLockUnchecked { publishLocked() }
    }

    deinit {
        run?.requestStop()
        discardRun?.requestStop()
        meterTimer?.cancel()
        for e in entries { e.observer?.cancel() }
        snapshotHub.finish()
        eventHub.finish()
        meterHub.finish()
    }

    // MARK: - Observation

    /// The current state. Cheap.
    public var snapshot: EngineSnapshot { lock.withLockUnchecked { makeSnapshotLocked() } }

    /// Every state change; a new subscriber first receives the latest snapshot.
    public var snapshots: AsyncStream<EngineSnapshot> { snapshotHub.makeStream() }

    public var events: AsyncStream<EngineEvent> { eventHub.makeStream() }

    /// Source level at ~`meterRateHz` while playing.
    public var meters: AsyncStream<MeterReading> { meterHub.makeStream() }

    /// The timeline packets are currently (or were last) stamped on.
    public var currentTimeline: StreamTimeline? { lock.withLockUnchecked { timeline } }

    /// Statistics of the current pacer run (or the last one).
    public var pacerStatistics: PacerStatistics {
        lock.withLockUnchecked { run?.statistics ?? lastStatistics }
    }

    // MARK: - Transport

    /// Start (from stopped/ended) or resume (from paused). A new timeline is anchored
    /// `latency` from now and every enabled sink (failed ones included: this is the retry point)
    /// is prepared on it concurrently; the clock starts immediately and sinks join as they are ready.
    public func play() async throws {
        try await control.runThrowing { [self] in try await playLocked() }
    }

    /// Stops the clock, flushes the sinks (they stay connected). Frames continue on resume.
    ///
    /// For a finite source, the audio already sent but not yet audible at the pause instant (about
    /// one latency) is kept and played first on resume, so playback continues from what was last
    /// heard rather than from what was last read. Pass `retainUnplayedAudio: false` when the old
    /// audio must not come back (e.g. a seek). For a live source the input keeps being drained and
    /// discarded and nothing is retained (it would be stale).
    public func pause(retainUnplayedAudio: Bool = true) async {
        await control.run { [self] in await pauseLocked(retain: retainUnplayedAudio) }
    }

    /// Stops the clock, flushes and stops all sinks, stops the source. Sinks stay in the list.
    public func stop() async {
        await control.run { [self] in await stopLocked() }
    }

    /// Switch the source without tearing down sinks. While playing: flush + re-anchor + continue.
    /// After `.ended`, if the previous tail is still buffered, continues gaplessly on the same timeline.
    /// Passing `nil` stops playback.
    public func setSource(_ newSource: AudioSource?) async throws {
        try await control.runThrowing { [self] in try await setSourceLocked(newSource) }
    }

    /// Takes effect at the next anchor (play / resume / source change).
    public func setLatency(nanos: UInt64) {
        lock.withLockUnchecked {
            latencyNanos = max(nanos, PacingSchedule.packetNanos * 4)
            publishLocked()
        }
    }

    /// Stop everything, remove all sinks, finish all streams.
    public func shutdown() async {
        await control.run { [self] in
            await stopLocked()
            let all: [Entry] = lock.withLockUnchecked { entries }
            for e in all { await removeLocked(e) }
        }
        snapshotHub.finish()
        eventHub.finish()
        meterHub.finish()
    }

    // MARK: - Sinks

    /// Adds a sink. If playing, it is prepared against the CURRENT timeline and then starts
    /// receiving packets (with backfill of the still-future ones, see `Configuration.lateJoinBackfill`).
    /// Adding an id that is already present does nothing and returns false.
    @discardableResult
    public func addSink(_ sink: AudioSink, volume: Float? = nil, muted: Bool = false, offsetMillis: Int = 0) async -> Bool {
        await control.run { [self] in
            let entry = Entry(sink: sink, volume: VolumeMath.clamp(volume ?? configuration.defaultSinkVolume))
            entry.muted = muted
            entry.offsetMillis = offsetMillis
            enum Outcome { case duplicate, added, addedWhilePlaying(UInt64, StreamTimeline) }
            let outcome: Outcome = lock.withLockUnchecked {
                if entries.contains(where: { $0.id == entry.id }) { return .duplicate }
                entries.append(entry)
                publishLocked()
                if transport == .playing, let tl = timeline { return .addedWhilePlaying(generation, tl) }
                return .added
            }
            switch outcome {
            case .duplicate:
                return false
            case .added:
                startObserving(entry)
            case .addedWhilePlaying(let gen, let tl):
                startObserving(entry)
                startJoin(entry, generation: gen, timeline: tl)
            }
            return true
        }
    }

    /// Removes a sink, mid-playback included. When this returns the pacer will not call
    /// `enqueue` on it again, and it has been flushed and stopped (bounded wait).
    public func removeSink(id: String) async {
        await control.run { [self] in
            guard let e = lock.withLockUnchecked({ entries.first { $0.id == id } }) else { return }
            await removeLocked(e)
        }
    }

    /// Re-prepare a failed sink now (if playing) or clear its failure (otherwise).
    public func retrySink(id: String) async {
        await control.run { [self] in
            let join: (UInt64, StreamTimeline)? = lock.withLockUnchecked {
                guard let e = entries.first(where: { $0.id == id }) else { return nil }
                e.failure = nil
                defer { publishLocked() }
                guard transport == .playing, e.enabled, e.activeGeneration == nil, e.preparingGeneration == nil,
                      let tl = timeline else { return nil }
                return (generation, tl)
            }
            if let join, let e = lock.withLockUnchecked({ entries.first { $0.id == id } }) {
                startJoin(e, generation: join.0, timeline: join.1)
            }
        }
    }

    /// Disabled sinks are excluded from playback and stopped (device released) but keep their
    /// settings; enabling one while playing prepares it on the current timeline.
    public func setEnabled(_ enabled: Bool, forSink id: String) async {
        await control.run { [self] in
            guard let e = lock.withLockUnchecked({ entries.first { $0.id == id } }) else { return }
            if enabled {
                let join: (UInt64, StreamTimeline)? = lock.withLockUnchecked {
                    guard !e.enabled else { return nil }
                    e.enabled = true
                    e.failure = nil
                    defer { publishLocked() }
                    if transport == .playing, let tl = timeline { return (generation, tl) }
                    return nil
                }
                if let join { startJoin(e, generation: join.0, timeline: join.1) }
            } else {
                let (wasEnabled, version, run): (Bool, UInt64, PacerRun?) = lock.withLockUnchecked {
                    guard e.enabled else { return (false, 0, nil) }
                    e.enabled = false
                    e.activeGeneration = nil
                    e.preparingGeneration = nil
                    let v = rebuildPlanLocked()
                    publishLocked()
                    return (true, v, self.run)
                }
                guard wasEnabled else { return }
                await run?.waitUntilObserved(version)
                let sink = e.sink
                let t = e.queue.enqueue {
                    await sink.flush()
                    await sink.stop()
                }
                lock.withLockUnchecked { e.hasBeenPrepared = false }
                await awaitAll([t], timeoutNanos: configuration.sinkCommandTimeoutNanos)
            }
        }
    }

    public func setMasterVolume(_ volume: Float) {
        let all: [Entry] = lock.withLockUnchecked {
            masterVolume = VolumeMath.clamp(volume)
            publishLocked()
            return entries
        }
        for e in all { requestVolumePush(e) }
    }

    public func setVolume(_ volume: Float, forSink id: String) {
        guard let e = updateEntry(id, { $0.volume = VolumeMath.clamp(volume) }) else { return }
        requestVolumePush(e)
    }

    public func setMuted(_ muted: Bool, forSink id: String) {
        guard let e = updateEntry(id, { $0.muted = muted }) else { return }
        requestVolumePush(e)
    }

    /// Per-speaker sync trim passthrough (positive = later).
    public func setOffset(millis: Int, forSink id: String) {
        guard let e = updateEntry(id, { $0.offsetMillis = millis }) else { return }
        let sink = e.sink
        e.queue.enqueue { [weak self, weak e] in
            guard let self, let e else { return }
            let latest = self.lock.withLockUnchecked { e.offsetMillis }
            await sink.setOffset(millis: latest)
        }
    }

    // MARK: - Transport implementation (always on `control`)

    private func playLocked() async throws {
        let (state, src, started) = lock.withLockUnchecked { (transport, source, sourceStarted) }
        if state == .playing { return }
        guard let src else { throw EngineError.noSource }
        if let d = lock.withLockUnchecked({ () -> PacerRun? in let d = discardRun; discardRun = nil; return d }) {
            _ = await d.stop()
        }
        if !started {
            try await src.start()
            lock.withLockUnchecked { sourceStarted = true }
        }
        beginTimeline(source: src)
    }

    private func pauseLocked(retain: Bool) async {
        guard lock.withLockUnchecked({ transport == .playing }) else { return }
        guard let r = lock.withLockUnchecked({ run }) else { return }
        let result = await r.stop()
        let ended = absorb(r, result)
        if ended { return }
        // What the speakers have NOT played yet is everything from the packet audible now on.
        // Rounded down to a packet: repeating < 8 ms is better than losing it.
        var keep: [Data] = []
        if retain, !r.source.isLive {
            let audible = r.timeline.frame(atHostNanos: HostClock.nowNanos())
            keep = r.unplayedPayloads(fromFrame: Self.packetFloor(audible, timeline: r.timeline))
        }
        lock.withLockUnchecked { retained = keep }
        let (all, src): ([Entry], AudioSource?) = lock.withLockUnchecked {
            transport = .paused
            for e in entries { e.activeGeneration = nil; e.preparingGeneration = nil }
            publishLocked()
            return (entries, source)
        }
        await flushAll(all)
        if let src, src.isLive { startDiscardRun(src) }
    }

    private func stopLocked() async {
        lock.withLockUnchecked { retained = [] }
        if let d = lock.withLockUnchecked({ () -> PacerRun? in let d = discardRun; discardRun = nil; return d }) {
            _ = await d.stop()
        }
        _ = await retireRun()
        let (all, src, started): ([Entry], AudioSource?, Bool) = lock.withLockUnchecked {
            transport = .stopped
            for e in entries { e.activeGeneration = nil; e.preparingGeneration = nil }
            let started = sourceStarted
            sourceStarted = false
            publishLocked()
            return (entries, source, started)
        }
        var tasks: [Task<Void, Never>] = []
        for e in all {
            let sink = e.sink
            tasks.append(e.queue.enqueue {
                await sink.flush()
                await sink.stop()
            })
            lock.withLockUnchecked { e.hasBeenPrepared = false }
        }
        await awaitAll(tasks, timeoutNanos: configuration.sinkCommandTimeoutNanos)
        if started, let src { await src.stop() }
    }

    private func setSourceLocked(_ newSource: AudioSource?) async throws {
        let (state, old, oldStarted) = lock.withLockUnchecked { (transport, source, sourceStarted) }
        if old === newSource { return }
        // Audio retained from a pause belongs to the old source.
        lock.withLockUnchecked { retained = [] }
        guard let newSource else {
            await stopLocked()
            lock.withLockUnchecked { source = nil; publishLocked() }
            return
        }

        switch state {
        case .stopped:
            lock.withLockUnchecked { source = newSource; sourceStarted = false; publishLocked() }
            if oldStarted, let old { await old.stop() }

        case .paused:
            if let d = lock.withLockUnchecked({ () -> PacerRun? in let d = discardRun; discardRun = nil; return d }) {
                _ = await d.stop()
            }
            if oldStarted, let old { await old.stop() }
            lock.withLockUnchecked { source = newSource; sourceStarted = false; publishLocked() }
            try await startSourceOrStop(newSource)
            if newSource.isLive { startDiscardRun(newSource) }

        case .playing:
            let ended = await retireRun()
            if !ended {
                let all: [Entry] = lock.withLockUnchecked {
                    for e in entries { e.activeGeneration = nil; e.preparingGeneration = nil }
                    _ = rebuildPlanLocked()
                    return entries
                }
                await flushAll(all)
            }
            if oldStarted, let old { await old.stop() }
            lock.withLockUnchecked { source = newSource; sourceStarted = false; publishLocked() }
            try await startSourceOrStop(newSource)
            if ended {
                continueAfterEnd(source: newSource)
            } else {
                beginTimeline(source: newSource)
            }

        case .ended:
            if oldStarted, let old { await old.stop() }
            lock.withLockUnchecked { source = newSource; sourceStarted = false; publishLocked() }
            try await startSourceOrStop(newSource)
            continueAfterEnd(source: newSource)
        }
    }

    private func startSourceOrStop(_ src: AudioSource) async throws {
        do {
            try await src.start()
            lock.withLockUnchecked { sourceStarted = true }
        } catch {
            await stopLocked()
            throw error
        }
    }

    /// After end-of-stream: if the tail of the previous source is still buffered far enough ahead,
    /// keep the same timeline (sinks stay prepared) so the next source follows without a gap.
    private func continueAfterEnd(source src: AudioSource) {
        let gapless: Bool = lock.withLockUnchecked {
            guard let tl = timeline else { return false }
            let lead = TimelineMath.playoutHostNanos(tl, forFrame: nextFrame)
            let now = HostClock.nowNanos()
            guard lead > now + configuration.minDeliveryLeadNanos else { return false }
            transport = .playing
            startRunLocked(source: src, timeline: tl, startFrame: nextFrame)
            publishLocked()
            return true
        }
        if !gapless { beginTimeline(source: src) }
    }

    /// Issue a new timeline anchored `latency` from now at `nextFrame`, start the clock and
    /// (re)prepare every enabled sink on it concurrently.
    private func beginTimeline(source src: AudioSource) {
        let (joins, tl, gen): ([Entry], StreamTimeline, UInt64) = lock.withLockUnchecked {
            generation += 1
            let tl = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + latencyNanos,
                                    anchorFrame: nextFrame, latencyNanos: latencyNanos)
            timeline = tl
            transport = .playing
            for e in entries { e.activeGeneration = nil; e.preparingGeneration = nil }
            let preroll = retained
            retained = []
            startRunLocked(source: src, timeline: tl, startFrame: nextFrame, preroll: preroll)
            let joins = entries.filter { $0.enabled && !$0.removed }
            publishLocked()
            return (joins, tl, generation)
        }
        eventHub.yield(.timelineChanged(tl))
        for e in joins { startJoin(e, generation: gen, timeline: tl) }
    }

    private func startRunLocked(source src: AudioSource, timeline tl: StreamTimeline, startFrame: UInt64,
                                preroll: [Data] = []) {
        let options = PacerRun.Options(maxBurstPackets: configuration.maxBurstPackets,
                                       minDeliveryLeadNanos: configuration.minDeliveryLeadNanos,
                                       backfill: configuration.lateJoinBackfill,
                                       realtime: configuration.realtimeThread)
        planVersion += 1
        let r = PacerRun(timeline: tl, startFrame: startFrame, source: src, mode: .play,
                         plan: makePlanLocked(version: planVersion), options: options,
                         preroll: preroll) { [weak self] run, result in
            guard let self else { return }
            self.control.enqueue { await self.handleRunEnded(run, result) }
        }
        run = r
        r.start()
        startMeterTimerLocked(r)
    }

    private func startDiscardRun(_ src: AudioSource) {
        lock.withLockUnchecked {
            let tl = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + latencyNanos, anchorFrame: 0,
                                    latencyNanos: latencyNanos)
            let options = PacerRun.Options(maxBurstPackets: configuration.maxBurstPackets,
                                           minDeliveryLeadNanos: configuration.minDeliveryLeadNanos,
                                           backfill: false, realtime: configuration.realtimeThread)
            let r = PacerRun(timeline: tl, startFrame: 0, source: src, mode: .discard,
                             plan: RenderPlan(version: 0, sinks: [], joinVersions: []), options: options) { [weak self] run, result in
                guard let self, result.reason == .endOfStream else { return }
                self.control.enqueue { await self.handleDiscardEnded(run) }
            }
            discardRun = r
            r.start()
        }
    }

    /// Stops the current play run. Returns true if it had actually hit end-of-stream (state → ended).
    private func retireRun() async -> Bool {
        guard let r = lock.withLockUnchecked({ run }) else { return false }
        let result = await r.stop()
        return absorb(r, result)
    }

    /// Applies a finished run's result. Returns true if it ended by end-of-stream.
    @discardableResult
    private func absorb(_ r: PacerRun, _ result: PacerRun.Result) -> Bool {
        let event: EngineEvent? = lock.withLockUnchecked {
            guard run === r else { return nil }
            run = nil
            lastStatistics = r.statistics
            meterTimer?.cancel()
            meterTimer = nil
            nextFrame = result.nextFrame
            guard result.reason == .endOfStream else { return nil }
            transport = .ended
            publishLocked()
            return .endOfStream(endFrame: result.nextFrame,
                                audibleUntilHostNanos: TimelineMath.playoutHostNanos(r.timeline, forFrame: result.nextFrame))
        }
        if let event { eventHub.yield(event); return true }
        return false
    }

    private func handleRunEnded(_ r: PacerRun, _ result: PacerRun.Result) async {
        absorb(r, result)
    }

    private func handleDiscardEnded(_ r: PacerRun) async {
        let ended: Bool = lock.withLockUnchecked {
            guard discardRun === r else { return false }
            discardRun = nil
            transport = .ended
            publishLocked()
            return true
        }
        if ended {
            eventHub.yield(.endOfStream(endFrame: lock.withLockUnchecked { nextFrame }, audibleUntilHostNanos: HostClock.nowNanos()))
        }
    }

    private func flushAll(_ all: [Entry]) async {
        var tasks: [Task<Void, Never>] = []
        for e in all where e.enabled {
            let sink = e.sink
            tasks.append(e.queue.enqueue { await sink.flush() })
        }
        await awaitAll(tasks, timeoutNanos: configuration.sinkCommandTimeoutNanos)
    }

    private func removeLocked(_ e: Entry) async {
        let (version, run): (UInt64, PacerRun?) = lock.withLockUnchecked {
            e.removed = true
            e.activeGeneration = nil
            e.preparingGeneration = nil
            entries.removeAll { $0 === e }
            let v = rebuildPlanLocked()
            publishLocked()
            return (v, self.run)
        }
        await run?.waitUntilObserved(version)
        e.observer?.cancel()
        let sink = e.sink
        let t = e.queue.enqueue {
            await sink.flush()
            await sink.stop()
        }
        await awaitAll([t], timeoutNanos: configuration.sinkCommandTimeoutNanos)
    }

    // MARK: - Joining (per-sink queue; never blocks other sinks or the clock)

    private func startJoin(_ e: Entry, generation gen: UInt64, timeline tl: StreamTimeline) {
        lock.withLockUnchecked {
            e.preparingGeneration = gen
            e.failure = nil
            publishLocked()
        }
        let timeout = configuration.prepareTimeoutNanos
        e.queue.enqueue { [weak self] in
            guard let self else { return }
            guard self.lock.withLockUnchecked({ e.preparingGeneration == gen && !e.removed }) else { return }
            let sink = e.sink
            if self.lock.withLockUnchecked({ e.hasBeenPrepared }) {
                await sink.flush()
            }
            // Volume and trim reach the device BEFORE any audio can.
            await self.pushVolumeNow(e)
            let offset = self.lock.withLockUnchecked { e.offsetMillis }
            if offset != 0 { await sink.setOffset(millis: offset) }
            do {
                try await withDeadline(nanos: timeout,
                                       timeoutError: EngineError.prepareTimedOut(seconds: Double(timeout) / 1e9)) {
                    try await sink.prepare(timeline: tl)
                }
            } catch {
                let message = (error as? EngineError)?.description ?? String(describing: error)
                let failed: Bool = self.lock.withLockUnchecked {
                    guard e.preparingGeneration == gen else { return false }
                    e.preparingGeneration = nil
                    e.failure = message
                    self.publishLocked()
                    return true
                }
                if failed { self.eventHub.yield(.sinkFailed(id: e.id, message: message)) }
                return
            }
            self.lock.withLockUnchecked { e.hasBeenPrepared = true }
            await self.pushVolumeNow(e)
            let joined: Bool = self.lock.withLockUnchecked {
                guard e.preparingGeneration == gen else { return false }
                e.preparingGeneration = nil
                guard self.generation == gen, self.transport == .playing, e.enabled, !e.removed else { return false }
                e.activeGeneration = gen
                self.planVersion += 1
                e.joinVersion = self.planVersion
                _ = self.rebuildPlanLocked(bump: false)
                self.publishLocked()
                return true
            }
            if joined { self.eventHub.yield(.sinkJoined(id: e.id, timelineAnchorFrame: tl.anchorFrame)) }
        }
    }

    private func startObserving(_ e: Entry) {
        let updates = e.sink.stateUpdates
        e.observer = Task { [weak self, weak e] in
            for await state in updates {
                guard let self, let e else { return }
                self.handleReported(e, state)
            }
        }
    }

    private func handleReported(_ e: Entry, _ state: SinkState) {
        let failure: String? = lock.withLockUnchecked {
            guard !e.removed else { return nil }
            e.reported = state
            var failure: String?
            if case .failed(let message) = state, e.activeGeneration != nil {
                e.activeGeneration = nil
                e.failure = message
                _ = rebuildPlanLocked()
                failure = message
            }
            publishLocked()
            return failure
        }
        if let failure { eventHub.yield(.sinkFailed(id: e.id, message: failure)) }
    }

    // MARK: - Volume (coalesced)

    private func effectiveLocked(_ e: Entry) -> Float {
        VolumeMath.effective(sink: e.volume, master: masterVolume, muted: e.muted)
    }

    private func pushVolumeNow(_ e: Entry) async {
        let v: Float = lock.withLockUnchecked {
            let v = effectiveLocked(e)
            e.lastPushedVolume = v
            e.lastVolumePushNanos = HostClock.nowNanos()
            return v
        }
        await e.sink.setVolume(v)
    }

    /// Leading-edge push, then at most one push per `volumeCoalesceNanos` carrying the latest value.
    private func requestVolumePush(_ e: Entry) {
        let wait: UInt64? = lock.withLockUnchecked {
            if e.volumePushScheduled || e.removed { return nil }
            e.volumePushScheduled = true
            let earliest = e.lastVolumePushNanos + configuration.volumeCoalesceNanos
            let now = HostClock.nowNanos()
            return earliest > now ? earliest - now : 0
        }
        guard let wait else { return }
        let push: @Sendable () -> Void = { [weak self, weak e] in
            guard let self, let e else { return }
            e.queue.enqueue { [weak self, weak e] in
                guard let self, let e else { return }
                let v: Float? = self.lock.withLockUnchecked {
                    e.volumePushScheduled = false
                    let v = self.effectiveLocked(e)
                    if v == e.lastPushedVolume { return nil }
                    e.lastPushedVolume = v
                    e.lastVolumePushNanos = HostClock.nowNanos()
                    return v
                }
                if let v { await e.sink.setVolume(v) }
            }
        }
        if wait == 0 {
            push()
        } else {
            Task {
                try? await Task.sleep(nanoseconds: wait)
                push()
            }
        }
    }

    // MARK: - Plan / snapshot helpers (call with `lock` held)

    private func updateEntry(_ id: String, _ body: (Entry) -> Void) -> Entry? {
        lock.withLockUnchecked {
            guard let e = entries.first(where: { $0.id == id }) else { return nil }
            body(e)
            publishLocked()
            return e
        }
    }

    private func makePlanLocked(version: UInt64) -> RenderPlan {
        let active = entries.filter { $0.activeGeneration == generation && $0.activeGeneration != nil && $0.enabled && !$0.removed }
        return RenderPlan(version: version, sinks: active.map { $0.sink }, joinVersions: active.map { $0.joinVersion })
    }

    /// Publishes a new plan to the running pacer; returns its version.
    @discardableResult
    private func rebuildPlanLocked(bump: Bool = true) -> UInt64 {
        if bump { planVersion += 1 }
        run?.setPlan(makePlanLocked(version: planVersion))
        return planVersion
    }

    private func statusLocked(_ e: Entry) -> EngineSnapshot.SinkStatus {
        if !e.enabled { return .disabled }
        if e.failure != nil { return .failed }
        if e.preparingGeneration != nil { return .connecting }
        if e.activeGeneration != nil {
            if case .connecting = e.reported { return .connecting }
            return .playing
        }
        return .idle
    }

    private func makeSnapshotLocked() -> EngineSnapshot {
        EngineSnapshot(
            revision: revision,
            transport: transport,
            sourceName: source?.displayName,
            sourceIsLive: source?.isLive ?? false,
            masterVolume: masterVolume,
            latencyMillis: Int(latencyNanos / 1_000_000),
            sinks: entries.map { e in
                EngineSnapshot.SinkEntry(id: e.id, name: e.name, state: statusLocked(e), error: e.failure,
                                         volume: e.volume, muted: e.muted, enabled: e.enabled,
                                         offsetMillis: e.offsetMillis, effectiveVolume: effectiveLocked(e))
            }
        )
    }

    private func publishLocked() {
        revision += 1
        snapshotHub.yield(makeSnapshotLocked())
    }

    /// The packet-grid frame (relative to the anchor) at or before the fractional `frame`,
    /// clamped to the anchor.
    static func packetFloor(_ frame: Double, timeline tl: StreamTimeline) -> UInt64 {
        let anchor = Double(tl.anchorFrame)
        guard frame.isFinite, frame > anchor else { return tl.anchorFrame }
        let packets = UInt64((frame - anchor) / Double(PCM.framesPerPacket))
        return tl.anchorFrame + packets * UInt64(PCM.framesPerPacket)
    }

    // MARK: - Meters

    private func startMeterTimerLocked(_ r: PacerRun) {
        meterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: meterQueue)
        let interval = 1.0 / max(1, min(configuration.meterRateHz, 120))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        let hub = meterHub
        let tl = r.timeline
        timer.setEventHandler { [weak r] in
            guard let r else { return }
            let acc = r.takeMeter()
            guard !acc.isEmpty else { return }
            let audible = max(0, tl.frame(atHostNanos: HostClock.nowNanos()))
            hub.yield(acc.reading(audibleFrame: UInt64(audible)))
        }
        meterTimer = timer
        timer.resume()
    }
}
