import AudioToolbox
import Foundation
import Testing
import MulticastAudio
@testable import MulticastRAOP

/// NOTE: these check our mapping against `SyncMapping.receiverPlayoutHostNanos`, a MODEL of the
/// receiver rule (the iTunes / shairport-sync "11025 bias" convention). They prove the arithmetic
/// is consistent with that assumed rule and wraps correctly; they cannot show that a given device
/// family actually follows it (no captured real-device fixtures are available).
@Suite struct SyncMappingTests {
    @Test func firstReceivableFrameIsTheAnchorUntilItIsAudibleThenThePacketAudibleNow() {
        let tl = StreamTimeline(anchorHostNanos: 10_000_000_000, anchorFrame: 352 * 5)
        // Before the anchor is audible (normal play): the anchor.
        #expect(SyncMapping.firstReceivableFrame(timeline: tl, atHostNanos: 8_000_000_000) == tl.anchorFrame)
        #expect(SyncMapping.firstReceivableFrame(timeline: tl, atHostNanos: 10_000_000_000) == tl.anchorFrame)
        // One hour later (late joiner): the packet audible now, packet-aligned to the anchor grid.
        let hour: UInt64 = 3_600_000_000_000
        let f = SyncMapping.firstReceivableFrame(timeline: tl, atHostNanos: tl.anchorHostNanos + hour)
        #expect((f - tl.anchorFrame) % 352 == 0)
        let exact = tl.anchorFrame + 3_600 * 44_100
        #expect(f <= exact && exact - f < 352)
        // Ten days later (past 2^31 frames and past the contract helper's overflow): no trap.
        let tenDays: UInt64 = 10 * 86_400 * 1_000_000_000
        let g = SyncMapping.firstReceivableFrame(timeline: tl, atHostNanos: tl.anchorHostNanos + tenDays)
        #expect(g - tl.anchorFrame <= 10 * 86_400 * 44_100 && 10 * 86_400 * 44_100 - (g - tl.anchorFrame) < 352)
    }

    let epoch: UInt64 = 3_970_000_000 * 1_000_000_000

    @Test(arguments: [Int64(0), 50_000_000, -30_000_000])
    func receiverPlaysEachFrameAtTimelinePlayout(offset: Int64) {
        let timeline = StreamTimeline(anchorHostNanos: 50_000_000_000, anchorFrame: 352 * 1000)
        let mapping = SyncMapping(timeline: timeline, rtpBase: 0xFFFF_0000, offsetNanos: offset)
        // Sync packets sent at various moments: before the anchor (start-up), at it, long after.
        for now: UInt64 in [48_000_000_000, 49_999_999_999, 50_000_000_000, 50_123_456_789, 3_650_000_000_000] {
            let sync = mapping.syncPacket(atHostNanos: now, isFirst: false, ntpEpochOffset: epoch)
            // iTunes-compatible latency field: 2 s latency -> 88200 - 11025 = 77175.
            #expect(sync.rtpNow &- sync.rtpMinusLatency == 77_175)
            // The sync point is "now" to within one frame and never in the future.
            let syncHost = NTPTime.hostNanos(fromNTP: sync.ntpTime, epochOffset: epoch)
            #expect(syncHost <= now + 1 && now - syncHost < 22_700 + 1)
            for k: UInt64 in [0, 1, 5, 300, 10_000] {
                let frame = timeline.anchorFrame + k * 352
                let expected = Int64(timeline.playoutHostNanos(forFrame: frame)) + offset
                let got = SyncMapping.receiverPlayoutHostNanos(rtp: mapping.rtp(forFrame: frame), sync: sync, ntpEpochOffset: epoch)
                // Only valid within ±2^31 frames of the sync point (RTP wrap), which these are.
                if abs(Int64(frame) - Int64(timeline.anchorFrame)) < 1 << 30 {
                    #expect(abs(got - expected) <= 2, "frame \(frame) now \(now): \(got) vs \(expected)")
                }
            }
        }
    }

