import AVFoundation
import CoreMedia
import Foundation
import MulticastAudio
import Testing
@testable import MulticastSources

@Suite struct PushedFillControllerTests {
    @Test func waitsUntilPrimedThenDelivers() {
        var fill = PushedFillController()
        // Chunks of 1024: safety is the 50 ms minimum (2205), prime is 2205 + 1024.
        #expect(fill.primeLevel(chunkFrames: 1024) == 3229)
        #expect(fill.decide(available: 3000, requested: 352, chunkFrames: 1024) == .wait)
        #expect(fill.isPriming)
        #expect(fill.decide(available: 3229, requested: 352, chunkFrames: 1024) == .read(frames: 352))
        #expect(!fill.isPriming)
    }

    @Test func largeChunksRaiseTheCushion() {
        let fill = PushedFillController()
        // Half-second chunks: the cushion is one chunk, delivery starts at two.
        #expect(fill.safetyFrames(chunkFrames: 22_050) == 22_050)
        #expect(fill.primeLevel(chunkFrames: 22_050) == 44_100)
        // Absurd chunks are planned for as one second.
        #expect(fill.primeLevel(chunkFrames: 500_000) == 88_200)
    }

    @Test func underrunHandsOverTheTailThenPrimesAgain() {
        var fill = PushedFillController()
        _ = fill.decide(available: 4000, requested: 352, chunkFrames: 1024)
        #expect(fill.decide(available: 100, requested: 352, chunkFrames: 1024) == .read(frames: 100))
        #expect(fill.decide(available: 0, requested: 352, chunkFrames: 1024) == .wait)
        #expect(fill.isPriming)
        // Not enough to start again yet.
        #expect(fill.decide(available: 2000, requested: 352, chunkFrames: 1024) == .wait)
        #expect(fill.decide(available: 3300, requested: 352, chunkFrames: 1024) == .read(frames: 352))
    }

    @Test func overrunDropsTheOldestDownToThePrimeLevel() {
        var fill = PushedFillController()
        _ = fill.decide(available: 4000, requested: 352, chunkFrames: 1024)
        let limit = fill.overrunLevel(chunkFrames: 1024)
        #expect(limit == 3229 + 1024 + 22_050)
        #expect(fill.decide(available: limit, requested: 352, chunkFrames: 1024) == .read(frames: 352))
        #expect(fill.decide(available: limit + 5000, requested: 352, chunkFrames: 1024)
            == .resync(drop: limit + 5000 - 3229, frames: 352))
    }

    /// Simulates a producer and a consumer on clocks that differ by `ppm` and returns the fill
    /// level once a second, with the corrections made.
    private func simulate(ppm: Double, seconds: Int, chunk: Int) -> (levels: [Int], drops: Int, dups: Int, underruns: Int, resyncs: Int) {
        var fill = PushedFillController()
        var level = 0
        var produced = 0.0
        var levels: [Int] = []
        var drops = 0, dups = 0, underruns = 0, resyncs = 0
        let pulls = seconds * PCM.sampleRate / PCM.framesPerPacket
        let perPull = Double(PCM.framesPerPacket) * (1 + ppm / 1_000_000)
        var started = false
        for pull in 0..<pulls {
            produced += perPull
            while produced >= Double(chunk) {
                produced -= Double(chunk)
                level += chunk
            }
            switch fill.decide(available: level, requested: PCM.framesPerPacket, chunkFrames: chunk) {
            case .wait:
                if started { underruns += 1 }
            case .read(let n):
                started = true
                level -= n
            case .readDroppingOne(let n):
                level -= n + 1
                drops += 1
            case .readDuplicatingOne(let n):
                level -= n - 1
                dups += 1
            case .resync(let drop, let n):
                level -= drop + n
                resyncs += 1
            }
            if pull % (PCM.sampleRate / PCM.framesPerPacket) == 0 { levels.append(level) }
        }
        return (levels, drops, dups, underruns, resyncs)
    }

    @Test func aFastCaptureClockIsHeldByDroppingFrames() {
        // 500 ppm fast for ten minutes would add 13 230 frames; the level must stay bounded.
        let run = simulate(ppm: 500, seconds: 600, chunk: 1024)
        #expect(run.drops > 0)
        #expect(run.underruns == 0)
        #expect(run.resyncs == 0)
        #expect(run.levels.max()! < 3229 + 1024 + 4410)
    }

    @Test func aSlowCaptureClockIsHeldByRepeatingFrames() {
        let run = simulate(ppm: -500, seconds: 600, chunk: 1024)
        #expect(run.dups > 0)
        #expect(run.underruns == 0)
        #expect(run.levels.dropFirst(5).min()! > 0)
    }

    @Test func matchedClocksNeedNoCorrectionEvenWithHalfSecondChunks() {
        let run = simulate(ppm: 0, seconds: 120, chunk: 22_050)
        #expect(run.drops == 0)
        #expect(run.dups == 0)
        #expect(run.underruns == 0)
        #expect(run.resyncs == 0)
    }

    @Test func driftIsHeldWithHalfSecondChunksToo() {
        let fast = simulate(ppm: 300, seconds: 900, chunk: 22_050)
        #expect(fast.underruns == 0)
        #expect(fast.resyncs == 0)
        #expect(fast.levels.max()! < 44_100 + 22_050 + 11_025)
        let slow = simulate(ppm: -300, seconds: 900, chunk: 22_050)
        #expect(slow.underruns == 0)
    }
}

