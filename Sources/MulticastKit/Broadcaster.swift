import Foundation
import os

/// Holds a current value and fans changes out to any number of `AsyncStream`s.
/// Each new stream gets the current value first. Only the newest value is buffered per
/// subscriber, so a slow UI never builds up a backlog. Never used on real-time threads.
final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var value: Value
        var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]
        var finished = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ initial: Value) {
        state = OSAllocatedUnfairLock(initialState: State(value: initial))
    }

    var current: Value { state.withLock { $0.value } }

    func send(_ value: Value) {
        let subs: [AsyncStream<Value>.Continuation] = state.withLock {
            $0.value = value
            return Array($0.subscribers.values)
        }
        for c in subs { c.yield(value) }
    }

    /// Mutates the value in place and publishes the result.
    func update(_ body: (inout Value) -> Void) {
        let (value, subs): (Value, [AsyncStream<Value>.Continuation]) = state.withLock {
            body(&$0.value)
            return ($0.value, Array($0.subscribers.values))
        }
        for c in subs { c.yield(value) }
    }

    func makeStream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let (value, finished): (Value, Bool) = state.withLock {
                if !$0.finished { $0.subscribers[id] = continuation }
                return ($0.value, $0.finished)
            }
            continuation.yield(value)
            if finished { continuation.finish(); return }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func finish() {
        let subs: [AsyncStream<Value>.Continuation] = state.withLock {
            $0.finished = true
            defer { $0.subscribers.removeAll() }
            return Array($0.subscribers.values)
        }
        for c in subs { c.finish() }
    }
}
