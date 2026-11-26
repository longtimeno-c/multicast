import Foundation
import MulticastAudio

// MARK: - NTP time

/// 64-bit NTP timestamps (32.32 fixed point seconds since 1900-01-01) derived from `HostClock`.
///
/// RAOP receivers never compare our NTP time with a real NTP server: they estimate the offset
/// between their clock and ours from the timing exchange (0x52/0x53) and then use the NTP time
/// in sync packets (0x54) through that offset. So any monotonic clock works as long as timing
/// replies and sync packets use the same one. We use `HostClock` (monotonic, never jumps) shifted
/// once per process onto the real NTP era, so values look plausible to picky receivers.
public enum NTPTime {
    /// Seconds from 1900-01-01 to 1970-01-01.
    public static let unixEpochOffsetSeconds: UInt64 = 2_208_988_800

    /// Nanoseconds to add to a `HostClock` reading to get nanoseconds since the NTP epoch.
    /// Captured once per process so it never changes while sessions run.
    public static let hostToNTPEpochNanos: UInt64 = {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let host = HostClock.nowNanos()
        let wall = (UInt64(tv.tv_sec) + unixEpochOffsetSeconds) * 1_000_000_000 + UInt64(tv.tv_usec) * 1_000
        return wall &- host
    }()

    /// Nanoseconds since the NTP epoch -> 32.32 fixed point.
    public static func ntp(fromEpochNanos nanos: UInt64) -> UInt64 {
        let seconds = nanos / 1_000_000_000
        let remainder = nanos % 1_000_000_000
        let fraction = (remainder << 32) / 1_000_000_000
        return (seconds << 32) | fraction
    }

    /// 32.32 fixed point -> nanoseconds since the NTP epoch (rounded to nearest).
    public static func epochNanos(fromNTP ntp: UInt64) -> UInt64 {
        let seconds = ntp >> 32
        let fraction = ntp & 0xFFFF_FFFF
        return seconds * 1_000_000_000 + (fraction * 1_000_000_000 + (1 << 31)) >> 32
    }

    public static func ntp(fromHostNanos host: UInt64, epochOffset: UInt64 = hostToNTPEpochNanos) -> UInt64 {
        ntp(fromEpochNanos: host &+ epochOffset)
    }

    public static func hostNanos(fromNTP ntp: UInt64, epochOffset: UInt64 = hostToNTPEpochNanos) -> UInt64 {
        epochNanos(fromNTP: ntp) &- epochOffset
    }

    public static func now() -> UInt64 { ntp(fromHostNanos: HostClock.nowNanos()) }
}

// MARK: - Byte helpers

@inline(__always) func putBE16(_ value: UInt16, _ p: UnsafeMutableRawPointer, _ offset: Int) {
    p.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
}

@inline(__always) func putBE32(_ value: UInt32, _ p: UnsafeMutableRawPointer, _ offset: Int) {
    p.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
}

@inline(__always) func putBE64(_ value: UInt64, _ p: UnsafeMutableRawPointer, _ offset: Int) {
    p.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt64.self)
}

@inline(__always) func getBE16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

@inline(__always) func getBE32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(getBE16(bytes, offset)) << 16 | UInt32(getBE16(bytes, offset + 2))
}

@inline(__always) func getBE64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
    UInt64(getBE32(bytes, offset)) << 32 | UInt64(getBE32(bytes, offset + 4))
}

// MARK: - RTP audio

/// RTP audio packets (payload type 96) as RAOP expects them.
public enum RTPAudio {
    public static let headerSize = 12
    public static let payloadType: UInt8 = 0x60

    /// Writes the 12-byte RTP header. The marker bit flags the first packet after RECORD/FLUSH.
    public static func writeHeader(into p: UnsafeMutableRawPointer, seq: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool) {
        p.storeBytes(of: 0x80, toByteOffset: 0, as: UInt8.self)
        p.storeBytes(of: marker ? 0x80 | payloadType : payloadType, toByteOffset: 1, as: UInt8.self)
        putBE16(seq, p, 2)
        putBE32(timestamp, p, 4)
        putBE32(ssrc, p, 8)
    }

    public static func packet(seq: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool, payload: Data) -> Data {
        var data = Data(count: headerSize + payload.count)
        data.withUnsafeMutableBytes { raw in
            writeHeader(into: raw.baseAddress!, seq: seq, timestamp: timestamp, ssrc: ssrc, marker: marker)
            payload.withUnsafeBytes { src in
                if let base = src.baseAddress { (raw.baseAddress! + headerSize).copyMemory(from: base, byteCount: src.count) }
            }
        }
        return data
    }

