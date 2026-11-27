import Foundation
import MulticastAudio

/// The test sound of sync calibration: a short rising sweep, repeated at a fixed period.
///
/// A sweep rather than a click or noise: its energy is spread over a quarter of a second, so it
/// can be played quietly, yet correlating a recording with it compresses that energy into a peak
/// a fraction of a millisecond wide (the bandwidth sets the width, the length sets how far the
/// peak stands above room noise). The band is one every speaker and microphone carries, small
/// Bluetooth speakers and phone microphones included.
///
/// The sweep is defined as a function of time, not as samples, so the microphone side can build
/// the same sound at whatever rate its device runs at.
public struct CalibrationSignal: Sendable, Equatable {
    public var startHz: Double
    public var endHz: Double
    /// Length of one sweep, seconds.
    public var sweepSeconds: Double
    /// From one sweep's start to the next. Longer than any delay worth measuring plus the room's
    /// echo, so a late speaker is never taken for the next sweep.
    public var periodSeconds: Double
    /// Silence before the first sweep (the session fades a source in over its first half second).
    public var leadInSeconds: Double
    /// Peak level, 0…1 of full scale. Loudness is then whatever each speaker's volume makes of it.
    public var amplitude: Double

    public init(startHz: Double = 900, endHz: Double = 6500, sweepSeconds: Double = 0.25, periodSeconds: Double = 1.0,
                leadInSeconds: Double = 1.0, amplitude: Double = 0.3) {
        self.startHz = startHz
        self.endHz = endHz
        self.sweepSeconds = sweepSeconds
        self.periodSeconds = periodSeconds
        self.leadInSeconds = leadInSeconds
        self.amplitude = amplitude
    }

    /// The sweep's value `t` seconds after it starts, at unit amplitude; 0 outside it. A linear
    /// sweep under a window with raised-cosine ends (no click at either end).
    public func value(at t: Double) -> Double {
        guard t >= 0, t < sweepSeconds, sweepSeconds > 0 else { return 0 }
        let taper = 0.1 * sweepSeconds
        var window = 1.0
        if t < taper {
            window = 0.5 - 0.5 * cos(.pi * t / taper)
        } else if t > sweepSeconds - taper {
            window = 0.5 - 0.5 * cos(.pi * (sweepSeconds - t) / taper)
        }
        let phase = 2 * Double.pi * (startHz * t + (endHz - startHz) * t * t / (2 * sweepSeconds))
        return window * sin(phase)
    }

    /// One sweep at unit amplitude, sampled at `sampleRate`: what a recording is correlated with.
    public func template(sampleRate: Double) -> [Float] {
        let count = max(1, Int((sweepSeconds * sampleRate).rounded()))
        return (0..<count).map { Float(value(at: Double($0) / sampleRate)) }
    }

    // MARK: Position in the pipeline

    public var periodFrames: Int { max(1, Int((periodSeconds * Double(PCM.sampleRate)).rounded())) }
    public var leadInFrames: Int { max(0, Int((leadInSeconds * Double(PCM.sampleRate)).rounded())) }
    public var sweepFrames: Int { max(1, Int((sweepSeconds * Double(PCM.sampleRate)).rounded())) }

    /// The frame, counted from the source's first, at which sweep `index` starts.
    public func startFrame(ofSweep index: Int) -> UInt64 {
        UInt64(leadInFrames + max(0, index) * periodFrames)
    }
}

/// Plays `CalibrationSignal` through the pipeline: silence, then a sweep every period, on both
/// channels, until stopped. Sweep `k` starts exactly `signal.startFrame(ofSweep: k)` frames after
/// the first frame read, so with the timeline the engine issues when it starts this source, the
/// moment each sweep is due at the loudspeakers is known.
public final class CalibrationSource: AudioSource, @unchecked Sendable {
    public let signal: CalibrationSignal
    public let displayName = "Sync calibration"
    public var isLive: Bool { false }

    private let sweep: [Int16]
    private let period: Int
    private let leadIn: Int
    /// Frames read since `start()`. Written by `start()` before the engine reads, then only by
    /// the pacing thread.
    private var position = 0

    public init(signal: CalibrationSignal = CalibrationSignal()) {
        self.signal = signal
        let rate = Double(PCM.sampleRate)
        let level = min(1, max(0, signal.amplitude)) * Double(Int16.max)
        sweep = (0..<signal.sweepFrames).map { Int16((signal.value(at: Double($0) / rate) * level).rounded()) }
        period = signal.periodFrames
        leadIn = signal.leadInFrames
    }

    public func start() async throws { position = 0 }
    public func stop() async {}

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        var p = position
        for i in 0..<frameCount {
            var s: Int16 = 0
            if p >= leadIn {
                let within = (p - leadIn) % period
                if within < sweep.count { s = sweep[within] }
            }
            buffer[2 * i] = s
            buffer[2 * i + 1] = s
            p += 1
        }
        position = p
        return frameCount
    }
}
