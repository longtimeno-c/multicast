import Foundation
import MulticastAudio
import AudioToolbox
import CoreAudio

/// Platform-independent real-time renderer shared by the macOS AUHAL sink and the iOS
/// AVAudioEngine sink.
///
/// Threads:
/// - control thread (sink methods): `setTimeline`, `setActive`, latency / offset / gain setters,
///   `resetForStart` (only while the IO is stopped), `snapshotStats`.
/// - producer (engine pacing thread): `write(packet:)` — lock-free ring write.
/// - IO thread: `render(...)` — reads atomics, never blocks, never allocates, never logs.
final class RenderCore: @unchecked Sendable {
    let ring: TimelineRingBuffer
    /// Largest callback (in pipeline frames) the preallocated scratch space supports.
    let maxFrames: Int
    /// Crossfade length for cursor jumps (frames).
    let crossfadeFrames: Int

    // MARK: Control → IO (atomics)

    private let tlSeq = AtomicU64(0)
    private let tlAnchorHost = AtomicU64(0)
    private let tlAnchorFrame = AtomicU64(0)
    private let tlLatency = AtomicU64(0)
    private let tlGeneration = AtomicU64(0)
    private let activeFlag = AtomicU64(0)
    private let outputLatencyNanos = AtomicU64(0)
    private let offsetNanosBits = AtomicU64(0)
    private let gainTargetBits = AtomicU64(UInt64(Float(1).bitPattern))

    // MARK: IO → control (stats atomics)

    private let statCallbacks = AtomicU64(0)
    private let statLastError = AtomicU64(0)
    private let statFiltered = AtomicU64(0)
    private let statRatio = AtomicU64((1.0).bitPattern)
    private let statJumps = AtomicU64(0)
    private let statUnderrun = AtomicU64(0)
    private let statExtrapolated = AtomicU64(0)
    private let statOversized = AtomicU64(0)
    private let statReadFrame = AtomicU64(0)

    // MARK: IO-thread private state

    private var rtTimeline: StreamTimeline?
    private var rtGeneration: UInt64 = .max
    private var readPos: Double = 0
    private var locked = false
    private var corrector = DriftCorrector()
    private var gain = GainRamp(initial: 0)
    private var lastHostNanos: UInt64 = 0
    private var lastFrames: Int = 0
    private var wasAudible = false
    private var hasSeenAudio = false
    private var xfadeOldPos: Double = 0
    private var xfadeRemaining = 0
    private var callbackCount: UInt64 = 0
    private var lastOutL: Float = 0
    private var lastOutR: Float = 0
    private let declickFrames = 64

    private let scratchIn: UnsafeMutablePointer<Float>
    private let scratchOldIn: UnsafeMutablePointer<Float>
    private let oldOut: UnsafeMutablePointer<Float>
    private let mixOut: UnsafeMutablePointer<Float>
    private let scratchFrames: Int

    init(ringFrames: Int = 1 << 18, maxFrames: Int = 8192, crossfadeFrames: Int = 128) {
        ring = TimelineRingBuffer(minimumFrames: ringFrames)
        self.maxFrames = maxFrames
        self.crossfadeFrames = max(1, crossfadeFrames)
        // Varispeed reads at most maxFrames * (1 + 0.001) + interpolation taps.
        scratchFrames = maxFrames + maxFrames / 256 + 16
        scratchIn = .allocate(capacity: scratchFrames * PCM.channels)
        scratchOldIn = .allocate(capacity: scratchFrames * PCM.channels)
        oldOut = .allocate(capacity: maxFrames * PCM.channels)
        mixOut = .allocate(capacity: maxFrames * PCM.channels)
        scratchIn.initialize(repeating: 0, count: scratchFrames * PCM.channels)
        scratchOldIn.initialize(repeating: 0, count: scratchFrames * PCM.channels)
        oldOut.initialize(repeating: 0, count: maxFrames * PCM.channels)
        mixOut.initialize(repeating: 0, count: maxFrames * PCM.channels)
    }

    deinit {
        scratchIn.deallocate()
        scratchOldIn.deallocate()
        oldOut.deallocate()
        mixOut.deallocate()
    }

    // MARK: Capacity

    /// Headroom kept free in the ring beyond one latency: catch-up bursts (up to 8 packets),
    /// the reader's interpolation taps and scheduling jitter.
    static let ringMarginFrames = 11_025