    public struct Header: Equatable, Sendable {
        public var marker: Bool
        public var payloadType: UInt8
        public var seq: UInt16
        public var timestamp: UInt32
        public var ssrc: UInt32
    }

    public static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { b in
            guard b[0] & 0xC0 == 0x80 else { return nil }
            return Header(marker: b[1] & 0x80 != 0, payloadType: b[1] & 0x7F,
                          seq: getBE16(b, 2), timestamp: getBE32(b, 4), ssrc: getBE32(b, 8))
        }
    }
}

// MARK: - Control channel

/// Sync packet (payload type 0x54) sent to the receiver's control port.
///
/// Layout: `0x80|0x10(first) 0xD4 0x00 0x07`, rtp-time-minus-latency (BE32),
/// NTP time (BE64), rtp-time-now (BE32). See `SyncMapping` for the meaning of the fields.
public struct SyncPacket: Equatable, Sendable {
    public static let size = 20
    public var isFirst: Bool
    public var rtpMinusLatency: UInt32
    public var ntpTime: UInt64
    public var rtpNow: UInt32

    public init(isFirst: Bool, rtpMinusLatency: UInt32, ntpTime: UInt64, rtpNow: UInt32) {
        self.isFirst = isFirst
        self.rtpMinusLatency = rtpMinusLatency
        self.ntpTime = ntpTime
        self.rtpNow = rtpNow
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            p.storeBytes(of: isFirst ? 0x90 : 0x80, toByteOffset: 0, as: UInt8.self)
            p.storeBytes(of: 0xD4, toByteOffset: 1, as: UInt8.self)
            putBE16(0x0007, p, 2)
            putBE32(rtpMinusLatency, p, 4)
            putBE64(ntpTime, p, 8)
            putBE32(rtpNow, p, 16)
        }
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) -> SyncPacket? {
        guard bytes.count >= size, bytes[1] & 0x7F == 0x54 else { return nil }
        return bytes.withUnsafeBytes { b in
            SyncPacket(isFirst: b[0] & 0x10 != 0, rtpMinusLatency: getBE32(b, 4), ntpTime: getBE64(b, 8), rtpNow: getBE32(b, 16))
        }
    }
}

/// Retransmit request (0x55) from the receiver: `0x80 0xD5 seq(2) firstMissingSeq(2) count(2)`.
public struct ResendRequest: Equatable, Sendable {
    public var firstSeq: UInt16
    public var count: UInt16

    public init(firstSeq: UInt16, count: UInt16) {
        self.firstSeq = firstSeq
        self.count = count
    }

    public static func parse(_ bytes: UnsafeRawBufferPointer) -> ResendRequest? {
        guard bytes.count >= 8, bytes[1] & 0x7F == 0x55 else { return nil }
        return ResendRequest(firstSeq: getBE16(bytes, 4), count: getBE16(bytes, 6))
    }

    public static func parse(_ bytes: [UInt8]) -> ResendRequest? {
        bytes.withUnsafeBytes { parse($0) }
    }

    /// The sequence numbers asked for, in order (wrapping at 65535).
    public var sequenceNumbers: [UInt16] {
        (0..<Int(count)).map { firstSeq &+ UInt16(truncatingIfNeeded: $0) }
    }
}

/// Retransmit response (0x56): `0x80 0xD6 seq(2)` followed by the original RTP packet.
public enum ResendResponse {
    public static let headerSize = 4

    public static func write(original: UnsafeRawBufferPointer, seq: UInt16, into out: UnsafeMutableRawPointer) -> Int {
        out.storeBytes(of: 0x80, toByteOffset: 0, as: UInt8.self)
        out.storeBytes(of: 0xD6, toByteOffset: 1, as: UInt8.self)
        putBE16(seq, out, 2)
        (out + headerSize).copyMemory(from: original.baseAddress!, byteCount: original.count)
        return headerSize + original.count
    }
}

// MARK: - Timing channel

/// NTP-style timing request (0x52) / reply (0x53).
///
/// Layout: `0x80 0xD2|0xD3 0x00 0x07`, 4 zero bytes, reference/origin time (8),
/// receive time (8), transmit time (8). A reply copies the request's transmit time into origin.
public enum TimingPacket {
    public static let size = 32

