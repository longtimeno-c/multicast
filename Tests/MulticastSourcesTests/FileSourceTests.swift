import AVFoundation
import Foundation
import MulticastAudio
import Testing
@testable import MulticastSources

@Suite struct FileSourceTests {
    @Test func monoWAVAt48kIsUpmixedAndResampled() async throws {
        let url = TestAudio.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestAudio.writeWAV(url: url, sampleRate: 48_000, channels: 1, frames: 48_000) { i, _ in
            Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        }
        let src = try FileSource(url: url)
        #expect(src.fileSampleRate == 48_000)
        #expect(src.fileChannelCount == 1)
        #expect(src.durationFrames == 44_100)
        #expect(abs(src.duration - 1.0) < 1e-9)
        #expect(!src.isLive)

        try await src.start()
        let (s, ended) = TestAudio.drain(src)
        #expect(ended)
        #expect(abs(s.count / 2 - 44_100) <= 64, "got \(s.count / 2)")
        let l = TestAudio.channel(s, 0), r = TestAudio.channel(s, 1)
        #expect(l == r)
        let f = TestAudio.estimateFrequency(Array(l[2000..<40000]), sampleRate: 44100)
        #expect(abs(f - 1000) < 1, "estimated \(f)")
        #expect(src.isAtEnd)
        #expect(abs(src.positionFrames - Int64(s.count / 2)) <= 1)
        src.close()
    }

    /// A 44.1 kHz stereo file whose left channel encodes the frame index, so positions can be
    /// read back from the decoded samples.
    private func makeIndexFile(seconds: Double) throws -> URL {
        let url = TestAudio.tempURL("wav")
        let frames = Int(44_100 * seconds)
        try TestAudio.writeWAV(url: url, sampleRate: 44_100, channels: 2, frames: frames) { i, c in
            c == 0 ? Float(i % 30_000) / 32768 : -0.25
        }
        return url
    }

    @Test func seekPositionPauseAndEndOfStream() async throws {
        let url = try makeIndexFile(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileSource(url: url, bufferSeconds: 1)
        #expect(src.durationFrames == 132_300)

        // Before start: delivers nothing.
        var buf = [Int16](repeating: 0, count: 2 * 352)
        #expect(buf.withUnsafeMutableBufferPointer { src.read(into: $0.baseAddress!, frameCount: 352) } == 0)

        try await src.start()
        let (first, _) = TestAudio.drain(src, maxFrames: 1000)
        let l0 = TestAudio.channel(first, 0)
        #expect(abs(Int(l0[0]) - 0) <= 1)
        #expect(abs(Int(l0[999]) - 999) <= 1)
        #expect(src.positionFrames == 1000)

        // Seek forward while playing: next sample is frame 66150 (1.5 s); old buffered audio is skipped.
        src.seek(to: 1.5)
        #expect(src.positionFrames == 66_150)
        let (afterSeek, _) = TestAudio.drain(src, maxFrames: 500)
        let l1 = TestAudio.channel(afterSeek, 0)
        #expect(abs(Int(l1[0]) - 66_150 % 30_000) <= 1, "got \(l1[0])")
        #expect(abs(Int(l1[499]) - (66_649 % 30_000)) <= 1)
        #expect(src.positionFrames == 66_650)

        // Pause: no frames, position held.
        await src.stop()
        #expect(src.isPaused)
        #expect(buf.withUnsafeMutableBufferPointer { src.read(into: $0.baseAddress!, frameCount: 352) } == 0)
        #expect(src.positionFrames == 66_650)

        // Seek while paused, then resume.
        src.seek(to: 0.25)
        #expect(abs(src.position - 0.25) < 1e-9)
        try await src.start()
        let (afterResume, _) = TestAudio.drain(src, maxFrames: 10)
        #expect(abs(Int(TestAudio.channel(afterResume, 0)[0]) - 11_025) <= 1)

        // Play to the end.
        let (rest, ended) = TestAudio.drain(src)
        #expect(ended)
        #expect(11_025 + 10 + rest.count / 2 == 132_300)
        #expect(src.isAtEnd)

        // Seek revives the source after EOS.
        src.seek(to: 2.9)
        #expect(!src.isAtEnd)
        let (tail, ended2) = TestAudio.drain(src)
        #expect(ended2)
        #expect(abs(tail.count / 2 - (132_300 - 127_890)) <= 1)
        src.close()
    }

    @Test func seekBackwardRepeatedly() async throws {
        let url = try makeIndexFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileSource(url: url)
        try await src.start()
        for target in [0.5, 0.1, 1.9, 0.0, 1.0] {
            src.seek(to: target)
            let (s, _) = TestAudio.drain(src, maxFrames: 4)
            let expected = Int((target * 44_100).rounded()) % 30_000
            #expect(abs(Int(TestAudio.channel(s, 0)[0]) - expected) <= 1, "seek \(target)")
        }
        src.close()
    }

    @Test func seekBeyondEndClampsAndEnds() async throws {
        let url = try makeIndexFile(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileSource(url: url)
        try await src.start()
        src.seek(to: 99)
        #expect(src.positionFrames == src.durationFrames)
        let (s, ended) = TestAudio.drain(src, timeout: 5)
        #expect(ended)
        #expect(s.isEmpty)
    }

    @Test func rejectsNonAudioFile() throws {
        let url = TestAudio.tempURL("wav")
        try Data("definitely not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FileSource.FileSourceError.self) { try FileSource(url: url) }
    }

    @Test func metadataMergeAndArtworkSniffing() {
        let a = AudioMetadata(title: "T", artist: nil, album: nil, artworkData: nil)
        let b = AudioMetadata(title: "X", artist: "A", album: "B", artworkData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let m = a.filling(from: b)
        #expect(m.title == "T" && m.artist == "A" && m.album == "B")
        #expect(m.artworkMIMEType == "image/jpeg")
        #expect(ArtworkSniffer.mimeType(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
        #expect(ArtworkSniffer.mimeType(of: Data([1, 2, 3])) == nil)
    }

    /// End-to-end decode of a real system sound (AIFF, 48 kHz on current macOS).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Library/Sounds/Glass.aiff")))
    func decodesSystemSound() async throws {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        let src = try await FileSource.open(url: url)
        #expect(src.duration > 0.2)
        try await src.start()
        let (s, ended) = TestAudio.drain(src)
        #expect(ended)
        #expect(abs(Int64(s.count / 2) - src.durationFrames) <= 64)
        #expect(TestAudio.peak(s[...]) > 1000)
        print("[live] Glass.aiff: \(src.fileSampleRate) Hz x\(src.fileChannelCount), \(src.duration) s, decoded \(s.count / 2) frames, peak \(TestAudio.peak(s[...])), metadata title=\(src.metadata.title ?? "nil")")
    }
}