    @Test func worksWithAnchorFrameZeroBeforeAnchor() {
        // Engine anchors frame 0 two seconds in the future; first sync is sent "now", i.e. at frame -88200.
        let timeline = StreamTimeline(anchorHostNanos: 10_000_000_000, anchorFrame: 0)
        let mapping = SyncMapping(timeline: timeline, rtpBase: 1234)
        let (frame, due) = mapping.frameAndTime(atHostNanos: 8_000_000_000)
        #expect(frame == -88_200)
        #expect(due == 8_000_000_000)
        let sync = mapping.syncPacket(atHostNanos: 8_000_000_000, isFirst: true, ntpEpochOffset: epoch)
        #expect(sync.isFirst)
        #expect(sync.rtpMinusLatency == 1234 &- 88_200 &+ 11_025)
        #expect(sync.rtpNow == 1234)  // frame 0 is what is being sent now
        let got = SyncMapping.receiverPlayoutHostNanos(rtp: mapping.rtp(forFrame: UInt64(0)), sync: sync, ntpEpochOffset: epoch)
        #expect(got == 10_000_000_000)
    }

    @Test func frameAndTimeFloorsBetweenFrames() {
        let timeline = StreamTimeline(anchorHostNanos: 1_000_000_000, anchorFrame: 100)
        let mapping = SyncMapping(timeline: timeline, rtpBase: 0)
        // 1.5 frames after the anchor -> frame 101, due 1 frame (22675 ns) after anchor.
        let (f, t) = mapping.frameAndTime(atHostNanos: 1_000_000_000 + 34_013)
        #expect(f == 101)
        #expect(t == 1_000_000_000 + 22_675)
        // 0.5 frames before the anchor -> frame 99 (floor), due 1 frame earlier.
        let (f2, t2) = mapping.frameAndTime(atHostNanos: 1_000_000_000 - 11_000)
        #expect(f2 == 99)
        #expect(t2 == 1_000_000_000 - 22_676)
    }

    @Test func latencyRepresentability() {
        let ok = SyncMapping(timeline: StreamTimeline(anchorHostNanos: 0, anchorFrame: 0, latencyNanos: 500_000_000), rtpBase: 0)
        #expect(ok.isLatencyRepresentable)
        #expect(ok.latencyFrames == 22_050)
        let bad = SyncMapping(timeline: StreamTimeline(anchorHostNanos: 0, anchorFrame: 0, latencyNanos: 200_000_000), rtpBase: 0)
        #expect(!bad.isLatencyRepresentable)
    }

    @Test func sharedTimelineGivesSameAudibleTimeAcrossSinks() {
        // Two sinks with different random RTP bases agree on when each frame is audible.
        let timeline = StreamTimeline(anchorHostNanos: 20_000_000_000, anchorFrame: 0)
        let a = SyncMapping(timeline: timeline, rtpBase: 7)
        let b = SyncMapping(timeline: timeline, rtpBase: 0x9000_0000)
        let sa = a.syncPacket(atHostNanos: 18_500_000_000, isFirst: true, ntpEpochOffset: epoch)
        let sb = b.syncPacket(atHostNanos: 18_500_333_333, isFirst: true, ntpEpochOffset: epoch)
        for f: UInt64 in [0, 352, 44_100, 441_000] {
            let ta = SyncMapping.receiverPlayoutHostNanos(rtp: a.rtp(forFrame: f), sync: sa, ntpEpochOffset: epoch)
            let tb = SyncMapping.receiverPlayoutHostNanos(rtp: b.rtp(forFrame: f), sync: sb, ntpEpochOffset: epoch)
            #expect(abs(ta - tb) <= 2)
        }
    }
}

