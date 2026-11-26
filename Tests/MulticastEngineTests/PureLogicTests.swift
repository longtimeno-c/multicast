import Foundation
import MulticastAudio
import Testing
@testable import MulticastEngine

@Suite struct PacingScheduleTests {
    let packet = UInt64(PCM.framesPerPacket)

    func makeTimeline(anchorHost: UInt64 = 10_000_000_000, anchorFrame: UInt64 = 0,
                      latency: UInt64 = 2_000_000_000) -> StreamTimeline {
        StreamTimeline(anchorHostNanos: anchorHost, anchorFrame: anchorFrame, latencyNanos: latency)
    }

    @Test func deadlinesDeriveFromFrameIndexWithoutDrift() {
        let tl = makeTimeline(anchorFrame: 352 * 1000)
        let s = PacingSchedule(timeline: tl, startFrame: tl.anchorFrame, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        let base = tl.anchorHostNanos - tl.latencyNanos
        #expect(s.deadline(forFrame: tl.anchorFrame) == base)
        // One million packets ≈ 2.2 hours: exact against closed form, every step 7_981_859 or 7_981_860 ns.
        var previous = base
        for k in stride(from: UInt64(1), through: 1_000_000, by: 1) {
            let d = s.deadline(forFrame: tl.anchorFrame + k * packet)
            #expect(d == base + k * packet * 1_000_000_000 / 44_100)
            let step = d - previous
            if step != 7_981_859 && step != 7_981_860 { Issue.record("step \(step) at k=\(k)"); break }
            previous = d
        }
    }

    @Test func emitsOncePerPacketWhenOnTimeAndNeverEarly() {
        let tl = makeTimeline()
        var s = PacingSchedule(timeline: tl, startFrame: 0, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        var now = tl.anchorHostNanos - tl.latencyNanos - 5_000_000
        var rng = SystemRandomNumberGenerator()
        var emitted: [UInt64] = []
        var burst = 0
        while emitted.count < 10_000 {
            switch s.step(now: now, burstSoFar: burst) {
            case .sleep(let until):
                #expect(until > now)
                // Simulated wake-up jitter 0…2 ms.
                now = until + UInt64.random(in: 0...2_000_000, using: &rng)
                burst = 0
            case .emit(let frame, let deadline):
                #expect(now >= deadline)
                #expect(now - deadline <= 2_000_000)
                emitted.append(frame)
                burst += 1
            case .skip:
                Issue.record("unexpected skip")
                return
            }
        }
        #expect(emitted.first == 0)
        for i in 1..<emitted.count where emitted[i] != emitted[i - 1] + packet {
            Issue.record("gap/dupe at \(i)")
            break
        }
    }

    @Test func catchesUpAfterStallInBoundedBursts() {
        let tl = makeTimeline()
        var s = PacingSchedule(timeline: tl, startFrame: 0, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        // Stall: first wake-up 500 ms after the first deadline (below the skip threshold of 1.75 s).
        var now = tl.anchorHostNanos - tl.latencyNanos + 500_000_000
        var burst = 0
        var maxBurst = 0
        var frames: [UInt64] = []
        var breathers = 0
        while frames.count < 200 {
            switch s.step(now: now, burstSoFar: burst) {
            case .sleep(let until):
                if until - now < PacingSchedule.packetNanos / 2 { breathers += 1 }
                now = until
                burst = 0
            case .emit(let f, _):
                frames.append(f)
                burst += 1
                maxBurst = max(maxBurst, burst)
                now += 20_000 // 20 µs of work per packet
            case .skip:
                Issue.record("should catch up, not skip")
                return
            }
        }
        #expect(maxBurst == 8)
        #expect(breathers > 0)
        #expect(frames == (0..<200).map { UInt64($0) * packet })
        // Caught up: the last packet is emitted at (not before) its deadline.
        #expect(now >= s.deadline(forFrame: frames.last!))
    }

    @Test func skipsWholePacketsWhenTooLateToDeliver() {
        let tl = makeTimeline()
        var s = PacingSchedule(timeline: tl, startFrame: 0, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        let base = tl.anchorHostNanos - tl.latencyNanos
        let now = base + 5_000_000_000 // 5 s stall, more than latency
        let step = s.step(now: now, burstSoFar: 0)
        guard case .skip(let count) = step else { Issue.record("expected skip, got \(step)"); return }
        let expectedTarget = PCM.frames(forNanos: 5_000_000_000) / packet * packet
        #expect(count == expectedTarget / packet)
        #expect(s.nextFrame == expectedTarget)
        guard case .emit(let f, let d) = s.step(now: now, burstSoFar: 0) else { Issue.record("expected emit"); return }
        #expect(f == expectedTarget)
        #expect(d <= now && now - d < PacingSchedule.packetNanos)
    }

    @Test func continuesFromMidTimelineStartFrame() {
        let tl = makeTimeline(anchorFrame: 3520)
        var s = PacingSchedule(timeline: tl, startFrame: 3520 + 10 * packet, maxBurst: 4, minDeliveryLeadNanos: 250_000_000)
        let d = s.deadline(forFrame: 3520 + 10 * packet)
        guard case .emit(let f, _) = s.step(now: d, burstSoFar: 0) else { Issue.record("expected emit"); return }
        #expect(f == 3520 + 10 * packet)
    }
}

@Suite struct MeterAndVolumeTests {
    @Test func meterFullScaleAndSilence() {
        let frames = PCM.framesPerPacket
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        defer { buf.deallocate() }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { scratch.deallocate() }
        for i in 0..<frames {
            buf[2 * i] = i % 2 == 0 ? Int16.min : Int16.min // |−32768| = full scale
            buf[2 * i + 1] = 0
        }
        var acc = MeterAccumulator()
        MeterMath.measure(buf, frames: frames, scratch: scratch, into: &acc)
        let r = acc.reading(audibleFrame: 0)
        #expect(abs(r.peakLeft - 1) < 1e-6)
        #expect(abs(r.rmsLeft - 1) < 1e-6)
        #expect(r.peakRight == 0)
        #expect(r.rmsRight == 0)
        #expect(acc.frames == UInt64(frames))
    }

    @Test func meterSineRMSAndMerge() {
        let frames = PCM.framesPerPacket
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        defer { buf.deallocate() }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { scratch.deallocate() }
        var total = MeterAccumulator()
        var phase = 0.0
        for _ in 0..<20 {
            for i in 0..<frames {
                let v = sin(phase) * 0.5
                phase += 2 * .pi * 441 / 44_100
                buf[2 * i] = Int16(v * 32767)
                buf[2 * i + 1] = Int16(v * 0.25 * 32767)
            }
            var acc = MeterAccumulator()
            MeterMath.measure(buf, frames: frames, scratch: scratch, into: &acc)
            total.merge(acc)
        }
        let r = total.reading(audibleFrame: 0)
        #expect(abs(r.peakLeft - 0.5) < 0.002)
        #expect(abs(r.rmsLeft - Float(0.5 / 2.0.squareRoot())) < 0.003)
        #expect(abs(r.rmsRight - Float(0.125 / 2.0.squareRoot())) < 0.002)
        #expect(MeterReading.decibels(0.5) > -6.03 && MeterReading.decibels(0.5) < -6.01)
        #expect(MeterReading.decibels(0) == -96)
    }

    @Test func volumeMath() {
        #expect(abs(VolumeMath.effective(sink: 0.5, master: 0.3, muted: false) - Float(0.5) * Float(0.3)) < 1e-7)
        #expect(VolumeMath.effective(sink: 0.5, master: 0.3, muted: true) == 0)
        #expect(VolumeMath.effective(sink: 0.5, master: 0.3, muted: false, enabled: false) == 0)
        #expect(VolumeMath.effective(sink: 2, master: 1, muted: false) == 1)
        #expect(VolumeMath.effective(sink: -1, master: 1, muted: false) == 0)
        #expect(VolumeMath.effective(sink: .nan, master: 1, muted: false) == 0)
        #expect(VolumeMath.effective(sink: 1, master: .infinity, muted: false) == 0)
    }
}

@Suite struct SnapshotCodingTests {
    @Test func roundTripsAndUsesStableKeys() throws {
        let snap = EngineSnapshot(
            revision: 7, transport: .playing, sourceName: "Tone", sourceIsLive: false,
            masterVolume: 0.8, latencyMillis: 2000,
            sinks: [.init(id: "542a1b001122", name: "Hall Sonos", state: .failed, error: "timeout",
                          volume: 0.15, muted: false, enabled: true, offsetMillis: -20, effectiveVolume: 0.12)]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(snap)
        let back = try JSONDecoder().decode(EngineSnapshot.self, from: data)
        #expect(back == snap)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys) == ["revision", "transport", "sourceName", "sourceIsLive", "masterVolume", "latencyMillis", "sinks"])
        #expect(obj["transport"] as? String == "playing")
        let sink = try #require((obj["sinks"] as? [[String: Any]])?.first)
        #expect(Set(sink.keys) == ["id", "name", "state", "error", "volume", "muted", "enabled", "offsetMillis", "effectiveVolume"])
        #expect(sink["state"] as? String == "failed")
    }

    @Test func meterReadingCodable() throws {
        let m = MeterReading(peakLeft: 0.5, peakRight: 0.25, rmsLeft: 0.3, rmsRight: 0.1, frame: 352, audibleFrame: 0)
        let back = try JSONDecoder().decode(MeterReading.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }
}

@Suite struct AsyncSupportTests {
    @Test func deadlineReturnsOnTimeoutEvenIfOperationIgnoresCancellation() async {
        let start = HostClock.nowNanos()
        let gate = OneShot()
        await #expect(throws: EngineError.self) {
            try await withDeadline(nanos: 100_000_000, timeoutError: EngineError.prepareTimedOut(seconds: 0.1)) {
                // Ignores cancellation; never finishes on its own within the test.
                let t0 = HostClock.nowNanos()
                while HostClock.nowNanos() - t0 < 1_000_000_000 { _ = gate; await Task.yield() }
            }
        }
        let elapsed = HostClock.nowNanos() - start
        #expect(elapsed < 400_000_000)
    }

    @Test func serialQueueRunsInOrder() async {
        let q = SerialAsyncQueue()
        let box = LockedBox<[Int]>([])
        var tasks: [Task<Void, Never>] = []
        for i in 0..<50 {
            tasks.append(q.enqueue {
                if i % 7 == 0 { await Task.yield() }
                box.mutate { $0.append(i) }
            })
        }
        for t in tasks { await t.value }
        #expect(box.value == Array(0..<50))
    }

    @Test func broadcasterReplaysLatest() async {
        let hub = Broadcaster<Int>(replayLatest: true, bufferSize: 4)
        hub.yield(1)
        hub.yield(2)
        var it = hub.makeStream().makeAsyncIterator()
        #expect(await it.next() == 2)
        hub.yield(3)
        #expect(await it.next() == 3)
        hub.finish()
        #expect(await it.next() == nil)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// The contract helpers trap ~4.84 days after a timeline's anchor (frames * 1e9 overflows UInt64);
/// the engine's own math must not.
@Suite struct LongRunTimelineMathTests {
    let packet = UInt64(PCM.framesPerPacket)
    let overflowFrames: UInt64 = UInt64.max / 1_000_000_000 + 1   // first Δframes the contract helper traps on

    @Test func matchesContractHelpersWhereTheyDoNotTrap() {
        for f: UInt64 in [0, 1, 351, 352, 44_100, 44_101, 123_456_789, overflowFrames - 1] {
            #expect(TimelineMath.nanos(forFrames: f) == PCM.nanos(forFrames: f))
        }
        for n: UInt64 in [0, 1, 22_675, 22_676, 1_000_000_000, 7_981_859, 400_000_000_000_000] {
            #expect(TimelineMath.frames(forNanos: n) == PCM.frames(forNanos: n))
        }
        let tl = StreamTimeline(anchorHostNanos: 5_000_000_000, anchorFrame: 1_000_000)
        for f: UInt64 in [0, 999_648, 1_000_000, 1_000_352, 9_000_000_000] {
            #expect(TimelineMath.playoutHostNanos(tl, forFrame: f) == tl.playoutHostNanos(forFrame: f))
        }
    }

    @Test func thirtyDaysAfterTheAnchorDeadlinesAreExactAndDoNotTrap() {
        let tl = StreamTimeline(anchorHostNanos: 10_000_000_000, anchorFrame: 352 * 7, latencyNanos: 2_000_000_000)
        let s = PacingSchedule(timeline: tl, startFrame: tl.anchorFrame, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        let thirtyDaysPackets: UInt64 = 30 * 86_400 * 44_100 / 352
        let frame = tl.anchorFrame + thirtyDaysPackets * packet
        #expect(frame - tl.anchorFrame > overflowFrames, "the case the contract helper would trap on")
        let d = s.deadline(forFrame: frame)
        // Exact closed form in 128-bit arithmetic: anchorHost + Δ*1e9/44100 - latency.
        let delta = frame - tl.anchorFrame
        let wide = delta.multipliedFullWidth(by: 1_000_000_000)
        let ns = UInt64(44_100).dividingFullWidth(wide).quotient
        #expect(d == tl.anchorHostNanos + ns - tl.latencyNanos)
        // Consecutive packets still step by one packet duration.
        let step = s.deadline(forFrame: frame + packet) - d
        #expect(step == 7_981_859 || step == 7_981_860)
    }

    @Test func skipAfterAStallFiveDaysIntoATimelineLandsOnTheDuePacket() {
        let tl = StreamTimeline(anchorHostNanos: 10_000_000_000, anchorFrame: 0, latencyNanos: 2_000_000_000)
        var s = PacingSchedule(timeline: tl, startFrame: 0, maxBurst: 8, minDeliveryLeadNanos: 250_000_000)
        let fiveDays: UInt64 = 5 * 86_400 * 1_000_000_000
        let now = tl.anchorHostNanos - tl.latencyNanos + fiveDays
        guard case .skip(let count) = s.step(now: now, burstSoFar: 0) else {
            Issue.record("expected a skip"); return
        }
        #expect(count > 0)
        let next = s.nextFrame
        #expect(next % packet == 0)
        #expect(s.deadline(forFrame: next) <= now)
        #expect(s.deadline(forFrame: next + packet) > now)
    }

    @Test func saturatesInsteadOfTrapping() {
        #expect(TimelineMath.nanos(forFrames: .max) == .max)
        let tl = StreamTimeline(anchorHostNanos: .max - 10, anchorFrame: 0)
        #expect(TimelineMath.playoutHostNanos(tl, forFrame: 1_000_000) == .max)
    }
}
