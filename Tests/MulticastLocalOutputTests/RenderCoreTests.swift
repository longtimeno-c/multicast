import Foundation
import Testing
import MulticastAudio
@testable import MulticastLocalOutput

/// Drives `RenderCore` with a simulated device clock (no hardware).
final class RenderSim {
    let core: RenderCore
    let timeline: StreamTimeline
    let callbackFrames: Int
    /// Device clock rate error: > 0 means the device consumes samples faster than host time.
    var ppm: Double
    var deviceFrames: Double = 0
    let startHost: UInt64
    var out: [Float]
    var written: UInt64 = 0

    init(callbackFrames: Int = 512, ppm: Double = 0, startOffsetFrames: Double = 1000, latencyNanos: UInt64 = 0) {
        core = RenderCore(ringFrames: 1 << 16, maxFrames: 4096)
        timeline = StreamTimeline(anchorHostNanos: 1_000_000_000, anchorFrame: 0)
        self.callbackFrames = callbackFrames
        self.ppm = ppm
        startHost = UInt64(Int64(1_000_000_000) + Int64(startOffsetFrames * 1e9 / 44_100))
        out = [Float](repeating: 0, count: callbackFrames * 2)
        core.resetForStart()
        core.setTimeline(timeline)
        core.setOutputLatency(nanos: latencyNanos)
        core.setGainTarget(1)
        core.setActive(true)
    }

    /// Keep the ring filled up to `aheadFrames` beyond the current read position.
    func feed(upTo frame: UInt64) {
        while written < frame {
            core.write(packet: AudioPacket(firstFrame: written, samples: rampSamples(firstFrame: written, frames: PCM.framesPerPacket)))
            written += UInt64(PCM.framesPerPacket)
        }
    }

    var hostNow: UInt64 {
        startHost + UInt64(deviceFrames * 1e9 / 44_100 / (1 + ppm))
    }

    @discardableResult
    func callback(hostValid: Bool = true) -> Bool {
        let h = hostNow
        let silent = out.withUnsafeMutableBufferPointer {
            core.render(hostNanos: hostValid ? h : nil, frames: callbackFrames, into: $0.baseAddress!)
        }
        deviceFrames += Double(callbackFrames)
        return silent
    }

    var left: [Float] { stride(from: 0, to: out.count, by: 2).map { out[$0] } }
}

@Suite struct RenderCoreTests {
    @Test func rendersTheFrameDueAtTheCallbackTime() {
        let sim = RenderSim()
        sim.feed(upTo: 20_000)
        for _ in 0..<4 { sim.callback() } // lock on + let the 20 ms fade-in finish
        let firstExpected = 1000 + 4 * 512
        sim.callback()
        for (i, v) in sim.left.enumerated() {
            #expect(abs(v - expectedLeft(Int64(firstExpected + i))) < 1e-4)
        }
    }

    @Test func outputLatencyIsCompensated() {
        let sim = RenderSim(latencyNanos: 10_000_000) // 10 ms = 441 frames
        sim.feed(upTo: 20_000)
        for _ in 0..<4 { sim.callback() }
        sim.callback()
        let firstExpected = 1000 + 4 * 512 + 441
        #expect(abs(sim.left[0] - expectedLeft(Int64(firstExpected))) < 1e-4)
        #expect(abs(sim.left[511] - expectedLeft(Int64(firstExpected + 511))) < 1e-4)
    }

    @Test func silenceBeforeTheStreamStarts() {
        // Callbacks start 1 s before the anchor; the stream's first frame is 0.
        let sim = RenderSim(startOffsetFrames: -44_100)
        sim.feed(upTo: 50_000)
        var silentCallbacks = 0
        while sim.deviceFrames + 512 < 44_100 {
            if sim.callback() { silentCallbacks += 1 }
            #expect(sim.left.allSatisfy { $0 == 0 })
        }
        #expect(silentCallbacks > 80)
        // Run past the anchor: audio appears.
        for _ in 0..<5 { sim.callback() }
        #expect(sim.left.contains { $0 != 0 })
        #expect(sim.core.snapshotStats().underrunFrames == 0)
    }

    /// Device clock 500 ppm fast for ~2 minutes: no jumps, error under 1 ms, and the output is a
    /// continuous ramp (no skipped or repeated samples = no clicks).
    @Test func tracksDeviceDriftSmoothly() {
        let sim = RenderSim(ppm: 500e-6)
        var maxStep: Float = 0
        var prev: Float?
        var maxErr = 0.0
        for i in 0..<10_000 {
            sim.feed(upTo: UInt64(sim.deviceFrames) + 20_000)
            sim.callback()
            if i > 20 {
                for v in sim.left {
                    if let p = prev, min(p, v) > 0.03, max(p, v) < 0.95 { maxStep = max(maxStep, abs(v - p)) } // skip the mod-32000 wrap
                    prev = v
                }
            } else {
                prev = sim.left.last
            }
            if i > 4000 { maxErr = max(maxErr, abs(sim.core.snapshotStats().lastErrorFrames)) }
        }
        let stats = sim.core.snapshotStats()
        #expect(stats.jumps == 0)
        #expect(maxErr < 10) // integral action removes the steady-state error
        #expect(stats.ratio < 1) // slowing down to match a fast device
        #expect(maxStep < 1.5 / 32768) // one ramp step per sample ± varispeed
        #expect(stats.underrunFrames == 0)
    }

