import Foundation

/// When to try a failed network speaker again, so a Wi-Fi blip heals by itself.
///
/// Each failed speaker gets its own backoff: the first retry `delays[0]` after it failed, then
/// `delays[1]` after that, and so on, repeating the last delay. A speaker that stops failing
/// (recovered, deselected, or playback stopped) is forgotten, so its next failure starts over.
/// `retrySoon` brings a speaker's next try forward (it reappeared on the network, or someone
/// pressed Refresh). Failures that waiting cannot fix (a wrong password, the same receiver
/// picked twice) are never retried. Pure; unit-tested.
public struct ReconnectSchedule: Sendable, Equatable {
    public var delays: [TimeInterval]

    private struct Track: Sendable, Equatable {
        var attempts: Int
        var nextAt: Date
    }

    private var tracks: [String: Track] = [:]

    public init(delays: [TimeInterval] = [2, 5, 10, 20, 30]) {
        self.delays = delays.isEmpty ? [30] : delays
    }

    /// Whether a failure message is worth retrying on a timer.
    public static func isTransient(_ message: String?) -> Bool {
        let s = (message ?? "").lowercased()
        let permanent = ["password", "authentication", "same physical device", "not a local output", "no output channels",
                         "refused access"]
        return !permanent.contains(where: { s.contains($0) })
    }

    /// Takes the speakers failing now (id → failure message) and returns the ones due a retry.
    public mutating func due(failing: [String: String?], at now: Date) -> [String] {
        for id in tracks.keys where failing[id] == nil { tracks[id] = nil }
        var due: [String] = []
        for (id, message) in failing where Self.isTransient(message) {
            guard let t = tracks[id] else {
                tracks[id] = Track(attempts: 0, nextAt: now.addingTimeInterval(delays[0]))
                continue
            }
            guard now >= t.nextAt else { continue }
            let attempts = t.attempts + 1
            tracks[id] = Track(attempts: attempts, nextAt: now.addingTimeInterval(delays[min(attempts, delays.count - 1)]))
            due.append(id)
        }
        return due.sorted()
    }

    /// The next `due` call retries `id` (if it is still failing).
    public mutating func retrySoon(_ id: String, at now: Date) {
        if var t = tracks[id] {
            t.nextAt = now
            tracks[id] = t
        } else {
            tracks[id] = Track(attempts: 0, nextAt: now)
        }
    }

    public mutating func reset() { tracks.removeAll() }

    /// How many timed retries `id` has had since it started failing.
    public func attempts(for id: String) -> Int { tracks[id]?.attempts ?? 0 }
}
