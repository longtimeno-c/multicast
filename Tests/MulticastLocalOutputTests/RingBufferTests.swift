import Foundation
import Testing
import MulticastAudio
@testable import MulticastLocalOutput

/// Interleaved S16LE stereo where left = frame mod 32000 and right = −left.
func rampSamples(firstFrame: UInt64, frames: Int) -> Data {
    var d = Data(count: frames * PCM.bytesPerFrame)
    d.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for i in 0..<frames {
            let v = Int16(Int((firstFrame + UInt64(i)) % 32000))
            p[2 * i] = v.littleEndian
            p[2 * i + 1] = (0 &- v).littleEndian
        }
    }
    return d
}

func expectedLeft(_ frame: Int64) -> Float { Float(Int(frame % 32000)) / 32768 }

@discardableResult
func write(_ ring: TimelineRingBuffer, _ first: UInt64, _ frames: Int) -> TimelineRingBuffer.WriteResult {
    rampSamples(firstFrame: first, frames: frames).withUnsafeBytes { ring.write(firstFrame: first, samples: $0) }
}

func read(_ ring: TimelineRingBuffer, _ from: Int64, _ count: Int) -> ([Float], Int) {
    var out = [Float](repeating: .nan, count: count * 2)
    let valid = out.withUnsafeMutableBufferPointer { ring.read(from: from, count: count, into: $0.baseAddress!) }
    return (out, valid)
}

@Suite struct RingBufferTests {
    @Test func capacityRoundsUpToPowerOfTwo() {
        #expect(TimelineRingBuffer(minimumFrames: 1000).capacityFrames == 1024)
        #expect(TimelineRingBuffer(minimumFrames: 1024).capacityFrames == 1024)
    }

    @Test func framesAreIndexedByTimelineFrame() {
        let ring = TimelineRingBuffer(minimumFrames: 4096)
        let start: UInt64 = 1_000_003 // arbitrary, not slot-aligned
        #expect(write(ring, start, 352) == .restarted)
        #expect(write(ring, start + 352, 352) == .appended)
        let (out, valid) = read(ring, Int64(start) + 100, 400)
        #expect(valid == 400)
        for i in 0..<400 {
            let f = Int64(start) + 100 + Int64(i)
            #expect(out[2 * i] == expectedLeft(f))
            #expect(out[2 * i + 1] == -expectedLeft(f))
        }
        #expect(ring.readableRange() == Int64(start)..<Int64(start + 704))
    }

