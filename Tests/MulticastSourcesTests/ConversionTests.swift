import Foundation
import MulticastAudio
import Testing
@testable import MulticastSources

@Suite struct ConversionTests {
    @Test func floatToInt16ClipsAndRounds() {
        #expect(SampleConversion.int16(fromFloat: 0) == 0)
        #expect(SampleConversion.int16(fromFloat: 1) == 32767)
        #expect(SampleConversion.int16(fromFloat: 2) == 32767)
        #expect(SampleConversion.int16(fromFloat: -1) == -32767)
        #expect(SampleConversion.int16(fromFloat: -5) == -32768)
        #expect(SampleConversion.int16(fromFloat: .nan) == 0)
        #expect(SampleConversion.int16(fromFloat: 0.5) == 16384) // 16383.5 rounds away
    }

    @Test func monoUpmixDuplicates() {
        let mono: [Float] = [0.1, -0.2, 0.3]
        var l = [Float](repeating: 0, count: 3), r = [Float](repeating: 0, count: 3)
        mono.withUnsafeBufferPointer { m in
            SampleConversion.toStereo(planar: [m.baseAddress!], frames: 3, left: &l, right: &r)
        }
        #expect(l == mono && r == mono)
    }

    @Test func multichannelKeepsFrontPair() {
        let a: [Float] = [1, 2], b: [Float] = [3, 4], c: [Float] = [5, 6]
        var l = [Float](repeating: 0, count: 2), r = [Float](repeating: 0, count: 2)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in c.withUnsafeBufferPointer { pc in
            SampleConversion.toStereo(planar: [pa.baseAddress!, pb.baseAddress!, pc.baseAddress!], frames: 2, left: &l, right: &r)
        } } }
        #expect(l == a && r == b)
    }

    @Test func interleave() {
        let l: [Float] = [0, 1], r: [Float] = [-1, 0.5]
        var out = [Int16](repeating: 0, count: 4)
        SampleConversion.interleaveToS16(left: l, right: r, frames: 2, into: &out)
        #expect(out == [0, -32767, 32767, 16384])
    }

    private func convert(rate: Double, seconds: Double, freq: Double) throws -> [Int16] {
        let conv = try PipelineConverter(inputSampleRate: rate, maxInputFrames: 4096)
        let total = Int(rate * seconds)
        var out: [Int16] = []
        var l = [Float](repeating: 0, count: 4096), r = [Float](repeating: 0, count: 4096)
        var i = 0
        while i < total {
            let n = min(4096, total - i)
            for k in 0..<n {
                let v = Float(0.5 * sin(2 * Double.pi * freq * Double(i + k) / rate))
                l[k] = v
                r[k] = -v
            }
            try conv.convert(left: l, right: r, frames: n) { p, f in out.append(contentsOf: UnsafeBufferPointer(start: p, count: f * 2)) }
            i += n
        }
        try conv.finish { p, f in out.append(contentsOf: UnsafeBufferPointer(start: p, count: f * 2)) }
        return out
    }

    @Test func resample48kTo44k1PreservesLengthAndPitch() throws {
        let out = try convert(rate: 48_000, seconds: 2, freq: 1000)
        let frames = out.count / 2
        #expect(abs(frames - 88_200) <= 64, "got \(frames) frames")
        let l = TestAudio.channel(out, 0)
        let f = TestAudio.estimateFrequency(Array(l[4000..<80000]), sampleRate: 44100)
        #expect(abs(f - 1000) < 1, "estimated \(f) Hz")
        let peak = TestAudio.peak(l[4000..<80000])
        #expect(abs(peak - 16384) < 400)
        // Channels kept apart (R is inverted L).
        let r = TestAudio.channel(out, 1)
        #expect(abs(Int(l[10_000]) + Int(r[10_000])) <= 2)
    }

    @Test func resample22050UpTo44k1() throws {
        let out = try convert(rate: 22_050, seconds: 1, freq: 440)
        #expect(abs(out.count / 2 - 44_100) <= 64)
        let f = TestAudio.estimateFrequency(Array(TestAudio.channel(out, 0)[2000..<40000]), sampleRate: 44100)
        #expect(abs(f - 440) < 1)
    }

    @Test func passThroughAt44k1IsLengthExact() throws {
        let out = try convert(rate: 44_100, seconds: 1, freq: 440)
        #expect(out.count / 2 == 44_100)
    }

    @Test func expectedOutputFrames() {
        #expect(SampleConversion.expectedOutputFrames(inputFrames: 48_000, inputRate: 48_000) == 44_100)
        #expect(SampleConversion.expectedOutputFrames(inputFrames: 4096, inputRate: 44_100) == 4096)
    }
}
