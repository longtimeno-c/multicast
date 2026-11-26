import MulticastAudio

/// Overflow-safe versions of the contract's frame/nanosecond conversions.
///
/// `PCM.nanos(forFrames:)` computes `frames * 1e9` and `PCM.frames(forNanos:)` computes
/// `nanos * 44100` with trapping arithmetic; both overflow UInt64 once the delta reaches about
/// 1.84e10 frames / 4.18e14 ns, i.e. ~4.84 days after a timeline's anchor. A timeline lives as long
/// as playback is not paused or re-anchored (live capture, gapless playlists), so the engine must
/// never call them with an unbounded delta. Everything here uses 128-bit intermediates and the
/// same rounding (floor) as the contract helpers, so results are identical where those do not trap.
/// (Contracts.swift is frozen; this is listed as a contract gap.)
enum TimelineMath {
    private static let rate = UInt64(PCM.sampleRate)
    private static let nanosPerSecond: UInt64 = 1_000_000_000

    /// floor(frames * 1e9 / 44100), saturating at UInt64.max.
    static func nanos(forFrames frames: UInt64) -> UInt64 {
        let product = frames.multipliedFullWidth(by: nanosPerSecond)
        guard product.high < rate else { return .max }
        return rate.dividingFullWidth(product).quotient
    }

    /// floor(nanos * 44100 / 1e9). Never overflows (the quotient is < nanos).
    static func frames(forNanos nanos: UInt64) -> UInt64 {
        let product = nanos.multipliedFullWidth(by: rate)
        return nanosPerSecond.dividingFullWidth(product).quotient
    }

    /// Same as `StreamTimeline.playoutHostNanos(forFrame:)`, without the overflow trap
    /// (saturates at UInt64.max / 0).
    static func playoutHostNanos(_ timeline: StreamTimeline, forFrame frame: UInt64) -> UInt64 {
        if frame >= timeline.anchorFrame {
            let delta = nanos(forFrames: frame - timeline.anchorFrame)
            let (sum, overflow) = timeline.anchorHostNanos.addingReportingOverflow(delta)
            return overflow ? .max : sum
        }
        let back = nanos(forFrames: timeline.anchorFrame - frame)
        return timeline.anchorHostNanos > back ? timeline.anchorHostNanos - back : 0
    }
}
