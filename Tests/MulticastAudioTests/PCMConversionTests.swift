import Testing
@testable import MulticastAudio

@Suite struct PCMConversionTests {
    /// The first frame count whose `frames * 1e9` no longer fits in 64 bits (the old trap).
    let firstWideFrames: UInt64 = UInt64.max / 1_000_000_000 + 1
    /// The first nanosecond count whose `nanos * 44100` no longer fits in 64 bits.
    let firstWideNanos: UInt64 = UInt64.max / 44_100 + 1

    @Test func smallValuesRoundDownExactly() {
        #expect(PCM.nanos(forFrames: 0) == 0)
        #expect(PCM.nanos(forFrames: 1) == 22_675)          // 22675.73…
        #expect(PCM.nanos(forFrames: 352) == 7_981_859)     // one packet, 7981859.41…
        #expect(PCM.nanos(forFrames: 44_100) == 1_000_000_000)
        #expect(PCM.frames(forNanos: 0) == 0)
        #expect(PCM.frames(forNanos: 22_675) == 0)
        #expect(PCM.frames(forNanos: 22_676) == 1)
        #expect(PCM.frames(forNanos: 1_000_000_000) == 44_100)
        #expect(PCM.frames(forNanos: 7_981_859) == 351)
        #expect(PCM.frames(forNanos: 7_981_860) == 352)
    }

    @Test func largeFrameCountsDoNotTrapAndAreExact() {
        // Thirty days of frames: well past the old overflow point (~4.8 days).
        let thirtyDays: UInt64 = 30 * 86_400 * 44_100
        #expect(thirtyDays > firstWideFrames)
        #expect(PCM.nanos(forFrames: thirtyDays) == 30 * 86_400 * 1_000_000_000)
        for f in [firstWideFrames - 1, firstWideFrames, firstWideFrames + 12_345, UInt64(1) << 50] {
            let n = PCM.nanos(forFrames: f)
            #expect(isFloor(n, numerator: wide(f, 1_000_000_000), divisor: 44_100))
        }
    }

    @Test func largeNanosDoNotTrapAndAreExact() {
        let thirtyDaysNanos: UInt64 = 30 * 86_400 * 1_000_000_000
        #expect(thirtyDaysNanos > firstWideNanos)
        #expect(PCM.frames(forNanos: thirtyDaysNanos) == 30 * 86_400 * 44_100)
        for n in [firstWideNanos - 1, firstWideNanos, UInt64(1) << 62, .max] {
            let f = PCM.frames(forNanos: n)
            #expect(isFloor(f, numerator: wide(n, 44_100), divisor: 1_000_000_000))
        }
    }

    @Test func saturatesOnlyWhenTheDurationCannotBeRepresented() {
        #expect(PCM.nanos(forFrames: .max) == .max)
        // The largest frame count whose duration fits in 64 bits: floor(max * 44100 / 1e9).
        let last = UInt64(1_000_000_000).dividingFullWidth(UInt64.max.multipliedFullWidth(by: 44_100)).quotient
        let n = PCM.nanos(forFrames: last)
        #expect(isFloor(n, numerator: wide(last, 1_000_000_000), divisor: 44_100))
        #expect(PCM.nanos(forFrames: last + 1) == .max)
    }

    @Test func roundTripLosesLessThanOneFrame() {
        for frames: UInt64 in [1, 351, 352, 1_000_003, 30 * 86_400 * 44_100 + 17] {
            let back = PCM.frames(forNanos: PCM.nanos(forFrames: frames))
            #expect(back == frames || back == frames - 1)
        }
    }

    // MARK: 128-bit checks, independent of how the conversions divide

    private typealias Wide = (high: UInt64, low: UInt64)

    private func wide(_ a: UInt64, _ b: UInt64) -> Wide {
        let p = a.multipliedFullWidth(by: b)
        return (p.high, p.low)
    }

    private func less(_ a: Wide, _ b: Wide) -> Bool { a.high != b.high ? a.high < b.high : a.low < b.low }

    /// q == floor(numerator / divisor)  ⇔  q·d ≤ numerator < (q+1)·d
    private func isFloor(_ q: UInt64, numerator: Wide, divisor: UInt64) -> Bool {
        let lower = wide(q, divisor)
        let (q1, overflow) = q.addingReportingOverflow(1)
        let upperExceeds = overflow ? true : less(numerator, wide(q1, divisor))
        return !less(numerator, lower) && upperExceeds
    }
}
