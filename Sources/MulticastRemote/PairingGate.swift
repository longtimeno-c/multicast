import Foundation

/// How hard the hub makes repeated pairing attempts.
public struct PairingPolicy: Sendable, Equatable {
    /// Failed (or abandoned) attempts in a row before pairing locks.
    public var failuresBeforeLockout: Int
    /// The first lockout; each further lockout doubles it, up to `maxLockout`.
    public var lockout: TimeInterval
    public var maxLockout: TimeInterval

    public init(failuresBeforeLockout: Int = 3, lockout: TimeInterval = 60, maxLockout: TimeInterval = 3600) {
        self.failuresBeforeLockout = max(1, failuresBeforeLockout)
        self.lockout = lockout
        self.maxLockout = maxLockout
    }
}

/// The hub's pairing admission: one attempt at a time, and a growing lockout after repeated
/// failures. Remote ids are chosen by the remote, so the count is global, not per remote.
/// Pure: the caller passes the time.
struct PairingGate {
    enum Refusal: Error, Equatable {
        case busy
        case locked(retryAfter: TimeInterval)
    }

    let policy: PairingPolicy
    private(set) var active: UUID?
    private(set) var failuresInARow = 0
    private(set) var lockouts = 0
    private(set) var lockedUntil: Date?

    init(policy: PairingPolicy) { self.policy = policy }

    mutating func begin(now: Date) -> Result<UUID, Refusal> {
        if let until = lockedUntil, now < until { return .failure(.locked(retryAfter: until.timeIntervalSince(now))) }
        guard active == nil else { return .failure(.busy) }
        let id = UUID()
        active = id
        return .success(id)
    }

    /// Ends attempt `id`. Anything but success counts as a failure (a wrong code, a timeout, a
    /// remote that walked away), so nobody can pop pairing prompts on the Mac forever.
    mutating func end(_ id: UUID, succeeded: Bool, now: Date) {
        guard active == id else { return }
        active = nil
        if succeeded {
            failuresInARow = 0
            lockouts = 0
            lockedUntil = nil
            return
        }
        failuresInARow += 1
        if failuresInARow >= policy.failuresBeforeLockout {
            failuresInARow = 0
            lockouts += 1
            let duration = min(policy.maxLockout, policy.lockout * pow(2, Double(min(lockouts - 1, 30))))
            lockedUntil = now.addingTimeInterval(duration)
        }
    }

    /// Ends attempt `id` without counting it (the person on the Mac cancelled it).
    mutating func cancel(_ id: UUID) {
        if active == id { active = nil }
    }
}
