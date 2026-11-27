import Foundation
import MulticastAudio
import Testing
@testable import MulticastCalibration

/// A repeatable noise generator (the tests must not depend on luck).
struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    private mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }

    /// Gaussian, unit variance.
    mutating func next() -> Double {
        sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
    }
}

/// A made-up microphone recording: the sweep arriving `delay` seconds in, optional echoes
/// (later copies), and noise.
func recording(signal: CalibrationSignal, sampleRate: Double, seconds: Double, delay: Double?,
               level: Double = 0.05, echoes: [(after: Double, gain: Double)] = [], noise: Double = 0,
               seed: UInt64 = 1) -> [Float] {
    var generator = SeededNoise(seed: seed)
    return (0..<Int(seconds * sampleRate)).map { i in
        let t = Double(i) / sampleRate
        var v = noise * generator.next()
        if let delay {
            v += level * signal.value(at: t - delay)
            for e in echoes { v += level * e.gain * signal.value(at: t - delay - e.after) }
        }
        return Float(v)
    }
}

@Suite("Calibration signal")
struct CalibrationSignalTests {
    @Test func sweepStartsAndEndsAtSilenceAndStaysInRange() {
        let signal = CalibrationSignal()
        let template = signal.template(sampleRate: 44_100)
        #expect(template.count == 11_025)
        #expect(abs(template.first!) < 1e-6 && abs(template.last!) < 0.01)
        #expect(template.map(abs).max()! <= 1)
        #expect(template.map(abs).max()! > 0.95)
        #expect(signal.value(at: -0.001) == 0 && signal.value(at: signal.sweepSeconds) == 0)
    }

    @Test func sourcePlaysASweepEveryPeriodAfterTheLeadIn() async throws {
        let signal = CalibrationSignal(sweepSeconds: 0.05, periodSeconds: 0.2, leadInSeconds: 0.1, amplitude: 0.5)
        let source = CalibrationSource(signal: signal)
        try await source.start()
        let frames = 22_050
        var buffer = [Int16](repeating: 0, count: frames * 2)
        // Read in engine-sized packets, as the pacing thread does.
        var done = 0
        while done < frames {
            let n = min(PCM.framesPerPacket, frames - done)
            let got = buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress! + 2 * done, frameCount: n) }
            #expect(got == n)
            done += n
        }
        let left = stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }
        let right = stride(from: 1, to: buffer.count, by: 2).map { buffer[$0] }
        #expect(left == right)
        func isSilent(_ range: Range<Int>) -> Bool { left[range].allSatisfy { $0 == 0 } }
        func peak(_ range: Range<Int>) -> Int { left[range].map { abs(Int($0)) }.max() ?? 0 }
        let first = Int(signal.startFrame(ofSweep: 0)), second = Int(signal.startFrame(ofSweep: 1))
        #expect(first == 4410 && second == 4410 + 8820)
        #expect(isSilent(0..<first))
        #expect(abs(peak(first..<first + signal.sweepFrames) - 16_383) < 400)
        #expect(isSilent(first + signal.sweepFrames..<second))
        #expect(Array(left[first..<first + signal.sweepFrames]) == Array(left[second..<second + signal.sweepFrames]))

        // Starting again starts the count again.
        try await source.start()
        var again = [Int16](repeating: 1, count: 2 * 352)
        _ = again.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: 352) }
        #expect(again.allSatisfy { $0 == 0 })
    }
}

@Suite("Delay estimator")
struct DelayEstimatorTests {
    let signal = CalibrationSignal()

