import Foundation
import MulticastAudio

/// Maps the shared `StreamTimeline` onto one receiver's RTP clock and builds its sync packets.
///
/// ## The math
///
/// Definitions (all frame counts at 44.1 kHz):
/// - `P(F) = timeline.playoutHostNanos(forFrame: F) + offset` — host time frame `F` must be
///   audible at this speaker (`offset` is the per-sink trim, positive = later).
/// - `rtp(F) = rtpBase + F (mod 2^32)` — the RTP timestamp we stamp on frame `F`.
/// - `L = frames(timeline.latencyNanos)` — how far ahead of playout packets are sent.
///
/// A sync packet carries, at NTP time `N`:
/// - `rtpNow`            — the RTP time currently being *sent*,
/// - `rtpMinusLatency`   — "rtpNow minus latency",
/// and receivers (AirPort Express, Apple's AirTunes stack, shairport-sync, libraop) interpret it the
/// way iTunes produced it. iTunes keeps 2 s (88200 frames) of audio in flight but sends
/// `rtpNow - rtpMinusLatency = 77175`: receivers add back the missing 11025 frames (0.25 s) —
/// the "11025 convention" (shairport-sync: `latency = rtpNow - rtpMinusLatency + 11025`).
/// The resulting receiver rule is:
///
///     frame with RTP time X is audible at   N + (X - rtpMinusLatency + 11025) / 44100 s
///
/// i.e. the frame audible exactly at `N` is `rtpMinusLatency - 11025`.
///
/// We pick the sync point from the timeline: let `Fn` be the (integer) frame that must be audible
/// at host time `t` (≈ now), `t = P(Fn)` exactly, `N = ntp(t)`. Then
///
///     rtpMinusLatency = rtp(Fn) + 11025
///     rtpNow          = rtp(Fn) + L          (so rtpNow - rtpMinusLatency = L - 11025)
///
/// Substituting into the receiver rule gives: frame X audible at `N + (X - rtp(Fn)) / 44100`,
/// which is exactly `P(F)` for `X = rtp(F)` — the timeline contract. For the default 2 s
/// latency this reproduces iTunes byte-for-byte (difference 77175). `receiverBiasFrames`
/// (11025) is configurable in case a receiver family turns out to apply a different bias.
///
/// The `Audio-Latency` header a receiver returns from RECORD is that device's *minimum* buffer
/// requirement in frames; it is not added to the mapping (the receiver already plays to the
/// NTP mapping), but a sink should warn when `L` is smaller than it.
public struct SyncMapping: Sendable, Equatable {
    public var timeline: StreamTimeline
    public var rtpBase: UInt32
    public var offsetNanos: Int64
    public var receiverBiasFrames: UInt32

    public static let defaultReceiverBiasFrames: UInt32 = 11_025

    public init(timeline: StreamTimeline, rtpBase: UInt32, offsetNanos: Int64 = 0, receiverBiasFrames: UInt32 = SyncMapping.defaultReceiverBiasFrames) {
        self.timeline = timeline
        self.rtpBase = rtpBase
        self.offsetNanos = offsetNanos
        self.receiverBiasFrames = receiverBiasFrames
    }

    /// Latency in frames between sending and playout (`timeline.latencyNanos`).
    public var latencyFrames: UInt32 { UInt32(truncatingIfNeeded: PCM.frames(forNanos: timeline.latencyNanos)) }

    /// Smallest timeline latency this mapping can express (must exceed the receiver bias).
    public var isLatencyRepresentable: Bool { latencyFrames > receiverBiasFrames }

    /// RTP timestamp for a (signed) frame index.
    @inline(__always)
    public func rtp(forFrame frame: Int64) -> UInt32 {
        rtpBase &+ UInt32(truncatingIfNeeded: frame)
    }

    @inline(__always)
    public func rtp(forFrame frame: UInt64) -> UInt32 {
        rtpBase &+ UInt32(truncatingIfNeeded: frame)
    }

    /// Integer frame that must be audible at `hostNanos` (floor), and the exact host time it is due.
    public func frameAndTime(atHostNanos hostNanos: UInt64) -> (frame: Int64, hostNanos: UInt64) {
        let rate = Int64(PCM.sampleRate)
        // Signed nanoseconds since the anchor, with the trim removed.
        let delta = Int64(bitPattern: hostNanos &- timeline.anchorHostNanos) &- offsetNanos
        // floor(delta * rate / 1e9) without overflow.
        let product = delta.multipliedFullWidth(by: rate)
        var (q, r) = Int64(1_000_000_000).dividingFullWidth(product)
        if r < 0 { q -= 1; r += 1_000_000_000 }
        let frame = Int64(bitPattern: timeline.anchorFrame) &+ q
        // Exact due time of `frame`: anchor + offset + q * 1e9 / rate (floor).
        let ns = q.multipliedFullWidth(by: 1_000_000_000)
        var (back, rem) = rate.dividingFullWidth(ns)
        if rem < 0 { back -= 1; rem += rate }
        let due = timeline.anchorHostNanos &+ UInt64(bitPattern: back &+ offsetNanos)
        return (frame, due)
    }

    /// Sync packet for "now" (`hostNanos`), see the type documentation.
    public func syncPacket(atHostNanos hostNanos: UInt64, isFirst: Bool, ntpEpochOffset: UInt64 = NTPTime.hostToNTPEpochNanos) -> SyncPacket {
        let (frame, due) = frameAndTime(atHostNanos: hostNanos)
        let base = rtp(forFrame: frame)
        return SyncPacket(
            isFirst: isFirst,
            rtpMinusLatency: base &+ receiverBiasFrames,
            ntpTime: NTPTime.ntp(fromHostNanos: due, epochOffset: ntpEpochOffset),
            rtpNow: base &+ latencyFrames)
    }

    /// The packet-aligned frame of the earliest packet a sink preparing at `hostNanos` can still
    /// receive: the timeline's anchor if it is still in the future, otherwise the packet audible
    /// now (anything earlier is already late, so the engine neither backfills nor sends it).
    /// Used for RECORD's `RTP-Info` so its rtptime matches its seq even for a late joiner.
    public static func firstReceivableFrame(timeline: StreamTimeline, atHostNanos hostNanos: UInt64) -> UInt64 {
        let mapping = SyncMapping(timeline: timeline, rtpBase: 0)
        let audible = mapping.frameAndTime(atHostNanos: hostNanos).frame
        let anchor = Int64(bitPattern: timeline.anchorFrame)
        guard audible > anchor else { return timeline.anchorFrame }
        let packet = Int64(PCM.framesPerPacket)
        return UInt64(bitPattern: anchor + (audible - anchor) / packet * packet)
    }

    /// What a receiver following the iTunes rule would compute as the audible host time of RTP time `rtp`,
    /// given sync packet `sync`. This MODELS the receiver (shairport-sync's documented rule); tests that
    /// use it check that our mapping is consistent with that assumed rule, not that real devices obey it.
    public static func receiverPlayoutHostNanos(rtp: UInt32, sync: SyncPacket, biasFrames: UInt32 = defaultReceiverBiasFrames,
                                                ntpEpochOffset: UInt64 = NTPTime.hostToNTPEpochNanos) -> Int64 {
        let syncHost = Int64(bitPattern: NTPTime.hostNanos(fromNTP: sync.ntpTime, epochOffset: ntpEpochOffset))
        let frames = Int64(Int32(bitPattern: rtp &- sync.rtpMinusLatency &+ biasFrames))
        return syncHost + frames * 1_000_000_000 / Int64(PCM.sampleRate)
    }
}