    /// The engine delivers packets ~`latencyNanos` before they are due and the IO thread reads them
    /// just before they are due, so the producer leads the reader by up to one latency. If that
    /// lead approaches the ring size the producer laps the reader and the output reads silence.
    static func ringCanHold(latencyNanos: UInt64, capacityFrames: Int) -> Bool {
        let latencyFrames = latencyNanos / 1_000_000_000 * UInt64(PCM.sampleRate)
            + (latencyNanos % 1_000_000_000) * UInt64(PCM.sampleRate) / 1_000_000_000
        return latencyFrames + UInt64(ringMarginFrames) <= UInt64(max(0, capacityFrames))
    }

    /// Largest group latency (ms) this core's ring supports.
    var maxLatencyMillis: Int {
        max(0, (ring.capacityFrames - Self.ringMarginFrames) * 1000 / PCM.sampleRate)
    }

    /// Throws `latencyTooLarge` when `timeline`'s latency does not fit the ring.
    func checkCapacity(for timeline: StreamTimeline) throws {
        guard Self.ringCanHold(latencyNanos: timeline.latencyNanos, capacityFrames: ring.capacityFrames) else {
            throw LocalOutputError.latencyTooLarge(latencyMillis: Int(timeline.latencyNanos / 1_000_000),
                                                   maxMillis: maxLatencyMillis)
        }
    }

    // MARK: Control API

    /// Publish a new timeline (seqlock; one control writer at a time).
    func setTimeline(_ t: StreamTimeline) {
        tlSeq.add(1) // odd: write in progress
        fenceRelease()
        tlAnchorHost.store(t.anchorHostNanos, release: false)
        tlAnchorFrame.store(t.anchorFrame, release: false)
        tlLatency.store(t.latencyNanos, release: false)
        tlSeq.add(1) // even: stable
        tlGeneration.add(1)
    }

    func setActive(_ on: Bool) { activeFlag.store(on ? 1 : 0) }
    var isActive: Bool { activeFlag.load() != 0 }

    func setOutputLatency(nanos: UInt64) { outputLatencyNanos.store(nanos) }
    var outputLatency: UInt64 { outputLatencyNanos.load() }

    func setOffset(millis: Int) { offsetNanosBits.store(int64: Int64(millis) * 1_000_000) }
    var offsetNanos: Int64 { offsetNanosBits.loadInt64() }

    /// Linear amplitude target; the IO thread ramps towards it.
    func setGainTarget(_ amplitude: Float) { gainTargetBits.store(UInt64(amplitude.bitPattern)) }

    /// Reset IO-private state. Call only while the IO is NOT running.
    func resetForStart() {
        rtTimeline = nil
        rtGeneration = .max
        readPos = 0
        locked = false
        corrector.reset()
        gain.snap(to: 0)
        lastHostNanos = 0
        lastFrames = 0
        wasAudible = false
        hasSeenAudio = false
        xfadeRemaining = 0
        callbackCount = 0
        lastOutL = 0
        lastOutR = 0
        statCallbacks.store(0); statLastError.store(double: 0); statFiltered.store(double: 0)
        statRatio.store(double: 1); statJumps.store(0); statUnderrun.store(0)
        statExtrapolated.store(0); statOversized.store(0); statReadFrame.store(double: 0)
        ring.clearReaderPosition()
    }

    func snapshotStats() -> LocalOutputSyncStats {
        LocalOutputSyncStats(
            callbacks: statCallbacks.load(),
            lastErrorFrames: statLastError.loadDouble(),
            filteredErrorFrames: statFiltered.loadDouble(),
            ratio: statRatio.loadDouble(),
            jumps: statJumps.load(),
            underrunFrames: statUnderrun.load(),
            overrunWrites: ring.overrunWrites.load(),
            extrapolatedTimestamps: statExtrapolated.load(),
            oversizedCallbacks: statOversized.load(),
            readFrame: statReadFrame.loadDouble()
        )
    }

    // MARK: Producer

    @inline(__always)
    func write(packet: AudioPacket) {
        packet.samples.withUnsafeBytes { raw in
            _ = ring.write(firstFrame: packet.firstFrame, samples: raw)
        }
    }

    // MARK: IO thread