    @Test(arguments: [0.0123, 0.1502, 0.33337, 0.7001])
    func recoversADelayThroughNoiseAndAnEcho(delay: Double) throws {
        // Sweep at 0.05, noise at 0.05 RMS (as loud as the sweep's peak), an echo 7 ms later.
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.15, delay: delay,
                            echoes: [(after: 0.007, gain: 0.7)], noise: 0.05, seed: 7)
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000))
        #expect(abs(arrival.seconds - delay) < 0.001)
        #expect(arrival.strength > 6.5)
    }

    @Test func isAccurateToAFractionOfAMillisecondWhenClean() throws {
        for rate in [44_100.0, 48_000.0, 16_000.0] {
            let delay = 0.20013
            let rec = recording(signal: signal, sampleRate: rate, seconds: 1.0, delay: delay, noise: 0.001)
            let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: rate))
            #expect(abs(arrival.seconds - delay) < 0.0002, "rate \(rate): off by \((arrival.seconds - delay) * 1000) ms")
        }
    }

    @Test func takesTheDirectSoundWhenAReflectionIsLouder() throws {
        let delay = 0.25
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.0, delay: delay,
                            echoes: [(after: 0.011, gain: 1.4), (after: 0.019, gain: 0.6)], noise: 0.01, seed: 3)
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000))
        #expect(abs(arrival.seconds - delay) < 0.001)
    }

    @Test func worksWhenTheSpeakerIsWiredOutOfPhase() throws {
        let rec = recording(signal: signal, sampleRate: 44_100, seconds: 1.0, delay: 0.1, level: -0.05, noise: 0.01)
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 44_100))
        #expect(abs(arrival.seconds - 0.1) < 0.001)
    }

    @Test func hearsAQuietSweepUnderLouderNoise() throws {
        // The sweep's peak is a third of the noise's RMS: inaudible in the recording by eye.
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.15, delay: 0.4, level: 0.01, noise: 0.03, seed: 11)
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000))
        #expect(abs(arrival.seconds - 0.4) < 0.001)
    }

    @Test(arguments: Array(1...40) as [UInt64])
    func refusesNoiseAlone(seed: UInt64) {
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.15, delay: nil, noise: 0.05, seed: seed)
        #expect(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000) == nil)
    }

    @Test func refusesSilenceATonAndARecordingThatIsTooShort() {
        let estimator = DelayEstimator(signal: signal)
        #expect(estimator.arrival(in: [Float](repeating: 0, count: 48_000), sampleRate: 48_000) == nil)
        let hum = (0..<48_000).map { Float(0.2 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        #expect(estimator.arrival(in: hum, sampleRate: 48_000) == nil)
        #expect(estimator.arrival(in: [Float](repeating: 0.1, count: 1000), sampleRate: 48_000) == nil)
        #expect(estimator.arrival(in: [], sampleRate: 48_000) == nil)
    }

    /// A quiet room with one loud event in it: a burst of noise, a click, a shout.
    static func roomWithAnEvent(_ kind: Int, seed: UInt64) -> [Float] {
        var generator = SeededNoise(seed: seed)
        let rate = 48_000.0
        return (0..<Int(1.15 * rate)).map { i in
            let t = Double(i) / rate
            var v = 0.002 * generator.next()
            switch kind {
            case 0: if t > 0.5, t < 0.62 { v += 0.2 * generator.next() }               // a burst of noise
            case 1: if i == 30_000 || i == 30_900 { v += 0.9 }                          // clicks
            case 2: if t > 0.4, t < 0.7 { v += 0.3 * sin(2 * .pi * (1800 + 900 * sin(2 * .pi * 5 * t)) * t) }  // a wavering voice-like tone
            default:                                                                     // a chord swelling and fading, in the sweep's band
                let swell = max(0, sin(2 * .pi * 2 * t))
                for f in [1100.0, 1730, 2450, 3300, 4700, 5900] { v += 0.05 * swell * sin(2 * .pi * f * t + f) }
            }
            return Float(v)
        }
    }

    @Test(arguments: [0, 1, 2, 3], [1, 2, 3] as [UInt64])
    func refusesALoudEventInAQuietRoom(kind: Int, seed: UInt64) {
        let rec = Self.roomWithAnEvent(kind, seed: seed)
        #expect(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000) == nil)
    }

    @Test func stillHearsTheSweepNextToALoudEvent() throws {
        var rec = Self.roomWithAnEvent(0, seed: 9)
        let sweep = recording(signal: signal, sampleRate: 48_000, seconds: 1.15, delay: 0.2, level: 0.02)
        for i in rec.indices { rec[i] += sweep[i] }
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000))
        #expect(abs(arrival.seconds - 0.2) < 0.001)
    }

    @Test func hearsASweepAtTheVeryStartOfTheRecording() throws {
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.0, delay: 0.0004, noise: 0.01)
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000))
        #expect(abs(arrival.seconds - 0.0004) < 0.001)
    }

    @Test func aSweepTooFaintToTrustIsRefused() {
        let rec = recording(signal: signal, sampleRate: 48_000, seconds: 1.15, delay: 0.4, level: 0.0005, noise: 0.05, seed: 5)
        #expect(DelayEstimator(signal: signal).arrival(in: rec, sampleRate: 48_000) == nil)
    }
}

