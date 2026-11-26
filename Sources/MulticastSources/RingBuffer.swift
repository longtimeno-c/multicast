import Foundation

/// Lock-free single-producer / single-consumer ring buffer of interleaved audio frames.
///
/// - Exactly one thread may call the producer methods (`write`, `withWritableRegions`) and
///   exactly one thread the consumer methods (`read`, `skip`, `discardAll`, `skip(toCount:)`);
///   the two may be different threads and run concurrently. The `available*` queries are safe
///   from any thread (they return a snapshot).
/// - No locks, no allocation after `init`: safe for real-time audio threads.
/// - Positions are kept as monotonically increasing 64-bit frame counters (`writeCount`,
///   `readCount`), so callers can reason about absolute stream positions.
public final class SPSCRingBuffer<Sample: BitwiseCopyable>: @unchecked Sendable {
    public let channels: Int
    /// Capacity in frames (a power of two, at least the requested capacity).
    public let capacityFrames: Int

    private let mask: Int64
    private let storage: UnsafeMutablePointer<Sample>
    private let writeCounter = AtomicInt64(0)
    private let readCounter = AtomicInt64(0)

    public init(capacityFrames requested: Int, channels: Int) {
        precondition(requested > 0 && channels > 0)
        var cap = 1
        while cap < requested { cap <<= 1 }
        self.capacityFrames = cap
        self.channels = channels
        self.mask = Int64(cap - 1)
        let count = cap * channels
        storage = UnsafeMutablePointer<Sample>.allocate(capacity: count)
        storage.withMemoryRebound(to: UInt8.self, capacity: count * MemoryLayout<Sample>.stride) {
            $0.initialize(repeating: 0, count: count * MemoryLayout<Sample>.stride)
        }
    }

    deinit {
        storage.deallocate()
    }

    /// Total frames ever written.
    public var writeCount: Int64 { writeCounter.load() }
    /// Total frames ever consumed (read or skipped).
    public var readCount: Int64 { readCounter.load() }

    public var availableToRead: Int {
        let r = readCounter.load()
        let w = writeCounter.load()
        return Int(max(0, w - r))
    }

    public var availableToWrite: Int {
        let w = writeCounter.load()
        let r = readCounter.load()
        return capacityFrames - Int(max(0, w - r))
    }

    // MARK: Producer

    /// Copies up to `frames` frames from `source`; returns the number of frames written.
    @discardableResult
    public func write(_ source: UnsafePointer<Sample>, frames: Int) -> Int {
        withWritableRegions(maxFrames: frames) { dst, count, offset in
            dst.update(from: source + offset * channels, count: count * channels)
        }
    }

    /// Exposes up to two contiguous writable regions (to cover wrap-around) totalling at most
    /// `maxFrames` frames, then publishes them. `body(destination, frameCount, framesAlreadyGiven)`.
    /// Returns the number of frames published.
    @discardableResult
    public func withWritableRegions(
        maxFrames: Int,
        _ body: (UnsafeMutablePointer<Sample>, Int, Int) -> Void
    ) -> Int {
        let w = writeCounter.load()
        let r = readCounter.load()
        let free = capacityFrames - Int(w - r)
        let n = min(max(0, maxFrames), free)
        if n == 0 { return 0 }
        let start = Int(w & mask)
        let first = min(n, capacityFrames - start)
        body(storage + start * channels, first, 0)
        if n > first {
            body(storage, n - first, first)
        }
        writeCounter.add(Int64(n)) // full barrier: data is visible before the new count
        return n
    }

    // MARK: Consumer

    /// Copies up to `frames` frames into `destination`; returns the number of frames read.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Sample>, frames: Int) -> Int {
        let r = readCounter.load()
        let w = writeCounter.load()
        let n = min(max(0, frames), Int(w - r))
        if n == 0 { return 0 }
        let start = Int(r & mask)
        let first = min(n, capacityFrames - start)
        destination.update(from: storage + start * channels, count: first * channels)
        if n > first {
            (destination + first * channels).update(from: storage, count: (n - first) * channels)
        }
        readCounter.add(Int64(n)) // full barrier: copy completes before the slot is released
        return n
    }

    /// Copies the most recently read frame (or zeros if nothing was ever read) into `destination`.
    /// Consumer only. Used for drift correction (frame duplication).
    public func copyLastReadFrame(into destination: UnsafeMutablePointer<Sample>) {
        let r = readCounter.load()
        if r == 0 {
            destination.withMemoryRebound(to: UInt8.self, capacity: channels * MemoryLayout<Sample>.stride) {
                $0.initialize(repeating: 0, count: channels * MemoryLayout<Sample>.stride)
            }
            return
        }
        // The slot of frame r-1 may already be overwritten by the producer if the ring is full;
        // callers only use this when the ring is far from full.
        let idx = Int((r - 1) & mask)
        destination.update(from: storage + idx * channels, count: channels)
    }

    /// Drops up to `frames` frames; returns the number dropped.
    @discardableResult
    public func skip(frames: Int) -> Int {
        let r = readCounter.load()
        let w = writeCounter.load()
        let n = min(max(0, frames), Int(w - r))
        if n > 0 { readCounter.add(Int64(n)) }
        return n
    }

    /// Advances the read position to absolute frame counter `target` (clamped to what has been
    /// written). No-op if already past it. Returns the number of frames dropped.
    @discardableResult
    public func skip(toCount target: Int64) -> Int {
        let r = readCounter.load()
        let w = writeCounter.load()
        let t = min(target, w)
        if t <= r { return 0 }
        readCounter.add(t - r)
        return Int(t - r)
    }

    /// Drops everything currently buffered.
    @discardableResult
    public func discardAll() -> Int {
        skip(toCount: writeCounter.load())
    }
}

/// The pipeline ring: interleaved S16 stereo at 44.1 kHz.
public typealias PCMRingBuffer = SPSCRingBuffer<Int16>