    @Test func wrapsAroundTheEndOfStorage() {
        let ring = TimelineRingBuffer(minimumFrames: 1024)
        // 1000 → 1352 crosses slot 1023 → 0.
        write(ring, 1000, 352)
        let (out, valid) = read(ring, 1000, 352)
        #expect(valid == 352)
        for i in 0..<352 { #expect(out[2 * i] == expectedLeft(1000 + Int64(i))) }
        // Keep going for several laps; the latest window must always read back exactly.
        var f: UInt64 = 1352
        for _ in 0..<20 { write(ring, f, 352); f += 352 }
        let (o2, v2) = read(ring, Int64(f) - 1000, 1000)
        #expect(v2 == 1000)
        for i in 0..<1000 { #expect(o2[2 * i] == expectedLeft(Int64(f) - 1000 + Int64(i))) }
    }

    @Test func underrunAndBeforeStartReadAsSilence() {
        let ring = TimelineRingBuffer(minimumFrames: 4096)
        write(ring, 1000, 352)
        // Starts before the stream (and before frame 0), ends after the written data.
        let (out, valid) = read(ring, -10, 2000)
        #expect(valid == 352)
        for i in 0..<2000 {
            let f = -10 + Int64(i)
            let expected: Float = (f >= 1000 && f < 1352) ? expectedLeft(f) : 0
            #expect(out[2 * i] == expected)
        }
        let (tail, tailValid) = read(ring, 1352, 100)
        #expect(tailValid == 0)
        #expect(tail.allSatisfy { $0 == 0 })
    }

    @Test func overrunOverwritesOldestAndIsCounted() {
        let ring = TimelineRingBuffer(minimumFrames: 1024)
        ring.setReaderPosition(0)
        var f: UInt64 = 0
        var results: [TimelineRingBuffer.WriteResult] = []
        for _ in 0..<5 { results.append(write(ring, f, 352)); f += 352 } // 1760 frames > 1024
        #expect(results.contains(.overran))
        #expect(ring.overrunWrites.load() >= 1)
        // Oldest frames are gone (silence), newest 1024 readable.
        let (old, oldValid) = read(ring, 0, 352)
        #expect(oldValid == 0)
        #expect(old.allSatisfy { $0 == 0 })
        let (new, newValid) = read(ring, Int64(f) - 1024, 1024)
        #expect(newValid == 1024)
        #expect(new[0] == expectedLeft(Int64(f) - 1024))
    }

    @Test func noOverrunCountedWithoutAReader() {
        let ring = TimelineRingBuffer(minimumFrames: 1024)
        var f: UInt64 = 0
        for _ in 0..<5 { write(ring, f, 352); f += 352 }
        #expect(ring.overrunWrites.load() == 0)
    }

    @Test func resetEmptiesImmediatelyAndRestartsOnNextWrite() {
        let ring = TimelineRingBuffer(minimumFrames: 4096)
        write(ring, 0, 352)
        ring.requestReset()
        #expect(ring.readableRange() == nil)
        #expect(read(ring, 0, 352).1 == 0)
        // After a flush the stream may restart anywhere — even at an earlier frame.
        #expect(write(ring, 50, 352) == .restarted)
        #expect(ring.readableRange() == 50..<402)
        #expect(read(ring, 0, 50).1 == 0)
        #expect(read(ring, 50, 352).1 == 352)
    }

    @Test func gapsAreZeroFilled() {
        let ring = TimelineRingBuffer(minimumFrames: 4096)
        write(ring, 0, 352)
        write(ring, 704, 352) // skipped packet 352..<704
        #expect(ring.gapFrames.load() == 352)
        let (out, _) = read(ring, 352, 352)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(read(ring, 704, 352).0[2] == expectedLeft(705))
    }

    @Test func backwardsWriteWithoutFlushIsADiscontinuity() {
        let ring = TimelineRingBuffer(minimumFrames: 4096)
        write(ring, 10_000, 352)
        #expect(write(ring, 0, 352) == .restarted)
        #expect(ring.discontinuities.load() == 1)
        #expect(ring.readableRange() == 0..<352)
    }

    @Test func hugeForwardJumpRestarts() {
        let ring = TimelineRingBuffer(minimumFrames: 1024)
        write(ring, 0, 352)
        #expect(write(ring, 100_000, 352) == .restarted)
        #expect(ring.readableRange() == 100_000..<100_352)
    }

    /// Producer and consumer on two threads: every frame the consumer reports as valid must
    /// carry exactly its own frame's value (never torn, never a stale lap).
    @Test func concurrentProducerConsumerNeverTears() async {
        let ring = TimelineRingBuffer(minimumFrames: 2048) // small: forces laps and overwrites
        let packets = 4000
        let producer = Thread {
            var f: UInt64 = 0
            for _ in 0..<packets {
                let d = rampSamples(firstFrame: f, frames: 352)
                d.withUnsafeBytes { _ = ring.write(firstFrame: f, samples: $0) }
                f += 352
            }
        }
        producer.start()
        var bad = 0
        var validTotal = 0
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 2)
        defer { buf.deallocate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let r = ring.readableRange() else { continue }
            // Read the oldest part — the region the producer is about to overwrite.
            let from = r.lowerBound
            let valid = ring.read(from: from, count: 512, into: buf)
            validTotal += valid
            for i in 0..<512 {
                let v = buf[2 * i]
                if v != 0 && v != expectedLeft(from + Int64(i)) { bad += 1 }
            }
            if r.upperBound >= Int64(packets * 352) { break }
        }
        #expect(bad == 0)
        #expect(validTotal > 0)
    }
}