    /// Parses a request and returns its transmit timestamp (to be echoed as origin).
    public static func requestTransmitTime(_ bytes: UnsafeRawBufferPointer) -> UInt64? {
        guard bytes.count >= size, bytes[1] & 0x7F == 0x52 else { return nil }
        return getBE64(bytes, 24)
    }

    public static func writeReply(into p: UnsafeMutableRawPointer, origin: UInt64, receive: UInt64, transmit: UInt64) {
        p.storeBytes(of: 0x80, toByteOffset: 0, as: UInt8.self)
        p.storeBytes(of: 0xD3, toByteOffset: 1, as: UInt8.self)
        putBE16(0x0007, p, 2)
        putBE32(0, p, 4)
        putBE64(origin, p, 8)
        putBE64(receive, p, 16)
        putBE64(transmit, p, 24)
    }

    public static func reply(origin: UInt64, receive: UInt64, transmit: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { writeReply(into: $0.baseAddress!, origin: origin, receive: receive, transmit: transmit) }
        return bytes
    }

    public static func request(transmit: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            p.storeBytes(of: 0x80, toByteOffset: 0, as: UInt8.self)
            p.storeBytes(of: 0xD2, toByteOffset: 1, as: UInt8.self)
            putBE16(0x0007, p, 2)
            putBE64(transmit, p, 24)
        }
        return bytes
    }
}

// MARK: - Retransmit backlog

/// Fixed-size ring of the last `capacity` sent RTP packets, indexed by sequence number.
/// Storage is allocated once; storing a packet copies bytes and never allocates.
public struct RetransmitBacklog {
    public let capacity: Int
    public let maxPacketSize: Int
    private var storage: [UInt8]
    private var lengths: [Int]
    private var seqs: [UInt16]

    /// `capacity` must be a power of two that divides 65536 so the ring index is `seq & (capacity-1)`.
    public init(capacity: Int = 1024, maxPacketSize: Int = 1536) {
        precondition(capacity > 0 && capacity <= 65_536 && capacity & (capacity - 1) == 0)
        self.capacity = capacity
        self.maxPacketSize = maxPacketSize
        storage = [UInt8](repeating: 0, count: capacity * maxPacketSize)
        lengths = [Int](repeating: 0, count: capacity)
        seqs = [UInt16](repeating: 0, count: capacity)
    }

    public mutating func store(seq: UInt16, packet: UnsafeRawBufferPointer) {
        let slot = Int(seq) & (capacity - 1)
        let n = min(packet.count, maxPacketSize)
        storage.withUnsafeMutableBytes { dst in
            (dst.baseAddress! + slot * maxPacketSize).copyMemory(from: packet.baseAddress!, byteCount: n)
        }
        lengths[slot] = n
        seqs[slot] = seq
    }

    public mutating func store(seq: UInt16, packet: [UInt8]) {
        packet.withUnsafeBytes { store(seq: seq, packet: $0) }
    }

    /// Calls `body` with the stored packet bytes, or returns false when `seq` is no longer held.
    @discardableResult
    public func withPacket(seq: UInt16, _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        let slot = Int(seq) & (capacity - 1)
        guard lengths[slot] > 0, seqs[slot] == seq else { return false }
        storage.withUnsafeBytes { src in
            body(UnsafeRawBufferPointer(start: src.baseAddress! + slot * maxPacketSize, count: lengths[slot]))
        }
        return true
    }

    public func packet(seq: UInt16) -> [UInt8]? {
        var result: [UInt8]?
        withPacket(seq: seq) { result = Array($0) }
        return result
    }

    public mutating func removeAll() {
        for i in 0..<capacity { lengths[i] = 0 }
    }
}

// MARK: - Volume

public enum RAOPVolume {
    /// Linear 0…1 -> RAOP volume in dB: 0 is mute (-144), otherwise -30…0 dB linearly.
    public static func decibels(forLinear volume: Float) -> Float {
        guard volume.isFinite, volume > 0 else { return -144 }
        return -30 + 30 * min(volume, 1)
    }

    /// RAOP dB -> linear 0…1 (inverse of `decibels(forLinear:)`).
    public static func linear(forDecibels db: Float) -> Float {
        if db <= -30 { return 0 }
        return min(1, (db + 30) / 30)
    }

    /// `text/parameters` body for SET_PARAMETER.
    public static func parameterBody(forLinear volume: Float) -> String {
        String(format: "volume: %.6f\r\n", decibels(forLinear: volume))
    }
}