    @Test func offsetChangeAboveThresholdCrossfadesOnce() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<10 { sim.callback() }
        sim.core.setOffset(millis: 100) // play 100 ms later: well above the 50 ms immediate threshold
        sim.callback()
        var maxStep: Float = 0
        var prev = sim.left.last!
        for _ in 0..<10 {
            sim.callback()
            for v in sim.left { maxStep = max(maxStep, abs(v - prev)); prev = v }
        }
        let stats = sim.core.snapshotStats()
        #expect(stats.jumps == 1)
        #expect(abs(stats.lastErrorFrames) < 2)
        #expect(maxStep < 2 / 32768)
        // Now rendering 4410 frames earlier in the stream than before.
        let expectedRead = 1000.0 + 21 * 512 - 4410
        #expect(abs(stats.readFrame - expectedRead) < 2)
    }

    @Test func smallOffsetChangeIsSlewedNotJumped() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<10 { sim.callback() }
        sim.core.setOffset(millis: 3)
        for _ in 0..<1500 {
            sim.feed(upTo: UInt64(sim.deviceFrames) + 20_000)
            sim.callback()
        }
        let stats = sim.core.snapshotStats()
        #expect(stats.jumps == 0)
        #expect(abs(stats.lastErrorFrames) < 15) // 132 frames slewed away to < 15 in ~17 s
    }

    @Test func flushGoesSilentWithoutAClick() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<10 { sim.callback() }
        let last = sim.left.last!
        sim.core.ring.requestReset()
        sim.callback()
        let l = sim.left
        #expect(abs(l[0] - last) < 0.02) // decays from the last value
        #expect(l[63...].allSatisfy { $0 == 0 })
        sim.callback()
        #expect(sim.left.allSatisfy { $0 == 0 })
    }

    @Test func gainIsRampedAndApplied() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<5 { sim.callback() }
        sim.core.setGainTarget(0.5)
        sim.callback() // frames 3560..<4072: ramp 1 -> 0.5 over 882 frames starts here
        let ramped = sim.left
        sim.callback()
        sim.callback() // frames 4584..<5096: fully attenuated
        #expect(abs(sim.left[0] - 0.5 * expectedLeft(4584)) < 1e-4)
        // During the ramp the gain moves gradually: at frame 256 of 882 it is ~1 - 0.5*256/882.
        let g = ramped[256] / expectedLeft(3560 + 256)
        #expect(abs(g - (1 - 0.5 * 256 / 882)) < 0.01)
    }

    @Test func inactiveRendersSilence() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        sim.core.setActive(false)
        #expect(sim.callback())
        #expect(sim.left.allSatisfy { $0 == 0 })
    }

    @Test func missingHostTimeIsExtrapolated() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<5 { sim.callback() }
        for _ in 0..<5 { sim.callback(hostValid: false) }
        let stats = sim.core.snapshotStats()
        #expect(stats.extrapolatedTimestamps == 5)
        #expect(stats.jumps == 0)
        #expect(abs(stats.lastErrorFrames) < 2)
    }

    @Test func reanchorRelocksToNewTimeline() {
        let sim = RenderSim()
        sim.feed(upTo: 60_000)
        for _ in 0..<5 { sim.callback() }
        // New timeline: frame 0 is audible right now (e.g. after a seek + flush).
        sim.core.ring.requestReset()
        let now = sim.hostNow
        sim.core.setTimeline(StreamTimeline(anchorHostNanos: now, anchorFrame: 0))
        sim.written = 0
        sim.feed(upTo: 50_000)
        sim.callback()
        let stats = sim.core.snapshotStats()
        #expect(abs(stats.readFrame - 512) < 1)
        #expect(stats.jumps == 0) // a re-anchor is not counted as a drift jump
    }
}

@Suite struct RingCapacityTests {
    @Test func defaultRingHoldsTwoSecondsButNotSix() throws {
        let core = RenderCore()
        #expect(core.ring.capacityFrames == 1 << 18)
        let now = HostClock.nowNanos()
        try core.checkCapacity(for: StreamTimeline(anchorHostNanos: now, anchorFrame: 0))            // 2 s default
        try core.checkCapacity(for: StreamTimeline(anchorHostNanos: now, anchorFrame: 0, latencyNanos: 5_600_000_000))
        #expect(throws: LocalOutputError.latencyTooLarge(latencyMillis: 6000, maxMillis: core.maxLatencyMillis)) {
            try core.checkCapacity(for: StreamTimeline(anchorHostNanos: now, anchorFrame: 0, latencyNanos: 6_000_000_000))
        }
        #expect(core.maxLatencyMillis == (262_144 - 11_025) * 1000 / 44_100)
    }

    @Test func boundaryIsExactInFrames() {
        let cap = 100_000
        let fitFrames = UInt64(cap - RenderCore.ringMarginFrames)
        let fitNanos = fitFrames * 1_000_000_000 / 44_100        // floor → converts back to ≤ fitFrames
        #expect(RenderCore.ringCanHold(latencyNanos: fitNanos, capacityFrames: cap))
        #expect(!RenderCore.ringCanHold(latencyNanos: fitNanos + 1_000_000, capacityFrames: cap))
        #expect(RenderCore.ringCanHold(latencyNanos: UInt64.max, capacityFrames: cap) == false)
    }
}