@Suite struct PushedAudioFormatTests {
    private func asbd(rate: Double = 44_100, channels: UInt32 = 2, bits: UInt32 = 16, flags: AudioFormatFlags,
                      bytesPerFrame: UInt32? = nil, id: AudioFormatID = kAudioFormatLinearPCM) -> AudioStreamBasicDescription {
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let frame = bytesPerFrame ?? (bits / 8) * (interleaved ? channels : 1)
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: frame,
                                           mFramesPerPacket: 1, mBytesPerFrame: frame, mChannelsPerFrame: channels,
                                           mBitsPerChannel: bits, mReserved: 0)
    }

    @Test func readsTheLayoutsReplayKitUses() {
        // App audio has been seen as big-endian S16 stereo at 44.1 kHz…
        let big = PushedAudioFormat(asbd(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian))
        #expect(big == PushedAudioFormat(sampleRate: 44_100, channels: 2, sample: .int16, isBigEndian: true))
        // …and microphone-style little-endian mono.
        let mono = PushedAudioFormat(asbd(rate: 48_000, channels: 1, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked))
        #expect(mono == PushedAudioFormat(sampleRate: 48_000, channels: 1, sample: .int16))
        let planarFloat = PushedAudioFormat(asbd(rate: 48_000, bits: 32, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved))
        #expect(planarFloat == PushedAudioFormat(sampleRate: 48_000, channels: 2, sample: .float32, isInterleaved: false))
    }

    @Test func refusesWhatItCannotDecode() {
        #expect(PushedAudioFormat(asbd(flags: 0, id: kAudioFormatMPEG4AAC)) == nil)
        #expect(PushedAudioFormat(asbd(bits: 24, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)) == nil)
        // 24 bits in a 32-bit slot is not packed.
        #expect(PushedAudioFormat(asbd(bits: 16, flags: kAudioFormatFlagIsSignedInteger, bytesPerFrame: 8)) == nil)
        #expect(PushedAudioFormat(asbd(flags: kAudioFormatFlagIsPacked)) == nil) // unsigned
        #expect(PushedAudioFormat(asbd(rate: 0, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)) == nil)
    }
}

@Suite struct PushedAudioSourceTests {
    /// A source that starts delivering at once (no cushion), for exact comparisons.
    private func immediateSource(capacitySeconds: Double = 4) async throws -> PushedAudioSource {
        let fill = PushedFillController(minimumSafetyFrames: 0, maximumChunkFrames: 0, overrunHeadroomFrames: 1 << 40)
        let source = PushedAudioSource(displayName: "Test", capacitySeconds: capacitySeconds, fill: fill)
        try await source.start()
        return source
    }

