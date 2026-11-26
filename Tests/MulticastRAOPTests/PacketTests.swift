import Foundation
import Testing
import MulticastAudio
@testable import MulticastRAOP

@Suite struct PacketTests {
    @Test func rtpHeader() throws {
        let packet = RTPAudio.packet(seq: 0xFFFF, timestamp: 0xDEADBEEF, ssrc: 0x01020304, marker: true, payload: Data([9, 8]))
        #expect([UInt8](packet) == [0x80, 0xE0, 0xFF, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 9, 8])
        let header = try #require(RTPAudio.parseHeader(packet))
        #expect(header == RTPAudio.Header(marker: true, payloadType: 96, seq: 0xFFFF, timestamp: 0xDEADBEEF, ssrc: 0x01020304))
        let plain = RTPAudio.packet(seq: 1, timestamp: 2, ssrc: 3, marker: false, payload: Data())
        #expect(plain[1] == 0x60)
    }

    @Test func sequenceAndTimestampWrap() {
        let timeline = StreamTimeline(anchorHostNanos: 1_000_000_000, anchorFrame: 0)
        let mapping = SyncMapping(timeline: timeline, rtpBase: UInt32.max - 351)
        #expect(mapping.rtp(forFrame: UInt64(0)) == UInt32.max - 351)
        #expect(mapping.rtp(forFrame: UInt64(352)) == 0)
        #expect(mapping.rtp(forFrame: UInt64(704)) == 352)
        // Frames beyond 2^32 keep wrapping consistently.
        #expect(mapping.rtp(forFrame: UInt64(1) << 32) == UInt32.max - 351)
        // Negative frames (before frame 0) wrap backwards.
        #expect(mapping.rtp(forFrame: Int64(-1)) == UInt32.max - 352)
        let seq: UInt16 = 0xFFFF
        #expect(seq &+ 1 == 0)
        #expect(ResendRequest(firstSeq: 65534, count: 3).sequenceNumbers == [65534, 65535, 0])
    }

    @Test func syncPacketEncoding() throws {
        let sync = SyncPacket(isFirst: true, rtpMinusLatency: 0x01020304, ntpTime: 0x1122334455667788, rtpNow: 0xA0B0C0D0)
        let bytes = sync.encoded()
        #expect(bytes == [0x90, 0xD4, 0x00, 0x07, 1, 2, 3, 4, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0xA0, 0xB0, 0xC0, 0xD0])
        #expect(SyncPacket.decode(bytes) == sync)
        var later = sync
        later.isFirst = false
        #expect(later.encoded()[0] == 0x80)
    }

    @Test func timingReply() throws {
        let request = TimingPacket.request(transmit: 0xCAFEBABE_00000001)
        let origin = request.withUnsafeBytes { TimingPacket.requestTransmitTime($0) }
        #expect(origin == 0xCAFEBABE_00000001)
        let reply = TimingPacket.reply(origin: 0xCAFEBABE_00000001, receive: 0x10, transmit: 0x20)
        #expect(reply.count == 32)
        #expect(Array(reply[0..<8]) == [0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
        #expect(Array(reply[8..<16]) == [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 1])
        #expect(Array(reply[16..<24]) == [0, 0, 0, 0, 0, 0, 0, 0x10])
        #expect(Array(reply[24..<32]) == [0, 0, 0, 0, 0, 0, 0, 0x20])
        // Not a timing request.
        let sync = SyncPacket(isFirst: false, rtpMinusLatency: 0, ntpTime: 0, rtpNow: 0).encoded() + [UInt8](repeating: 0, count: 12)
        #expect(sync.withUnsafeBytes { TimingPacket.requestTransmitTime($0) } == nil)
    }

    @Test func resendRequestParsing() throws {
        let req = try #require(ResendRequest.parse([0x80, 0xD5, 0x00, 0x01, 0x12, 0x34, 0x00, 0x05]))
        #expect(req == ResendRequest(firstSeq: 0x1234, count: 5))
        #expect(ResendRequest.parse([0x80, 0xD4, 0, 1, 0, 0, 0, 1]) == nil)
        #expect(ResendRequest.parse([0x80, 0xD5, 0]) == nil)
    }

    @Test func retransmitBacklog() throws {
        var backlog = RetransmitBacklog(capacity: 8, maxPacketSize: 16)
        for seq in UInt16(65530)...UInt16(65535) { backlog.store(seq: seq, packet: [UInt8(seq & 0xFF), 1, 2]) }
        for seq: UInt16 in 0...3 { backlog.store(seq: seq, packet: [UInt8(seq), 9]) }
        // 10 stored into 8 slots: the two oldest (65530, 65531) were overwritten.
        #expect(backlog.packet(seq: 65530) == nil)
        #expect(backlog.packet(seq: 65531) == nil)
        #expect(backlog.packet(seq: 65532) == [0xFC, 1, 2])
        #expect(backlog.packet(seq: 3) == [3, 9])
        #expect(backlog.packet(seq: 4) == nil)
        // Response framing: 0x80 0xD6 seq + original.
        var out = [UInt8](repeating: 0, count: 32)
        let original: [UInt8] = [0x80, 0x60, 0x00, 0x03]
        let n = original.withUnsafeBytes { src in out.withUnsafeMutableBytes { ResendResponse.write(original: src, seq: 3, into: $0.baseAddress!) } }
        #expect(Array(out[0..<n]) == [0x80, 0xD6, 0x00, 0x03, 0x80, 0x60, 0x00, 0x03])
        backlog.removeAll()
        #expect(backlog.packet(seq: 3) == nil)
        // Oversized packets are truncated to the slot size rather than overflowing.
        backlog.store(seq: 7, packet: [UInt8](repeating: 0xAB, count: 40))
        #expect(backlog.packet(seq: 7)?.count == 16)
    }

    @Test func ntpConversion() {
        // 1.5 s after the NTP epoch.
        #expect(NTPTime.ntp(fromEpochNanos: 1_500_000_000) == (1 << 32) | 0x8000_0000)
        #expect(NTPTime.epochNanos(fromNTP: (1 << 32) | 0x8000_0000) == 1_500_000_000)
        // Round trip is exact to well under a nanosecond for arbitrary values.
        for ns: UInt64 in [0, 1, 999_999_999, 3_976_000_000_123_456_789, 123_456_789_012] {
            let back = NTPTime.epochNanos(fromNTP: NTPTime.ntp(fromEpochNanos: ns))
            #expect(back == ns || back + 1 == ns)
        }
        // Host <-> NTP with an explicit epoch offset.
        let offset: UInt64 = 3_900_000_000 * 1_000_000_000
        let ntp = NTPTime.ntp(fromHostNanos: 2_000_000_000, epochOffset: offset)
        #expect(ntp >> 32 == 3_900_000_002)
        #expect(NTPTime.hostNanos(fromNTP: ntp, epochOffset: offset) == 2_000_000_000)
        // The process offset lands in the current NTP era (after 2020, before 2036 wrap).
        let seconds = NTPTime.now() >> 32
        #expect(seconds > 3_786_825_600 && seconds < 4_294_967_295)
    }
}
