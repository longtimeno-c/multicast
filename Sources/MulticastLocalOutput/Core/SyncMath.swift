import Foundation
import MulticastAudio

// MARK: - Frame for host time

/// The timing math that turns an IO callback into "which timeline frame goes to the hardware now".
public enum PlayoutClock {
    /// Host time at which the first sample handed over in this callback leaves the loudspeaker.
    ///
    /// `callbackHostNanos` is the callback's `AudioTimeStamp.mHostTime` converted to nanoseconds
    /// (the HAL's output time for the buffer); `outputLatencyNanos` is everything after that point
    /// (device + stream latency + safety offset + converter latency, or iOS `outputLatency`).
    @inline(__always)
    public static func audibleHostNanos(callbackHostNanos: UInt64, outputLatencyNanos: UInt64) -> UInt64 {
        callbackHostNanos &+ outputLatencyNanos
    }

    /// The (fractional, possibly negative) timeline frame that must be handed to the hardware in a
    /// callback stamped `callbackHostNanos`, so that it becomes audible at its timeline playout
    /// time shifted by the user trim (`offsetNanos` > 0 plays later).
    ///
    /// frame F is due at `playout(F) + offset`. The sample written now is audible at
    /// `callback + latency`, so F = timeline.frame(at: callback + latency − offset).
    @inline(__always)
    public static func frameToRender(
        timeline: StreamTimeline,
        callbackHostNanos: UInt64,
        outputLatencyNanos: UInt64,
        offsetNanos: Int64
    ) -> Double {
        let audible = audibleHostNanos(callbackHostNanos: callbackHostNanos, outputLatencyNanos: outputLatencyNanos)
        let target = UInt64(bitPattern: Int64(bitPattern: audible) &- offsetNanos)
        return timeline.frame(atHostNanos: target)
    }
}

// MARK: - Drift corrector

/// Keeps the read cursor locked to the ideal timeline position.
///
/// Every callback it is told the error `read cursor − ideal frame` (in pipeline frames, positive
/// = we are ahead / playing too early) and returns either a playback-rate ratio very close to 1
/// (a proportional controller on a low-pass-filtered error, clamped to ±`maxRatioDeviation`,
/// i.e. an inaudible varispeed) or a request to jump the cursor (performed by the renderer as a
/// short crossfade) when the error is too large to slew away quietly.
public struct DriftCorrector: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Read `ratio` input frames per output frame this callback.
        case rate(Double)
        /// Reposition the read cursor onto the ideal frame (crossfaded skip/repeat).
        case jump
    }

    /// Filtered-error threshold for a jump (default 441 frames = 10 ms).
    public var jumpThresholdFrames: Double
    /// Raw single-callback error that triggers an immediate jump (default 50 ms) — re-anchors,
    /// offset changes, IO stalls.
    public var immediateJumpThresholdFrames: Double
    /// Maximum |ratio − 1| (default 0.001 = 1000 ppm ≈ 1.7 cents, inaudible).
    public var maxRatioDeviation: Double
    /// Seconds over which a small error is slewed away (sets the proportional gain).
    public var correctionTimeSeconds: Double
    /// Low-pass time constant of the error filter, in seconds.
    public var filterTimeSeconds: Double

    /// Integral time of the PI controller in seconds (removes the steady-state error a pure
    /// proportional loop would leave under constant clock drift).
    public var integralTimeSeconds: Double

    public private(set) var filteredError: Double = 0
    public private(set) var ratio: Double = 1
    private var integral: Double = 0
    private var primed = false

    public init(
        jumpThresholdFrames: Double = 441,
        immediateJumpThresholdFrames: Double = 2205,
        maxRatioDeviation: Double = 0.001,
        correctionTimeSeconds: Double = 2.0,
        filterTimeSeconds: Double = 0.25,
        integralTimeSeconds: Double = 8.0
    ) {
        self.integralTimeSeconds = integralTimeSeconds
        self.jumpThresholdFrames = jumpThresholdFrames
        self.immediateJumpThresholdFrames = immediateJumpThresholdFrames
        self.maxRatioDeviation = maxRatioDeviation
        self.correctionTimeSeconds = correctionTimeSeconds
        self.filterTimeSeconds = filterTimeSeconds
    }

    /// Forget history (after a jump, re-anchor or restart).
    public mutating func reset() {
        filteredError = 0
        ratio = 1
        integral = 0
        primed = false
    }

    /// - Parameters:
    ///   - errorFrames: read cursor − ideal frame, measured at the start of this callback.
    ///   - callbackFrames: frames rendered by this callback (sets the filter step).
    public mutating func update(errorFrames: Double, callbackFrames: Int) -> Decision {
        if abs(errorFrames) > immediateJumpThresholdFrames {
            reset()
            return .jump
        }
        let dt = Double(callbackFrames) / Double(PCM.sampleRate)
        if !primed {
            filteredError = errorFrames
            primed = true
        } else {
            let alpha = min(1, dt / max(filterTimeSeconds, 1e-6))
            filteredError += alpha * (errorFrames - filteredError)
        }
        if abs(filteredError) > jumpThresholdFrames {
            reset()
            return .jump
        }
        // PI: an error of e frames is removed in ~correctionTimeSeconds; the integral term learns
        // the device's constant clock-rate offset.
        let kp = 1.0 / (correctionTimeSeconds * Double(PCM.sampleRate))
        if integralTimeSeconds > 0 {
            let ki = kp / integralTimeSeconds
            integral += filteredError * dt
            let limit = maxRatioDeviation / ki // anti-windup
            integral = max(-limit, min(limit, integral))
        }
        let iTerm = integralTimeSeconds > 0 ? (kp / integralTimeSeconds) * integral : 0
        let deviation = max(-maxRatioDeviation, min(maxRatioDeviation, kp * filteredError + iTerm))
        ratio = 1.0 - deviation
        return .rate(ratio)
    }
}

