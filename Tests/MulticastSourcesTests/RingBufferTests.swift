import Foundation
import Testing
@testable import MulticastSources

@Suite struct RingBufferTests {
    @Test func capacityRoundsUpToPowerOfTwo() {
        let ring = PCMRingBuffer(capacityFrames: 1000, channels: 2)
        #expect(ring.capacityFrames == 1024)
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == 1024)
    }

    @Test func writeThenReadPreservesOrderAcrossWrap() {
        let ring = PCMRingBuffer(capacityFrames: 8, channels: 2)
        var next: Int16 = 0
        var expected: Int16 = 0
        var out = [Int16](repeating: 0, count: 2 * 8)
        // Many cycles with odd sizes force wrap-around in both directions.
        for cycle in 0..<50 {
            let writeN = (cycle % 5) + 1
            var src = [Int16]()
            for _ in 0..<writeN { src.append(next); src.append(-next); next &+= 1 }
            let w = src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: writeN) }
            next &-= Int16(writeN - w) // un-count frames that did not fit
            let readN = (cycle % 3) + 2
            let r = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: readN) }
            for i in 0..<r {
                #expect(out[2 * i] == expected)
                #expect(out[2 * i + 1] == -expected)
                expected &+= 1
            }
        }
        #expect(ring.writeCount - ring.readCount == Int64(ring.availableToRead))
    }

    @Test func writeIsClampedToFreeSpace() {
        let ring = PCMRingBuffer(capacityFrames: 4, channels: 2)
        let src = [Int16](repeating: 7, count: 2 * 10)
        let w = src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 10) }
        #expect(w == 4)
        #expect(ring.availableToWrite == 0)
        #expect(ring.availableToRead == 4)
    }

    @Test func readIsClampedToAvailable() {
        let ring = PCMRingBuffer(capacityFrames: 16, channels: 2)
        let src: [Int16] = [1, 2, 3, 4]
        _ = src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 2) }
        var out = [Int16](repeating: 0, count: 20)
        let r = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 10) }
        #expect(r == 2)
        #expect(Array(out.prefix(4)) == [1, 2, 3, 4])
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 10) } == 0)
    }

    @Test func skipAndSkipToCount() {
        let ring = PCMRingBuffer(capacityFrames: 16, channels: 1)
        let src: [Int16] = Array(0..<10)
        _ = src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 10) }
        #expect(ring.skip(frames: 3) == 3)
        #expect(ring.skip(toCount: 2) == 0) // already past
        #expect(ring.skip(toCount: 6) == 3)
        var out = [Int16](repeating: 0, count: 1)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 1) }
        #expect(out[0] == 6)
        #expect(ring.skip(toCount: 100) == 3) // clamped to written
        #expect(ring.availableToRead == 0)
    }

    @Test func discardAllEmptiesRing() {
        let ring = PCMRingBuffer(capacityFrames: 16, channels: 2)
        let src = [Int16](repeating: 1, count: 20)
        _ = src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 10) }
        #expect(ring.discardAll() == 10)
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == 16)
    }

    @Test func writableRegionsSplitAtWrap() {
        let ring = PCMRingBuffer(capacityFrames: 8, channels: 1)
        let six = [Int16](repeating: 0, count: 6)
        _ = six.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 6) }
        ring.skip(frames: 6)
        var regions: [(Int, Int)] = []
        let n = ring.withWritableRegions(maxFrames: 5) { dst, count, offset in
            regions.append((count, offset))
            for i in 0..<count { dst[i] = Int16(offset + i + 100) }
        }
        #expect(n == 5)
        #expect(regions.count == 2)
        #expect(regions[0].0 == 2 && regions[0].1 == 0)
        #expect(regions[1].0 == 3 && regions[1].1 == 2)
        var out = [Int16](repeating: 0, count: 5)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 5) }
        #expect(out == [100, 101, 102, 103, 104])
    }

    @Test func concurrentProducerConsumerDeliversEverySampleInOrder() async {
        let ring = SPSCRingBuffer<Int32>(capacityFrames: 512, channels: 1)
        let total = 400_000
        let producer = Thread {
            var v: Int32 = 0
            var chunk = [Int32](repeating: 0, count: 97)
            while Int(v) < total {
                let n = min(chunk.count, total - Int(v))
                for i in 0..<n { chunk[i] = v + Int32(i) }
                let w = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: n) }
                v += Int32(w)
                if w == 0 { usleep(50) }
            }
        }
        producer.start()
        var expected: Int32 = 0
        var ok = true
        var out = [Int32](repeating: 0, count: 61)
        let deadline = Date().addingTimeInterval(20)
        while Int(expected) < total, Date() < deadline {
            let r = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 61) }
            for i in 0..<r where out[i] != expected + Int32(i) { ok = false }
            expected += Int32(r)
            if r == 0 { usleep(20) }
        }
        #expect(ok)
        #expect(Int(expected) == total)
    }

    @Test func atomicsBasic() {
        let a = AtomicInt64(5)
        #expect(a.add(3) == 8)
        a.store(-2)
        #expect(a.load() == -2)
        #expect(a.compareAndSwap(expected: -2, desired: 9))
        #expect(!a.compareAndSwap(expected: -2, desired: 1))
        #expect(a.storeMax(4) == 9)
        #expect(a.storeMax(12) == 12)
        let b = AtomicBool(true)
        #expect(b.exchangeFalse())
        #expect(!b.exchangeFalse())
    }
}
