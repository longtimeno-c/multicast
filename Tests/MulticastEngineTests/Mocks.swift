import Foundation
import MulticastAudio
import os
@testable import MulticastEngine

/// Sample pattern that encodes the source position, so tests can check continuity of content
/// (not just of frame stamps). Left = pos % 32768, right = (pos / 32768) % 32768.
enum Pattern {
    static func left(_ pos: UInt64) -> Int16 { Int16(pos % 32768) }
    static func right(_ pos: UInt64) -> Int16 { Int16((pos / 32768) % 32768) }
    static func position(left: Int16, right: Int16) -> UInt64 { UInt64(right) * 32768 + UInt64(left) }
}

final class MockSource: AudioSource, @unchecked Sendable {
    let displayName: String
    let isLive: Bool
    /// nil = infinite.
    let totalFrames: UInt64?
    /// If set, every read returns at most this many frames (to exercise silence padding).
    let maxFramesPerRead: Int?
    /// If set, every sample is this constant instead of the position pattern.
    let constant: Int16?
    /// Added to positions so two sources produce distinguishable content.
    let positionBase: UInt64

    private let lock = OSAllocatedUnfairLock()
    private var position: UInt64 = 0
    private var reads: UInt64 = 0
    private var starts = 0
    private var stops = 0

    init(name: String = "mock", isLive: Bool = false, totalFrames: UInt64? = nil, maxFramesPerRead: Int? = nil,
         constant: Int16? = nil, positionBase: UInt64 = 0) {
        displayName = name
        self.isLive = isLive
        self.totalFrames = totalFrames
        self.maxFramesPerRead = maxFramesPerRead
        self.constant = constant
        self.positionBase = positionBase
    }

    func start() async throws { lock.withLockUnchecked { starts += 1 } }
    func stop() async { lock.withLockUnchecked { stops += 1 } }

    var readCount: UInt64 { lock.withLockUnchecked { reads } }
    var startCount: Int { lock.withLockUnchecked { starts } }
    var stopCount: Int { lock.withLockUnchecked { stops } }

    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        lock.withLockUnchecked {
            reads += 1
            var n = frameCount
            if let m = maxFramesPerRead { n = min(n, m) }
            if let total = totalFrames {
                if position >= total { return nil }
                n = min(n, Int(total - position))
            }
            for i in 0..<n {
                let p = positionBase + position + UInt64(i)
                buffer[2 * i] = constant ?? Pattern.left(p)
                buffer[2 * i + 1] = constant ?? Pattern.right(p)
            }
            position += UInt64(n)
            return n
        }
    }
}

final class MockSink: AudioSink, @unchecked Sendable {
    enum Call: Equatable {
        case prepare(StreamTimeline)
        case flush
        case stop
        case volume(Float)
        case offset(Int)
    }

    enum PrepareBehavior {
        case succeed(delayNanos: UInt64)
        case hang
        case fail(String)
    }

    struct Received {
        var frame: UInt64
        var hostNanos: UInt64
        var samples: Data
    }

    let id: String
    let displayName: String

    private let lock = OSAllocatedUnfairLock()
    private var _calls: [Call] = []
    private var _received: [Received] = []
    private var _firstEnqueueCallIndex: Int?
    private var _behavior: PrepareBehavior
    private var hung: [CheckedContinuation<Void, Never>] = []
    private var stateContinuations: [AsyncStream<SinkState>.Continuation] = []
    private var state: SinkState = .idle
    private var prepared = false

    init(id: String, behavior: PrepareBehavior = .succeed(delayNanos: 0)) {
        self.id = id
        displayName = "Sink \(id)"
        _behavior = behavior
        _received.reserveCapacity(4096)
    }

    var behavior: PrepareBehavior {
        get { lock.withLockUnchecked { _behavior } }
        set { lock.withLockUnchecked { _behavior = newValue } }
    }

    var calls: [Call] { lock.withLockUnchecked { _calls } }
    var received: [Received] { lock.withLockUnchecked { _received } }
    var receivedCount: Int { lock.withLockUnchecked { _received.count } }
    var firstEnqueueCallIndex: Int? { lock.withLockUnchecked { _firstEnqueueCallIndex } }
    var volumes: [Float] { calls.compactMap { if case .volume(let v) = $0 { return v } else { return nil } } }
    var prepares: [StreamTimeline] { calls.compactMap { if case .prepare(let t) = $0 { return t } else { return nil } } }

    private func record(_ c: Call) { lock.withLockUnchecked { _calls.append(c) } }

    func report(_ s: SinkState) {
        let cs: [AsyncStream<SinkState>.Continuation] = lock.withLockUnchecked {
            state = s
            return stateContinuations
        }
        for c in cs { c.yield(s) }
    }

    func releaseHangs() {
        let hs: [CheckedContinuation<Void, Never>] = lock.withLockUnchecked {
            let h = hung
            hung = []
            return h
        }
        for h in hs { h.resume() }
    }

    func prepare(timeline: StreamTimeline) async throws {
        record(.prepare(timeline))
        report(.connecting)
        switch behavior {
        case .succeed(let delay):
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            lock.withLockUnchecked { prepared = true }
            report(.playing)
        case .hang:
            // Ignores cancellation on purpose: a badly behaved device.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLockUnchecked { hung.append(c) }
            }
        case .fail(let msg):
            report(.failed(msg))
            throw NSError(domain: "MockSink", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func enqueue(_ packet: AudioPacket) {
        let now = HostClock.nowNanos()
        lock.withLockUnchecked {
            if _firstEnqueueCallIndex == nil { _firstEnqueueCallIndex = _calls.count }
            _received.append(Received(frame: packet.firstFrame, hostNanos: now, samples: packet.samples))
        }
    }

    func setVolume(_ volume: Float) async { record(.volume(volume)) }
    func setOffset(millis: Int) async { record(.offset(millis)) }
    func flush() async { record(.flush) }
    func stop() async {
        record(.stop)
        lock.withLockUnchecked { prepared = false }
        report(.idle)
    }

    var stateUpdates: AsyncStream<SinkState> {
        AsyncStream { c in
            let current: SinkState = lock.withLockUnchecked {
                stateContinuations.append(c)
                return state
            }
            c.yield(current)
        }
    }
}

// MARK: - Helpers

func sleepMillis(_ ms: UInt64) async {
    try? await Task.sleep(nanoseconds: ms * 1_000_000)
}

/// Polls until `condition` is true or the timeout elapses; returns the final value.
@discardableResult
func waitUntil(timeoutMillis: UInt64 = 3000, _ condition: () -> Bool) async -> Bool {
    let deadline = HostClock.nowNanos() + timeoutMillis * 1_000_000
    while HostClock.nowNanos() < deadline {
        if condition() { return true }
        await sleepMillis(2)
    }
    return condition()
}

func firstSamplePosition(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        return Pattern.position(left: s[0], right: s[1])
    }
}

func testConfiguration(latencyMillis: UInt64 = 300) -> MulticastEngine.Configuration {
    var c = MulticastEngine.Configuration()
    c.latencyNanos = latencyMillis * 1_000_000
    c.prepareTimeoutNanos = 500_000_000
    c.minDeliveryLeadNanos = 50_000_000
    c.volumeCoalesceNanos = 100_000_000
    c.defaultSinkVolume = 0.15
    return c
}

extension Array where Element == MockSink.Received {
    /// True if frames are strictly consecutive packets (no gaps, no duplicates).
    var isContiguous: Bool {
        guard count > 1 else { return true }
        for i in 1..<count where self[i].frame != self[i - 1].frame + UInt64(PCM.framesPerPacket) {
            return false
        }
        return true
    }
}
