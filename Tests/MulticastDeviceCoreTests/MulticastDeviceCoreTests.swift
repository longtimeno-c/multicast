import Foundation
import MulticastDeviceCore
import Testing

private func stereo(_ frames: Int, start: Float = 1) -> [Float] {
    (0..<frames).flatMap { i in [start + Float(i), -(start + Float(i))] }
}

@Suite struct LoopbackRingTests {
    @Test func readsBackWhatWasWrittenAtTheSameSampleTimes() {
        let ring = MCLoopbackCreate(1024)!
        defer { MCLoopbackDestroy(ring) }
        let input = stereo(256)
        MCLoopbackWrite(ring, 5000, input, 256, 1)
        var out = [Float](repeating: 9, count: 256 * 2)
        #expect(MCLoopbackRead(ring, 5000, &out, 256) == 256)
        #expect(out == input)
        #expect(MCLoopbackWriteEnd(ring) == 5256)
    }

    @Test func framesNeverWrittenAreSilence() {
        let ring = MCLoopbackCreate(1024)!
        defer { MCLoopbackDestroy(ring) }
        var out = [Float](repeating: 9, count: 8)
        #expect(MCLoopbackRead(ring, 0, &out, 4) == 0)
        #expect(out == [Float](repeating: 0, count: 8))
        MCLoopbackWrite(ring, 100, stereo(10), 10, 1)
        // Straddles the end of the run: 5 real, 5 silent.
        var tail = [Float](repeating: 9, count: 20)
        #expect(MCLoopbackRead(ring, 105, &tail, 10) == 5)
        #expect(Array(tail[10...]) == [Float](repeating: 0, count: 10))
        // Before the run started.
        var before = [Float](repeating: 9, count: 20)
        #expect(MCLoopbackRead(ring, 90, &before, 10) == 0)
    }

    @Test func aGapStartsANewRunSoOldLapsNeverLeak() {
        let ring = MCLoopbackCreate(64)!
        defer { MCLoopbackDestroy(ring) }
        MCLoopbackWrite(ring, 0, stereo(64), 64, 1)
        // Output stops, then restarts much later: frames in between must be silence, not the
        // ring's old contents that happen to sit in the same slots.
        MCLoopbackWrite(ring, 1000, stereo(8, start: 500), 8, 1)
        var gap = [Float](repeating: 9, count: 16)
        #expect(MCLoopbackRead(ring, 992, &gap, 8) == 0)
        #expect(gap == [Float](repeating: 0, count: 16))
        var fresh = [Float](repeating: 0, count: 16)
        #expect(MCLoopbackRead(ring, 1000, &fresh, 8) == 8)
        #expect(fresh == stereo(8, start: 500))
    }

    @Test func overwrittenLapsAreNotReadable() {
        let ring = MCLoopbackCreate(64)!
        defer { MCLoopbackDestroy(ring) }
        for block in 0..<4 { MCLoopbackWrite(ring, Int64(block * 32), stereo(32, start: Float(block * 100)), 32, 1) }
        // 128 frames written into 64 slots: only [64, 128) survives.
        var old = [Float](repeating: 9, count: 64)
        #expect(MCLoopbackRead(ring, 32, &old, 32) == 0)
        var kept = [Float](repeating: 0, count: 128)
        #expect(MCLoopbackRead(ring, 64, &kept, 64) == 64)
        #expect(Array(kept[0..<64]) == stereo(32, start: 200))
    }

    @Test func appliesGainAndResetSilences() {
        let ring = MCLoopbackCreate(64)!
        defer { MCLoopbackDestroy(ring) }
        MCLoopbackWrite(ring, 0, [1, -1, 0.5, -0.5], 2, 0.5)
        var out = [Float](repeating: 0, count: 4)
        MCLoopbackRead(ring, 0, &out, 2)
        #expect(out == [0.5, -0.5, 0.25, -0.25])
        MCLoopbackReset(ring)
        #expect(MCLoopbackRead(ring, 0, &out, 2) == 0)
    }

    @Test func capacityRoundsUpToAPowerOfTwo() {
        let ring = MCLoopbackCreate(1000)!
        defer { MCLoopbackDestroy(ring) }
        #expect(MCLoopbackCapacity(ring) == 1024)
    }

    @Test func oversizedWriteKeepsTheNewestFrames() {
        let ring = MCLoopbackCreate(4)!
        defer { MCLoopbackDestroy(ring) }
        MCLoopbackWrite(ring, 0, stereo(6), 6, 1)
        var out = [Float](repeating: 0, count: 8)
        #expect(MCLoopbackRead(ring, 2, &out, 4) == 4)
        #expect(out == Array(stereo(6)[4...]))
    }
}

