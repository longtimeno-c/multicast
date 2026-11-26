import Foundation
import Testing
import MulticastAudio
#if os(macOS)
import CoreAudio
#endif
@testable import MulticastLocalOutput

@Suite struct PlayoutClockTests {
    let tl = StreamTimeline(anchorHostNanos: 10_000_000_000, anchorFrame: 44_100)

    @Test func noLatencyNoOffsetIsTheTimelineFrame() {
        let f = PlayoutClock.frameToRender(timeline: tl, callbackHostNanos: 10_000_000_000, outputLatencyNanos: 0, offsetNanos: 0)
        #expect(f == 44_100)
    }

    @Test func latencyMeansRenderingAFrameFromTheFuture() {
        // Audible 100 ms after the callback -> hand over the frame due 100 ms from now.
        let f = PlayoutClock.frameToRender(timeline: tl, callbackHostNanos: 10_000_000_000, outputLatencyNanos: 100_000_000, offsetNanos: 0)
        #expect(abs(f - (44_100 + 4_410)) < 1e-9)
    }

    @Test func positiveOffsetPlaysLater() {
        let f = PlayoutClock.frameToRender(timeline: tl, callbackHostNanos: 10_000_000_000, outputLatencyNanos: 0, offsetNanos: 50_000_000)
        #expect(abs(f - (44_100 - 2_205)) < 1e-9)
        let g = PlayoutClock.frameToRender(timeline: tl, callbackHostNanos: 10_000_000_000, outputLatencyNanos: 0, offsetNanos: -50_000_000)
        #expect(abs(g - (44_100 + 2_205)) < 1e-9)
    }

    @Test func beforeTheAnchorIsNegativeRelative() {
        let t0 = StreamTimeline(anchorHostNanos: 5_000_000_000, anchorFrame: 0)
        let f = PlayoutClock.frameToRender(timeline: t0, callbackHostNanos: 4_000_000_000, outputLatencyNanos: 0, offsetNanos: 0)
        #expect(abs(f - (-44_100)) < 1e-9)
    }

    @Test func roundTripsWithPlayoutHostNanos() {
        for frame: UInt64 in [44_100, 50_000, 1_000_000, 123_456_789] {
            let host = tl.playoutHostNanos(forFrame: frame)
            let f = PlayoutClock.frameToRender(timeline: tl, callbackHostNanos: host - 30_000_000, outputLatencyNanos: 30_000_000, offsetNanos: 0)
            #expect(abs(f - Double(frame)) < 0.05) // playoutHostNanos rounds down to whole ns
        }
    }

    @Test func latencyTotals() {
        let l = LocalOutputLatency(deviceSampleRate: 48_000, deviceFrames: 480, streamFrames: 240, safetyOffsetFrames: 240,
                                   bufferFrames: 512, unitLatencySeconds: 0.001)
        // (480+240+240)/48000 = 20 ms, + 1 ms converter; buffer not included.
        #expect(l.totalNanos == 21_000_000)
        #expect(LocalOutputLatency(deviceSampleRate: 48_000, platformLatencySeconds: 0.25).totalMillis == 250)
    }
}

@Suite struct DriftCorrectorTests {
    @Test func zeroErrorIsUnityRate() {
        var c = DriftCorrector()
        #expect(c.update(errorFrames: 0, callbackFrames: 512) == .rate(1))
    }

    @Test func aheadSlowsDownBehindSpeedsUp() {
        var a = DriftCorrector()
        guard case .rate(let ra) = a.update(errorFrames: 50, callbackFrames: 512) else { Issue.record("jump"); return }
        #expect(ra < 1)
        var b = DriftCorrector()
        guard case .rate(let rb) = b.update(errorFrames: -50, callbackFrames: 512) else { Issue.record("jump"); return }
        #expect(rb > 1)
    }

