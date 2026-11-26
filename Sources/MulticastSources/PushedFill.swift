import Foundation
import MulticastAudio

/// Decides, pull by pull, how a live source fed in bursts hands audio to the engine.
///
/// A pushed source (a ReplayKit broadcast, say) receives audio in chunks of whatever size the
/// system chooses, on the capture device's clock; the engine pulls 352 frames at a time on the
/// host clock. This keeps a cushion between the two and steers it:
///
/// - **Priming.** Nothing is delivered until the ring holds `primeLevel` frames (a safety
///   margin plus one chunk), so the first chunk boundary cannot starve the engine.
/// - **Underrun.** When the ring runs dry the pull returns what is left (the engine pads the
///   rest with silence) and the controller primes again. A gap in capture becomes a gap in
///   playback, not a stutter.
/// - **Drift.** The lowest fill level seen over each window is compared with the safety margin.
///   Too high (capture clock fast) and one frame is dropped per pull; too low and one is
///   repeated, until a later window is back in range. At 352-frame pulls that is ±0.28 %.
/// - **Overrun.** If the ring is far above where it should ever be (the engine stalled, or a
///   burst arrived), the oldest audio is dropped down to the prime level in one step.
///
/// Pure value type with no clock: everything is counted in frames, so it is unit-tested.
public struct PushedFillController: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        /// Deliver nothing (priming, or the ring is empty).
        case wait
        /// Deliver `frames` frames.
        case read(frames: Int)
        /// Deliver `frames` frames and drop one more behind them.
        case readDroppingOne(frames: Int)
        /// Deliver `frames - 1` frames from the ring and repeat the last one.
        case readDuplicatingOne(frames: Int)
        /// Drop `drop` frames first, then deliver `frames`.
        case resync(drop: Int, frames: Int)
    }

    public enum Correction: Equatable, Sendable { case none, dropping, duplicating }

    /// The smallest cushion kept under the chunk troughs (50 ms).
    public var minimumSafetyFrames: Int
    /// The largest chunk size planned for (1 s); larger chunks are treated as this.
    public var maximumChunkFrames: Int
    /// How far above the expected peak the ring may get before the oldest audio is dropped.
    public var overrunHeadroomFrames: Int

    public private(set) var isPriming = true
    public private(set) var correction: Correction = .none
    private var windowMinimum = Int.max
    private var windowFrames = 0

    public init(minimumSafetyFrames: Int = PCM.sampleRate / 20,
                maximumChunkFrames: Int = PCM.sampleRate,
                overrunHeadroomFrames: Int = PCM.sampleRate / 2) {
        self.minimumSafetyFrames = minimumSafetyFrames
        self.maximumChunkFrames = maximumChunkFrames
        self.overrunHeadroomFrames = overrunHeadroomFrames
    }

    /// The cushion wanted under the troughs, for chunks of `chunkFrames`.
    public func safetyFrames(chunkFrames: Int) -> Int {
        max(minimumSafetyFrames, min(max(0, chunkFrames), maximumChunkFrames))
    }

    /// The fill level at which delivery starts.
    public func primeLevel(chunkFrames: Int) -> Int {
        safetyFrames(chunkFrames: chunkFrames) + min(max(0, chunkFrames), maximumChunkFrames)
    }

    /// The fill level above which the oldest audio is dropped.
    public func overrunLevel(chunkFrames: Int) -> Int {
        primeLevel(chunkFrames: chunkFrames) + min(max(0, chunkFrames), maximumChunkFrames) + overrunHeadroomFrames
    }

    /// Back to priming (after a flush or a restart).
    public mutating func reset() {
        isPriming = true
        correction = .none
        windowMinimum = .max
        windowFrames = 0
    }

    /// One engine pull: `available` frames are in the ring, `requested` are wanted, and the
    /// producer's recent chunks were about `chunkFrames` long.
    public mutating func decide(available: Int, requested: Int, chunkFrames: Int) -> Action {
        if requested <= 0 { return .read(frames: 0) }
        let prime = primeLevel(chunkFrames: chunkFrames)
        if isPriming {
            if available < prime { return .wait }
            isPriming = false
            correction = .none
            windowMinimum = .max
            windowFrames = 0
        }
        if available <= 0 {
            reset()
            return .wait
        }
        if available > overrunLevel(chunkFrames: chunkFrames) {
            let drop = available - prime
            correction = .none
            windowMinimum = .max
            windowFrames = 0
            return .resync(drop: drop, frames: min(requested, available - drop))
        }
        let n = min(requested, available)
        if n < requested {
            // The ring just ran dry: hand over the tail; the next pull finds it empty and primes.
            return .read(frames: n)
        }

        let after = available - n
        windowMinimum = min(windowMinimum, after)
        windowFrames += n
        let safety = safetyFrames(chunkFrames: chunkFrames)
        let window = max(PCM.sampleRate, 3 * min(max(0, chunkFrames), maximumChunkFrames))
        if windowFrames >= window {
            let tolerance = max(safety / 2, PCM.sampleRate / 100)
            if windowMinimum > safety + tolerance {
                correction = .dropping
            } else if windowMinimum < safety - tolerance {
                correction = .duplicating
            } else {
                correction = .none
            }
            windowMinimum = .max
            windowFrames = 0
        }
        switch correction {
        case .dropping where after >= 1: return .readDroppingOne(frames: n)
        case .duplicating where n >= 2: return .readDuplicatingOne(frames: n)
        default: return .read(frames: n)
        }
    }
}
