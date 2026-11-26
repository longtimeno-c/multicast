import Foundation
import Darwin
import MulticastAudio
import os

/// Immutable list of sinks the pacer delivers to. Swapped as a whole (one pointer under a
/// lock the pacer only ever *tries*), never mutated, so the pacer thread never allocates or
/// waits to see membership changes.
final class RenderPlan: @unchecked Sendable {
    let version: UInt64
    let sinks: [AudioSink]
    /// Plan version at which each sink became active (parallel to `sinks`), for late-join backfill.
    let joinVersions: [UInt64]

    init(version: UInt64, sinks: [AudioSink], joinVersions: [UInt64]) {
        precondition(sinks.count == joinVersions.count)
        self.version = version
        self.sinks = sinks
        self.joinVersions = joinVersions
    }
}

/// One continuous stretch of pacing against one timeline and one source (play → pause, etc.).
/// Owns a dedicated thread with time-constraint scheduling.
final class PacerRun: @unchecked Sendable {
    enum Mode: Sendable {
        /// Normal playback: read, stamp, fan out.
        case play
        /// Live source while paused: keep pulling at real-time rate and throw the audio away so a
        /// capture source does not accumulate stale audio. Nothing reaches the sinks.
        case discard
    }

    enum EndReason: Sendable, Equatable {
        case stopped
        case endOfStream
    }

    struct Result: Sendable, Equatable {
        var reason: EndReason
        /// First frame that was NOT emitted (where the next timeline continues).
        var nextFrame: UInt64
    }

    struct Options: Sendable {
        var maxBurstPackets: Int
        var minDeliveryLeadNanos: UInt64
        var backfill: Bool
        var realtime: Bool
    }

    private struct Shared {
        var plan: RenderPlan
        var stopRequested = false
        var observedVersion: UInt64 = 0
        var stats = PacerStatistics()
    }

    let timeline: StreamTimeline
    let mode: Mode
    let source: AudioSource
    private let startFrame: UInt64
    private let options: Options
    private let shared: OSAllocatedUnfairLock<Shared>
    private let meter = OSAllocatedUnfairLock(initialState: MeterAccumulator())
    private let finish = OSAllocatedUnfairLock<(result: Result?, waiters: [CheckedContinuation<Result, Never>])>(
        uncheckedState: (nil, [])
    )
    private let onEnd: @Sendable (PacerRun, Result) -> Void

    // Owned by the pacer thread only (preallocated; freed in deinit).
    private let buffer: UnsafeMutablePointer<Int16>
    private let scratch: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<AudioPacket?>
    private let ringCapacity: Int

    private var thread: Thread?

    /// Packet payloads emitted before the source is read again (audio retained across a pause).
    private let preroll: [Data]
    /// How many `preroll` payloads the thread consumed. Written by the pacer thread; read only after
    /// it finished (the `finish` lock orders the accesses).
    private var prerollConsumed = 0

    init(timeline: StreamTimeline, startFrame: UInt64, source: AudioSource, mode: Mode, plan: RenderPlan,
         options: Options, preroll: [Data] = [], onEnd: @escaping @Sendable (PacerRun, Result) -> Void) {
        self.preroll = mode == .play ? preroll : []
        self.timeline = timeline
        self.startFrame = startFrame
        self.source = source
        self.mode = mode
        self.options = options
        self.onEnd = onEnd
        self.shared = OSAllocatedUnfairLock(uncheckedState: Shared(plan: plan))
        buffer = .allocate(capacity: PCM.framesPerPacket * PCM.channels)
        buffer.initialize(repeating: 0, count: PCM.framesPerPacket * PCM.channels)
        scratch = .allocate(capacity: PCM.framesPerPacket)
        scratch.initialize(repeating: 0, count: PCM.framesPerPacket)
        // History of emitted packets covering one latency window: used for late-join backfill and
        // to recover the sent-but-not-yet-audible audio when the run is paused.
        let ringPackets = Int(timeline.latencyNanos / PacingSchedule.packetNanos) + 2
        ringCapacity = mode == .play ? max(ringPackets, 1) : 1
        ring = .allocate(capacity: ringCapacity)
        ring.initialize(repeating: nil, count: ringCapacity)
    }

    deinit {
        buffer.deinitialize(count: PCM.framesPerPacket * PCM.channels)
        buffer.deallocate()
        scratch.deinitialize(count: PCM.framesPerPacket)
        scratch.deallocate()
        ring.deinitialize(count: ringCapacity)
        ring.deallocate()
    }

    // MARK: Control side

