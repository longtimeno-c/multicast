import Foundation
import os

// Small concurrency helpers shared by the server and the client. No I/O.

/// A value behind an unfair lock. Bodies must be short and must never await or call out.
final class Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(uncheckedState: value) }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R { try lock.withLockUnchecked(body) }

    var value: Value { lock.withLockUnchecked { $0 } }
}

/// Errors of the link itself (as opposed to a refusal the hub sends on purpose).
public enum RemoteLinkError: Error, Equatable, Sendable, LocalizedError {
    /// The connection closed or failed.
    case closed(String)
    /// Nothing arrived in time.
    case timedOut(String)
    /// A frame announced more bytes than the receiver accepts. Nothing past the header was read.
    case frameTooLarge(length: Int, limit: Int)
    /// The bytes don't follow the protocol.
    case malformed(String)
    /// A peer failed to prove it holds the pairing key, or a sealed frame failed to open.
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .closed(let why): why
        case .timedOut(let what): "Timed out: \(what)"
        case .frameTooLarge(let length, let limit): "Frame of \(length) bytes exceeds the \(limit)-byte limit"
        case .malformed(let why): "Malformed message: \(why)"
        case .authenticationFailed(let why): why
        }
    }
}

private enum DeadlineOutcome<T: Sendable>: Sendable {
    case value(T)
    case expired
}

/// Runs `operation`, and if it hasn't finished after `seconds`, calls `onTimeout` (which must make
/// the operation return soon, e.g. by cancelling its connection) and throws `.timedOut`.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval, _ what: String,
    onTimeout: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return .expired
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        switch first {
        case .value(let v):
            return v
        case .expired:
            onTimeout()
            throw RemoteLinkError.timedOut(what)
        }
    }
}

/// A FIFO async mutex: callers run one at a time, in the order they asked.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Fans values out to any number of `AsyncStream` subscribers. With `replaysLatest`, a new
/// subscriber gets the latest value at once (nothing if none was published yet).
final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private struct Inner {
        var latest: Element?
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let inner = Locked(Inner())
    private let replaysLatest: Bool
    private let policy: AsyncStream<Element>.Continuation.BufferingPolicy
    /// Called (outside the lock) with the new subscriber count whenever it changes.
    var onSubscriberCountChange: (@Sendable (Int) -> Void)?

    init(replaysLatest: Bool, policy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(1)) {
        self.replaysLatest = replaysLatest
        self.policy = policy
    }

    var latest: Element? { inner.value.latest }
    var subscriberCount: Int { inner.value.subscribers.count }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: policy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            let count: Int? = self.inner.withLock {
                $0.subscribers.removeValue(forKey: id) == nil ? nil : $0.subscribers.count
            }
            if let count { self.onSubscriberCountChange?(count) }
        }
        let result: (finished: Bool, count: Int) = inner.withLock {
            if replaysLatest, let latest = $0.latest { continuation.yield(latest) }
            if !$0.finished { $0.subscribers[id] = continuation }
            return ($0.finished, $0.subscribers.count)
        }
        if result.finished {
            continuation.finish()
        } else {
            onSubscriberCountChange?(result.count)
        }
        return stream
    }

    func yield(_ value: Element) {
        inner.withLock {
            $0.latest = value
            for c in $0.subscribers.values { c.yield(value) }
        }
    }

    func finish() {
        let all: [AsyncStream<Element>.Continuation] = inner.withLock {
            $0.finished = true
            defer { $0.subscribers.removeAll() }
            return Array($0.subscribers.values)
        }
        for c in all { c.finish() }
    }
}

/// Exponential backoff with jitter for reconnect attempts.
struct Backoff: Sendable {
    var range: ClosedRange<TimeInterval>

    /// Delay before retry number `attempt` (1-based): doubles from the lower bound to the upper,
    /// then ±20 % jitter so many remotes don't retry in lockstep.
    func delay(attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 30)))
        let base = min(range.upperBound, range.lowerBound * pow(2, exponent))
        return max(range.lowerBound * 0.5, base * (1 + jitter))
    }
}

/// Identifiers chosen by a peer (remote ids, hub ids) end up as keychain accounts and log text:
/// keep them short and boring.
enum PeerText {
    static func isValidID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    /// A display name with control characters removed, trimmed and capped; `fallback` if empty.
    static func displayName(_ raw: String, fallback: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(64))
        return capped.isEmpty ? fallback : capped
    }
}