@Suite("Delay measurement")
struct DelayMeasurementTests {
    @Test func agreeingSweepsGiveTheirMedian() {
        let m = DelayMeasurement.combine([0.1502, 0.1500, nil, 0.1504, 0.1501])
        guard case .measured(let seconds, let spread) = m else { Issue.record("expected a measurement, got \(m)"); return }
        #expect(abs(seconds - 0.15015) < 1e-9)
        #expect(abs(spread - 0.0004) < 1e-9)
    }

    @Test func oneStrayReadingIsLeftOut() {
        let m = DelayMeasurement.combine([0.150, 0.151, 0.420, 0.1505])
        guard case .measured(let seconds, _) = m else { Issue.record("expected a measurement, got \(m)"); return }
        #expect(abs(seconds - 0.1505) < 1e-9)
    }

    @Test func tooFewHeardIsNotHeard() {
        #expect(DelayMeasurement.combine([nil, 0.2, nil, 0.2]) == .notHeard)
        #expect(DelayMeasurement.combine([nil, nil, nil, nil]) == .notHeard)
        #expect(DelayMeasurement.combine([]) == .notHeard)
    }

    @Test func readingsThatDisagreeAreInconsistent() {
        #expect(DelayMeasurement.combine([0.10, 0.25, 0.40, 0.31]) == .inconsistent)
    }
}

@Suite("Trim planner")
struct TrimPlannerTests {
    let range = -500...500

    @Test func lateSpeakersMoveEarlierToTheEarliest() {
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 12.2, currentTrimMs: 0),
            .init(id: "b", delayMs: 187.6, currentTrimMs: 0),
            .init(id: "c", delayMs: 40.0, currentTrimMs: 0),
        ], range: range)
        #expect(out.map(\.trimMs) == [0, -175, -28])
        #expect(out.map { $0.lagMs.rounded() } == [0, 175, 28])
        #expect(out.allSatisfy { !$0.isOutOfRange })
    }

    @Test func trimsAlreadySetAreAccountedFor() {
        // b was measured only 20 ms late, but with 150 ms of "earlier" already dialled in.
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 10, currentTrimMs: 0),
            .init(id: "b", delayMs: 30, currentTrimMs: -150),
        ], range: range)
        #expect(out.map(\.trimMs) == [0, -170])
        #expect(out[1].lagMs == 170)
    }

    @Test func speakersAlreadyLinedUpKeepTheirTrims() {
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 25, currentTrimMs: 40),
            .init(id: "b", delayMs: 25, currentTrimMs: -120),
        ], range: range)
        #expect(out.map(\.trimMs) == [40, -120])
    }

    @Test func thePreferredReferenceKeepsItsTrimEvenWhenNotTheEarliest() {
        let out = TrimPlanner.plan([
            .init(id: "early", delayMs: 5, currentTrimMs: 0),
            .init(id: "mac", delayMs: 20, currentTrimMs: 10, isPreferredReference: true),
            .init(id: "late", delayMs: 220, currentTrimMs: 0),
        ], range: range)
        #expect(out.map(\.trimMs) == [15, 10, -200])
        #expect(out.map(\.lagMs) == [-5, 0, 210])
    }

    @Test func aSingleSpeakerKeepsItsTrim() {
        let out = TrimPlanner.plan([.init(id: "only", delayMs: 300, currentTrimMs: -35)], range: range)
        #expect(out == [.init(id: "only", trimMs: -35, lagMs: 0, isOutOfRange: false, isReference: true)])
        #expect(TrimPlanner.plan([], range: range).isEmpty)
    }

    @Test func allMoveTogetherWhenThatBringsThemIntoRange() {
        // b would need -700; moving both 200 later keeps them lined up and in range.
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 0, currentTrimMs: 0),
            .init(id: "b", delayMs: 700, currentTrimMs: 0),
        ], range: range)
        #expect(out.map(\.trimMs) == [200, -500])
        #expect(out.allSatisfy { !$0.isOutOfRange })
    }

    @Test func whatCannotBeReachedIsClampedAndSaid() {
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 0, currentTrimMs: 0),
            .init(id: "b", delayMs: 1200, currentTrimMs: 0),
        ], range: range)
        #expect(out.map(\.trimMs) == [0, -500])
        #expect(out.map(\.isOutOfRange) == [false, true])
        #expect(out.allSatisfy { range.contains($0.trimMs) })
    }

    @Test func halvesRoundToWholeMilliseconds() {
        let out = TrimPlanner.plan([
            .init(id: "a", delayMs: 0, currentTrimMs: 0),
            .init(id: "b", delayMs: 12.4, currentTrimMs: 0),
            .init(id: "c", delayMs: 12.6, currentTrimMs: 0),
        ], range: range)
        #expect(out.map(\.trimMs) == [0, -12, -13])
    }
}

