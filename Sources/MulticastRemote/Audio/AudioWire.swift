import CryptoKit
import Foundation
import MulticastAudio

// MARK: - The audio channel
//
// A paired iPhone can offer itself as a speaker. The hub then sends it the stream it is already
// playing, over UDP, next to the TCP link:
//
//   datagram := kind:u8 seq:u64be sealed(body) tag[16]
//
// Why not the TCP link: states, query answers and artwork (frames of megabytes) travel there in
// order, so audio would wait behind them, and one lost segment holds back everything after it.
// A datagram that is late is simply asked for again or skipped.
//
// Why raw PCM and not ALAC: one pipeline packet (352 frames, 1408 bytes) plus this header, the
// audio header and the tag is 1445 bytes, under the 1452 bytes a UDP datagram can carry over
// IPv6 on a 1500-byte link, so nothing is fragmented; and 1.4 Mbit/s is little for Wi-Fi. ALAC
// would roughly halve the rate for an encoder on the hub's pacing thread and a decoder on the
// phone, to save bandwidth nobody is short of.
//
// Keys: the hub answers an offer (inside the sealed TCP session) with a UDP port and a random
// salt; each side derives one key per direction from its session keys and that salt
// (HKDF-SHA256), so every offer has fresh keys and sequence numbers start at 0. Datagrams are
// sealed with ChaCha20-Poly1305, the sequence number as nonce and `kind ‖ seq` as associated
// data; the receiver keeps a replay window. A datagram that fails to open is dropped, never
// answered.
//
//   hub → phone
//     1 audio       epoch:u32 firstFrame:u64 pcm[1408]
//     2 control     epoch:u32 flags:u8 anchorHost:u64 anchorFrame:u64 latency:u64 volume:f32 offsetMs:i32
//     3 clockReply  t1:u64 t2:u64 t3:u64          (the phone's t1 echoed; hub receive and send times)
//   phone → hub
//     16 hello      t1:u64 status:u8              (keep-alive and clock ping, phone's monotonic clock)
//     17 nack       epoch:u32 count:u8 firstFrame:u64 …
//
// All integers big-endian; clock values are `HostClock.nowNanos()` of the side that took them.
// The control datagram is the whole state of the stream, sent on every change and a few times a
// second, so losing one never matters. `epoch` goes up on every flush or new timeline: audio of
// an older epoch is dropped.

enum AudioChannel {
    static let headerLength = 9
    static let tagLength = 16
    static let maxNackFrames = 32
    static let hubToPhone = "multicast audio hub→remote"
    static let phoneToHub = "multicast audio remote→hub"
    static let saltLength = 16

    /// One direction's key for one offer.
    static func key(from sessionKey: SymmetricKey, salt: Data, direction: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: salt, info: Data(direction.utf8), outputByteCount: 32)
    }
}

/// The keys of one offer, from one side's point of view.
struct AudioChannelKeys: Sendable {
    var send: SymmetricKey
    var receive: SymmetricKey
}

/// Everything the phone needs to know about the stream, sent whole each time.
struct StreamControl: Equatable, Sendable {
    var epoch: UInt32
    /// The hub is (about to be) sending audio on `timeline`.
    var isActive: Bool
    /// On the HUB's clock.
    var timeline: StreamTimeline
    var volume: Float
    var offsetMillis: Int32
}

enum AudioDatagram: Equatable, Sendable {
    case audio(epoch: UInt32, firstFrame: UInt64, samples: Data)
    case control(StreamControl)
    case clockReply(t1: UInt64, t2: UInt64, t3: UInt64)
    case hello(t1: UInt64, status: UInt8)
    case nack(epoch: UInt32, frames: [UInt64])

    var kind: UInt8 {
        switch self {
        case .audio: 1
        case .control: 2
        case .clockReply: 3
        case .hello: 16
        case .nack: 17
        }
    }

    func body() -> Data {
        var w = ByteWriter()
        switch self {
        case .audio(let epoch, let firstFrame, let samples):
            w.data.reserveCapacity(12 + samples.count)
            w.u32(epoch)
            w.u64(firstFrame)
            w.data.append(samples)
        case .control(let c):
            w.u32(c.epoch)
            w.u8(c.isActive ? 1 : 0)
            w.u64(c.timeline.anchorHostNanos)
            w.u64(c.timeline.anchorFrame)
            w.u64(c.timeline.latencyNanos)
            w.u32(c.volume.bitPattern)
            w.u32(UInt32(bitPattern: c.offsetMillis))
        case .clockReply(let t1, let t2, let t3):
            w.u64(t1)
            w.u64(t2)
            w.u64(t3)
        case .hello(let t1, let status):
            w.u64(t1)
            w.u8(status)
        case .nack(let epoch, let frames):
            let list = frames.prefix(AudioChannel.maxNackFrames)
            w.u32(epoch)
            w.u8(UInt8(list.count))
            for f in list { w.u64(f) }
        }
        return w.data
    }

