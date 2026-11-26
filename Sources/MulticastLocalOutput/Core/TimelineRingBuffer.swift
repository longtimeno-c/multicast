import Foundation
import MulticastAudio

/// Lock-free single-producer / single-consumer ring of pipeline-format audio (S16 stereo),
/// indexed by **timeline frame** rather than by a free-running write cursor.
///
/// - The producer (engine pacing thread) calls `write(firstFrame:samples:)` in timeline order.
///   Frame `F` is stored in slot `F & mask`, so the consumer can ask for any frame range directly.
/// - The consumer (audio IO thread) calls `read(from:count:into:)`, which fills frames that are
///   not available (before the stream started, not yet written = underrun, already overwritten,
///   or torn by a concurrent overwrite) with silence and reports how many frames were real.
/// - Any third thread may call `requestReset()` (flush). The reset is carried out by the producer
///   on its next write; until then the consumer sees an empty ring. This keeps the structure
///   strictly single-producer.
///
/// Overrun policy: the newest data always wins. If the producer laps the consumer, the oldest
/// frames are overwritten and the consumer reads them as silence (seqlock-style validation with
/// the `reserve` word guarantees it never plays a half-overwritten slot).
final class TimelineRingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let capacity: Int64
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Int16>

    // Written by the producer only.
    private let start = AtomicU64(0)
    private let end = AtomicU64(0)
    private let reserve = AtomicU64(0)
    private let ackedReset = AtomicU64(0)
    // Written by any control thread.
    private let resetRequests = AtomicU64(0)
    // Written by the consumer only.
    private let readerPosition = AtomicU64(TimelineRingBuffer.noReader)
    static let noReader = UInt64.max

    // Producer-private state (only touched inside `write`).
    private var producerEpoch: UInt64 = 0
    private var producerHasData = false
    private var producerEnd: UInt64 = 0

    // Statistics (producer-written counters).
    let overrunWrites = AtomicU64(0)
    let discontinuities = AtomicU64(0)
    let gapFrames = AtomicU64(0)

    /// - Parameter minimumFrames: rounded up to a power of two.
    init(minimumFrames: Int) {
        precondition(minimumFrames > 0)
        var cap = 1
        while cap < minimumFrames { cap <<= 1 }
        capacityFrames = cap
        capacity = Int64(cap)
        mask = UInt64(cap - 1)
        storage = .allocate(capacity: cap * PCM.channels)
        storage.initialize(repeating: 0, count: cap * PCM.channels)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Control

    /// Drop everything. Safe from any thread; takes effect on the producer's next write, and the
    /// consumer sees an empty ring immediately.
    func requestReset() {
        resetRequests.add(1)
    }

    // MARK: Producer

    enum WriteResult: Equatable {
        case appended
        /// The ring was (re)started at this packet (first write, after a reset, or a discontinuity).
        case restarted
        /// Written, but it overwrote frames the consumer had not reached yet.
        case overran
    }

    /// Write interleaved S16LE stereo frames whose first frame is `firstFrame`. Never blocks,
    /// never allocates. Gaps since the previous write (shorter than the capacity) are zero-filled.
    @discardableResult
    func write(firstFrame: UInt64, samples: UnsafeRawBufferPointer) -> WriteResult {
        let frames = samples.count / PCM.bytesPerFrame
        guard frames > 0 else { return .appended }
        var result = WriteResult.appended

        let req = resetRequests.load()
        if req != producerEpoch || !producerHasData || firstFrame < producerEnd
            || firstFrame - producerEnd >= UInt64(capacity) {
            if producerHasData && req == producerEpoch { discontinuities.add(1) }
            // Publish an empty ring starting at `firstFrame`, then acknowledge the reset.
            reserve.store(firstFrame)
            start.store(firstFrame)
            end.store(firstFrame)
            ackedReset.store(req)
            producerEpoch = req
            producerHasData = true
            producerEnd = firstFrame
            result = .restarted
        }

        let gap = firstFrame - producerEnd
        let newEnd = firstFrame + UInt64(frames)

        let reader = readerPosition.load(acquire: false)
        if reader != TimelineRingBuffer.noReader, newEnd > reader &+ UInt64(capacity) {
            overrunWrites.add(1)
            if result == .appended { result = .overran }
        }

        // Announce the range about to be overwritten before touching the slots.
        reserve.store(newEnd, release: false)
        fenceRelease()

        if gap > 0 {
            gapFrames.add(gap)
            fillZero(fromFrame: producerEnd, count: Int(gap))
        }
        copyIn(fromFrame: firstFrame, samples: samples, frames: frames)

        end.store(newEnd)
        producerEnd = newEnd
        return result
    }

    private func fillZero(fromFrame frame: UInt64, count: Int) {
        var remaining = count
        var f = frame
        while remaining > 0 {
            let slot = Int(f & mask)
            let n = min(remaining, capacityFrames - slot)
            (storage + slot * PCM.channels).update(repeating: 0, count: n * PCM.channels)
            remaining -= n
            f += UInt64(n)
        }
    }

    private func copyIn(fromFrame frame: UInt64, samples: UnsafeRawBufferPointer, frames: Int) {
        guard let base = samples.baseAddress else { return }
        var done = 0
        var f = frame
        while done < frames {
            let slot = Int(f & mask)
            let n = min(frames - done, capacityFrames - slot)
            let dst = storage + slot * PCM.channels
            let src = base + done * PCM.bytesPerFrame
            #if _endian(little)
            UnsafeMutableRawPointer(dst).copyMemory(from: src, byteCount: n * PCM.bytesPerFrame)
            #else
            for i in 0..<(n * PCM.channels) {
                dst[i] = Int16(littleEndian: src.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            }
            #endif
            done += n
            f += UInt64(n)
        }
    }

    // MARK: Consumer

    /// Publish where the consumer is reading (used for overrun accounting only).
    func setReaderPosition(_ frame: Int64) {
        readerPosition.store(frame < 0 ? 0 : UInt64(frame), release: false)
    }

    func clearReaderPosition() {
        readerPosition.store(TimelineRingBuffer.noReader, release: false)
    }

    /// Read `count` frames starting at timeline frame `frame` (may be negative = before the
    /// timeline origin) into `out` as interleaved Float32 stereo in -1…1. Unavailable frames are
    /// written as 0. Returns the number of frames that held real audio. Never blocks/allocates.
    func read(from frame: Int64, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard count > 0 else { return 0 }
        let req = resetRequests.load()
        let acked = ackedReset.load()
        if req != acked {
            out.update(repeating: 0, count: count * PCM.channels)
            return 0
        }
        let e = Int64(bitPattern: end.load())
        let s = Int64(bitPattern: start.load())
        let lo = max(s, e - capacity, frame)
        let hi = min(e, frame + Int64(count))
        if hi <= lo {
            out.update(repeating: 0, count: count * PCM.channels)
            return 0
        }
        let headZeros = Int(lo - frame)
        let validCount = Int(hi - lo)
        let tailZeros = count - headZeros - validCount
        if headZeros > 0 { out.update(repeating: 0, count: headZeros * PCM.channels) }
        if tailZeros > 0 { (out + (headZeros + validCount) * PCM.channels).update(repeating: 0, count: tailZeros * PCM.channels) }

        // Copy + convert.
        let scale: Float = 1.0 / 32768.0
        var f = UInt64(lo)
        var o = out + headZeros * PCM.channels
        var remaining = validCount
        while remaining > 0 {
            let slot = Int(f & mask)
            let n = min(remaining, capacityFrames - slot)
            let src = storage + slot * PCM.channels
            for i in 0..<(n * PCM.channels) { o[i] = Float(src[i]) * scale }
            o += n * PCM.channels
            remaining -= n
            f += UInt64(n)
        }

        // Validate: anything the producer started overwriting while we copied is torn.
        fenceAcquire()
        let req2 = resetRequests.load(acquire: false)
        if req2 != req {
            out.update(repeating: 0, count: count * PCM.channels)
            return 0
        }
        let safeLo = Int64(bitPattern: reserve.load(acquire: false)) - capacity
        if safeLo > lo {
            let tornEnd = min(safeLo, hi)
            let torn = Int(tornEnd - lo)
            (out + headZeros * PCM.channels).update(repeating: 0, count: torn * PCM.channels)
            return validCount - torn
        }
        return validCount
    }

    /// The currently readable frame range `[start, end)`, or nil if empty / reset pending.
    func readableRange() -> Range<Int64>? {
        if resetRequests.load() != ackedReset.load() { return nil }
        let e = Int64(bitPattern: end.load())
        let s = max(Int64(bitPattern: start.load()), e - capacity)
        return s < e ? s..<e : nil
    }
}