    private func pull(_ source: PushedAudioSource, frames: Int, chunk: Int = PCM.framesPerPacket) -> [Int16] {
        var out: [Int16] = []
        var buffer = [Int16](repeating: 0, count: chunk * 2)
        while out.count / 2 < frames {
            let want = min(chunk, frames - out.count / 2)
            let got = buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: want) } ?? 0
            if got == 0 { break }
            out.append(contentsOf: buffer[0..<(got * 2)])
        }
        return out
    }

    private func push<T>(_ source: PushedAudioSource, _ samples: [T], frames: Int, format: PushedAudioFormat) -> Bool {
        samples.withUnsafeBytes { source.push(interleaved: $0, frames: frames, format: format) }
    }

    @Test func pipelineFormatPassesThroughBitForBit() async throws {
        let source = try await immediateSource()
        let frames = 5000
        var input = [Int16]()
        for i in 0..<frames { input.append(Int16(truncatingIfNeeded: i * 7 - 16_000)); input.append(Int16(truncatingIfNeeded: -i * 3)) }
        #expect(push(source, input, frames: frames, format: .init(sampleRate: 44_100, channels: 2, sample: .int16)))
        #expect(pull(source, frames: frames) == input)
        #expect(source.statistics.framesPushed == Int64(frames))
        #expect(source.statistics.inputSampleRate == 44_100)
    }

    @Test func bigEndianIsSwapped() async throws {
        let source = try await immediateSource()
        let native: [Int16] = [1, -2, 300, -400, 32_767, -32_768]
        let swapped = native.map { $0.bigEndian }
        #expect(push(source, swapped, frames: 3, format: .init(sampleRate: 44_100, channels: 2, sample: .int16, isBigEndian: true)))
        #expect(pull(source, frames: 3) == native)
    }

    @Test func monoIsPlayedOnBothSides() async throws {
        let source = try await immediateSource()
        let mono: [Int16] = [10, -20, 30, -40]
        #expect(push(source, mono, frames: 4, format: .init(sampleRate: 44_100, channels: 1, sample: .int16)))
        #expect(pull(source, frames: 4) == [10, 10, -20, -20, 30, 30, -40, -40])
    }

    @Test func extraChannelsKeepTheFrontPair() async throws {
        let source = try await immediateSource()
        // 5.1-style frames: L R C LFE Ls Rs.
        let surround: [Int16] = [1, 2, 9, 9, 9, 9, 3, 4, 9, 9, 9, 9]
        #expect(push(source, surround, frames: 2, format: .init(sampleRate: 44_100, channels: 6, sample: .int16)))
        #expect(pull(source, frames: 2) == [1, 2, 3, 4])
    }

    @Test func floatAndInt32AreScaledAndClipped() async throws {
        let source = try await immediateSource()
        let floats: [Float] = [0.5, -0.5, 2.0, -2.0, .nan, 0]
        #expect(push(source, floats, frames: 3, format: .init(sampleRate: 44_100, channels: 2, sample: .float32)))
        #expect(pull(source, frames: 3) == [16_384, -16_384, 32_767, -32_768, 0, 0])

        let ints: [Int32] = [0x1234_5678, -0x1234_5678, Int32.max, Int32.min]
        #expect(push(source, ints, frames: 2, format: .init(sampleRate: 44_100, channels: 2, sample: .int32)))
        #expect(pull(source, frames: 2) == [0x1234, -0x1235, 32_767, -32_768])
    }

    @Test func planarBuffersAreInterleaved() async throws {
        let source = try await immediateSource()
        var left: [Float] = [0.25, 0.5, 0.75]
        var right: [Float] = [-0.25, -0.5, -0.75]
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let ok = left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                return source.push(bufferList: UnsafePointer(list.unsafeMutablePointer), frames: 3,
                                   format: .init(sampleRate: 44_100, channels: 2, sample: .float32, isInterleaved: false))
            }
        }
        #expect(ok)
        #expect(pull(source, frames: 3) == [8192, -8192, 16_384, -16_384, 24_575, -24_575])
    }

    @Test func fortyEightKilohertzIsResampledToTheSameTone() async throws {
        let source = try await immediateSource()
        let rate = 48_000.0
        let tone = 1000.0
        let seconds = 2
        // Pushed in ReplayKit-sized chunks that do not divide the slice size.
        let chunk = 1024
        var frame = 0
        while frame < Int(rate) * seconds {
            var samples = [Int16]()
            for i in frame..<(frame + chunk) {
                let s = Int16((sin(2 * .pi * tone * Double(i) / rate) * 16_000).rounded())
                samples.append(s); samples.append(s)
            }
            #expect(push(source, samples, frames: chunk, format: .init(sampleRate: rate, channels: 2, sample: .int16)))
            frame += chunk
        }
        let out = pull(source, frames: 200_000)
        let outFrames = out.count / 2
        // Two seconds in, two seconds out (less the resampler's short tail).
        let expected = Int(Double(frame) * 44_100 / rate)
        #expect(abs(outFrames - expected) < 200)

        // Same frequency: count rising zero crossings over the middle second.
        let left = TestAudio.channel(out, 0)
        var crossings = 0
        let from = 10_000, to = from + 44_100
        for i in from..<to where left[i - 1] < 0 && left[i] >= 0 { crossings += 1 }
        #expect(abs(crossings - 1000) <= 1)
        // Same level, within half a decibel.
        let peak = left[from..<to].map { abs(Int($0)) }.max()!
        #expect(abs(Double(peak) - 16_000) < 900)
        // Both sides carry it.
        #expect(TestAudio.channel(out, 1)[from..<to].map { abs(Int($0)) }.max()! > 15_000)
    }

    @Test func ringWrapsManyTimesWithoutLosingOrder() async throws {
        // A ring of 2048 frames, cycled through 100 000.
        let source = try await immediateSource(capacitySeconds: 2048.0 / 44_100)
        var next: Int16 = 0
        var expected: Int16 = 0
        var total = 0
        while total < 100_000 {
            let n = 300 + total % 211
            var samples = [Int16]()
            for _ in 0..<n { samples.append(next); samples.append(~next); next &+= 1 }
            #expect(push(source, samples, frames: n, format: .init(sampleRate: 44_100, channels: 2, sample: .int16)))
            let out = pull(source, frames: n, chunk: 97)
            #expect(out.count == n * 2)
            for i in 0..<(out.count / 2) {
                if out[2 * i] != expected || out[2 * i + 1] != ~expected {
                    Issue.record("order lost at frame \(total + i)")
                    return
                }
                expected &+= 1
            }
            total += n
        }
        #expect(source.statistics.overflowFrames == 0)
    }

    @Test func overflowDropsTheNewestAndCountsIt() async throws {
        // The smallest ring is 2048 frames.
        let source = try await immediateSource(capacitySeconds: 0.01)
        var samples = [Int16]()
        for i in 0..<3000 { samples.append(Int16(i)); samples.append(Int16(i)) }
        #expect(push(source, samples, frames: 3000, format: .init(sampleRate: 44_100, channels: 2, sample: .int16)))
        let stats = source.statistics
        #expect(stats.framesPushed == 2048)
        #expect(stats.overflowFrames == 952)
        // What was kept is the start of the buffer, in order.
        let out = pull(source, frames: 5000)
        try #require(out.count == 4096)
        #expect(out[0] == 0 && out[4094] == 2047)
    }

    @Test func nothingIsAcceptedBeforeStartOrAfterStop() async throws {
        let source = PushedAudioSource(displayName: "Test")
        let samples = [Int16](repeating: 5, count: 200)
        let format = PushedAudioFormat(sampleRate: 44_100, channels: 2, sample: .int16)
        #expect(!push(source, samples, frames: 100, format: format))
        #expect(source.statistics.rejectedFrames == 100)
        try await source.start()
        #expect(push(source, samples, frames: 100, format: format))
        await source.stop()
        #expect(!push(source, samples, frames: 100, format: format))
        // Stopping also drops what was buffered.
        try await source.start()
        var buffer = [Int16](repeating: 1, count: 704)
        #expect(buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: 352) } == 0)
    }

    @Test func defaultPolicyPrimesBeforeDeliveringAndCountsUnderruns() async throws {
        let source = PushedAudioSource(displayName: "Test")
        try await source.start()
        let format = PushedAudioFormat(sampleRate: 44_100, channels: 2, sample: .int16)
        let chunk = [Int16](repeating: 100, count: 2048)
        var buffer = [Int16](repeating: 0, count: 704)
        func read() -> Int { buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: 352) } ?? -1 }

        // Three chunks of 1024 are short of the 3229-frame prime level.
        for _ in 0..<3 { #expect(push(source, chunk, frames: 1024, format: format)) }
        #expect(read() == 0)
        #expect(source.statistics.underruns == 0)
        #expect(push(source, chunk, frames: 1024, format: format))
        #expect(read() == 352)
        // Drain it: the tail comes out short, then silence, and that is one underrun.
        var drained = 352
        while true {
            let n = read()
            if n == 0 { break }
            drained += n
        }
        #expect(drained == 4096)
        #expect(source.statistics.underruns == 1)
        #expect(read() == 0)
        #expect(source.statistics.underruns == 1)
    }

    @Test func silenceIsToldApartFromSound() async throws {
        let source = try await immediateSource()
        let format = PushedAudioFormat(sampleRate: 48_000, channels: 2, sample: .int16)
        #expect(push(source, [Int16](repeating: 0, count: 2048), frames: 1024, format: format))
        #expect(source.statistics.buffersPushed == 1)
        #expect(source.statistics.audibleBuffers == 0)
        #expect(source.statistics.lastAudibleHostNanos == 0)
        #expect(push(source, [Int16](repeating: 9, count: 2048), frames: 1024, format: format))
        #expect(source.statistics.audibleBuffers == 1)
        #expect(source.statistics.lastAudibleHostNanos > 0)
    }

    @Test func aRateChangeMidStreamKeepsPlaying() async throws {
        let source = try await immediateSource()
        let a = [Int16](repeating: 1000, count: 9600)
        #expect(push(source, a, frames: 4800, format: .init(sampleRate: 48_000, channels: 2, sample: .int16)))
        #expect(push(source, a, frames: 4800, format: .init(sampleRate: 44_100, channels: 2, sample: .int16)))
        #expect(push(source, a, frames: 4800, format: .init(sampleRate: 32_000, channels: 2, sample: .int16)))
        let out = pull(source, frames: 100_000)
        // 0.1 s + 0.109 s + 0.15 s, less resampler tails.
        #expect(out.count / 2 > 14_000)
        #expect(out.count / 2 < 16_100)
    }

    // MARK: CMSampleBuffer (what ReplayKit delivers)

    private func sampleBuffer(_ bytes: [UInt8], frames: Int, asbd: AudioStreamBasicDescription) throws -> CMSampleBuffer {
        var description = asbd
        var format: CMAudioFormatDescription?
        try #require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
        try #require(CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block!, offsetIntoDestination: 0,
                                                   dataLength: bytes.count) == noErr)
        var sample: CMSampleBuffer?
        try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    @Test func sampleBuffersInReplayKitsBigEndianLayoutArePlayed() async throws {
        let source = try await immediateSource()
        let native: [Int16] = [100, -100, 2000, -2000, 30_000, -30_000]
        var bytes = [UInt8]()
        for s in native { bytes.append(UInt8(truncatingIfNeeded: s >> 8)); bytes.append(UInt8(truncatingIfNeeded: s)) }
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        #expect(source.push(sampleBuffer: try sampleBuffer(bytes, frames: 3, asbd: asbd)))
        #expect(pull(source, frames: 3) == native)
    }

    @Test func compressedSampleBuffersAreRefused() async throws {
        let source = try await immediateSource()
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatULaw, mFormatFlags: 0,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 2, mBitsPerChannel: 8, mReserved: 0)
        #expect(!source.push(sampleBuffer: try sampleBuffer([UInt8](repeating: 0, count: 8), frames: 4, asbd: asbd)))
        #expect(source.statistics.rejectedFrames == 4)
        #expect(source.statistics.framesPushed == 0)
    }

    @Test func pushAndReadRunOnTwoThreadsWithoutLosingOrder() async throws {
        let source = try await immediateSource(capacitySeconds: 0.25)
        let total = 400_000
        let producer = Thread {
            var next: Int32 = 0
            var samples = [Int16](repeating: 0, count: 2 * 441)
            while next < Int32(total) {
                // Leave room: this test is about order, not overflow.
                if source.statistics.bufferedFrames > 8000 { usleep(200); continue }
                let n = min(441, total - Int(next))
                for i in 0..<n {
                    let v = next + Int32(i)
                    samples[2 * i] = Int16(truncatingIfNeeded: v)
                    samples[2 * i + 1] = Int16(truncatingIfNeeded: v >> 16)
                }
                _ = samples.withUnsafeBytes {
                    source.push(interleaved: $0, frames: n, format: .init(sampleRate: 44_100, channels: 2, sample: .int16))
                }
                next += Int32(n)
            }
        }
        producer.start()
        var expected: Int32 = 0
        var buffer = [Int16](repeating: 0, count: 704)
        let deadline = Date().addingTimeInterval(20)
        while expected < Int32(total), Date() < deadline {
            let got = buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frameCount: 352) } ?? 0
            if got == 0 { usleep(100); continue }
            for i in 0..<got {
                let v = Int32(UInt16(bitPattern: buffer[2 * i])) | (Int32(buffer[2 * i + 1]) << 16)
                if v != expected {
                    Issue.record("expected frame \(expected), read \(v)")
                    return
                }
                expected += 1
            }
        }
        #expect(expected == Int32(total))
        #expect(source.statistics.overflowFrames == 0)
    }
}