@Suite("Recording ring")
struct RecordingRingTests {
    /// A ramp, so every sample says which frame it is.
    private func fill(_ ring: RecordingRing, frames: Int, bufferFrames: Int, startNanos: UInt64) {
        var frame = 0
        while frame < frames {
            let n = min(bufferFrames, frames - frame)
            let host = startNanos + UInt64(Double(frame) * 1e9 / ring.sampleRate)
            ring.append((frame..<frame + n).map { Float($0) }, hostNanos: host)
            frame += n
        }
    }

    @Test func answersByTime() throws {
        let ring = RecordingRing(sampleRate: 48_000, seconds: 4)
        fill(ring, frames: 96_000, bufferFrames: 480, startNanos: 5_000_000_000)
        // Half a second in, for a quarter of a second.
        let r = try #require(ring.recording(fromHostNanos: 5_500_000_000, seconds: 0.25))
        #expect(r.samples.count == 12_000)
        #expect(r.samples.first == 24_000 && r.samples.last == 35_999)
        #expect(r.startHostNanos == 5_500_000_000)
    }

    @Test func aStartBetweenSamplesReportsTheSampleItReallyStartsAt() throws {
        let ring = RecordingRing(sampleRate: 48_000, seconds: 4)
        fill(ring, frames: 48_000, bufferFrames: 512, startNanos: 1_000_000_000)
        // 10.5 samples after frame 4800.
        let asked: UInt64 = 1_100_000_000 + 218_750
        let r = try #require(ring.recording(fromHostNanos: asked, seconds: 0.1))
        #expect(r.samples.first == 4811)
        #expect(abs(Double(r.startHostNanos) - (1_000_000_000 + 4811 * 1e9 / 48_000)) <= 1)
        #expect(r.startHostNanos >= asked)
    }

    @Test func whatIsNotRecordedYetOrAlreadyGoneIsNil() {
        let ring = RecordingRing(sampleRate: 48_000, seconds: 1)
        #expect(ring.recording(fromHostNanos: 0, seconds: 0.1) == nil)
        fill(ring, frames: 96_000, bufferFrames: 480, startNanos: 1_000_000_000)
        // Ends after the last sample recorded.
        #expect(ring.recording(fromHostNanos: 2_950_000_000, seconds: 0.1) == nil)
        // Began more than the ring's second ago.
        #expect(ring.recording(fromHostNanos: 1_500_000_000, seconds: 0.1) == nil)
        // Longer than the ring.
        #expect(ring.recording(fromHostNanos: 2_000_000_000, seconds: 2) == nil)
        #expect(ring.recording(fromHostNanos: 2_500_000_000, seconds: 0.1)?.samples.first == 72_000)
    }

    @Test func takesOneChannelOutOfInterleavedAudio() throws {
        let ring = RecordingRing(sampleRate: 1000, seconds: 1)
        let interleaved: [Float] = (0..<200).map { $0 % 2 == 0 ? Float($0 / 2) : -1 }
        interleaved.withUnsafeBufferPointer { ring.append($0.baseAddress!, frames: 100, stride: 2, hostNanos: 0) }
        let r = try #require(ring.recording(fromHostNanos: 10_000_000, seconds: 0.05))
        #expect(r.samples == (10..<60).map { Float($0) })
    }

    @Test func aRecordingMadeThroughTheRingGivesTheSameDelay() throws {
        // End to end without a device: a sweep due at a known host time, heard 37.5 ms late.
        let signal = CalibrationSignal()
        let rate = 48_000.0, due: UInt64 = 20_000_000_000, late = 0.0375
        let ringStart: UInt64 = 19_000_000_000
        let all = recording(signal: signal, sampleRate: rate, seconds: 2.5, delay: 1.0 + late, noise: 0.01)
        let ring = RecordingRing(sampleRate: rate, seconds: 4)
        var i = 0
        while i < all.count {
            let n = min(441, all.count - i)
            ring.append(Array(all[i..<i + n]), hostNanos: ringStart + UInt64(Double(i) * 1e9 / rate))
            i += n
        }
        let r = try #require(ring.recording(fromHostNanos: due - 150_000_000, seconds: 1.0))
        let arrival = try #require(DelayEstimator(signal: signal).arrival(in: r.samples, sampleRate: rate))
        let delay = (Double(r.startHostNanos) + arrival.seconds * 1e9 - Double(due)) / 1e9
        #expect(abs(delay - late) < 0.0003)
    }
}
