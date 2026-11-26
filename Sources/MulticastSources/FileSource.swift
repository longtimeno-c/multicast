import AVFoundation
import Foundation
import MulticastAudio

/// Plays any file AVFoundation can decode (mp3, AAC/m4a, ALAC, FLAC, WAV, AIFF, CAF…).
///
/// A background decoder thread reads the file, up-mixes mono / selects the front pair of
/// multichannel audio, resamples to 44.1 kHz, converts to S16 stereo and fills a lock-free
/// ring buffer that `read` drains on the engine's pacing thread.
///
/// Transport semantics (designed for an engine that calls `start`/`stop` and flushes its sinks):
/// - `start()` starts (or resumes) delivery; it waits briefly until audio is buffered.
/// - `stop()` PAUSES: `read` returns 0 frames (silence) and the position is kept, so a later
///   `start()` resumes exactly at the next undelivered frame. Buffered audio is kept.
/// - `seek(to:)` works at any time (playing or paused); already-buffered audio from before the
///   seek is discarded by the reader, never played.
/// - At end of file `read` returns `nil` once the ring has drained. A `seek` revives the source.
/// - `close()` (or deinit) stops the decoder thread and releases the file.
///
/// `position` counts frames handed to the engine. What is audible lags this by the engine's
/// group latency (`StreamTimeline.latencyNanos`); an engine implementing pause should `seek`
/// back to the audible frame if it wants a gapless resume.
public final class FileSource: AudioSource, @unchecked Sendable {
    public enum FileSourceError: Error, Equatable {
        case cannotOpen(String)
        case emptyFile
        case unsupportedFormat(String)
    }

    public let url: URL
    public let displayName: String
    public var isLive: Bool { false }

    /// Source file sample rate and channel count.
    public let fileSampleRate: Double
    public let fileChannelCount: Int
    /// Length in pipeline (44.1 kHz) frames.
    public let durationFrames: Int64
    public var duration: TimeInterval { Double(durationFrames) / Double(PCM.sampleRate) }

    private let core: FileDecoderCore
    private let metadataLock = NSLock()
    private var _metadata: AudioMetadata

    /// Opens the file and reads its tags synchronously (AudioToolbox). Call `loadMetadata()` to
    /// also merge AVFoundation's common metadata (more complete for some formats).
    public init(url: URL, bufferSeconds: Double = 4) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FileSourceError.cannotOpen("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let fmt = file.processingFormat
        guard fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved else {
            throw FileSourceError.unsupportedFormat("processing format \(fmt)")
        }
        guard file.length > 0 else { throw FileSourceError.emptyFile }
        self.url = url
        self.fileSampleRate = fmt.sampleRate
        self.fileChannelCount = Int(fmt.channelCount)
        self.durationFrames = Int64((Double(file.length) * Double(PCM.sampleRate) / fmt.sampleRate).rounded())
        let meta = MetadataReader.audioFileMetadata(url: url)
        self._metadata = meta
        self.displayName = meta.title ?? url.deletingPathExtension().lastPathComponent
        self.core = try FileDecoderCore(file: file, bufferFrames: Int(bufferSeconds * Double(PCM.sampleRate)))
    }

    /// Opens the file and loads complete metadata.
    public static func open(url: URL, bufferSeconds: Double = 4) async throws -> FileSource {
        let source = try FileSource(url: url, bufferSeconds: bufferSeconds)
        _ = await source.loadMetadata()
        return source
    }

    deinit {
        core.close()
    }

    public var metadata: AudioMetadata {
        metadataLock.withLock { _metadata }
    }

    /// Merges AVFoundation metadata into `metadata` and returns the result.
    @discardableResult
    public func loadMetadata() async -> AudioMetadata {
        let current = metadata
        if current.isComplete { return current }
        let asset = await MetadataReader.assetMetadata(url: url)
        return metadataLock.withLock {
            _metadata = _metadata.filling(from: asset)
            return _metadata
        }
    }

    // MARK: Transport

    public func start() async throws {
        core.startThreadIfNeeded()
        // Give the decoder a head start so the first pulls are not empty.
        let deadline = Date().addingTimeInterval(1.0)
        while core.ring.availableToRead < PCM.sampleRate / 4, !core.decoderAtEOF, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        core.paused.store(false)
    }

    /// Pause delivery (see type docs). Position and buffer are kept.
    public func stop() async {
        core.paused.store(true)
    }