    private func loadTimeline() -> StreamTimeline? {
        for _ in 0..<4 {
            let s1 = tlSeq.load()
            if s1 & 1 == 1 { continue }
            let host = tlAnchorHost.load(acquire: false)
            let frame = tlAnchorFrame.load(acquire: false)
            let lat = tlLatency.load(acquire: false)
            fenceAcquire()
            let s2 = tlSeq.load(acquire: false)
            if s1 == s2 {
                return StreamTimeline(anchorHostNanos: host, anchorFrame: frame, latencyNanos: lat)
            }
        }
        return nil
    }

    /// Render `frames` frames of interleaved Float32 stereo into `out`.
    /// - Parameter hostNanos: the callback's `mHostTime` in ns, or nil when the timestamp has none.
    /// - Returns: true if the whole buffer is silence.
    func render(hostNanos: UInt64?, frames n: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        callbackCount &+= 1
        statCallbacks.store(callbackCount, release: false)

        let t: UInt64
        if let h = hostNanos, h != 0 {
            t = h
        } else {
            statExtrapolated.add(1)
            t = lastHostNanos != 0 ? lastHostNanos &+ PCM.nanos(forFrames: UInt64(lastFrames)) : HostClock.nowNanos()
        }
        lastHostNanos = t
        lastFrames = n

        if n > maxFrames {
            statOversized.add(1)
            out.update(repeating: 0, count: n * PCM.channels)
            locked = false
            return true
        }

        guard activeFlag.load() != 0 else {
            out.update(repeating: 0, count: n * PCM.channels)
            locked = false
            wasAudible = false
            ring.clearReaderPosition()
            return true
        }

        let gen = tlGeneration.load()
        if gen != rtGeneration, let tl = loadTimeline() {
            rtTimeline = tl
            rtGeneration = gen
            // A new timeline re-labels every frame, so a crossfade from the old cursor would read
            // unrelated audio: lock on afresh (with the lock-on fade-in) instead.
            locked = false
        }
        guard let timeline = rtTimeline else {
            out.update(repeating: 0, count: n * PCM.channels)
            return true
        }

        let ideal = PlayoutClock.frameToRender(
            timeline: timeline,
            callbackHostNanos: t,
            outputLatencyNanos: outputLatencyNanos.load(acquire: false),
            offsetNanos: Int64(bitPattern: offsetNanosBits.load(acquire: false))
        )
        let targetGain = Float(bitPattern: UInt32(truncatingIfNeeded: gainTargetBits.load(acquire: false)))

        var ratio = 1.0
        if !locked {
            readPos = ideal.rounded()
            corrector.reset()
            gain.snap(to: 0) // fade in on lock-on (joining mid-stream never clicks)
            locked = true
            hasSeenAudio = false
            statLastError.store(double: 0, release: false)
        } else {
            let err = readPos - ideal
            statLastError.store(double: err, release: false)
            let decision = corrector.update(errorFrames: err, callbackFrames: n)
            switch decision {
            case .jump:
                if wasAudible {
                    xfadeOldPos = readPos
                    xfadeRemaining = crossfadeFrames
                }
                readPos = ideal.rounded()
                statJumps.add(1)
            case .rate(let r):
                ratio = r
            }
        }
        gain.setTarget(targetGain)

        let valid = renderSpan(start: readPos, ratio: ratio, frames: n, scratch: scratchIn, into: out)

        if xfadeRemaining > 0 {
            let m = min(n, xfadeRemaining)
            _ = renderSpan(start: xfadeOldPos, ratio: 1, frames: m, scratch: scratchOldIn, into: oldOut)
            let len = Float(crossfadeFrames)
            for i in 0..<m {
                let wOld = Float(xfadeRemaining - i) / len
                let wNew = 1 - wOld
                out[2 * i] = out[2 * i] * wNew + oldOut[2 * i] * wOld
                out[2 * i + 1] = out[2 * i + 1] * wNew + oldOut[2 * i + 1] * wOld
            }
            xfadeOldPos += Double(m)
            xfadeRemaining -= m
        }

        // Declick: audio stopped abruptly (flush / underrun) -> decay the last sample to 0.
        var declicked = false
        if wasAudible && valid == 0 && xfadeRemaining == 0 {
            let m = min(n, declickFrames)
            let len = Float(declickFrames)
            for i in 0..<m {
                let w = Float(declickFrames - 1 - i) / len
                out[2 * i] = lastOutL * w
                out[2 * i + 1] = lastOutR * w
            }
            declicked = true
        }
        if n > 0 {
            lastOutL = out[2 * (n - 1)]
            lastOutR = out[2 * (n - 1) + 1]
        }

        for i in 0..<n {
            let g = gain.next()
            out[2 * i] *= g
            out[2 * i + 1] *= g
        }

        // A flush empties the ring on purpose (a source switch or seek drops what was queued
        // and the new audio is heard one group latency later): that silence is not an underrun.
        if ring.isResetPending { hasSeenAudio = false }
        if hasSeenAudio && valid < n {
            statUnderrun.add(UInt64(n - valid))
        }
        if valid > 0 { hasSeenAudio = true }
        wasAudible = valid > 0

        readPos += ratio * Double(n)
        ring.setReaderPosition(Int64(readPos.rounded(.down)))
        statRatio.store(double: ratio)
        statFiltered.store(double: corrector.filteredError)
        statReadFrame.store(double: readPos)
        return valid == 0 && xfadeRemaining == 0 && !declicked
    }