@Suite struct ALACTests {
    func testPCM(frames: Int) -> Data {
        var d = Data(count: frames * 4)
        d.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                s[2 * i] = Int16(truncatingIfNeeded: (i * 977) &- 30_000).littleEndian
                s[2 * i + 1] = Int16(truncatingIfNeeded: -(i * 131) + (i % 7 == 0 ? Int(Int16.min) : 0)).littleEndian
            }
        }
        return d
    }

    @Test func headerAndSize() {
        let pcm = testPCM(frames: 352)
        let alac = ALACFramer.encode(pcm)
        #expect(alac.count == 1412)  // (23 + 352*32 + 3 bits) rounded up
        // 001 0000 0|0000 0000|000 0 00 1 x  -> 0x20 0x00 0x02|msb of first sample
        #expect(alac[0] == 0x20)
        #expect(alac[1] == 0x00)
        #expect(alac[2] & 0xFE == 0x02)
    }

    /// Hand-decodes the bitstream and checks every sample and the END tag.
    @Test func bitExactRoundTrip() {
        for frames in [352, 100] {
            let pcm = testPCM(frames: frames)
            let alac = [UInt8](ALACFramer.encode(pcm))
            var reader = BitReader(bytes: alac)
            #expect(reader.read(3) == 1)
            #expect(reader.read(4) == 0)
            #expect(reader.read(12) == 0)
            let partial = reader.read(1)
            #expect(partial == (frames == 352 ? 0 : 1))
            #expect(reader.read(2) == 0)
            #expect(reader.read(1) == 1)
            if partial == 1 { #expect(reader.read(32) == UInt32(frames)) }
            let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
            var ok = true
            for s in samples where Int16(bitPattern: UInt16(reader.read(16))) != s { ok = false }
            #expect(ok)
            #expect(reader.read(3) == 7)
            #expect(alac.count == ALACFramer.packetBytes(frames: frames))
        }
    }

    /// Decodes our packets with Apple's own ALAC decoder (the one receivers' firmware shares a
    /// lineage with) and checks the PCM comes back bit-exact.
    @Test func appleDecoderAcceptsUncompressedFrames() throws {
        var alacFormat = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatAppleLossless, mFormatFlags: 1 /* 16-bit source */,
            mBytesPerPacket: 0, mFramesPerPacket: 352, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var pcmFormat = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var converter: AudioConverterRef?
        #expect(AudioConverterNew(&alacFormat, &pcmFormat, &converter) == noErr)
        let conv = try #require(converter)
        defer { AudioConverterDispose(conv) }
        var cookie = [UInt8](ALACFramer.magicCookie)
        #expect(cookie.count == 24)
        #expect(AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), &cookie) == noErr)

        for round in 0..<3 {
            var pcm = testPCM(frames: 352)
            if round == 1 { pcm = Data(count: 352 * 4) }
            let packet = [UInt8](ALACFramer.encode(pcm))
            let box = InputBox(packet: packet)
            var out = [UInt8](repeating: 0, count: 352 * 4)
            var produced: UInt32 = 352
            let status: OSStatus = out.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(conv, alacInputProc, Unmanaged.passUnretained(box).toOpaque(), &produced, &list, nil)
            }
            #expect(status == noErr)
            #expect(produced == 352)
            #expect(Data(out) == pcm, "round \(round) decoded PCM differs")
        }
    }
}

private final class InputBox {
    var packet: [UInt8]
    var consumed = false
    var description = AudioStreamPacketDescription()
    init(packet: [UInt8]) { self.packet = packet }
}

private func alacInputProc(_ converter: AudioConverterRef, _ ioPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>,
                           _ outDesc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    let box = Unmanaged<InputBox>.fromOpaque(user!).takeUnretainedValue()
    if box.consumed {
        ioPackets.pointee = 0
        return 1 // "no more data for now"
    }
    box.consumed = true
    ioPackets.pointee = 1
    box.packet.withUnsafeMutableBytes { raw in
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = raw.baseAddress
        ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
        ioData.pointee.mBuffers.mNumberChannels = 2
    }
    box.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(box.packet.count))
    if let outDesc {
        withUnsafeMutablePointer(to: &box.description) { outDesc.pointee = $0 }
    }
    return noErr
}

struct BitReader {
    let bytes: [UInt8]
    var bit = 0
    mutating func read(_ count: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bit / 8]
            v = v << 1 | UInt32((byte >> (7 - UInt8(bit % 8))) & 1)
            bit += 1
        }
        return v
    }
}