    public func pause() { core.paused.store(true) }
    public func resume() {
        core.startThreadIfNeeded()
        core.paused.store(false)
    }

    public var isPaused: Bool { core.paused.load() }

    /// Seek to `seconds` (clamped to the file). Thread-safe, any state.
    public func seek(to seconds: TimeInterval) {
        let frame = Int64((max(0, seconds) * Double(PCM.sampleRate)).rounded())
        seek(toFrame: frame)
    }

    public func seek(toFrame frame: Int64) {
        core.requestSeek(toFrame: min(max(0, frame), durationFrames))
        core.startThreadIfNeeded()
    }

    /// Frames delivered to the engine so far (or the pending seek target).
    public var positionFrames: Int64 { core.position() }
    public var position: TimeInterval { Double(positionFrames) / Double(PCM.sampleRate) }

    /// True once every frame of the file has been delivered.
    public var isAtEnd: Bool { core.isAtEnd() }

    /// The decode error that ended the stream early, if any.
    public var decodeError: String? { core.decodeError() }

    /// Stop the decoder thread and release the file. The source cannot be restarted.
    public func close() { core.close() }

    // MARK: Real-time

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        core.read(into: buffer, frameCount: frameCount)
    }
}

/// Owns the decoder thread and ring. Separate from `FileSource` so the thread never keeps the
/// public object alive (deinit can stop it).
final class FileDecoderCore: @unchecked Sendable {
    let ring: PCMRingBuffer

    // Segment descriptor (seqlock; written by the decoder thread only).
    private let segEpoch = AtomicInt64(0)
    private let segStartCounter = AtomicInt64(0)
    private let segStartFrame = AtomicInt64(0)
    private let eofEpoch = AtomicInt64(-1)
    private let eofFlag = AtomicBool(false)

    // Published by the consumer.
    private let appliedEpochPublished = AtomicInt64(0)
    private let playedFrame = AtomicInt64(0)

    let paused = AtomicBool(true)
    private let closed = AtomicBool(false)
    private let seekPending = AtomicBool(false)

    // Consumer-thread state.
    private var cEpoch: Int64 = 0
    private var cStartCounter: Int64 = 0
    private var cStartFrame: Int64 = 0

    // Control state (never touched by the consumer).
    private let control = NSCondition()
    private var pendingSeekFrame: Int64?
    private var thread: Thread?
    private var errorText: String?

    // Decoder-thread state.
    private var file: AVAudioFile?
    private let fileRate: Double
    private let fileChannels: Int
    private let fileLength: AVAudioFramePosition
    private let converter: PipelineConverter
    private let readBuffer: AVAudioPCMBuffer
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let chunkFrames = 4096
    private let maxOutPerChunk: Int
    private var atEOF = false

    var decoderAtEOF: Bool { eofFlag.load() }

    init(file: AVAudioFile, bufferFrames: Int) throws {
        self.file = file
        fileRate = file.processingFormat.sampleRate
        fileChannels = Int(file.processingFormat.channelCount)
        fileLength = file.length
        converter = try PipelineConverter(inputSampleRate: fileRate, maxInputFrames: chunkFrames)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw FileSource.FileSourceError.unsupportedFormat("cannot allocate decode buffer")
        }
        readBuffer = buf
        left = .allocate(capacity: chunkFrames)
        right = .allocate(capacity: chunkFrames)
        maxOutPerChunk = SampleConversion.expectedOutputFrames(inputFrames: chunkFrames, inputRate: fileRate) + 1024
        ring = PCMRingBuffer(capacityFrames: max(bufferFrames, maxOutPerChunk * 4), channels: PCM.channels)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    // MARK: Control

