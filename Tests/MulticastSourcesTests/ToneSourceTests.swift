import Foundation
import MulticastAudio
import Testing
@testable import MulticastSources

@Suite struct ToneSourceTests {
    @Test func finiteToneHasExactLengthAndEnds() {
        let tone = ToneSource(frequency: 1000, amplitude: 0.5, duration: 0.1, fadeIn: 0.01, fadeOut: 0.01)
        #expect(!tone.isLive)
        let (s, ended) = TestAudio.drain(tone)
        #expect(ended)
        #expect(s.count / 2 == 4410)
        var buf = [Int16](repeating: 0, count: 2 * 352)
        #expect(buf.withUnsafeMutableBufferPointer { tone.read(into: $0.baseAddress!, frameCount: 352) } == nil)
        #expect(tone.framesRendered == 4410)
    }

    @Test func frequencyAmplitudeAndStereo() {
        let tone = ToneSource(frequency: 440, amplitude: 0.25, duration: 1.0, fadeIn: 0.02, fadeOut: 0.02)
        let (s, _) = TestAudio.drain(tone)
        let l = TestAudio.channel(s, 0), r = TestAudio.channel(s, 1)
        #expect(l == r)
        let f = TestAudio.estimateFrequency(Array(l[2000..<40000]), sampleRate: 44100)
        #expect(abs(f - 440) < 0.5)
        let peak = TestAudio.peak(l[5000..<30000])
        let expected = Int(0.25 * 32767)
        #expect(abs(peak - expected) <= 3)
    }

    @Test func fadesStartAndEndAtSilence() {
        let tone = ToneSource(frequency: 1000, amplitude: 0.5, duration: 0.5, fadeIn: 0.05, fadeOut: 0.05)
        let (s, _) = TestAudio.drain(tone)
        let l = TestAudio.channel(s, 0)
        #expect(l[0] == 0)
        // First 1 ms is far quieter than full scale (raised-cosine ramp).
        #expect(TestAudio.peak(l[0..<44]) < 200)
        // Mid-fade ≈ half amplitude.
        let mid = TestAudio.peak(l[1080..<1125])
        #expect(abs(mid - Int(0.5 * 0.5 * 32767)) < 1200)
        // Fully faded in after 50 ms.
        #expect(TestAudio.peak(l[3000..<6000]) > 16000)
        // Last ms is nearly silent; very last sample ~0.
        #expect(TestAudio.peak(l[(l.count - 44)...]) < 200)
        #expect(abs(Int(l.last!)) < 20)
    }

    @Test func envelopeMath() {
        #expect(ToneSource.envelope(frame: 0, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: -1) == 0)
        #expect(abs(ToneSource.envelope(frame: 50, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: -1) - 0.5) < 1e-9)
        #expect(ToneSource.envelope(frame: 100, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: -1) == 1)
        #expect(ToneSource.envelope(frame: 500, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: 1000) == 1)
        #expect(abs(ToneSource.envelope(frame: 1050, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: 1000) - 0.5) < 1e-9)
        #expect(ToneSource.envelope(frame: 1100, fadeInFrames: 100, fadeOutFrames: 100, fadeOutBegin: 1000) == 0)
    }

    @Test func infiniteToneFadesOutOnRequest() {
        let tone = ToneSource(frequency: 500, amplitude: 0.3, duration: nil, fadeIn: 0.01, fadeOut: 0.02)
        let (first, ended) = TestAudio.drain(tone, maxFrames: 10_000)
        #expect(!ended)
        #expect(first.count == 20_000)
        tone.requestFadeOut()
        let (rest, ended2) = TestAudio.drain(tone)
        #expect(ended2)
        #expect(rest.count / 2 == 882) // 20 ms
        #expect(abs(Int(rest[rest.count - 2])) < 30)
    }

    @Test func fadesAreScaledWhenLongerThanTone() {
        let tone = ToneSource(frequency: 1000, amplitude: 0.5, duration: 0.01, fadeIn: 0.05, fadeOut: 0.05)
        let (s, ended) = TestAudio.drain(tone)
        #expect(ended)
        #expect(s.count / 2 == 441)
    }
}