@Suite struct DeviceClockTests {
    @Test func ticksPerFrameFollowsTheTimebase() {
        // Apple silicon: 125/3 ns per tick (24 MHz).
        let t = MCHostTicksPerFrame(44_100, 125, 3)
        #expect(abs(t * 44_100 - 24_000_000) < 1e-3)
        #expect(MCHostTicksPerFrame(48_000, 1, 1) * 48_000 == 1e9)
        #expect(MCHostTicksPerFrame(0, 1, 1) == 0)
    }

    @Test func zeroTimeStampsStepOncePerPeriodAtTheNominalRate() {
        let tpf = MCHostTicksPerFrame(44_100, 1, 1) // nanoseconds
        let anchor: UInt64 = 1_000_000
        let period = UInt32(MC_PERIOD_FRAMES)
        var sample = 0.0, host: UInt64 = 0, seed: UInt64 = 0
        MCClockZeroTimeStamp(anchor, tpf, period, anchor, &sample, &host, &seed)
        #expect(sample == 0 && host == anchor && seed == 1)
        // Just short of one period.
        let onePeriod = UInt64((tpf * Double(period)).rounded())
        MCClockZeroTimeStamp(anchor, tpf, period, anchor + onePeriod - 10, &sample, &host, &seed)
        #expect(sample == 0)
        // Ten periods later (about 3.7 s at 44.1 kHz) the host time is exact to a tick.
        MCClockZeroTimeStamp(anchor, tpf, period, anchor + 10 * onePeriod + 5, &sample, &host, &seed)
        #expect(sample == Double(10 * period))
        let expected = Double(anchor) + 10 * Double(period) * 1e9 / 44_100
        #expect(abs(Double(host) - expected) <= 1)
        // Before the anchor (never expected, but must not wrap).
        MCClockZeroTimeStamp(anchor, tpf, period, 0, &sample, &host, &seed)
        #expect(sample == 0 && host == anchor)
    }

    @Test func oneHourOfSampleTimeMatchesHostTimeAtTheNominalRate() {
        // The hub's pacer runs on host time at 44.1 kHz; the device must not drift against it.
        let tpf = MCHostTicksPerFrame(44_100, 125, 3)
        let period = UInt32(MC_PERIOD_FRAMES)
        let hour: UInt64 = 3600 * 24_000_000
        var sample = 0.0, host: UInt64 = 0, seed: UInt64 = 0
        MCClockZeroTimeStamp(0, tpf, period, hour, &sample, &host, &seed)
        let impliedRate = sample / (Double(host) / 24_000_000)
        #expect(abs(impliedRate - 44_100) < 1e-6)
    }
}

@Suite struct DeviceVolumeTests {
    @Test func scalarAndDecibelsRoundTrip() {
        for s: Float in [0, 0.1, 0.25, 0.5, 0.75, 1] {
            #expect(abs(MCVolumeDecibelsToScalar(MCVolumeScalarToDecibels(s)) - s) < 1e-5)
        }
        #expect(MCVolumeScalarToDecibels(0) == MC_VOLUME_MIN_DB)
        #expect(MCVolumeScalarToDecibels(1) == 0)
        #expect(MCVolumeDecibelsToScalar(-200) == 0)
        #expect(MCVolumeDecibelsToScalar(6) == 1)
        #expect(MCVolumeScalarToDecibels(.nan) == MC_VOLUME_MIN_DB)
    }

    @Test func gainIsZeroWhenMutedAndMonotonic() {
        #expect(MCVolumeGain(1, true) == 0)
        #expect(MCVolumeGain(0, false) == 0)
        #expect(MCVolumeGain(1, false) == 1)
        #expect(abs(MCVolumeGain(0.5, false) - powf(10, -32 / 20)) < 1e-6)
        var last: Float = -1
        for i in 0...20 {
            let g = MCVolumeGain(Float(i) / 20, false)
            #expect(g >= last)
            last = g
        }
    }
}

@Suite struct DeviceFormatTests {
    @Test func offersThePipelineRateFirstAnd48k() {
        #expect(MCSupportedSampleRateCount() == 2)
        #expect(MCSupportedSampleRate(0) == 44_100)
        #expect(MCSupportedSampleRate(1) == 48_000)
        #expect(MCSupportedSampleRate(2) == 0)
        #expect(MCIsSupportedSampleRate(44_100))
        #expect(!MCIsSupportedSampleRate(96_000))
    }

    @Test func latencyFramesClampAndRound() {
        #expect(MCLatencyFrames(2, 44_100) == 88_200)
        #expect(MCLatencyFrames(1.5, 48_000) == 72_000)
        #expect(MCLatencyFrames(-1, 44_100) == 0)
        #expect(MCLatencyFrames(60, 44_100) == 441_000)
        #expect(MCLatencyFrames(.nan, 44_100) == 0)
    }
}
