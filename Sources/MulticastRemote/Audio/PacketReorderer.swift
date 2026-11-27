import Foundation
import MulticastAudio

/// The phone's jitter buffer: takes audio packets as the network delivers them (late, twice, out
/// of order, or never) and hands them on strictly in timeline order, which is what the output's
/// ring buffer needs.
///
/// - A packet ahead of the next expected one waits; the missing ones are asked for again
///   (`poll` returns their frames) after a short grace for plain reordering.
/// - A gap is given up when its audio is about to be due (`dueFrame`), when it was asked for
///   often enough, or when too much is waiting behind it. Giving up never stalls: the stream
///   continues at the next packet held.
/// - To hide a gap, the packet before it is faded out and the packet after it faded in. For
///   that, the newest in-order packet is held back until its successor is known (8 ms, nothing
///   against the two seconds the group runs ahead).
///
/// Pure: time comes in as arguments. One epoch at a time; `reset` starts another.
struct PacketReorderer {
    struct Configuration: Sendable {
        /// How long a hole may sit before it is asked for (covers ordinary reordering).
        var nackDelayNanos: UInt64 = 30_000_000
        var nackIntervalNanos: UInt64 = 120_000_000
        var maxAsks = 4
        var maxNacksPerPoll = AudioChannel.maxNackFrames
        /// Packets held behind a hole before the hole is given up (about 4 s).
        var maxPending = 500
        /// The packet held back for a fade is released after this long without a successor.
        var holdNanos: UInt64 = 60_000_000
    }

    struct Stats: Equatable, Sendable {
        /// Packets accepted (first copies only).
        var received: UInt64 = 0
        var duplicates: UInt64 = 0
        /// Arrived after the stream had moved past them.
        var late: UInt64 = 0
        /// Filled by a retransmission.
        var recovered: UInt64 = 0
        /// Given up: played as a faded gap.
        var concealed: UInt64 = 0
        var nacksSent: UInt64 = 0
        var gaps: UInt64 = 0
    }

    private struct Ask {
        var noticed: UInt64
        var last: UInt64?
        var count = 0
    }

    var configuration = Configuration()
    private(set) var stats = Stats()
    private var next: UInt64?
    private var highest: UInt64 = 0
    private var pending: [UInt64: Data] = [:]
    private var asks: [UInt64: Ask] = [:]
    private var held: AudioPacket?
    private var heldSince: UInt64 = 0
    private var fadeInNext = false

    private static let step = UInt64(PCM.framesPerPacket)

    /// Packets waiting behind a hole.
    var pendingCount: Int { pending.count }

    /// Forget everything (a flush or a new timeline). Counters are kept.
    mutating func reset() {
        next = nil
        highest = 0
        pending.removeAll(keepingCapacity: true)
        asks.removeAll(keepingCapacity: true)
        held = nil
        fadeInNext = false
    }

    /// A packet from the network. Returns what can be played now, in order.
    mutating func insert(firstFrame: UInt64, samples: Data, now: UInt64) -> [AudioPacket] {
        guard samples.count == PCM.bytesPerPacket else { return [] }
        var out: [AudioPacket] = []
        guard let expected = next else {
            next = firstFrame
            highest = firstFrame
            stats.received += 1
            pending[firstFrame] = samples
            drain(into: &out, now: now)
            return out
        }
        if firstFrame < expected {
            stats.late += 1
            return out
        }
        if (firstFrame - expected) % Self.step != 0 {
            // Not on this stream's packet grid: the hub started over without us noticing.
            skip(to: firstFrame, into: &out, countingGap: false)
        }
        if pending[firstFrame] != nil {
            stats.duplicates += 1
            return out
        }
        stats.received += 1
        if asks.removeValue(forKey: firstFrame)?.count ?? 0 > 0 { stats.recovered += 1 }
        pending[firstFrame] = samples
        highest = max(highest, firstFrame)
        drain(into: &out, now: now)
        if pending.count > configuration.maxPending, let first = pending.keys.min() {
            skip(to: first, into: &out, countingGap: true)
            drain(into: &out, now: now)
        }
        return out
    }

