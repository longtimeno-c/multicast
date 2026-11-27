import CryptoKit
import Foundation
import MulticastAudio
import Testing
@testable import MulticastRemote

/// Deterministic random numbers, so a failing run can be repeated.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Exponentially distributed with the given mean.
    mutating func exponential(mean: Double) -> Double {
        -mean * log(1 - Double.random(in: 0..<1, using: &self))
    }
}

func testPacket(_ index: Int, value: Int16 = 1000) -> Data {
    var samples = [Int16](repeating: value, count: PCM.framesPerPacket * PCM.channels)
    samples[0] = Int16(truncatingIfNeeded: index)
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

func sample(_ data: Data, _ i: Int) -> Int16 {
    data.withUnsafeBytes { $0.bindMemory(to: Int16.self)[i] }
}

func mustSeal(_ sealer: inout DatagramSealer, _ datagram: AudioDatagram) -> Data {
    sealer.seal(datagram) ?? Data()
}

private func channelKeys() -> (hub: AudioChannelKeys, phone: AudioChannelKeys) {
    let salt = Data(repeating: 7, count: AudioChannel.saltLength)
    let hubToRemote = SymmetricKey(data: Data(repeating: 1, count: 32))
    let remoteToHub = SymmetricKey(data: Data(repeating: 2, count: 32))
    let down = AudioChannel.key(from: hubToRemote, salt: salt, direction: AudioChannel.hubToPhone)
    let up = AudioChannel.key(from: remoteToHub, salt: salt, direction: AudioChannel.phoneToHub)
    return (AudioChannelKeys(send: down, receive: up), AudioChannelKeys(send: up, receive: down))
}

@Suite("Audio datagrams")
struct AudioDatagramTests {
    private let timeline = StreamTimeline(anchorHostNanos: 123_456_789_000, anchorFrame: 3520, latencyNanos: 2_000_000_000)

    @Test func everyKindSurvivesSealing() throws {
        let keys = channelKeys()
        var sealer = DatagramSealer(key: keys.hub.send)
        var opener = DatagramOpener(key: keys.phone.receive)
        let all: [AudioDatagram] = [
            .audio(epoch: 7, firstFrame: 1_000_032, samples: testPacket(3)),
            .control(StreamControl(epoch: 9, isActive: true, timeline: timeline, volume: 0.25, offsetMillis: -120)),
            .clockReply(t1: 1, t2: UInt64.max - 5, t3: 99),
            .hello(t1: 42, status: 1),
            .nack(epoch: 3, frames: [352, 704, 99_968]),
        ]
        for d in all {
            let sealed = mustSeal(&sealer, (d))
            #expect(opener.open(sealed) == d)
        }
    }

    @Test func anAudioDatagramFitsOneUnfragmentedPacket() throws {
        var sealer = DatagramSealer(key: channelKeys().hub.send)
        let sealed = mustSeal(&sealer, (.audio(epoch: 1, firstFrame: 0, samples: testPacket(0))))
        // 1500-byte link, IPv6 (40) and UDP (8) headers.
        #expect(sealed.count <= 1452)
        #expect(sealed.count == 1445)
    }

    @Test func tamperedReplayedAndForeignDatagramsAreDropped() throws {
        let keys = channelKeys()
        var sealer = DatagramSealer(key: keys.hub.send)
        var opener = DatagramOpener(key: keys.phone.receive)
        let first = mustSeal(&sealer, (.hello(t1: 1, status: 0)))
        var bent = first
        bent[bent.count - 3] ^= 0x10
        #expect(opener.open(bent) == nil)
        var renumbered = first
        renumbered[8] ^= 1            // the sequence number is authenticated too
        #expect(opener.open(renumbered) == nil)
        #expect(opener.open(first) != nil)
        #expect(opener.open(first) == nil)                                   // replay
        var stranger = DatagramSealer(key: SymmetricKey(size: .bits256))
        #expect(opener.open(mustSeal(&stranger, (.hello(t1: 1, status: 0)))) == nil)
        #expect(opener.open(Data([1, 2, 3])) == nil)
        // The other direction's key doesn't open it either.
        var wrongWay = DatagramOpener(key: keys.hub.receive)
        #expect(wrongWay.open(mustSeal(&sealer, (.hello(t1: 2, status: 0)))) == nil)
    }

    @Test func outOfOrderDatagramsOpenOnce() throws {
        let keys = channelKeys()
        var sealer = DatagramSealer(key: keys.hub.send)
        var opener = DatagramOpener(key: keys.phone.receive)
        let sealed = try (0..<6).map { mustSeal(&sealer, (.hello(t1: UInt64($0), status: 0))) }
        for i in [0, 3, 1, 5, 2, 4] { #expect(opener.open(sealed[i]) == .hello(t1: UInt64(i), status: 0)) }
        for i in 0..<6 { #expect(opener.open(sealed[i]) == nil) }
    }

    @Test func replayWindowRemembersAndForgets() {
        var w = ReplayWindow()
        for s: UInt64 in [10, 12, 11, 300] {
            #expect(w.isFresh(s))
            w.accept(s)
            #expect(!w.isFresh(s))
        }
        #expect(!w.isFresh(12))
        #expect(w.isFresh(299))
        #expect(w.isFresh(44))        // exactly 256 back
        #expect(!w.isFresh(43))       // too old to tell: refused
        w.accept(10_000)
        #expect(!w.isFresh(300))
    }

    @Test func malformedBodiesAreRefused() {
        #expect(AudioDatagram.parse(kind: 1, body: Data(repeating: 0, count: 100)) == nil)
        #expect(AudioDatagram.parse(kind: 2, body: Data(repeating: 0, count: 3)) == nil)
        #expect(AudioDatagram.parse(kind: 17, body: Data([0, 0, 0, 1, 200])) == nil)
        #expect(AudioDatagram.parse(kind: 99, body: Data([1])) == nil)
        // A volume that isn't a number can't reach the output.
        var w = ByteWriter()
        w.u32(1); w.u8(1); w.u64(1); w.u64(2); w.u64(3); w.u32(Float.nan.bitPattern); w.u32(0)
        guard case .control(let c)? = AudioDatagram.parse(kind: 2, body: w.data) else {
            Issue.record("control didn't parse")
            return
        }
        #expect(c.volume == 0)
    }
}

@Suite("Clock estimator")
struct ClockEstimatorTests {
    /// Runs exchanges every `interval` s over a link with the given one-way delays.
    /// Returns the worst error of the estimate (ns) over the samples after `settle` seconds.
    private func run(seconds: Double, interval: Double = 0.25, driftPPM: Double, baseDelay: Double, jitterMean: Double,
                     spikeChance: Double = 0.02, asymmetry: Double = 0, settle: Double, seed: UInt64) -> (worst: Double, estimator: ClockEstimator) {
        var rng = SplitMix64(seed: seed)
        var est = ClockEstimator()
        let phoneBase = 5_000_000_000_000.0, hubBase = 91_000_000_000_000.0
        func phone(_ t: Double) -> UInt64 { UInt64(phoneBase + t * 1e9) }
        func hub(_ t: Double) -> UInt64 { UInt64(hubBase + t * 1e9 * (1 + driftPPM * 1e-6)) }
        func delay(_ extra: Double) -> Double {
            var d = baseDelay + extra + rng.exponential(mean: jitterMean)
            if Double.random(in: 0..<1, using: &rng) < spikeChance { d += Double.random(in: 0.02...0.08, using: &rng) }
            return d
        }
        var worst = 0.0
        var t = 0.0
        while t < seconds {
            let up = delay(asymmetry), down = delay(0)
            let arrive = t + up
            let replied = arrive + 0.00005
            let back = replied + down
            est.add(t1: phone(t), t2: hub(arrive), t3: hub(replied), t4: phone(back))
            if back >= settle, let estimate = est.offsetNanos(at: phone(back)) {
                let truth = Double(hub(back)) - Double(phone(back))
                worst = max(worst, abs(Double(estimate) - truth))
            }
            t += interval
        }
        return (worst, est)
    }

    @Test func aQuietLinkIsExactToMicroseconds() {
        let r = run(seconds: 60, driftPPM: 0, baseDelay: 0.001, jitterMean: 0, spikeChance: 0, settle: 1, seed: 1)
        #expect(r.worst < 5_000)
    }

    @Test func jitterAndSpikesStayUnderHalfAMillisecond() {
        for seed: UInt64 in 1...5 {
            let r = run(seconds: 120, driftPPM: 35, baseDelay: 0.0015, jitterMean: 0.003, settle: 20, seed: seed)
            #expect(r.worst < 500_000, "seed \(seed): \(r.worst / 1e6) ms")
            #expect(abs(r.estimator.driftPPM - 35) < 6, "seed \(seed): drift \(r.estimator.driftPPM)")
            #expect(r.estimator.tracksDrift)
        }
    }

    @Test func theFirstSecondsAreGoodEnoughToStart() {
        for seed: UInt64 in 1...5 {
            let r = run(seconds: 4, interval: 0.06, driftPPM: -20, baseDelay: 0.0015, jitterMean: 0.003, settle: 0.4, seed: seed)
            #expect(r.worst < 2_500_000, "seed \(seed): \(r.worst / 1e6) ms")
        }
    }

    @Test func driftIsFollowedNotAveragedAway() {
        // 100 ppm for two minutes is 12 ms: an estimator that kept one old best sample would be off by that.
        let r = run(seconds: 120, driftPPM: 100, baseDelay: 0.002, jitterMean: 0.002, settle: 30, seed: 9)
        #expect(r.worst < 600_000)
    }

    @Test func aLopsidedLinkIsWrongByHalfTheDifferenceAndNoMore() {
        let r = run(seconds: 60, driftPPM: 0, baseDelay: 0.001, jitterMean: 0, spikeChance: 0, asymmetry: 0.004, settle: 5, seed: 3)
        #expect(abs(r.worst - 2_000_000) < 50_000)
    }

    @Test func impossibleExchangesAreIgnored() {
        var est = ClockEstimator()
        #expect(est.add(t1: 100, t2: 50, t3: 40, t4: 200) == nil)      // answered before received
        #expect(est.add(t1: 100, t2: 50, t3: 60, t4: 90) == nil)       // back before sent
        #expect(est.add(t1: 0, t2: 0, t3: 0, t4: 10_000_000_000) == nil)   // ten seconds on the way
        #expect(est.offsetNanos(at: 0) == nil)
        let made = est.add(t1: 1_000, t2: 501_000, t3: 501_100, t4: 1_300)
        #expect(made != nil)
        let got = est.offsetNanos(at: 2_000)
        #expect(got == 499_900)
    }
}

@Suite("Packet reorderer")
struct PacketReordererTests {
    private let step = UInt64(PCM.framesPerPacket)
    private let ms: UInt64 = 1_000_000

    @Test func inOrderPacketsPassWithOnePacketHeldBack() {
        var r = PacketReorderer()
        var out: [AudioPacket] = []
        for i in 0..<5 { out += r.insert(firstFrame: UInt64(i) * step, samples: testPacket(i), now: UInt64(i) * 8 * ms) }
        #expect(out.map(\.firstFrame) == [0, 352, 704, 1056])
        // Nothing follows: the held packet is let go, untouched.
        let tail = r.poll(now: 200 * ms, dueFrame: nil)
        #expect(tail.deliver.map(\.firstFrame) == [1408])
        #expect(sample(tail.deliver[0].samples, 5) == 1000)
        #expect(tail.nack.isEmpty)
        #expect(r.stats.received == 5 && r.stats.concealed == 0)
    }

    @Test func reorderedPacketsComeOutInOrderWithoutAsking() {
        var r = PacketReorderer()
        var out: [AudioPacket] = []
        for i in [0, 2, 1, 3, 5, 4, 6] { out += r.insert(firstFrame: UInt64(i) * step, samples: testPacket(i), now: 0) }
        out += r.poll(now: 10 * ms, dueFrame: nil).deliver
        #expect(out.map(\.firstFrame) == (0..<6).map { UInt64($0) * step })
        #expect(r.stats.nacksSent == 0)
    }

    @Test func aLostPacketIsAskedForAndFilled() {
        var r = PacketReorderer()
        var out: [AudioPacket] = []
        for i in [0, 1, 3, 4] { out += r.insert(firstFrame: UInt64(i) * step, samples: testPacket(i), now: 0) }
        #expect(out.map(\.firstFrame) == [0])
        #expect(r.poll(now: 5 * ms, dueFrame: nil).nack.isEmpty)            // inside the grace for reordering
        #expect(r.poll(now: 40 * ms, dueFrame: nil).nack == [2 * step])
        #expect(r.poll(now: 60 * ms, dueFrame: nil).nack.isEmpty)           // not again so soon
        #expect(r.poll(now: 170 * ms, dueFrame: nil).nack == [2 * step])
        out += r.insert(firstFrame: 2 * step, samples: testPacket(2), now: 180 * ms)
        #expect(out.map(\.firstFrame) == [0, 352, 704, 1056])
        #expect(r.stats.recovered == 1 && r.stats.concealed == 0)
        // No fades: the samples are as sent.
        #expect(out.allSatisfy { sample($0.samples, 9) == 1000 })
    }

    @Test func aHoleThatIsDueIsSkippedWithFades() {
        var r = PacketReorderer()
        var out: [AudioPacket] = []
        for i in [0, 1, 4, 5, 6] { out += r.insert(firstFrame: UInt64(i) * step, samples: testPacket(i), now: 0) }
        #expect(out.map(\.firstFrame) == [0])
        // Frame 3*352 must be handed over now: packets 2 and 3 are given up.
        out += r.poll(now: 20 * ms, dueFrame: 4 * step).deliver
        #expect(out.map(\.firstFrame) == [0, 352, 1408, 1760])
        #expect(r.stats.concealed == 2 && r.stats.gaps == 1)
        let before = out[1].samples, after = out[2].samples
        let last = PCM.framesPerPacket * 2 - 1
        #expect(sample(before, 3) > 900 && abs(sample(before, last)) < 10)    // fades out to silence
        #expect(abs(sample(after, 3)) < 10 && sample(after, last) > 900)      // fades in from silence
        #expect(sample(out[3].samples, 3) == 1000)
        // The late copies are no use any more.
        #expect(r.insert(firstFrame: 2 * step, samples: testPacket(2), now: 30 * ms).isEmpty)
        #expect(r.stats.late == 1)
    }

    @Test func aHoleNobodyAnswersIsGivenUpAfterTheLastAsk() {
        var r = PacketReorderer()
        _ = r.insert(firstFrame: 0, samples: testPacket(0), now: 0)
        _ = r.insert(firstFrame: 2 * step, samples: testPacket(2), now: 0)
        var asked = 0
        var delivered: [UInt64] = []
        var t: UInt64 = 0
        while t < 2_000 * ms {
            let p = r.poll(now: t, dueFrame: nil)
            asked += p.nack.count
            delivered += p.deliver.map(\.firstFrame)
            t += 10 * ms
        }
        #expect(asked == 4)
        #expect(delivered == [0, 2 * step])
        #expect(r.stats.concealed == 1)
    }

    @Test func duplicatesAndResetAreHandled() {
        var r = PacketReorderer()
        _ = r.insert(firstFrame: 0, samples: testPacket(0), now: 0)
        _ = r.insert(firstFrame: 2 * step, samples: testPacket(2), now: 0)
        #expect(r.insert(firstFrame: 2 * step, samples: testPacket(2), now: 0).isEmpty)
        #expect(r.stats.duplicates == 1)
        r.reset()
        // After a flush the stream may start anywhere, even earlier.
        let out = r.insert(firstFrame: 0, samples: testPacket(0), now: 0) + r.insert(firstFrame: step, samples: testPacket(1), now: 0)
        #expect(out.map(\.firstFrame) == [0])
    }

    @Test func tooMuchWaitingBehindAHoleGivesItUp() {
        var r = PacketReorderer()
        r.configuration.maxPending = 20
        var out: [AudioPacket] = []
        out += r.insert(firstFrame: 0, samples: testPacket(0), now: 0)
        for i in 2..<40 { out += r.insert(firstFrame: UInt64(i) * step, samples: testPacket(i), now: 0) }
        #expect(r.pendingCount < 20)
        #expect(out.first?.firstFrame == 0)
        #expect(out.map(\.firstFrame) == [0] + (2..<39).map { UInt64($0) * step })
    }
}
