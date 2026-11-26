import Foundation
import os

/// FIFO of async operations: each starts after the previous one has finished (control paths only).
final class AsyncFIFO: @unchecked Sendable {
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

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        await enqueue(operation).value
    }

    func runThrowing(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let box = OSAllocatedUnfairLock<Error?>(initialState: nil)
        await enqueue {
            do { try await operation() } catch { box.withLock { $0 = error } }
        }.value
        if let error = box.withLock({ $0 }) { throw error }
    }
}