    func startThreadIfNeeded() {
        control.lock(); defer { control.unlock() }
        guard thread == nil, !closed.load() else { return }
        let t = Thread { [self] in self.decodeLoop() }
        t.name = "Multicast.FileSource.decoder"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func requestSeek(toFrame frame: Int64) {
        control.lock()
        pendingSeekFrame = frame
        seekPending.store(true)
        control.signal()
        control.unlock()
    }

    func close() {
        closed.store(true)
        control.lock()
        control.signal()
        control.unlock()
    }

    func position() -> Int64 {
        if seekPending.load() {
            control.lock(); defer { control.unlock() }
            if let p = pendingSeekFrame { return p }
        }
        let e = segEpoch.load()
        if e & 1 == 0, e != appliedEpochPublished.load() {
            let f = segStartFrame.load()
            if segEpoch.load() == e { return f }
        }
        return playedFrame.load()
    }

    func isAtEnd() -> Bool {
        !seekPending.load() && eofEpoch.load() == appliedEpochPublished.load()
            && segEpoch.load() == appliedEpochPublished.load() && ring.availableToRead == 0
    }

    func decodeError() -> String? {
        control.lock(); defer { control.unlock() }
        return errorText
    }

    // MARK: Consumer (real-time)

    @inline(__always)
    private func applyPendingSegment() {
        let e1 = segEpoch.load()
        if e1 & 1 != 0 || e1 == cEpoch { return }
        let startCounter = segStartCounter.load()
        let startFrame = segStartFrame.load()
        guard segEpoch.load() == e1 else { return }
        ring.skip(toCount: startCounter)
        cEpoch = e1
        cStartCounter = startCounter
        cStartFrame = startFrame
        playedFrame.store(startFrame)
        appliedEpochPublished.store(e1)
    }

    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        if paused.load() { return 0 }
        // A requested seek the decoder has not applied yet: deliver nothing rather than
        // pre-seek audio.
        if seekPending.load() { return 0 }
        applyPendingSegment()
        let n = ring.read(into: buffer, frames: frameCount)
        if n > 0 {
            playedFrame.store(cStartFrame + (ring.readCount - cStartCounter))
            return n
        }
        if !seekPending.load(), eofEpoch.load() == cEpoch, segEpoch.load() == cEpoch {
            return nil
        }
        return 0
    }

    // MARK: Decoder thread

    private func publishSegment(startFrame: Int64) {
        segEpoch.add(1) // odd: writing
        segStartCounter.store(ring.writeCount)
        segStartFrame.store(startFrame)
        segEpoch.add(1) // even: stable
    }

    private func idle(_ seconds: Double) {
        control.lock()
        if pendingSeekFrame == nil, !closed.load() {
            _ = control.wait(until: Date().addingTimeInterval(seconds))
        }
        control.unlock()
    }

    private func emit(_ ptr: UnsafePointer<Int16>, _ frames: Int) {
        var offset = 0
        while offset < frames {
            let w = ring.write(ptr + offset * PCM.channels, frames: frames - offset)
            offset += w
            if offset < frames {
                // Only possible if the converter produced more than budgeted; wait for space.
                if closed.load() || seekPending.load() { return }
                usleep(2_000)
            }
        }
    }

    private func markEOF(error: String?) {
        if let error {
            control.lock(); errorText = error; control.unlock()
        }
        atEOF = true
        eofEpoch.store(segEpoch.load())
        eofFlag.store(true)
    }

    private func decodeLoop() {
        while !closed.load() {
            control.lock()
            let seekTarget = pendingSeekFrame
            pendingSeekFrame = nil
            control.unlock()

            guard let file else { break }

            if let target = seekTarget {
                var fileFrame = AVAudioFramePosition((Double(target) * fileRate / Double(PCM.sampleRate)).rounded())
                fileFrame = min(max(0, fileFrame), fileLength)
                file.framePosition = fileFrame
                converter.reset()
                publishSegment(startFrame: target)
                atEOF = false
                eofFlag.store(false)
                eofEpoch.store(-1)
                control.lock()
                if pendingSeekFrame == nil { seekPending.store(false) }
                control.unlock()
                continue
            }

            if atEOF || ring.availableToWrite < maxOutPerChunk {
                idle(atEOF ? 0.05 : 0.01)
                continue
            }

            do {
                if file.framePosition >= fileLength {
                    try converter.finish { emit($0, $1) }
                    markEOF(error: nil)
                    continue
                }
                readBuffer.frameLength = 0
                try file.read(into: readBuffer, frameCount: AVAudioFrameCount(chunkFrames))
                let n = Int(readBuffer.frameLength)
                if n == 0 {
                    try converter.finish { emit($0, $1) }
                    markEOF(error: nil)
                    continue
                }
                let channels = readBuffer.floatChannelData!
                var planar: [UnsafePointer<Float>] = []
                planar.reserveCapacity(min(fileChannels, 2))
                for c in 0..<min(fileChannels, 2) { planar.append(UnsafePointer(channels[c])) }
                SampleConversion.toStereo(planar: planar, frames: n, left: left, right: right)
                try converter.convert(left: left, right: right, frames: n) { emit($0, $1) }
            } catch {
                markEOF(error: error.localizedDescription)
            }
        }
        control.lock()
        file = nil
        thread = nil
        control.unlock()
    }
}
