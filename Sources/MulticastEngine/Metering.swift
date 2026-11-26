import Accelerate
import MulticastAudio

/// Running peak / sum-of-squares for both channels. Plain value type, merged across threads by copy.
struct MeterAccumulator: Sendable, Equatable {
    var peakLeft: Float = 0
    var peakRight: Float = 0
    var sumSquaresLeft: Double = 0
    var sumSquaresRight: Double = 0
    var frames: UInt64 = 0
    var endFrame: UInt64 = 0

    mutating func merge(_ other: MeterAccumulator) {
        peakLeft = max(peakLeft, other.peakLeft)
        peakRight = max(peakRight, other.peakRight)
        sumSquaresLeft += other.sumSquaresLeft
        sumSquaresRight += other.sumSquaresRight
        frames += other.frames
        endFrame = max(endFrame, other.endFrame)
    }

    var isEmpty: Bool { frames == 0 }

    func reading(audibleFrame: UInt64) -> MeterReading {
        let n = Double(max(frames, 1))
        return MeterReading(
            peakLeft: peakLeft,
            peakRight: peakRight,
            rmsLeft: Float((sumSquaresLeft / n).squareRoot()),
            rmsRight: Float((sumSquaresRight / n).squareRoot()),
            frame: endFrame,
            audibleFrame: audibleFrame
        )
    }
}

/// Measures interleaved S16 stereo with vDSP into a caller-owned scratch buffer (no allocation).
/// Cost for one 352-frame packet is a few microseconds; it runs on the pacer thread right after
/// the read, and only the merged result crosses threads (via try-lock), so the UI side never
/// touches the hot path.
enum MeterMath {
    /// `scratch` must hold at least `frames` floats.
    static func measure(_ samples: UnsafePointer<Int16>, frames: Int, scratch: UnsafeMutablePointer<Float>,
                        into acc: inout MeterAccumulator) {
        guard frames > 0 else { return }
        let n = vDSP_Length(frames)
        var scale: Float = 1.0 / 32768.0
        for channel in 0..<2 {
            vDSP_vflt16(samples + channel, 2, scratch, 1, n)
            vDSP_vsmul(scratch, 1, &scale, scratch, 1, n)
            var peak: Float = 0
            vDSP_maxmgv(scratch, 1, &peak, n)
            var sumSq: Float = 0
            vDSP_svesq(scratch, 1, &sumSq, n)
            if channel == 0 {
                acc.peakLeft = max(acc.peakLeft, peak)
                acc.sumSquaresLeft += Double(sumSq)
            } else {
                acc.peakRight = max(acc.peakRight, peak)
                acc.sumSquaresRight += Double(sumSq)
            }
        }
        acc.frames += UInt64(frames)
    }
}

/// Volume arithmetic shared by the engine and its tests.
enum VolumeMath {
    static func clamp(_ v: Float) -> Float {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }

    /// What gets pushed to the device.
    static func effective(sink: Float, master: Float, muted: Bool, enabled: Bool = true) -> Float {
        guard !muted, enabled else { return 0 }
        return clamp(sink) * clamp(master)
    }
}
