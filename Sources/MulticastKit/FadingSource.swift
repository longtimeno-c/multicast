import Foundation
import MulticastAudio
import os

/// Wraps any `AudioSource` with a fade-in at the start and an on-request fade-out, after which
/// it reports end of stream. Stopping through a fade (`MulticastSession.stop(fadeOut: true)`,
/// Ctrl-C or a time limit in the CLI) therefore never produces a click and never has to touch
/// device volume (which, on a Sonos, is the room's real volume and would stay at zero).
/// `MulticastSession.pause()` does NOT fade: it flushes the speakers at once (see its doc).
///
/// The wrapper is reusable: `start()` and `rearm()` reset the fade, so after a faded stop the
/// same source plays again (with a fresh fade-in) instead of ending immediately.
///
/// `read` runs on the engine's pacing thread: it only does arithmetic on frames and reads the
/// control state with a try-lock that never blocks (a missed try just applies a request one
/// packet later; while finished, a missed try pads one packet of silence instead of ending).
public final class FadingSource: AudioSource, @unchecked Sendable {
    public let underlying: AudioSource
    public var displayName: String { underlying.displayName }
    public var isLive: Bool { underlying.isLive }

    private let fadeInFrames: Int
    private let fadeOutFrames: Int

    // Pacing-thread only.
    private var gain = FadeGain(fadeInFrames: 0, fadeOutFrames: 0)
    private var seenGeneration: UInt64 = 0

    private struct Control {
        var fadeOutRequested = false
        /// Bumped by `rearm()`; the reader resets its gain when it sees a new value.
        var generation: UInt64 = 0
    }

    // Cross-thread: set by control code, picked up by `read`.
    private let control = OSAllocatedUnfairLock(initialState: Control())

    public init(_ source: AudioSource, fadeIn: TimeInterval = 0.5, fadeOut: TimeInterval = 0.5) {
        underlying = source
        fadeInFrames = max(0, Int(fadeIn * Double(PCM.sampleRate)))
        fadeOutFrames = max(0, Int(fadeOut * Double(PCM.sampleRate)))
        gain = FadeGain(fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
    }

    public func start() async throws {
        rearm()
        try await underlying.start()
    }
    public func stop() async { await underlying.stop() }

    /// Begin fading out now; the source ends `fadeOut` seconds of audio later. Any thread.
    public func requestFadeOut() {
        control.withLock { $0.fadeOutRequested = true }
    }

    /// True once a fade-out was requested (and not re-armed since).
    public var isFadeOutRequested: Bool { control.withLock { $0.fadeOutRequested } }

    /// Cancel any fade-out (finished or not) and start over with a fade-in. Any thread.
    public func rearm() {
        control.withLock {
            $0.fadeOutRequested = false
            $0.generation &+= 1
        }
    }

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        if let c = control.withLockIfAvailable({ $0 }) {
            if c.generation != seenGeneration {
                seenGeneration = c.generation
                gain = FadeGain(fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
            }
            if c.fadeOutRequested, !gain.fadingOut { gain.beginFadeOut() }
        } else if gain.finished {
            // Could not confirm that no re-arm is pending: one packet of silence, decide next time.
            return 0
        }
        if gain.finished { return nil }
        guard let n = underlying.read(into: buffer, frameCount: frameCount) else { return nil }
        gain.apply(to: buffer, frames: n, channels: PCM.channels)
        return n
    }
}

/// The pure gain schedule behind `FadingSource` (unit-tested).
public struct FadeGain: Sendable, Equatable {
    public let fadeInFrames: Int
    public let fadeOutFrames: Int
    /// Frames processed since the start.
    public private(set) var position: Int = 0
    /// Frames into the fade-out, or nil when not fading out.
    public private(set) var fadeOutPosition: Int?

    public init(fadeInFrames: Int, fadeOutFrames: Int) {
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
    }

    public var fadingOut: Bool { fadeOutPosition != nil }
    public var finished: Bool { (fadeOutPosition ?? -1) >= fadeOutFrames }

    public mutating func beginFadeOut() {
        if fadeOutPosition == nil { fadeOutPosition = 0 }
    }

    /// Gain for the next frame, 0…1.
    @inline(__always)
    func gainNow() -> Float {
        var g: Float = 1
        if position < fadeInFrames { g = Float(position) / Float(fadeInFrames) }
        if let fo = fadeOutPosition {
            g *= fadeOutFrames == 0 ? 0 : max(0, Float(fadeOutFrames - fo) / Float(fadeOutFrames))
        }
        return g
    }

    public mutating func apply(to buffer: UnsafeMutablePointer<Int16>, frames: Int, channels: Int) {
        let fullyOn = position >= fadeInFrames && fadeOutPosition == nil
        if fullyOn {
            position += frames
            return
        }
        for f in 0..<frames {
            let g = gainNow()
            if g < 1 {
                for c in 0..<channels {
                    let i = f * channels + c
                    buffer[i] = Int16((Float(buffer[i]) * g).rounded())
                }
            }
            position += 1
            if let fo = fadeOutPosition { fadeOutPosition = fo + 1 }
        }
    }
}