// MARK: - Gain

/// Maps the contract's perceptual volume (0…1) to a linear amplitude.
///
/// Uses the AirPlay convention (volume 0…1 ↔ −30…0 dB, 0 = mute) so a local speaker at a given
/// slider value sits at the same attenuation an AirPlay receiver applies.
public enum VolumeCurve {
    public static let rangeDB: Float = 30

    public static func amplitude(forVolume volume: Float) -> Float {
        let v = max(0, min(1, volume))
        if v <= 0 { return 0 }
        let db = -rangeDB + rangeDB * v
        return powf(10, db / 20)
    }
}

/// Linear per-sample gain ramp: changing the target never jumps (no zipper noise).
public struct GainRamp: Sendable, Equatable {
    public private(set) var current: Float
    public private(set) var target: Float
    public let rampFrames: Int
    private var step: Float = 0
    private var remaining: Int = 0

    /// - Parameter rampFrames: duration of a full transition (default 882 = 20 ms).
    public init(initial: Float = 0, rampFrames: Int = 882) {
        current = initial
        target = initial
        self.rampFrames = max(1, rampFrames)
    }

    public var isRamping: Bool { remaining > 0 }

    public mutating func setTarget(_ newTarget: Float) {
        guard newTarget != target else { return }
        target = newTarget
        remaining = rampFrames
        step = (target - current) / Float(rampFrames)
    }

    /// Jump straight to a value (only for when no audio is audible, e.g. before the first frame).
    public mutating func snap(to value: Float) {
        current = value
        target = value
        remaining = 0
        step = 0
    }

    /// Gain for the next frame.
    @inline(__always)
    public mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            current = remaining == 0 ? target : current + step
        }
        return current
    }
}

// MARK: - Interpolation

/// 4-point, 3rd-order Hermite interpolation between y0 and y1 at `t` in [0, 1).
@inline(__always)
func hermite(_ ym1: Float, _ y0: Float, _ y1: Float, _ y2: Float, _ t: Float) -> Float {
    let c0 = y0
    let c1 = 0.5 * (y1 - ym1)
    let c2 = ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
    let c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
    return ((c3 * t + c2) * t + c1) * t + c0
}