    /// Call often (every 10–20 ms). `dueFrame`: the frame that must be handed over by now to be
    /// played in time, if the timeline is known. Returns packets released and frames to ask for.
    mutating func poll(now: UInt64, dueFrame: UInt64?) -> (deliver: [AudioPacket], nack: [UInt64]) {
        var out: [AudioPacket] = []
        var nack: [UInt64] = []
        guard var expected = next else { return (out, nack) }

        // Give up the hole at the head when waiting longer can't help.
        while pending[expected] == nil, !pending.isEmpty {
            let ask = asks[expected]
            let exhausted = (ask?.count ?? 0) >= configuration.maxAsks
                && now >= (ask?.last ?? now) + configuration.nackIntervalNanos * 2
            let due = dueFrame.map { expected < $0 } ?? false
            guard exhausted || due, let first = pending.keys.min() else { break }
            // Skip no further than needed: only up to the due point when packets beyond it are
            // still worth waiting for, else to the next packet held.
            var target = first
            if !exhausted, let dueFrame, dueFrame < first {
                target = expected + ((dueFrame - expected) / Self.step + 1) * Self.step
                if target > first { target = first }
            }
            skip(to: target, into: &out, countingGap: true)
            drain(into: &out, now: now)
            guard let n = next else { break }
            expected = n
        }

        // Ask for what is missing between the head and the newest packet seen.
        if highest > expected {
            var frame = expected
            var scanned = 0
            while frame < highest, nack.count < configuration.maxNacksPerPoll, scanned < 512 {
                scanned += 1
                defer { frame += Self.step }
                guard pending[frame] == nil else { continue }
                var ask = asks[frame] ?? Ask(noticed: now)
                if ask.count < configuration.maxAsks, now >= ask.noticed + configuration.nackDelayNanos,
                   ask.last.map({ now >= $0 + configuration.nackIntervalNanos }) ?? true {
                    ask.last = now
                    ask.count += 1
                    nack.append(frame)
                }
                asks[frame] = ask
            }
            stats.nacksSent += UInt64(nack.count)
        }

        // Nothing followed the held packet: let it go as it is.
        if let h = held, now >= heldSince + configuration.holdNanos, pending.isEmpty {
            out.append(h)
            held = nil
        }
        return (out, nack)
    }

    // MARK: Internals

    private mutating func drain(into out: inout [AudioPacket], now: UInt64) {
        guard var expected = next else { return }
        while let samples = pending.removeValue(forKey: expected) {
            var data = samples
            if fadeInNext {
                Self.fade(&data, fadeIn: true)
                fadeInNext = false
            }
            if let h = held { out.append(h) }
            held = AudioPacket(firstFrame: expected, samples: data)
            heldSince = now
            expected += Self.step
        }
        next = expected
    }

    /// Moves the head to `frame`, leaving a faded gap behind.
    private mutating func skip(to frame: UInt64, into out: inout [AudioPacket], countingGap: Bool) {
        guard let expected = next, frame > expected else { return }
        if countingGap {
            let missing = stride(from: expected, to: frame, by: Int(Self.step)).reduce(0) { $0 + (pending[$1] == nil ? 1 : 0) }
            stats.concealed += UInt64(missing)
            stats.gaps += 1
        }
        if let h = held {
            var data = h.samples
            Self.fade(&data, fadeIn: false)
            out.append(AudioPacket(firstFrame: h.firstFrame, samples: data))
            held = nil
        }
        fadeInNext = true
        for key in pending.keys where key < frame { pending[key] = nil }
        for key in asks.keys where key < frame { asks[key] = nil }
        next = frame
        highest = max(highest, frame)
    }

    /// A linear fade over the whole packet (8 ms), in place.
    static func fade(_ samples: inout Data, fadeIn: Bool) {
        let frames = samples.count / PCM.bytesPerFrame
        guard frames > 0 else { return }
        samples.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let w = fadeIn ? Float(i) / Float(frames) : Float(frames - 1 - i) / Float(frames)
                p[2 * i] = Int16((Float(Int16(littleEndian: p[2 * i])) * w).rounded()).littleEndian
                p[2 * i + 1] = Int16((Float(Int16(littleEndian: p[2 * i + 1])) * w).rounded()).littleEndian
            }
        }
    }
}