    func start() {
        let t = Thread { [self] in self.threadMain() }
        t.name = "multicast.pacer"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func requestStop() {
        shared.withLockUnchecked { $0.stopRequested = true }
    }

    /// Waits until the pacer thread has left its loop.
    func finished() async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            let ready: Result? = finish.withLockUnchecked { state in
                if let r = state.result { return r }
                state.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func stop() async -> Result {
        requestStop()
        return await finished()
    }

    func setPlan(_ plan: RenderPlan) {
        shared.withLockUnchecked { $0.plan = plan }
    }

    var observedPlanVersion: UInt64 { shared.withLockUnchecked { $0.observedVersion } }
    var statistics: PacerStatistics { shared.withLockUnchecked { $0.stats } }
    var isFinished: Bool { finish.withLockUnchecked { $0.result != nil } }

    /// After the run finished: payloads of every packet starting at or after `frame` that was
    /// emitted (still in the history ring), followed by the preroll payloads never emitted, in
    /// stream order. This is the audio the sinks had been given but had not played yet when they
    /// were flushed. Returns [] while the thread is still running.
    func unplayedPayloads(fromFrame frame: UInt64) -> [Data] {
        guard isFinished, mode == .play else { return [] }
        var out: [Data] = []
        // Recover the ring order: the oldest slot is the first non-nil one after the newest.
        var packets: [AudioPacket] = []
        for i in 0..<ringCapacity { if let p = ring[i] { packets.append(p) } }
        packets.sort { $0.firstFrame < $1.firstFrame }
        for p in packets where p.firstFrame >= frame { out.append(p.samples) }
        if prerollConsumed < preroll.count { out.append(contentsOf: preroll[prerollConsumed...]) }
        return out
    }

    /// Takes (and resets) the meter accumulated since the previous call.
    func takeMeter() -> MeterAccumulator {
        meter.withLockUnchecked { acc in
            let out = acc
            let end = acc.endFrame
            acc = MeterAccumulator()
            acc.endFrame = end
            return out
        }
    }

    /// Waits (bounded) until the pacer thread has adopted plan `version`, i.e. it will never
    /// touch sinks that are absent from that plan again.
    func waitUntilObserved(_ version: UInt64, timeoutNanos: UInt64 = 200_000_000) async {
        let deadline = HostClock.nowNanos() + timeoutNanos
        while observedPlanVersion < version && !isFinished && HostClock.nowNanos() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: Pacer thread

    static func promoteCurrentThreadToRealtime() -> Bool {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(HostClock.hostTicks(fromNanos: PacingSchedule.packetNanos)),
            computation: UInt32(HostClock.hostTicks(fromNanos: 1_500_000)),
            constraint: UInt32(HostClock.hostTicks(fromNanos: 4_000_000)),
            preemptible: 1
        )
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return kr == KERN_SUCCESS
    }

    private func threadMain() {
        let realtime = options.realtime ? Self.promoteCurrentThreadToRealtime() : false

        let frames = PCM.framesPerPacket
        let samplesPerPacket = frames * PCM.channels
        var schedule = PacingSchedule(timeline: timeline, startFrame: startFrame,
                                      maxBurst: options.maxBurstPackets,
                                      minDeliveryLeadNanos: options.minDeliveryLeadNanos)
        var plan: RenderPlan = shared.withLockUnchecked { $0.plan }
        // Sinks already in the first plan this thread sees receive everything live; they must not
        // be "backfilled" again when the next plan arrives (that duplicated packets when a sink
        // joined between the run's creation and the thread's first line).
        var adoptedVersion: UInt64 = plan.version
        var burst = 0
        var stats = PacerStatistics()
        stats.realtimePolicyApplied = realtime
        var latenessSum: Double = 0
        var workSum: Double = 0
        var pendingMeter = MeterAccumulator()
        var ringHead = 0   // next write slot
        var ringCount = 0
        var prerollIndex = 0
        var reason = EndReason.stopped
        var endFrame = startFrame
        let isPlay = mode == .play

        loop: while true {
            // 1. Sync with the control side without ever waiting for it.
            var stop = false
            var newPlan: RenderPlan?
            _ = shared.withLockIfAvailableUnchecked { s in
                stop = s.stopRequested
                if s.plan !== plan { newPlan = s.plan }
                s.observedVersion = (newPlan ?? plan).version
                s.stats = stats
            }
            if stop { break loop }
            if let p = newPlan {
                if isPlay && options.backfill && ringCount > 0 {
                    backfill(plan: p, since: adoptedVersion, ringHead: ringHead, ringCount: ringCount, stats: &stats)
                }
                adoptedVersion = p.version
                plan = p
            }

            // 2. Pace.
            let now = HostClock.nowNanos()
            switch schedule.step(now: now, burstSoFar: burst) {
            case .sleep(let until):
                // Never sleep longer than ~a packet so stop requests are honoured promptly.
                let capped = min(until, now + PacingSchedule.packetNanos * 2)
                mach_wait_until(HostClock.hostTicks(fromNanos: capped))
                burst = 0

            case .skip(let count):
                stats.packetsSkipped += count

            case .emit(let frame, let deadline):
                let got: Int?
                if isPlay && prerollIndex < preroll.count {
                    // Retained audio first (a copy into the preallocated buffer, no allocation).
                    let payload = preroll[prerollIndex]
                    let bytes = samplesPerPacket * MemoryLayout<Int16>.size
                    payload.withUnsafeBytes { raw in
                        UnsafeMutableRawPointer(buffer).copyMemory(from: raw.baseAddress!, byteCount: min(raw.count, bytes))
                    }
                    prerollIndex += 1
                    stats.packetsReplayed += 1
                    got = frames
                } else {
                    got = source.read(into: buffer, frameCount: frames)
                }
                guard let produced = got else {
                    reason = .endOfStream
                    endFrame = frame
                    break loop
                }
                let n = min(max(produced, 0), frames)
                if n < frames {
                    (buffer + n * PCM.channels).update(repeating: 0, count: (frames - n) * PCM.channels)
                    stats.framesPadded += UInt64(frames - n)
                }
                endFrame = frame + UInt64(frames)
                burst += 1
                let lateness = now - deadline
                stats.packetsEmitted += 1
                latenessSum += Double(lateness)
                stats.meanLatenessNanos = latenessSum / Double(stats.packetsEmitted)
                if lateness > stats.maxLatenessNanos { stats.maxLatenessNanos = lateness }
                if burst > stats.maxBurst { stats.maxBurst = burst }
                guard isPlay else { continue loop }

                // Metering: a few µs of vDSP; result crosses threads via try-lock only.
                MeterMath.measure(buffer, frames: frames, scratch: scratch, into: &pendingMeter)
                pendingMeter.endFrame = endFrame
                let merged: Bool? = meter.withLockIfAvailableUnchecked { acc -> Bool in
                    acc.merge(pendingMeter)
                    return true
                }
                if merged != nil { pendingMeter = MeterAccumulator() }

                // One small heap block per packet: AudioPacket's payload is `Data` (contract).
                let packet = AudioPacket(firstFrame: frame,
                                         samples: Data(bytes: buffer, count: samplesPerPacket * MemoryLayout<Int16>.size))
                do {
                    ring[ringHead] = packet
                    ringHead = (ringHead + 1) % ringCapacity
                    if ringCount < ringCapacity { ringCount += 1 }
                }
                for sink in plan.sinks {
                    sink.enqueue(packet)
                }
                let work = HostClock.nowNanos() - now
                workSum += Double(work)
                stats.meanWorkNanos = workSum / Double(stats.packetsEmitted)
                if work > stats.maxWorkNanos { stats.maxWorkNanos = work }
            }
        }

        shared.withLockUnchecked { $0.stats = stats }
        prerollConsumed = prerollIndex
        let result = Result(reason: reason, nextFrame: endFrame)
        let waiters: [CheckedContinuation<Result, Never>] = finish.withLockUnchecked { state in
            state.result = result
            let w = state.waiters
            state.waiters = []
            return w
        }
        for w in waiters { w.resume(returning: result) }
        onEnd(self, result)
    }

    /// Late joiners get the already-emitted packets that are still far enough in the future,
    /// oldest first, before the next live packet. Runs on the pacer thread so per-sink order holds.
    private func backfill(plan: RenderPlan, since: UInt64, ringHead: Int, ringCount: Int, stats: inout PacerStatistics) {
        let earliestPlayout = HostClock.nowNanos() + options.minDeliveryLeadNanos
        for i in 0..<plan.sinks.count where plan.joinVersions[i] > since {
            let sink = plan.sinks[i]
            var index = (ringHead - ringCount + ringCapacity) % ringCapacity
            for _ in 0..<ringCount {
                if let packet = ring[index],
                   TimelineMath.playoutHostNanos(timeline, forFrame: packet.firstFrame) >= earliestPlayout {
                    sink.enqueue(packet)
                    stats.packetsBackfilled += 1
                }
                index = (index + 1) % ringCapacity
            }
        }
    }
}
