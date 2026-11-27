import Foundation
import os

/// The last few seconds a microphone heard, addressable by time.
///
/// The audio device hands over buffers with the host time of each buffer's first sample; a
/// calibration asks afterwards for "what was heard from T for one second". Samples are kept in
/// a ring, and each buffer leaves a time mark, so a request is answered from the mark just
/// before it (the device's clock and the host's drift apart only by microseconds within one
/// buffer's reach).
///
/// `append` is called on the device's IO thread; it takes a lock that is only ever held for a
/// copy, which is fine for a measurement that runs for some seconds with nothing else to starve.
public final class RecordingRing: @unchecked Sendable {
    public let sampleRate: Double
    private let capacity: Int

    private struct Mark {
        var frame: Int
        var hostNanos: UInt64
    }

    private struct State {
        var samples: [Float]
        /// Frames appended so far; frame `f` lives at `f % capacity`.
        var written = 0
        var marks: [Mark] = []
        var nextMark = 0
    }

    private static let markCapacity = 4096
    private let state: OSAllocatedUnfairLock<State>

    public init(sampleRate: Double, seconds: Double) {
        self.sampleRate = sampleRate
        capacity = max(1, Int(sampleRate * seconds))
        state = OSAllocatedUnfairLock(initialState: State(samples: [Float](repeating: 0, count: max(1, Int(sampleRate * seconds)))))
    }

    /// Adds one buffer. `base[i * stride]` is frame `i` (so one channel can be taken out of
    /// interleaved audio); `hostNanos` is when frame 0 was heard.
    public func append(_ base: UnsafePointer<Float>, frames: Int, stride: Int = 1, hostNanos: UInt64) {
        guard frames > 0 else { return }
        let capacity = capacity
        state.withLockUnchecked { s in
            let mark = Mark(frame: s.written, hostNanos: hostNanos)
            if s.marks.count < Self.markCapacity { s.marks.append(mark) } else { s.marks[s.nextMark] = mark }
            s.nextMark = (s.nextMark + 1) % Self.markCapacity
            var at = s.written % capacity
            s.samples.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames {
                    out[at] = base[i * stride]
                    at += 1
                    if at == capacity { at = 0 }
                }
            }
            s.written += frames
        }
    }

    public func append(_ samples: [Float], hostNanos: UInt64) {
        samples.withUnsafeBufferPointer { append($0.baseAddress!, frames: samples.count, hostNanos: hostNanos) }
    }

    /// `seconds` of what was heard from `fromHostNanos` on, with the exact time of the first
    /// sample returned (at or just after the time asked for). nil when that stretch hasn't all
    /// been recorded yet, or has already been overwritten.
    public func recording(fromHostNanos: UInt64, seconds: Double) -> (samples: [Float], startHostNanos: UInt64)? {
        let count = Int(seconds * sampleRate)
        guard count > 0, count <= capacity else { return nil }
        let capacity = capacity, rate = sampleRate
        return state.withLockUnchecked { s in
            // The latest mark at or before the start; failing that, the earliest there is.
            var before: Mark?, earliest: Mark?
            for m in s.marks {
                if m.hostNanos <= fromHostNanos, before == nil || m.hostNanos > before!.hostNanos { before = m }
                if earliest == nil || m.hostNanos < earliest!.hostNanos { earliest = m }
            }
            guard let mark = before ?? earliest else { return nil }
            let offsetNanos = Double(fromHostNanos) - Double(mark.hostNanos)
            let first = mark.frame + Int((offsetNanos * rate / 1e9).rounded(.up))
            guard first >= 0, first >= s.written - capacity, first + count <= s.written else { return nil }
            var out = [Float](repeating: 0, count: count)
            var at = first % capacity
            for i in 0..<count {
                out[i] = s.samples[at]
                at += 1
                if at == capacity { at = 0 }
            }
            let start = Double(mark.hostNanos) + Double(first - mark.frame) * 1e9 / rate
            return (out, UInt64(max(0, start.rounded())))
        }
    }

    func tail(_ count: Int, step: Int) -> [Float] {
        let capacity = capacity
        return state.withLockUnchecked { s in
            let available = min(s.written, capacity, count * step)
            var out: [Float] = []
            out.reserveCapacity(available / step + 1)
            var frame = s.written - available
            while frame < s.written {
                out.append(s.samples[frame % capacity])
                frame += step
            }
            return out
        }
    }
}