    static func parse(kind: UInt8, body: Data) -> AudioDatagram? {
        var r = ByteReader(body)
        switch kind {
        case 1:
            guard let epoch = r.u32(), let frame = r.u64(), r.remaining == PCM.bytesPerPacket else { return nil }
            return .audio(epoch: epoch, firstFrame: frame, samples: r.rest())
        case 2:
            guard let epoch = r.u32(), let flags = r.u8(), let host = r.u64(), let frame = r.u64(), let latency = r.u64(),
                  let volume = r.u32(), let offset = r.u32(), r.remaining == 0 else { return nil }
            let v = Float(bitPattern: volume)
            return .control(StreamControl(
                epoch: epoch, isActive: flags & 1 == 1,
                timeline: StreamTimeline(anchorHostNanos: host, anchorFrame: frame, latencyNanos: latency),
                volume: v.isFinite ? min(1, max(0, v)) : 0, offsetMillis: Int32(bitPattern: offset)))
        case 3:
            guard let t1 = r.u64(), let t2 = r.u64(), let t3 = r.u64(), r.remaining == 0 else { return nil }
            return .clockReply(t1: t1, t2: t2, t3: t3)
        case 16:
            guard let t1 = r.u64(), let status = r.u8(), r.remaining == 0 else { return nil }
            return .hello(t1: t1, status: status)
        case 17:
            guard let epoch = r.u32(), let count = r.u8(), Int(count) <= AudioChannel.maxNackFrames,
                  r.remaining == Int(count) * 8 else { return nil }
            var frames: [UInt64] = []
            for _ in 0..<count { if let f = r.u64() { frames.append(f) } }
            return .nack(epoch: epoch, frames: frames)
        default:
            return nil
        }
    }
}

// MARK: - Sealing

private func datagramNonce(_ seq: UInt64) -> ChaChaPoly.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    for i in 0..<8 { bytes[4 + i] = UInt8(seq >> UInt64(56 - 8 * i) & 0xFF) }
    return try! ChaChaPoly.Nonce(data: bytes)   // 12 bytes is always valid
}

/// Seals datagrams in one direction. Not thread-safe: the owner serialises calls.
struct DatagramSealer {
    private let key: SymmetricKey
    private(set) var next: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    mutating func seal(_ datagram: AudioDatagram) -> Data? {
        guard next < UInt64.max else { return nil }
        let seq = next
        var header = ByteWriter()
        header.u8(datagram.kind)
        header.u64(seq)
        guard let box = try? ChaChaPoly.seal(datagram.body(), using: key, nonce: datagramNonce(seq),
                                             authenticating: header.data) else { return nil }
        next += 1
        var out = header.data
        out.reserveCapacity(AudioChannel.headerLength + box.ciphertext.count + AudioChannel.tagLength)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }
}

/// Opens datagrams from the other direction: authentic, well formed and not seen before, or nil.
struct DatagramOpener {
    private let key: SymmetricKey
    private var window = ReplayWindow()

    init(key: SymmetricKey) { self.key = key }

    mutating func open(_ raw: Data) -> AudioDatagram? {
        guard raw.count >= AudioChannel.headerLength + AudioChannel.tagLength else { return nil }
        let raw = Data(raw)   // re-based at 0
        let header = raw.prefix(AudioChannel.headerLength)
        var r = ByteReader(header)
        guard let kind = r.u8(), let seq = r.u64(), window.isFresh(seq) else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(
                nonce: datagramNonce(seq),
                ciphertext: raw.dropFirst(AudioChannel.headerLength).dropLast(AudioChannel.tagLength),
                tag: raw.suffix(AudioChannel.tagLength)),
              let body = try? ChaChaPoly.open(box, using: key, authenticating: header),
              let datagram = AudioDatagram.parse(kind: kind, body: body) else { return nil }
        window.accept(seq)
        return datagram
    }
}

/// Which sequence numbers were already accepted: the highest, and a bitmap of the 256 before it.
/// Anything older than that is refused (UDP on a home network doesn't reorder that far).
struct ReplayWindow: Equatable, Sendable {
    static let span: UInt64 = 256
    private var highest: UInt64?
    private var seen = [UInt64](repeating: 0, count: 4)

    func isFresh(_ seq: UInt64) -> Bool {
        guard let highest else { return true }
        if seq > highest { return true }
        let back = highest - seq
        if back == 0 || back > Self.span { return false }
        let bit = back - 1
        return seen[Int(bit / 64)] & (1 << (bit % 64)) == 0
    }

    mutating func accept(_ seq: UInt64) {
        guard let h = highest else {
            highest = seq
            return
        }
        if seq > h {
            shift(by: seq - h)
            highest = seq
        } else if seq < h, h - seq <= Self.span {
            let bit = h - seq - 1
            seen[Int(bit / 64)] |= 1 << (bit % 64)
        }
    }

    /// Moves every remembered number `n` places further back and marks the old highest as seen.
    private mutating func shift(by n: UInt64) {
        if n > Self.span {
            seen = [0, 0, 0, 0]
            return
        }
        var out = [UInt64](repeating: 0, count: 4)
        // The old highest lands at bit n-1; old bit b lands at b+n.
        func set(_ bit: UInt64) { if bit < Self.span { out[Int(bit / 64)] |= 1 << (bit % 64) } }
        set(n - 1)
        for word in 0..<4 where seen[word] != 0 {
            for b in 0..<64 where seen[word] & (1 << UInt64(b)) != 0 { set(UInt64(word * 64 + b) + n) }
        }
        seen = out
    }
}

// MARK: - Bytes

struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8(v >> UInt32(s) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8(v >> UInt64(s) & 0xFF)) } }
}

struct ByteReader {
    private let data: Data
    private var at: Int

    init(_ data: Data) {
        self.data = data
        at = data.startIndex
    }

    var remaining: Int { data.endIndex - at }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { at += 1 }
        return data[at]
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { at += 4 }
        return data[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { at += 8 }
        return data[at..<at + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func rest() -> Data {
        defer { at = data.endIndex }
        return Data(data[at...])
    }
}
