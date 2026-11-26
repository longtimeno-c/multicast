import Foundation
import os

/// FIFO of async operations: each runs after the previous one has finished.
/// Used per sink (so flush → prepare → setVolume reach a device in order) and for transport
/// commands (so play/pause/stop never interleave).
final class SerialAsyncQueue: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLockUnchecked {
            let previous = tail
            let task = Task {
                await previous?.value
                await operation()
            }
            tail = task
            return task
        }
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await operation()) }
        }
    }

    func runThrowing<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do { continuation.resume(returning: try await operation()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Fires at most once.
final class OneShot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    /// Returns true if this call won.
    @discardableResult
    func fire(_ body: () -> Void) -> Bool {
        let won = lock.withLock { fired -> Bool in
            if fired { return false }
            fired = true
            return true
        }
        if won { body() }
        return won
    }
}

/// Runs `operation` in its own task and returns when it finishes or when `nanos` elapse,
/// whichever is first. On timeout the operation is cancelled but NOT awaited: a sink whose
/// `prepare` ignores cancellation and hangs cannot hold anybody up.
func withDeadline(nanos: UInt64, timeoutError: Error, _ operation: @escaping @Sendable () async throws -> Void) async throws {
    let gate = OneShot()
    let timerBox = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let work = Task {
            do {
                try await operation()
                gate.fire { continuation.resume() }
            } catch {
                gate.fire { continuation.resume(throwing: error) }
            }
            timerBox.withLockUnchecked { $0 }?.cancel()
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            if gate.fire({ continuation.resume(throwing: timeoutError) }) {
                work.cancel()
            }
        }
        timerBox.withLockUnchecked { $0 = timer }
    }
}

/// Waits for all tasks, but gives up after `nanos` (misbehaving sinks must not wedge transport).
/// Returns true if everything finished in time.
@discardableResult
func awaitAll(_ tasks: [Task<Void, Never>], timeoutNanos: UInt64) async -> Bool {
    guard !tasks.isEmpty else { return true }
    do {
        try await withDeadline(nanos: timeoutNanos, timeoutError: CancellationError()) {
            for t in tasks { await t.value }
        }
        return true
    } catch {
        return false
    }
}

/// Multi-subscriber AsyncStream fan-out, optionally replaying the latest value to new subscribers.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
    private var nextID: UInt64 = 0
    private var latest: Element?
    private var finished = false
    private let replayLatest: Bool
    private let bufferSize: Int

    init(replayLatest: Bool, bufferSize: Int) {
        self.replayLatest = replayLatest
        self.bufferSize = bufferSize
    }

    func makeStream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            let finishNow: Bool = lock.withLockUnchecked {
                if finished { return true }
                let id = nextID
                nextID += 1
                continuations[id] = continuation
                if replayLatest, let latest { continuation.yield(latest) }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLockUnchecked { _ = self.continuations.removeValue(forKey: id) }
                }
                return false
            }
            if finishNow { continuation.finish() }
        }
    }

    /// Yields under the lock so every subscriber sees values in the same order.
    func yield(_ value: Element) {
        lock.withLockUnchecked {
            latest = value
            for c in continuations.values { c.yield(value) }
        }
    }

    func finish() {
        let all: [AsyncStream<Element>.Continuation] = lock.withLockUnchecked {
            finished = true
            let all = Array(continuations.values)
            continuations.removeAll()
            return all
        }
        for c in all { c.finish() }
    }
}
