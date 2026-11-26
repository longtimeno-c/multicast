import AVFoundation
import CoreMedia
import Foundation
import MulticastAudio
import os

/// The layout of audio handed to a `PushedAudioSource`: linear PCM at any rate, as 16- or
/// 32-bit integers or 32-bit floats, either byte order, interleaved or one buffer per channel.
public struct PushedAudioFormat: Equatable, Sendable {
    public enum Sample: Equatable, Sendable { case int16, int32, float32 }

    public var sampleRate: Double
    public var channels: Int
    public var sample: Sample
    public var isBigEndian: Bool
    public var isInterleaved: Bool

    public init(sampleRate: Double, channels: Int, sample: Sample, isBigEndian: Bool = false, isInterleaved: Bool = true) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sample = sample
        self.isBigEndian = isBigEndian
        self.isInterleaved = isInterleaved
    }

    /// nil for anything that is not packed linear PCM in one of the supported sample types.
    public init?(_ asbd: AudioStreamBasicDescription) {
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame >= 1,
              asbd.mSampleRate >= 1000, asbd.mSampleRate <= 768_000 else { return nil }
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let sample: Sample
        switch (asbd.mBitsPerChannel, isFloat) {
        case (16, false): sample = .int16
        case (32, false): sample = .int32
        case (32, true): sample = .float32
        default: return nil
        }
        let channels = Int(asbd.mChannelsPerFrame)
        let bytes = sample.byteCount
        // Packed samples only: each one fills its slot in the frame.
        guard Int(asbd.mBytesPerFrame) == (interleaved ? bytes * channels : bytes) else { return nil }
        if !isFloat, flags & kAudioFormatFlagIsSignedInteger == 0 { return nil }
        self.init(sampleRate: asbd.mSampleRate, channels: channels, sample: sample,
                  isBigEndian: flags & kAudioFormatFlagIsBigEndian != 0, isInterleaved: interleaved)
    }

    /// Whether this is already the pipeline format at the pipeline rate (stereo or mono S16).
    var isPipelineRate: Bool { sampleRate == Double(PCM.sampleRate) }
}

extension PushedAudioFormat.Sample {
    public var byteCount: Int { self == .int16 ? 2 : 4 }
}