    @Test func ratioIsClamped() {
        var c = DriftCorrector(jumpThresholdFrames: 10_000, immediateJumpThresholdFrames: 100_000)
        guard case .rate(let r) = c.update(errorFrames: 9_000, callbackFrames: 512) else { Issue.record("jump"); return }
        #expect(abs(r - (1 - c.maxRatioDeviation)) < 1e-12)
    }

    @Test func largeErrorJumps() {
        var c = DriftCorrector()
        #expect(c.update(errorFrames: 3_000, callbackFrames: 512) == .jump) // > 50 ms immediate
        var d = DriftCorrector()
        #expect(d.update(errorFrames: 500, callbackFrames: 512) == .jump) // > 10 ms on first sample
        #expect(d.filteredError == 0)
    }

    @Test func singleSpikeIsFilteredNotJumped() {
        var c = DriftCorrector()
        for _ in 0..<50 { _ = c.update(errorFrames: 0, callbackFrames: 512) }
        // A one-callback 20 ms timestamp glitch (below the 50 ms immediate threshold).
        #expect(c.update(errorFrames: 882, callbackFrames: 512) != .jump)
        #expect(c.update(errorFrames: 0, callbackFrames: 512) != .jump)
    }

    /// Closed loop: a device clock 300 ppm fast must be tracked with no jumps and a sub-ms error.
    @Test func closedLoopTracksClockDrift() {
        var c = DriftCorrector()
        let ppm = 300e-6
        var read = 0.0
        var ideal = 0.0
        var maxErrAfterSettle = 0.0
        var jumps = 0
        for i in 0..<20_000 { // ~4 minutes of 512-frame callbacks
            let err = read - ideal
            var ratio = 1.0
            switch c.update(errorFrames: err, callbackFrames: 512) {
            case .jump: jumps += 1; read = ideal
            case .rate(let r): ratio = r
            }
            read += ratio * 512
            ideal += 512 / (1 + ppm) // device consumes faster than host time advances
            if i > 5_000 { maxErrAfterSettle = max(maxErrAfterSettle, abs(err)) }
        }
        #expect(jumps == 0)
        #expect(maxErrAfterSettle < 44.1) // < 1 ms
    }
}

@Suite struct GainTests {
    @Test func rampReachesTargetExactlyAfterRampFrames() {
        var g = GainRamp(initial: 0, rampFrames: 100)
        g.setTarget(1)
        var last: Float = 0
        var maxStep: Float = 0
        for _ in 0..<100 {
            let v = g.next()
            maxStep = max(maxStep, abs(v - last))
            #expect(v >= last) // monotonic
            last = v
        }
        #expect(last == 1)
        #expect(!g.isRamping)
        #expect(maxStep <= 0.0101) // no zipper: 1/100 per sample
        #expect(g.next() == 1)
    }

    @Test func retargetMidRampContinuesFromCurrentValue() {
        var g = GainRamp(initial: 0, rampFrames: 100)
        g.setTarget(1)
        for _ in 0..<50 { _ = g.next() }
        let mid = g.current
        g.setTarget(0)
        let next = g.next()
        #expect(abs(next - mid) < 0.02)
        for _ in 0..<99 { _ = g.next() }
        #expect(g.current == 0)
    }

    @Test func volumeCurve() {
        #expect(VolumeCurve.amplitude(forVolume: 0) == 0)
        #expect(VolumeCurve.amplitude(forVolume: -1) == 0)
        #expect(abs(VolumeCurve.amplitude(forVolume: 1) - 1) < 1e-6)
        #expect(abs(VolumeCurve.amplitude(forVolume: 0.5) - powf(10, -15 / 20)) < 1e-6)
        // Monotonic.
        var last: Float = 0
        for i in 1...100 {
            let a = VolumeCurve.amplitude(forVolume: Float(i) / 100)
            #expect(a > last)
            last = a
        }
    }

