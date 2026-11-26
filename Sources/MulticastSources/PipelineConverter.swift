import AVFoundation
import Foundation
import MulticastAudio

/// Small, pure sample-format helpers (allocation-free; safe anywhere).
public enum SampleConversion {
    /// Float [-1, 1] -> Int16 with clipping and rounding to nearest.
    @inline(__always)
    public static func int16(fromFloat x: Float) -> Int16 {
        if !(x == x) { return 0 } // NaN
        let scaled = (x * 32767).rounded()
        if scaled >= 32767 { return 32767 }
        if scaled <= -32768 { return -32768 }
        return Int16(scaled)
    }

    /// Int16 -> Float [-1, 1).
    @inline(__always)
    public static func float(fromInt16 s: Int16) -> Float {
        Float(s) / 32768
    }

    /// Writes the stereo (L, R) pair to use for a frame of `channelCount` planar channels.
    /// Mono is duplicated into both sides; two or more channels keep the first two
    /// (front left / front right in every standard layout).
    @inline(__always)
    public static func stereoPair(channelCount: Int, sample: (Int) -> Float) -> (Float, Float) {
        switch channelCount {
        case ..<1: return (0, 0)
        case 1:
            let m = sample(0)
            return (m, m)
        default:
            return (sample(0), sample(1))
        }
    }

    /// Up-mixes / selects planar float channels into two planar stereo buffers.
    public static func toStereo(
        planar channels: [UnsafePointer<Float>],
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        switch channels.count {
        case 0:
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
        case 1:
            left.update(from: channels[0], count: frames)
            right.update(from: channels[0], count: frames)
        default:
            left.update(from: channels[0], count: frames)
            right.update(from: channels[1], count: frames)
        }
    }

    /// Interleaves planar stereo floats into S16 stereo.
    public static func interleaveToS16(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int,
        into out: UnsafeMutablePointer<Int16>
    ) {
        for i in 0..<frames {
            out[2 * i] = int16(fromFloat: left[i])
            out[2 * i + 1] = int16(fromFloat: right[i])
        }
    }

    /// Expected number of output frames when resampling `inputFrames` from `inputRate` to the
    /// pipeline rate (44.1 kHz).
    public static func expectedOutputFrames(inputFrames: Int, inputRate: Double) -> Int {
        Int((Double(inputFrames) * Double(PCM.sampleRate) / inputRate).rounded())
    }
}

/// Converts planar stereo Float32 at any sample rate into the pipeline format
/// (44.1 kHz, interleaved S16 stereo) using `AVAudioConverter` (high quality SRC).
///
/// NOT real-time safe (AVAudioConverter may allocate): use it on a decoder/worker thread and
/// hand its output to the engine through a `PCMRingBuffer`.
public final class PipelineConverter {
    public enum ConverterError: Error, Equatable {
        case unsupportedInputRate(Double)
        case cannotCreateConverter
        case conversionFailed(String)
    }

    public let inputSampleRate: Double
    public let maxInputFrames: Int

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private var finished = false

    public static let outputFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(PCM.sampleRate),
        channels: AVAudioChannelCount(PCM.channels),
        interleaved: true
    )!

    public init(inputSampleRate: Double, maxInputFrames: Int = 4096) throws {
        guard inputSampleRate >= 1000, inputSampleRate <= 768_000,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 2)
        else { throw ConverterError.unsupportedInputRate(inputSampleRate) }
        guard let conv = AVAudioConverter(from: inFormat, to: Self.outputFormat) else {
            throw ConverterError.cannotCreateConverter
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        self.converter = conv
        self.inputSampleRate = inputSampleRate
        self.maxInputFrames = maxInputFrames
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(maxInputFrames)) else {
            throw ConverterError.cannotCreateConverter
        }
        let outCap = SampleConversion.expectedOutputFrames(inputFrames: maxInputFrames, inputRate: inputSampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(outCap)) else {
            throw ConverterError.cannotCreateConverter
        }
        inputBuffer = inBuf
        outputBuffer = outBuf
    }

    /// Feeds `frames` (<= maxInputFrames) of planar stereo float. `emit` is called with each
    /// chunk of converted pipeline-format output (interleaved S16 stereo, frame count).
    public func convert(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int,
        emit: (UnsafePointer<Int16>, Int) -> Void
    ) throws {
        precondition(frames <= maxInputFrames)
        if frames == 0 { return }
        if finished { converter.reset(); finished = false }
        let ch = inputBuffer.floatChannelData!
        ch[0].update(from: left, count: frames)
        ch[1].update(from: right, count: frames)
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        try run(endOfStream: false, emit: emit)
    }

    /// Feeds interleaved stereo float (L R L R ...).
    public func convert(
        interleaved: UnsafePointer<Float>,
        frames: Int,
        emit: (UnsafePointer<Int16>, Int) -> Void
    ) throws {
        precondition(frames <= maxInputFrames)
        if frames == 0 { return }
        if finished { converter.reset(); finished = false }
        let ch = inputBuffer.floatChannelData!
        let l = ch[0], r = ch[1]
        for i in 0..<frames {
            l[i] = interleaved[2 * i]
            r[i] = interleaved[2 * i + 1]
        }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        try run(endOfStream: false, emit: emit)
    }

    /// Flushes the resampler tail at end of stream.
    public func finish(emit: (UnsafePointer<Int16>, Int) -> Void) throws {
        if finished { return }
        inputBuffer.frameLength = 0
        try run(endOfStream: true, emit: emit)
        finished = true
    }

    /// Forget all internal state (after a seek or discontinuity).
    public func reset() {
        converter.reset()
        finished = false
    }

    private func run(endOfStream: Bool, emit: (UnsafePointer<Int16>, Int) -> Void) throws {
        var supplied = endOfStream || inputBuffer.frameLength == 0
        let input = inputBuffer
        while true {
            outputBuffer.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outputBuffer, error: &err) { _, outStatus in
                if !supplied {
                    supplied = true
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            let n = Int(outputBuffer.frameLength)
            if n > 0 {
                emit(UnsafePointer(outputBuffer.int16ChannelData![0]), n)
            }
            switch status {
            case .haveData:
                continue // output buffer was filled; more may be pending
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw ConverterError.conversionFailed(err?.localizedDescription ?? "unknown")
            @unknown default:
                return
            }
        }
    }
}