/// A live `AudioSource` fed by pushed buffers: whoever captures the audio (a ReplayKit
/// broadcast extension) calls `push`, the engine calls `read`.
///
/// `push` converts whatever arrives to the pipeline format (44.1 kHz S16 stereo): byte order,
/// sample type, mono to stereo (more than two channels keep the first two) and, when the rate
/// differs, a high-quality resample. Audio already at 44.1 kHz S16 is copied bit for bit. The
/// result goes into a lock-free ring that `read` drains under a `PushedFillController`.
///
/// Threads: `push` from one thread at a time (it is serialised by a lock that only `push`
/// takes, so the capture side may hop queues); `read` from the engine's pacing thread. `read`
/// never locks or allocates. `push` allocates only when the input format changes.
///
/// Memory is fixed after `init`: the ring (4 s, about 1 MB) and two scratch buffers.
public final class PushedAudioSource: AudioSource, @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        /// Pipeline-format frames accepted into the ring.
        public var framesPushed: Int64 = 0
        /// Frames that did not fit (the engine was not draining) and were dropped.
        public var overflowFrames: Int64 = 0
        /// Frames in buffers that were refused (unsupported format, or pushed while stopped).
        public var rejectedFrames: Int64 = 0
        /// Times the ring ran dry after delivery had started.
        public var underruns: Int64 = 0
        /// Times the oldest audio was dropped because the ring was far too full.
        public var resyncs: Int64 = 0
        public var driftDrops: Int64 = 0
        public var driftDuplicates: Int64 = 0
        /// Frames waiting in the ring now.
        public var bufferedFrames: Int = 0
        /// The size, in pipeline frames, the recent chunks arrived in.
        public var chunkFrames: Int = 0
        /// Buffers pushed, and how many of them held anything but digital silence.
        public var buffersPushed: Int64 = 0
        public var audibleBuffers: Int64 = 0
        /// Host time (`HostClock`) of the last buffer that held sound; 0 if none yet.
        public var lastAudibleHostNanos: UInt64 = 0
        /// The sample rate of the most recent input, 0 before the first buffer.
        public var inputSampleRate: Double = 0
    }

    public let displayName: String
    public var isLive: Bool { true }

    // Shared between the two sides.
    private let ring: PCMRingBuffer
    private let active = AtomicBool(false)
    private let flushRequested = AtomicBool(false)
    private let primeRequested = AtomicBool(false)
    private let chunk = AtomicInt64(0)
    private let framesPushed = AtomicInt64(0)
    private let overflow = AtomicInt64(0)
    private let rejected = AtomicInt64(0)
    private let underruns = AtomicInt64(0)
    private let resyncs = AtomicInt64(0)
    private let driftDrops = AtomicInt64(0)
    private let driftDups = AtomicInt64(0)
    private let buffers = AtomicInt64(0)
    private let audibleBuffers = AtomicInt64(0)
    private let lastAudible = AtomicInt64(0)
    private let inputRateMilli = AtomicInt64(0)

    // Engine side.
    private var fill: PushedFillController

    // Producer side (guarded by `pushLock`).
    private let pushLock = OSAllocatedUnfairLock()
    private var converter: PipelineConverter?
    private var converterRate: Double = 0
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private let scratchPCM: UnsafeMutablePointer<Int16>
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private static let sliceFrames = 4096
    private static let maxBuffers = 8

    /// - Parameters:
    ///   - capacitySeconds: ring size; audio beyond it is dropped while the engine is not reading.
    ///   - fill: the delivery policy (see `PushedFillController`).
    public init(displayName: String, capacitySeconds: Double = 4, fill: PushedFillController = PushedFillController()) {
        self.displayName = displayName
        self.fill = fill
        ring = PCMRingBuffer(capacityFrames: max(PCM.framesPerPacket * 4, Int(capacitySeconds * Double(PCM.sampleRate))),
                             channels: PCM.channels)
        scratchLeft = .allocate(capacity: Self.sliceFrames)
        scratchRight = .allocate(capacity: Self.sliceFrames)
        scratchPCM = .allocate(capacity: Self.sliceFrames * PCM.channels)
        scratchLeft.initialize(repeating: 0, count: Self.sliceFrames)
        scratchRight.initialize(repeating: 0, count: Self.sliceFrames)
        scratchPCM.initialize(repeating: 0, count: Self.sliceFrames * PCM.channels)
        bufferList = AudioBufferList.allocate(maximumBuffers: Self.maxBuffers)
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
        scratchPCM.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    // MARK: AudioSource

    public func start() async throws {
        if active.load() { return }
        // The engine starts a source before it pulls from it, so nothing is reading now:
        // drop what an earlier run left here, and have the next pull prime afresh.
        _ = flushRequested.exchangeFalse()
        ring.discardAll()
        primeRequested.store(true)
        active.store(true)
    }

    public func stop() async {
        active.store(false)
        flushRequested.store(true)
    }

    /// Drops everything buffered; delivery primes again (after a pause in capture, say).
    public func flush() {
        flushRequested.store(true)
    }

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        if flushRequested.exchangeFalse() {
            ring.discardAll()
            fill.reset()
        }
        if primeRequested.exchangeFalse() { fill.reset() }
        let wasPriming = fill.isPriming
        switch fill.decide(available: ring.availableToRead, requested: frameCount, chunkFrames: Int(chunk.load())) {
        case .wait:
            if !wasPriming { underruns.add(1) }
            return 0
        case .read(let n):
            return ring.read(into: buffer, frames: n)
        case .readDroppingOne(let n):
            let got = ring.read(into: buffer, frames: n)
            ring.skip(frames: 1)
            driftDrops.add(1)
            return got
        case .readDuplicatingOne(let n):
            let got = ring.read(into: buffer, frames: n - 1)
            guard got > 0 else { return 0 }
            buffer[2 * got] = buffer[2 * (got - 1)]
            buffer[2 * got + 1] = buffer[2 * (got - 1) + 1]
            driftDups.add(1)
            return got + 1
        case .resync(let drop, let n):
            ring.skip(frames: drop)
            resyncs.add(1)
            return ring.read(into: buffer, frames: n)
        }
    }

    public var statistics: Statistics {
        Statistics(
            framesPushed: framesPushed.load(),
            overflowFrames: overflow.load(),
            rejectedFrames: rejected.load(),
            underruns: underruns.load(),
            resyncs: resyncs.load(),
            driftDrops: driftDrops.load(),
            driftDuplicates: driftDups.load(),
            bufferedFrames: ring.availableToRead,
            chunkFrames: Int(chunk.load()),
            buffersPushed: buffers.load(),
            audibleBuffers: audibleBuffers.load(),
            lastAudibleHostNanos: UInt64(max(0, lastAudible.load())),
            inputSampleRate: Double(inputRateMilli.load()) / 1000
        )
    }

    // MARK: Pushing

    /// Pushes one `CMSampleBuffer` of linear PCM (what ReplayKit hands a broadcast extension).
    /// Returns false if the buffer was refused: not PCM, an unsupported layout, or the source
    /// is not started.
    @discardableResult
    public func push(sampleBuffer: CMSampleBuffer) -> Bool {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = PushedAudioFormat(asbd)
        else {
            rejected.add(Int64(max(0, frames)))
            return false
        }
        return pushLock.withLockUnchecked {
            // Core Media refuses a list size other than the one it needs, so ask first.
            var needed = 0
            let capacity = AudioBufferList.sizeInBytes(maximumBuffers: Self.maxBuffers)
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
                needed > 0, needed <= capacity
            else {
                rejected.add(Int64(frames))
                return false
            }
            var block: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: bufferList.unsafeMutablePointer,
                bufferListSize: needed,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &block
            )
            guard status == noErr else {
                rejected.add(Int64(frames))
                return false
            }
            return withExtendedLifetime(block) {
                pushLocked(bufferList: UnsafePointer(bufferList.unsafeMutablePointer), frames: frames, format: format)
            }
        }
    }

    /// Pushes `frames` frames described by an `AudioBufferList`: one buffer when interleaved,
    /// one per channel otherwise.
    @discardableResult
    public func push(bufferList list: UnsafePointer<AudioBufferList>, frames: Int, format: PushedAudioFormat) -> Bool {
        pushLock.withLockUnchecked { pushLocked(bufferList: list, frames: frames, format: format) }
    }

    /// Pushes `frames` interleaved frames from raw bytes.
    @discardableResult
    public func push(interleaved bytes: UnsafeRawBufferPointer, frames: Int, format: PushedAudioFormat) -> Bool {
        guard format.isInterleaved, let base = bytes.baseAddress,
              bytes.count >= frames * format.channels * format.sample.byteCount else {
            rejected.add(Int64(max(0, frames)))
            return false
        }
        return pushLock.withLockUnchecked {
            let size = format.sample.byteCount
            let stride = size * format.channels
            let right = format.channels >= 2 ? base + size : base
            return pushLocked(left: base, leftStride: stride, right: right, rightStride: stride, frames: frames, format: format)
        }
    }

    private func pushLocked(bufferList list: UnsafePointer<AudioBufferList>, frames: Int, format: PushedAudioFormat) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let size = format.sample.byteCount
        guard frames > 0, format.channels >= 1, let first = buffers.first, let firstData = first.mData else {
            rejected.add(Int64(max(0, frames)))
            return false
        }
        if format.isInterleaved {
            let stride = size * format.channels
            guard Int(first.mDataByteSize) >= frames * stride else {
                rejected.add(Int64(frames))
                return false
            }
            let base = UnsafeRawPointer(firstData)
            let right = format.channels >= 2 ? base + size : base
            return pushLocked(left: base, leftStride: stride, right: right, rightStride: stride, frames: frames, format: format)
        }
        guard Int(first.mDataByteSize) >= frames * size else {
            rejected.add(Int64(frames))
            return false
        }
        var right = UnsafeRawPointer(firstData)
        if format.channels >= 2 {
            guard buffers.count >= 2, let second = buffers[1].mData, Int(buffers[1].mDataByteSize) >= frames * size else {
                rejected.add(Int64(frames))
                return false
            }
            right = UnsafeRawPointer(second)
        }
        return pushLocked(left: UnsafeRawPointer(firstData), leftStride: size, right: right, rightStride: size,
                          frames: frames, format: format)
    }

    /// The one real entry: `left`/`right` point at the first sample of each side (the same
    /// pointer for mono) and advance by their stride per frame.
    private func pushLocked(left: UnsafeRawPointer, leftStride: Int, right: UnsafeRawPointer, rightStride: Int,
                            frames: Int, format: PushedAudioFormat) -> Bool {
        guard frames > 0, active.load() else {
            rejected.add(Int64(max(0, frames)))
            return false
        }
        if format.sampleRate < 1000 || format.sampleRate > 768_000 {
            rejected.add(Int64(frames))
            return false
        }
        inputRateMilli.store(Int64(format.sampleRate * 1000))

        let direct = format.isPipelineRate
        if !direct, converter == nil || converterRate != format.sampleRate {
            // A new input rate: the only allocation `push` ever makes.
            converter = try? PipelineConverter(inputSampleRate: format.sampleRate, maxInputFrames: Self.sliceFrames)
            converterRate = format.sampleRate
            guard converter != nil else {
                rejected.add(Int64(frames))
                return false
            }
        }

        var audible = false
        var written = 0
        var produced = 0
        var done = 0
        while done < frames {
            let n = min(Self.sliceFrames, frames - done)
            let l = left + done * leftStride
            let r = right + done * rightStride
            if direct {
                if Self.decodeToS16(l, leftStride, r, rightStride, n, format, into: scratchPCM) { audible = true }
                produced += n
                written += ring.write(scratchPCM, frames: n)
            } else if let converter {
                if Self.decodeToFloat(l, leftStride, r, rightStride, n, format, left: scratchLeft, right: scratchRight) {
                    audible = true
                }
                try? converter.convert(left: scratchLeft, right: scratchRight, frames: n) { pcm, count in
                    produced += count
                    written += ring.write(pcm, frames: count)
                }
            }
            done += n
        }

        // How large the chunks are, in pipeline frames: follows a larger chunk at once and
        // forgets an unusually large one slowly.
        let expected = direct ? frames : SampleConversion.expectedOutputFrames(inputFrames: frames, inputRate: format.sampleRate)
        let previous = Int(chunk.load())
        chunk.store(Int64(max(expected, previous - max(1, previous / 128))))

        framesPushed.add(Int64(written))
        if produced > written { overflow.add(Int64(produced - written)) }
        buffers.add(1)
        if audible {
            audibleBuffers.add(1)
            lastAudible.store(Int64(clamping: HostClock.nowNanos()))
        }
        return true
    }

    // MARK: Sample decoding

    /// Decodes one slice straight to interleaved S16 stereo. Returns whether any sample was
    /// non-zero. Integer input keeps its bits (32-bit keeps the top 16).
    @inline(__always)
    private static func decodeToS16(_ left: UnsafeRawPointer, _ leftStride: Int, _ right: UnsafeRawPointer, _ rightStride: Int,
                                    _ frames: Int, _ format: PushedAudioFormat, into out: UnsafeMutablePointer<Int16>) -> Bool {
        var any: Int16 = 0
        switch format.sample {
        case .int16:
            for i in 0..<frames {
                let l = int16(left + i * leftStride, format.isBigEndian)
                let r = int16(right + i * rightStride, format.isBigEndian)
                out[2 * i] = l
                out[2 * i + 1] = r
                any |= l | r
            }
        case .int32:
            for i in 0..<frames {
                let l = Int16(truncatingIfNeeded: int32(left + i * leftStride, format.isBigEndian) >> 16)
                let r = Int16(truncatingIfNeeded: int32(right + i * rightStride, format.isBigEndian) >> 16)
                out[2 * i] = l
                out[2 * i + 1] = r
                any |= l | r
            }
        case .float32:
            for i in 0..<frames {
                let l = SampleConversion.int16(fromFloat: float32(left + i * leftStride, format.isBigEndian))
                let r = SampleConversion.int16(fromFloat: float32(right + i * rightStride, format.isBigEndian))
                out[2 * i] = l
                out[2 * i + 1] = r
                any |= l | r
            }
        }
        return any != 0
    }

    /// Decodes one slice to planar float stereo for the resampler. Returns whether any sample
    /// was non-zero.
    @inline(__always)
    private static func decodeToFloat(_ left: UnsafeRawPointer, _ leftStride: Int, _ right: UnsafeRawPointer, _ rightStride: Int,
                                      _ frames: Int, _ format: PushedAudioFormat,
                                      left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>) -> Bool {
        var audible = false
        switch format.sample {
        case .int16:
            for i in 0..<frames {
                let l = int16(left + i * leftStride, format.isBigEndian)
                let r = int16(right + i * rightStride, format.isBigEndian)
                outLeft[i] = Float(l) / 32768
                outRight[i] = Float(r) / 32768
                if l != 0 || r != 0 { audible = true }
            }
        case .int32:
            for i in 0..<frames {
                let l = int32(left + i * leftStride, format.isBigEndian)
                let r = int32(right + i * rightStride, format.isBigEndian)
                outLeft[i] = Float(l) / 2_147_483_648
                outRight[i] = Float(r) / 2_147_483_648
                if l != 0 || r != 0 { audible = true }
            }
        case .float32:
            for i in 0..<frames {
                var l = float32(left + i * leftStride, format.isBigEndian)
                var r = float32(right + i * rightStride, format.isBigEndian)
                if !(l == l) { l = 0 }
                if !(r == r) { r = 0 }
                outLeft[i] = l
                outRight[i] = r
                if l != 0 || r != 0 { audible = true }
            }
        }
        return audible
    }

    @inline(__always)
    private static func int16(_ p: UnsafeRawPointer, _ bigEndian: Bool) -> Int16 {
        let raw = p.loadUnaligned(as: Int16.self)
        return bigEndian ? Int16(bigEndian: raw) : Int16(littleEndian: raw)
    }

    @inline(__always)
    private static func int32(_ p: UnsafeRawPointer, _ bigEndian: Bool) -> Int32 {
        let raw = p.loadUnaligned(as: Int32.self)
        return bigEndian ? Int32(bigEndian: raw) : Int32(littleEndian: raw)
    }

    @inline(__always)
    private static func float32(_ p: UnsafeRawPointer, _ bigEndian: Bool) -> Float {
        let raw = p.loadUnaligned(as: UInt32.self)
        return Float(bitPattern: bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw))
    }
}
