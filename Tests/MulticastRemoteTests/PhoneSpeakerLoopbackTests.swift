import CryptoKit
import Foundation
import MulticastAudio
import Testing
@testable import MulticastRemote

// The hub's sink and the phone's receiver joined by a simulated network, in simulated time:
// two clocks that disagree and drift, a link that delays, jitters, reorders and loses, and an
// "engine" that hands the sink a packet every 8 ms, two seconds before it is due.

/// Simulated true time, and the two devices' clocks derived from it.
final class SimWorld: @unchecked Sendable {
    var t: Double = 0                       // seconds
    let hubBase = 77_000_000_000_000.0
    let phoneBase = 3_000_000_000_000.0
    var phoneDriftPPM = 0.0
    private var events: [(at: Double, order: Int, run: () -> Void)] = []
    private var order = 0

    var hubNow: UInt64 { UInt64(hubBase + t * 1e9) }
    var phoneNow: UInt64 { UInt64(phoneBase + t * 1e9 * (1 + phoneDriftPPM * 1e-6)) }
    /// Hub clock minus phone clock, exactly.
    var trueOffset: Double { (hubBase + t * 1e9) - (phoneBase + t * 1e9 * (1 + phoneDriftPPM * 1e-6)) }

    func at(_ time: Double, _ run: @escaping () -> Void) {
        order += 1
        events.append((time, order, run))
    }

    func after(_ delay: Double, _ run: @escaping () -> Void) { at(t + delay, run) }

    func run(until end: Double) {
        while true {
            guard let i = events.indices.min(by: { (events[$0].at, events[$0].order) < (events[$1].at, events[$1].order) }),
                  events[i].at <= end else { break }
            let e = events.remove(at: i)
            t = max(t, e.at)
            e.run()
        }
        t = end
    }
}

/// One direction of a link.
struct SimLink {
    var baseDelay = 0.0015
    var jitterMean = 0.002
    var spikeChance = 0.01
    var loss = 0.0
    var rng: SplitMix64

    mutating func delay() -> Double? {
        if Double.random(in: 0..<1, using: &rng) < loss { return nil }
        var d = baseDelay + rng.exponential(mean: jitterMean)
        if Double.random(in: 0..<1, using: &rng) < spikeChance { d += Double.random(in: 0.02...0.06, using: &rng) }
        return d
    }
}

/// Records what the phone would have played.
final class RecordingOutput: PhoneAudioOutput, @unchecked Sendable {
    let world: SimWorld
    var mayStart = true
    var starts: [StreamTimeline] = []
    var stops = 0
    var flushes = 0
    var written: [AudioPacket] = []
    var volume: Float?
    var trim: Int?
    var clockOffset: Int64?
    var offsetSteps: [Int64] = []
    /// Per packet: seconds between its arrival at the output and the moment it is due.
    var slack: [Double] = []
    var running = false
    var worstClockError = 0.0
    var measureClockFrom = Double.infinity

    init(world: SimWorld) { self.world = world }

    func start(timeline: StreamTimeline) -> Bool {
        guard mayStart else { return false }
        starts.append(timeline)
        running = true
        return true
    }

    func setClockOffset(nanos: Int64) {
        if let old = clockOffset { offsetSteps.append(nanos - old) }
        clockOffset = nanos
        if world.t >= measureClockFrom { worstClockError = max(worstClockError, abs(Double(nanos) - world.trueOffset)) }
    }

    func write(_ packet: AudioPacket) {
        written.append(packet)
        if let tl = starts.last {
            let dueHub = Double(tl.playoutHostNanos(forFrame: packet.firstFrame))
            slack.append((dueHub - Double(world.hubNow)) / 1e9)
        }
    }

    func flush() { flushes += 1 }
    func setVolume(_ volume: Float) { self.volume = volume }
    func setOffset(millis: Int) { trim = millis }
    func stop() {
        stops += 1
        running = false
    }
}

final class Loopback {
    let world = SimWorld()
    let sink: PhoneSpeakerSink
    let receiver: PhoneSpeakerReceiver
    let output: RecordingOutput
    var down: SimLink
    var up: SimLink
    var sentPackets = 0
    private var nextFrame: UInt64 = 0
    private var streaming = false
    /// Datagrams from hub to phone, counted by kind.
    var downCount = 0

