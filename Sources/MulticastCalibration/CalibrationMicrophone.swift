import Foundation

/// Whether a microphone may be used.
public enum MicrophoneAccess: String, Sendable, Codable, Equatable {
    /// Never asked.
    case notDetermined
    case granted
    /// Refused: only the system's settings can change it.
    case denied
}

/// What a microphone made of one stretch of listening for the calibration sweep.
public struct HeardSweep: Sendable, Codable, Equatable {
    /// When the sweep began to arrive, on the clock the question was asked in; nil when it
    /// wasn't clearly heard.
    public var arrivalHostNanos: UInt64?
    /// How far the best candidate stood above the noise (`DelayEstimator.Analysis.strength`).
    public var strength: Double
    /// A picture of the search (`DelayEstimator.Analysis.trace`).
    public var trace: [UInt8]
    /// How loud the room was, 0…1 of full scale.
    public var level: Float

    public init(arrivalHostNanos: UInt64?, strength: Double, trace: [UInt8], level: Float) {
        self.arrivalHostNanos = arrivalHostNanos
        self.strength = strength
        self.trace = trace
        self.level = level
    }
}

/// A microphone sync calibration can listen with: the Mac's own, or a paired phone's over the
/// link. It answers with what it found, never with audio, so a recording stays on the device
/// that made it.
public protocol CalibrationMicrophone: Sendable {
    /// `ask: true` shows the system prompt when access was never asked for (and waits).
    func access(ask: Bool) async -> MicrophoneAccess
    /// Starts listening; the last few seconds are kept.
    func start() async throws
    func stop() async
    /// Looks for `signal` in what was heard for `seconds` from `fromHostNanos`. nil when that
    /// stretch isn't on record (not yet, no longer, or the microphone can't be reached).
    func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep?
}

extension RecordingRing {
    /// The answer a microphone built on this ring gives to `CalibrationMicrophone.listen`.
    public func heard(_ signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) -> HeardSweep? {
        guard let r = recording(fromHostNanos: fromHostNanos, seconds: seconds),
              let analysis = DelayEstimator(signal: signal).analyze(r.samples, sampleRate: sampleRate) else { return nil }
        let arrival = analysis.arrival.map { r.startHostNanos + UInt64(max(0, ($0.seconds * 1e9).rounded())) }
        return HeardSweep(arrivalHostNanos: arrival, strength: analysis.strength, trace: analysis.trace, level: analysis.level)
    }

    /// The most recent `count` samples, thinned to every `step`th, oldest first (for a live
    /// waveform). Fewer when less has been recorded.
    public func latest(_ count: Int, step: Int = 1) -> [Float] { tail(count, step: max(1, step)) }
}
