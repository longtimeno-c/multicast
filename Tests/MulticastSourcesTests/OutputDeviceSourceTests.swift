#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import MulticastSources

@Suite struct OutputDeviceSourceTests {
    private func withBufferList(_ buffers: [[Float]], channelsEach: UInt32,
                                _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let abl = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(abl.unsafeMutablePointer) }
        var storage = buffers
        storage.withUnsafeMutableBufferPointer { outer in
            for i in 0..<outer.count {
                outer[i].withUnsafeMutableBufferPointer { p in
                    abl[i] = AudioBuffer(mNumberChannels: channelsEach, mDataByteSize: UInt32(p.count * 4),
                                         mData: UnsafeMutableRawPointer(p.baseAddress))
                }
            }
            body(abl.unsafePointer)
        }
    }

    @Test func copiesInterleavedStereoInput() {
        let ring = SPSCRingBuffer<Float>(capacityFrames: 16, channels: 2)
        withBufferList([[0.1, -0.1, 0.2, -0.2, 0.3, -0.3]], channelsEach: 2) { abl in
            let r = OutputDeviceSource.copyInput(abl, into: ring)
            #expect(r.frames == 3 && r.nonSilent)
        }
        var out = [Float](repeating: 0, count: 6)
        #expect(ring.read(into: &out, frames: 3) == 3)
        #expect(out == [0.1, -0.1, 0.2, -0.2, 0.3, -0.3])
    }

    @Test func interleavesPlanarInputAndSpotsSilence() {
        let ring = SPSCRingBuffer<Float>(capacityFrames: 16, channels: 2)
        withBufferList([[0, 0], [0, 0]], channelsEach: 1) { abl in
            let r = OutputDeviceSource.copyInput(abl, into: ring)
            #expect(r.frames == 2 && !r.nonSilent)
        }
        withBufferList([[1, 2], [3, 4]], channelsEach: 1) { abl in
            _ = OutputDeviceSource.copyInput(abl, into: ring)
        }
        var out = [Float](repeating: 9, count: 8)
        #expect(ring.read(into: &out, frames: 4) == 4)
        #expect(out == [0, 0, 0, 0, 1, 3, 2, 4])
    }

    @Test func monoIsDuplicated() {
        let ring = SPSCRingBuffer<Float>(capacityFrames: 16, channels: 2)
        withBufferList([[0.5, 0.25]], channelsEach: 1) { abl in
            _ = OutputDeviceSource.copyInput(abl, into: ring)
        }
        var out = [Float](repeating: 0, count: 4)
        ring.read(into: &out, frames: 2)
        #expect(out == [0.5, 0.5, 0.25, 0.25])
    }

    @Test func fullRingDropsTheRestInsteadOfBlocking() {
        let ring = SPSCRingBuffer<Float>(capacityFrames: 2, channels: 2)
        withBufferList([[1, 1, 2, 2, 3, 3, 4, 4]], channelsEach: 2) { abl in
            let r = OutputDeviceSource.copyInput(abl, into: ring)
            #expect(r.frames == 4)
        }
        #expect(ring.availableToRead == 2)
    }

    @Test func floatToS16ClipsAndRounds() {
        let src: [Float] = [0, 1, -1, 2, -2, 0.5, .nan]
        var dst = [Int16](repeating: 7, count: src.count)
        OutputDeviceSource.floatToS16(src, count: src.count, into: &dst)
        #expect(dst == [0, 32767, -32767, 32767, -32768, 16384, 0])
    }

    @Test func uidsMatchTheDriver() throws {
        // Must stay equal to MC_OUTPUT_DEVICE_UID / MC_LOOPBACK_DEVICE_UID in MulticastDeviceCore.h.
        let header = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/MulticastDevice/Core/include/MulticastDeviceCore.h"), encoding: .utf8)
        #expect(header.contains("\"\(OutputDeviceSource.outputDeviceUID)\""))
        #expect(header.contains("\"\(OutputDeviceSource.loopbackDeviceUID)\""))
        #expect(header.contains(String(format: "0x%08Xu", OutputDeviceSource.hubLatencySelector)))
    }

    @Test func notInstalledIsReportedNotThrownAtInit() async {
        // On a Mac without the driver, start() says so; with it, this test only checks state.
        let source = OutputDeviceSource()
        if !OutputDeviceSource.isInstalled {
            await #expect(throws: OutputDeviceSource.SourceError.notInstalled) { try await source.start() }
        }
        #expect(source.isLive)
    }
}
#endif
