import Foundation
import MulticastAudio

/// A sine tone in the pipeline format, with raised-cosine fade in / fade out.
///
/// - With a `duration`, the tone fades out so that it reaches silence exactly at the end, then
///   `read` returns `nil`.
/// - Without a duration it plays until `requestFadeOut()` is called (thread-safe, e.g. from a
///   Ctrl-C handler); it then fades out over `fadeOut` seconds and ends.
///
/// `read` is real-time safe: pure arithmetic on reader-owned state plus one atomic load.
/// It must be called from a single thread at a time (the engine's pacing thread).
public final class ToneSource: AudioSource, @unchecked Sendable {
    public let frequency: Double
    /// Peak amplitude, linear 0…1 of full scale.
    public let amplitude: Double
    public let duration: TimeInterval?
    public let fadeIn: TimeInterval
    public let fadeOut: TimeInterval
    public let displayName: String
    public var isLive: Bool { false }

    /// Total frames if finite.
    public let totalFrames: Int64?
    private let fadeInFrames: Int64
    private let fadeOutFrames: Int64
    private let phaseIncrement: Double

    // Reader-thread state.
    private var frameIndex: Int64 = 0
    private var phase: Double = 0
    private var fadeOutStart: Int64 = -1
    private var fadeOutRequestApplied = false

    // Cross-thread.
    private let fadeOutRequested = AtomicBool(false)
    private let renderedFrames = AtomicInt64(0)

    public init(
        frequency: Double = 440,
        amplitude: Double = 0.1,
        duration: TimeInterval? = nil,
        fadeIn: TimeInterval = 0.05,
        fadeOut: TimeInterval = 0.05,
        displayName: String? = nil
    ) {
        precondition(frequency > 0 && frequency < Double(PCM.sampleRate) / 2, "frequency must be below Nyquist")
        self.frequency = frequency
        self.amplitude = min(max(amplitude, 0), 1)
        self.duration = duration.map { max(0, $0) }
        self.fadeIn = max(0, fadeIn)
        self.fadeOut = max(0, fadeOut)
        self.displayName = displayName ?? "Tone \(Int(frequency)) Hz"
        let sr = Double(PCM.sampleRate)
        let total = duration.map { Int64((max(0, $0) * sr).rounded()) }
        self.totalFrames = total
        var fi = Int64((self.fadeIn * sr).rounded())
        var fo = Int64((self.fadeOut * sr).rounded())
        if let total {
            // Fades never overlap more than the whole tone.
            if fi + fo > total {
                let scale = Double(total) / Double(max(1, fi + fo))
                fi = Int64(Double(fi) * scale)
                fo = total - fi
            }
        }
        self.fadeInFrames = fi
        self.fadeOutFrames = fo
        self.phaseIncrement = 2 * Double.pi * frequency / sr
        if let total { self.fadeOutStart = total - fo }
    }

    public func start() async throws {}
    public func stop() async {}

    /// Frames produced so far (any thread).
    public var framesRendered: Int64 { renderedFrames.load() }

    /// Begin the fade-out now; the source ends `fadeOut` seconds later. Thread-safe.
    public func requestFadeOut() {
        fadeOutRequested.store(true)
    }

    /// Gain envelope value (0…1) for frame `n`; `fadeOutBegin` is the frame where the fade-out
    /// starts (or -1 for none). Exposed for tests.
    @inline(__always)
    static func envelope(frame n: Int64, fadeInFrames: Int64, fadeOutFrames: Int64, fadeOutBegin: Int64) -> Double {
        var g = 1.0
        if fadeInFrames > 0, n < fadeInFrames {
            let x = Double(n) / Double(fadeInFrames)
            g *= 0.5 - 0.5 * cos(Double.pi * x)
        }
        if fadeOutBegin >= 0, n >= fadeOutBegin {
            if fadeOutFrames <= 0 { return 0 }
            let k = n - fadeOutBegin
            if k >= fadeOutFrames { return 0 }
            let x = Double(fadeOutFrames - k) / Double(fadeOutFrames)
            g *= 0.5 - 0.5 * cos(Double.pi * x)
        }
        return g
    }

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        if !fadeOutRequestApplied, fadeOutRequested.load() {
            fadeOutRequestApplied = true
            fadeOutStart = fadeOutStart < 0 ? frameIndex : min(fadeOutStart, frameIndex)
        }

        var end = Int64.max
        if let total = totalFrames { end = total }
        if fadeOutStart >= 0 { end = min(end, fadeOutStart + fadeOutFrames) }
        if frameIndex >= end { return nil }

        let n = Int(min(Int64(frameCount), end - frameIndex))
        let amp = amplitude
        for i in 0..<n {
            let f = frameIndex + Int64(i)
            let g = Self.envelope(frame: f, fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames, fadeOutBegin: fadeOutStart)
            let s = SampleConversion.int16(fromFloat: Float(amp * g * sin(phase)))
            buffer[2 * i] = s
            buffer[2 * i + 1] = s
            phase += phaseIncrement
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
        frameIndex += Int64(n)
        renderedFrames.store(frameIndex)
        return n
    }
}