    /// Render into an audio buffer list of any Float32 layout (interleaved or planar).
    func render(hostNanos: UInt64?, frames n: Int, abl: UnsafeMutableAudioBufferListPointer) -> Bool {
        if n > maxFrames {
            statOversized.add(1)
            locked = false
            for b in 0..<abl.count {
                if let d = abl[b].mData { memset(d, 0, Int(abl[b].mDataByteSize)) }
            }
            return true
        }
        let silent = render(hostNanos: hostNanos, frames: n, into: mixOut)
        copyInterleavedStereo(mixOut, frames: n, to: abl)
        return silent
    }

    /// Render `n` output frames reading the ring from fractional frame `start` at `ratio` input
    /// frames per output frame. Returns how many input frames read were real audio (approx.).
    private func renderSpan(
        start: Double, ratio: Double, frames n: Int,
        scratch: UnsafeMutablePointer<Float>, into out: UnsafeMutablePointer<Float>
    ) -> Int {
        let floorStart = start.rounded(.down)
        if ratio == 1, floorStart == start {
            return ring.read(from: Int64(floorStart), count: n, into: out)
        }
        let base = Int64(floorStart) - 1
        let lastPos = start + ratio * Double(n - 1)
        let count = Int(Int64(lastPos.rounded(.down)) - base + 3)
        guard count <= scratchFrames else {
            out.update(repeating: 0, count: n * PCM.channels)
            return 0
        }
        let valid = ring.read(from: base, count: count, into: scratch)
        for i in 0..<n {
            let p = start + ratio * Double(i)
            let fp = p.rounded(.down)
            let idx = Int(Int64(fp) - base) // index of y0
            let tt = Float(p - fp)
            let k = idx * 2
            out[2 * i] = hermite(scratch[k - 2], scratch[k], scratch[k + 2], scratch[k + 4], tt)
            out[2 * i + 1] = hermite(scratch[k - 1], scratch[k + 1], scratch[k + 3], scratch[k + 5], tt)
        }
        return min(n, valid)
    }
}

/// Copy interleaved stereo Float32 into whatever layout the output buffer list has.
@inline(__always)
func copyInterleavedStereo(_ src: UnsafePointer<Float>, frames n: Int, to abl: UnsafeMutableAudioBufferListPointer) {
    if abl.count == 1 {
        let buf = abl[0]
        guard let data = buf.mData else { return }
        let ch = Int(buf.mNumberChannels)
        let dst = data.assumingMemoryBound(to: Float.self)
        let capacity = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        if ch == 2 {
            let m = min(n * 2, capacity)
            dst.update(from: src, count: m)
        } else if ch == 1 {
            let m = min(n, capacity)
            for i in 0..<m { dst[i] = 0.5 * (src[2 * i] + src[2 * i + 1]) }
        } else if ch > 2 {
            let m = min(n, capacity / ch)
            for i in 0..<m {
                dst[i * ch] = src[2 * i]
                dst[i * ch + 1] = src[2 * i + 1]
                for c in 2..<ch { dst[i * ch + c] = 0 }
            }
        }
    } else {
        for b in 0..<abl.count {
            let buf = abl[b]
            guard let data = buf.mData else { continue }
            let dst = data.assumingMemoryBound(to: Float.self)
            let m = min(n, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            if b < 2 {
                for i in 0..<m { dst[i] = src[2 * i + b] }
            } else {
                dst.update(repeating: 0, count: m)
            }
        }
    }
}