    @Test func hermiteIsExactOnSamplesAndLines() {
        #expect(hermite(1, 2, 3, 4, 0) == 2)
        #expect(abs(hermite(1, 2, 3, 4, 0.25) - 2.25) < 1e-6)
        #expect(abs(hermite(-3, 0, 3, 6, 0.5) - 1.5) < 1e-6)
    }
}

@Suite struct TransportMappingTests {
    @Test func fourCC() {
        #expect(LocalKindMapping.fourCC("bltn") == 0x626C_746E)
    }

    @Test func coreAudioTransportTypes() {
        typealias T = LocalKindMapping.TransportType
        #expect(LocalKindMapping.kind(forTransportType: T.builtIn) == .builtIn)
        #expect(LocalKindMapping.kind(forTransportType: T.bluetooth) == .bluetooth)
        #expect(LocalKindMapping.kind(forTransportType: T.bluetoothLE) == .bluetooth)
        #expect(LocalKindMapping.kind(forTransportType: T.usb) == .usb)
        #expect(LocalKindMapping.kind(forTransportType: T.hdmi) == .hdmi)
        #expect(LocalKindMapping.kind(forTransportType: T.displayPort) == .displayPort)
        #expect(LocalKindMapping.kind(forTransportType: T.airPlay) == .airplaySystem)
        #expect(LocalKindMapping.kind(forTransportType: T.virtual) == .virtual)
        #expect(LocalKindMapping.kind(forTransportType: T.aggregate) == .aggregate)
        #expect(LocalKindMapping.kind(forTransportType: T.thunderbolt) == .other)
        #expect(LocalKindMapping.kind(forTransportType: 0) == .other)
    }

    #if os(macOS)
    @Test func constantsMatchCoreAudio() {
        typealias T = LocalKindMapping.TransportType
        #expect(T.builtIn == kAudioDeviceTransportTypeBuiltIn)
        #expect(T.bluetooth == kAudioDeviceTransportTypeBluetooth)
        #expect(T.bluetoothLE == kAudioDeviceTransportTypeBluetoothLE)
        #expect(T.usb == kAudioDeviceTransportTypeUSB)
        #expect(T.hdmi == kAudioDeviceTransportTypeHDMI)
        #expect(T.displayPort == kAudioDeviceTransportTypeDisplayPort)
        #expect(T.airPlay == kAudioDeviceTransportTypeAirPlay)
        #expect(T.virtual == kAudioDeviceTransportTypeVirtual)
        #expect(T.aggregate == kAudioDeviceTransportTypeAggregate)
        #expect(T.thunderbolt == kAudioDeviceTransportTypeThunderbolt)
    }
    #endif

    @Test func iosRoutePorts() {
        #expect(LocalKindMapping.kind(forRoutePortType: "Speaker") == .builtIn)
        #expect(LocalKindMapping.kind(forRoutePortType: "BluetoothA2DPOutput") == .bluetooth)
        #expect(LocalKindMapping.kind(forRoutePortType: "BluetoothLE") == .bluetooth)
        #expect(LocalKindMapping.kind(forRoutePortType: "USBAudio") == .usb)
        #expect(LocalKindMapping.kind(forRoutePortType: "HDMI") == .hdmi)
        #expect(LocalKindMapping.kind(forRoutePortType: "AirPlay") == .airplaySystem)
        #expect(LocalKindMapping.kind(forRoutePortType: "Headphones") == .other)
    }

    @Test func privateDevicesAreRecognised() {
        #expect(LocalKindMapping.isMulticastPrivateDevice(name: "Multicast Tap Aggregate", uid: "x"))
        #expect(LocalKindMapping.isMulticastPrivateDevice(name: "x", uid: "MulticastAggregate-1"))
        #expect(!LocalKindMapping.isMulticastPrivateDevice(name: "MacBook Air Speakers", uid: "BuiltInSpeakerDevice"))
        #expect(LocalKindMapping.speakerID(forDeviceUID: "ABC") == "local:ABC")
    }
}
