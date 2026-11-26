import Foundation

/// Hands one value stream to any number of subscribers: each gets the latest value at once,
/// then every published change. Tells its owner when the first subscriber arrives and the
/// last one leaves, so polling runs only while someone listens.
final class SnapshotFanout<Value: Sendable & Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var latest: Value?
    private let onActive: @Sendable (Bool) -> Void

    init(onActive: @escaping @Sendable (Bool) -> Void) {
        self.onActive = onActive
    }

    var current: Value? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            let token = UUID()
            lock.lock()
            continuations[token] = c
            let first = continuations.count == 1
            let value = latest
            lock.unlock()
            if let value { c.yield(value) }
            c.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[token] = nil
                let last = self.continuations.isEmpty
                self.lock.unlock()
                if last { self.onActive(false) }
            }
            if first { onActive(true) }
        }
    }

    /// Stores `value` and sends it to every subscriber (no de-duplication: callers decide
    /// what counts as a change).
    func publish(_ value: Value) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets { c.yield(value) }
    }

    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations = [:]
        lock.unlock()
        for c in targets { c.finish() }
    }
}