    init(seed: UInt64, loss: Double = 0, jitterMean: Double = 0.002, driftPPM: Double = 0) {
        let salt = Data(repeating: 9, count: AudioChannel.saltLength)
        let hubToRemote = SymmetricKey(data: Data(repeating: 3, count: 32))
        let remoteToHub = SymmetricKey(data: Data(repeating: 4, count: 32))
        let downKey = AudioChannel.key(from: hubToRemote, salt: salt, direction: AudioChannel.hubToPhone)
        let upKey = AudioChannel.key(from: remoteToHub, salt: salt, direction: AudioChannel.phoneToHub)
        let world = self.world
        world.phoneDriftPPM = driftPPM
        down = SimLink(jitterMean: jitterMean, loss: loss, rng: SplitMix64(seed: seed))
        up = SimLink(jitterMean: jitterMean, loss: loss, rng: SplitMix64(seed: seed &+ 1000))
        let output = RecordingOutput(world: world)
        self.output = output
        sink = PhoneSpeakerSink(id: "phone:test", displayName: "Test iPhone",
                                keys: AudioChannelKeys(send: downKey, receive: upKey), helloWait: 0.2,
                                now: { world.hubNow })
        let box = TransmitBox()
        receiver = PhoneSpeakerReceiver(keys: AudioChannelKeys(send: upKey, receive: downKey), output: output,
                                        now: { world.phoneNow }, transmit: { box.send?($0) })
        box.send = { [unowned self] data in
            guard let d = self.up.delay() else { return }
            world.after(d) { self.sink.receive(data) }
        }
        sink.setTransmit { [unowned self] data in
            self.downCount += 1
            guard let d = self.down.delay() else { return }
            world.after(d) { self.receiver.receive(data) }
        }
        scheduleTick()
        scheduleHubTick()
    }

    private final class TransmitBox: @unchecked Sendable { var send: ((Data) -> Void)? }

    private func scheduleTick() {
        world.after(0.01) { [weak self] in
            self?.receiver.tick()
            self?.scheduleTick()
        }
    }

    private func scheduleHubTick() {
        world.after(0.25) { [weak self] in
            self?.sink.tick()
            self?.scheduleHubTick()
        }
    }

    /// Starts the "engine": a packet every 352 frames of hub time, two seconds ahead of playout.
    func startStream() async throws -> StreamTimeline {
        let timeline = StreamTimeline(anchorHostNanos: world.hubNow + 2_000_000_000, anchorFrame: nextFrame)
        try await sink.prepare(timeline: timeline)
        streaming = true
        pump()
        return timeline
    }

    func stopStream() { streaming = false }

    private func pump() {
        guard streaming else { return }
        sink.enqueue(AudioPacket(firstFrame: nextFrame, samples: testPacket(sentPackets)))
        sentPackets += 1
        nextFrame += UInt64(PCM.framesPerPacket)
        world.after(Double(PCM.framesPerPacket) / Double(PCM.sampleRate)) { [weak self] in self?.pump() }
    }
}

@Suite("Phone speaker, hub to phone over a simulated network")
struct PhoneSpeakerLoopbackTests {
    private func frames(_ packets: [AudioPacket]) -> [UInt64] { packets.map(\.firstFrame) }

    @Test func aCleanLinkPlaysEveryPacketInOrderWellAhead() async throws {
        let lb = Loopback(seed: 11)
        lb.world.run(until: 1)                       // the phone says hello and learns the clock
        _ = try await lb.startStream()
        lb.output.measureClockFrom = 3
        lb.world.run(until: 21)
        lb.stopStream()
        lb.world.run(until: 21.5)

        let out = lb.output
        #expect(out.starts.count == 1)
        #expect(out.written.count >= lb.sentPackets - 3)
        #expect(frames(out.written) == frames(out.written).sorted())
        #expect(Set(frames(out.written)).count == out.written.count)
        #expect(out.written.first?.firstFrame == 0)
        let s = lb.receiver.stats
        #expect(s.packetsConcealed == 0 && s.isPlaying)
        // Handed over about two seconds before it is due, never close to late.
        #expect((out.slack.min() ?? 0) > 1.5)
        #expect(out.worstClockError < 600_000, "clock error \(out.worstClockError / 1e6) ms")
        #expect(s.bufferedMillis > 1500 && s.bufferedMillis < 2100)
    }

