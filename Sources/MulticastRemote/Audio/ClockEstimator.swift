import Foundation

/// Estimates the hub's monotonic clock from the phone's, well enough to play audio by.
///
/// Each sample is an NTP-style exchange: the phone sends at `t1` (its clock), the hub receives at
/// `t2` and answers at `t3` (its clock), the phone receives at `t4`. Then
///
///     offset = ((t2 − t1) + (t3 − t4)) / 2        hub clock minus phone clock
///     delay  = (t4 − t1) − (t3 − t2)              time spent on the network, both ways
///
/// and the offset is wrong by at most half the delay (exactly by half the difference between the
/// two directions). Wi-Fi adds delay in bursts and never removes any, so the samples with the
/// least delay are the truthful ones:
///
/// 1. Time is cut into buckets (2 s); each keeps only its lowest-delay sample.
/// 2. Buckets whose best sample still had a poor delay (more than twice the lowest seen, plus
///    half a millisecond) are left out.
/// 3. A straight line is fitted through the rest (offset against phone time), each sample
///    weighted by how close its delay came to the lowest seen. Its slope is the
///    drift between the two crystals, which is steady over minutes, so the line can be read at
///    "now" without waiting for a fresh sample.
///
/// Until there are enough buckets for a line (6, spanning 10 s) the estimate is the offset of
/// the lowest-delay sample so far, with no drift term.
///
/// Pure and deterministic; all times in nanoseconds.
public struct ClockEstimator: Sendable {
    public struct Sample: Sendable, Equatable {
        /// Phone time halfway through the exchange.
        public var local: UInt64
        /// Hub clock minus phone clock.
        public var offset: Int64
        public var delay: UInt64
    }

    public var bucketNanos: UInt64 = 2_000_000_000
    public var maxBuckets = 60
    public var minBucketsForDrift = 6
    public var minSpanForDriftNanos: UInt64 = 10_000_000_000
    /// Exchanges that took longer than this say nothing useful.
    public var maxDelayNanos: UInt64 = 250_000_000

    private var buckets: [(index: UInt64, best: Sample)] = []
    public private(set) var sampleCount = 0
    public private(set) var lastSample: Sample?

    public init() {}

    public mutating func reset() {
        buckets.removeAll()
        sampleCount = 0
        lastSample = nil
    }

    /// One exchange. Returns the sample it made, or nil when the numbers can't be right
    /// (a reply that seems to arrive before it was asked for, or an absurd delay).
    @discardableResult
    public mutating func add(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) -> Sample? {
        guard t4 >= t1, t3 >= t2 else { return nil }
        let round = t4 - t1
        let held = t3 - t2
        guard round >= held else { return nil }
        let delay = round - held
        guard delay <= maxDelayNanos else { return nil }
        let a = Int64(bitPattern: t2 &- t1)
        let b = Int64(bitPattern: t3 &- t4)
        // Halve before adding so two large same-sign values can't overflow.
        let offset = a / 2 + b / 2 + (a % 2 + b % 2) / 2
        let sample = Sample(local: t1 + round / 2, offset: offset, delay: delay)
        sampleCount += 1
        lastSample = sample

        let index = sample.local / bucketNanos
        if let last = buckets.last, last.index == index {
            if sample.delay < last.best.delay { buckets[buckets.count - 1].best = sample }
        } else if let last = buckets.last, index < last.index {
            // The phone's clock doesn't go back; ignore rather than reorder.
            return sample
        } else {
            buckets.append((index, sample))
            if buckets.count > maxBuckets { buckets.removeFirst(buckets.count - maxBuckets) }
        }
        return sample
    }

    /// The lowest delay among the buckets kept: how good the link has been at its best.
    public var bestDelayNanos: UInt64? { buckets.map(\.best.delay).min() }

    private func trusted() -> [Sample] {
        guard let least = bestDelayNanos else { return [] }
        let limit = least * 2 + 500_000
        let good = buckets.map(\.best).filter { $0.delay <= limit }
        return good.count >= minBucketsForDrift ? good : buckets.map(\.best)
    }

    private func line() -> (origin: Sample, slope: Double, intercept: Double)? {
        let s = trusted()
        guard s.count >= minBucketsForDrift, let first = s.first, let last = s.last,
              last.local - first.local >= minSpanForDriftNanos else { return nil }
        // Relative to the first sample, so doubles keep nanosecond precision. A sample can be
        // wrong by at most half of what its delay exceeds the link's floor by, so samples near
        // the floor count for much more.
        let floor = Double(s.map(\.delay).min() ?? 0)
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in s {
            let x = Double(p.local - first.local)
            let y = Double(p.offset &- first.offset)
            let excess = Double(p.delay) - floor + 200_000
            let w = 4e10 / (excess * excess)
            n += w
            sx += w * x
            sy += w * y
            sxx += w * x * x
            sxy += w * x * y
        }
        let denominator = n * sxx - sx * sx
        guard denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        // Two crystals never differ by more than a few hundred ppm; a steeper line is noise.
        guard abs(slope) < 500e-6 else { return nil }
        return (first, slope, (sy - slope * sx) / n)
    }

    /// Hub clock minus phone clock at phone time `local`; nil before the first sample.
    public func offsetNanos(at local: UInt64) -> Int64? {
        if let l = line() {
            let x = Double(Int64(bitPattern: local &- l.origin.local))
            return l.origin.offset &+ Int64((l.intercept + l.slope * x).rounded())
        }
        return buckets.map(\.best).min { $0.delay < $1.delay }?.offset
    }

    /// How much faster the hub's clock runs than the phone's, in parts per million; 0 until
    /// there is a line.
    public var driftPPM: Double { (line()?.slope ?? 0) * 1e6 }

    /// Whether the estimate includes drift (a line was fitted).
    public var tracksDrift: Bool { line() != nil }
}
