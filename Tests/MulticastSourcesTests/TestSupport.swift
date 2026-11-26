import AVFoundation
import Foundation
import MulticastAudio
@testable import MulticastSources

enum TestAudio {
    static var liveEnabled: Bool { ProcessInfo.processInfo.environment["MULTICAST_LIVE"] == "1" }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("multicast-test-\(UUID().uuidString).\(ext)")
    }

    /// Writes a 16-bit PCM WAV whose channel `c` sample at frame `i` is `sample(i, c)`.
    static func writeWAV(url: URL, sampleRate: Double, channels: Int, frames: Int,
                         sample: (Int, Int) -> Float) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = file.processingFormat
        let chunk = 4096
        var written = 0
        while written < frames {
            let n = min(chunk, frames - written)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels {
                let p = buf.floatChannelData![c]
                for i in 0..<n { p[i] = sample(written + i, c) }
            }
            try file.write(from: buf)
            written += n
        }
    }

    /// Pulls a source to its end (or `maxFrames`), like the engine, but tolerating 0-frame
    /// pulls while a background decoder catches up.
    static func drain(_ source: AudioSource, chunk: Int = PCM.framesPerPacket, maxFrames: Int = 10_000_000,
                      timeout: TimeInterval = 20) -> (samples: [Int16], ended: Bool) {
        var out: [Int16] = []
        var buf = [Int16](repeating: 0, count: chunk * 2)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count / 2 < maxFrames, Date() < deadline {
            let want = min(chunk, maxFrames - out.count / 2)
            let r = buf.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: want) }
            guard let n = r else { return (out, true) }
            if n == 0 { usleep(1000); continue }
            out.append(contentsOf: buf[0..<(n * 2)])
        }
        return (out, false)
    }

    static func channel(_ interleaved: [Int16], _ c: Int) -> [Int16] {
        stride(from: c, to: interleaved.count, by: 2).map { interleaved[$0] }
    }

    /// Frequency estimate from positive-going zero crossings (linear interpolated).
    static func estimateFrequency(_ x: [Int16], sampleRate: Double) -> Double {
        var crossings: [Double] = []
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 {
            let a = Double(x[i - 1]), b = Double(x[i])
            crossings.append(Double(i - 1) + (-a) / (b - a))
        }
        guard crossings.count >= 2 else { return 0 }
        let span = crossings.last! - crossings.first!
        return Double(crossings.count - 1) / span * sampleRate
    }

    static func peak(_ x: ArraySlice<Int16>) -> Int {
        x.reduce(0) { max($0, abs(Int($1))) }
    }
}