    @Test func lossAndJitterAreRepairedByAskingAgain() async throws {
        let lb = Loopback(seed: 23, loss: 0.03, jitterMean: 0.004, driftPPM: 40)
        lb.world.run(until: 1.5)
        _ = try await lb.startStream()
        lb.output.measureClockFrom = 12
        lb.world.run(until: 41.5)
        lb.stopStream()
        lb.world.run(until: 42.5)

        let out = lb.output
        let s = lb.receiver.stats
        #expect(frames(out.written) == frames(out.written).sorted())
        // 3 % lost each way: of about 5000 packets some 150 go missing and nearly all come back.
        #expect(s.packetsRecovered > 80)
        #expect(s.packetsConcealed <= 2, "concealed \(s.packetsConcealed)")
        #expect(out.written.count >= lb.sentPackets - 5)
        #expect((out.slack.min() ?? 0) > 1.0)
        #expect(lb.sink.counters.packetsResent >= s.packetsRecovered)
        // The clock is followed through drift without stepping the output.
        #expect(out.worstClockError < 1_000_000, "clock error \(out.worstClockError / 1e6) ms")
        #expect(out.offsetSteps.allSatisfy { abs($0) < 20_000_000 })
    }

    @Test func aBurstOfLossIsConcealedAndNeverStalls() async throws {
        let lb = Loopback(seed: 5)
        lb.world.run(until: 1)
        _ = try await lb.startStream()
        lb.world.run(until: 5)
        // The link dies for three seconds: longer than the hub keeps packets for.
        lb.down.loss = 1
        lb.up.loss = 1
        lb.world.run(until: 8)
        lb.down.loss = 0
        lb.up.loss = 0
        lb.world.run(until: 14)
        lb.stopStream()
        lb.world.run(until: 14.5)

        let out = lb.output
        let s = lb.receiver.stats
        #expect(s.packetsConcealed > 50)
        #expect(frames(out.written) == frames(out.written).sorted())
        // Playback went on after the gap, right up to the end of the stream.
        let last = try #require(out.written.last)
        #expect(last.firstFrame >= UInt64(lb.sentPackets - 3) * UInt64(PCM.framesPerPacket))
        #expect(out.stops == 0)
        #expect(s.isPlaying)
    }

    @Test func flushVolumeTrimAndStopReachThePhone() async throws {
        let lb = Loopback(seed: 2)
        lb.world.run(until: 1)
        _ = try await lb.startStream()
        lb.world.run(until: 3)
        await lb.sink.setVolume(0.2)
        await lb.sink.setOffset(millis: -80)
        lb.world.run(until: 3.5)
        #expect(lb.output.volume == 0.2)
        #expect(lb.output.trim == -80)

        let before = lb.output.written.count
        await lb.sink.flush()
        lb.world.run(until: 4)
        #expect(lb.output.flushes == 1)
        #expect(lb.output.written.count > before)        // the stream goes on in the new epoch

        lb.stopStream()
        await lb.sink.stop()
        lb.world.run(until: 5)
        #expect(lb.output.stops == 1)
        #expect(!lb.receiver.stats.isPlaying)
        #expect(!lb.receiver.stats.hubIsStreaming)
    }

    @Test func anInterruptedPhoneWaitsAndThenJoinsAgain() async throws {
        let lb = Loopback(seed: 4)
        lb.output.mayStart = false
        lb.world.run(until: 1)
        _ = try await lb.startStream()
        lb.world.run(until: 4)
        #expect(lb.output.starts.isEmpty)
        #expect(lb.sink.phoneStatus == 1)
        lb.output.mayStart = true
        lb.world.run(until: 8)
        #expect(lb.output.starts.count == 1)
        #expect(lb.sink.phoneStatus == 0)
        // It joined mid-stream with what was still ahead.
        #expect((lb.output.slack.min() ?? 0) > 0)
        #expect(lb.receiver.stats.isPlaying)
    }

    @Test func aSilentPhoneFailsPrepareAndIsNoticedWhenItGoesQuiet() async throws {
        let lb = Loopback(seed: 6)
        lb.up.loss = 1                                    // nothing from the phone arrives
        lb.world.run(until: 1)
        await #expect(throws: PhoneSpeakerError.notResponding) { _ = try await lb.startStream() }

        let other = Loopback(seed: 7)
        other.world.run(until: 1)
        _ = try await other.startStream()
        var states = other.sink.stateUpdates.makeAsyncIterator()
        #expect(await states.next() == .playing)
        other.up.loss = 1
        other.world.run(until: 9)
        #expect(await states.next() == .failed("The iPhone is not responding"))
    }
}
