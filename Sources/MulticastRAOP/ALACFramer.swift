import Foundation
import MulticastAudio

/// Packs PCM into *uncompressed* ALAC frames ("escape" frames), the format every RAOP
/// receiver decodes and that AirPort-era senders and pyatv/owntone/libraop use.
///
/// Bitstream of one frame (MSB first):
/// ```
/// 3  bits  element tag          = 1 (ID_CPE, a stereo channel pair)
/// 4  bits  element instance     = 0
/// 12 bits  unused               = 0
/// 1  bit   partial frame flag   = 0 for a full 352-frame packet (1: a 32-bit sample count follows)
/// 2  bits  bytes shifted        = 0
/// 1  bit   escape (uncompressed)= 1
/// [32 bits frame count if partial]
/// N x (16 bits left, 16 bits right), big-endian two's complement
/// 3  bits  element tag          = 7 (ID_END)
/// zero padding to a byte boundary
/// ```
/// No allocation: the caller passes the output buffer (`maxPacketBytes` is always enough).
public enum ALACFramer {
    static let headerBits = 3 + 4 + 12 + 1 + 2 + 1

    /// Bytes for one frame of `frames` stereo frames.
    public static func packetBytes(frames: Int) -> Int {
        let partialBits = frames == PCM.framesPerPacket ? 0 : 32
        return (headerBits + partialBits + frames * 32 + 3 + 7) / 8
    }

    /// Size of a full 352-frame packet (1412 bytes).
    public static let maxPacketBytes = packetBytes(frames: PCM.framesPerPacket) + 4

    /// Encodes `frames` interleaved S16 little-endian stereo frames from `pcm` into `out`.
    /// Returns the number of bytes written.
    @discardableResult
    public static func encode(pcm: UnsafeRawBufferPointer, frames: Int, into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(pcm.count >= frames * 4)
        precondition(out.count >= packetBytes(frames: frames))
        var writer = BitWriter(out.baseAddress!.assumingMemoryBound(to: UInt8.self))
        writer.write(1, bits: 3)   // ID_CPE
        writer.write(0, bits: 4)   // element instance tag
        writer.write(0, bits: 12)  // unused header
        let partial = frames != PCM.framesPerPacket
        writer.write(partial ? 1 : 0, bits: 1)
        writer.write(0, bits: 2)   // bytes shifted
        writer.write(1, bits: 1)   // escape: uncompressed samples follow
        if partial { writer.write(UInt32(frames), bits: 32) }
        let samples = pcm.baseAddress!
        for i in 0..<(frames * 2) {
            // Little-endian S16 in, big-endian 16-bit field out.
            let lo = UInt32(samples.load(fromByteOffset: i * 2, as: UInt8.self))
            let hi = UInt32(samples.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
            writer.write(hi << 8 | lo, bits: 16)
        }
        writer.write(7, bits: 3)   // ID_END
        return writer.finish()
    }

    /// Convenience for tests and non-real-time callers.
    public static func encode(_ pcm: Data) -> Data {
        let frames = pcm.count / 4
        var out = Data(count: packetBytes(frames: frames))
        let n = pcm.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in encode(pcm: src, frames: frames, into: dst) }
        }
        out.count = n
        return out
    }

    /// The ALACSpecificConfig "magic cookie" matching `RAOPSDP.alacFmtp` (for decoders).
    public static var magicCookie: Data {
        var d = Data()
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func be16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be32(UInt32(PCM.framesPerPacket))
        d.append(contentsOf: [0, 16, 40, 10, 14, 2])
        be16(255)
        be32(0)
        be32(0)
        be32(UInt32(PCM.sampleRate))
        return d
    }
}

/// MSB-first bit writer into a caller-provided buffer.
struct BitWriter {
    private let base: UnsafeMutablePointer<UInt8>
    private var byteIndex = 0
    private var accumulator: UInt64 = 0
    private var pending = 0

    init(_ base: UnsafeMutablePointer<UInt8>) { self.base = base }

    @inline(__always) mutating func write(_ value: UInt32, bits: Int) {
        let masked = bits == 32 ? UInt64(value) : UInt64(value) & ((1 << UInt64(bits)) - 1)
        accumulator = accumulator << UInt64(bits) | masked
        pending += bits
        while pending >= 8 {
            pending -= 8
            base[byteIndex] = UInt8(truncatingIfNeeded: accumulator >> UInt64(pending))
            byteIndex += 1
        }
        accumulator &= (1 << UInt64(pending)) - 1
    }

    mutating func finish() -> Int {
        if pending > 0 {
            base[byteIndex] = UInt8(truncatingIfNeeded: accumulator << UInt64(8 - pending))
            byteIndex += 1
            pending = 0
            accumulator = 0
        }
        return byteIndex
    }
}
