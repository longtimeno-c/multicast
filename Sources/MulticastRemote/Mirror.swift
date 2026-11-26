import Foundation
import MulticastHubModel

// Pure client-side bookkeeping for RemoteHubBackend: no I/O.

/// Commands waiting to be sent, in order. A command that arrives at drag rate replaces the
/// newest unsent command with the same `coalescingKey` (only when that one is the last in line,
/// so order across different commands never changes); its waiters then share the outcome.
struct CommandQueue<Waiter> {
    struct Entry {
        var command: HubCommand
        var waiters: [Waiter]
    }

    private(set) var entries: [Entry] = []

    mutating func enqueue(_ command: HubCommand, _ waiter: Waiter) {
        if let key = command.coalescingKey, let last = entries.indices.last,
           entries[last].command.coalescingKey == key {
            entries[last].command = command
            entries[last].waiters.append(waiter)
        } else {
            entries.append(Entry(command: command, waiters: [waiter]))
        }
    }

    mutating func popFirst() -> Entry? { entries.isEmpty ? nil : entries.removeFirst() }

    mutating func drain() -> [Entry] {
        defer { entries.removeAll() }
        return entries
    }
}

/// Keeps `HubState.content` counters moving forward across sessions. The hub may restart (its
/// counters start again) and changes may be missed while disconnected, so the first state of
/// every session lands one past anything published before, which makes clients refetch every
/// list; within a session, counters move exactly as the hub's do.
struct ContentRebaser {
    private var lastEmitted = ContentRevisions()
    private var offsets: ContentRevisions?

    mutating func beginSession() { offsets = nil }

    mutating func map(_ hub: ContentRevisions) -> ContentRevisions {
        if offsets == nil {
            offsets = ContentRevisions(
                library: lastEmitted.library &+ 1 &- hub.library,
                upNext: lastEmitted.upNext &+ 1 &- hub.upNext,
                files: lastEmitted.files &+ 1 &- hub.files,
                spotifyHistory: lastEmitted.spotifyHistory &+ 1 &- hub.spotifyHistory)
        }
        let o = offsets!
        let out = ContentRevisions(library: hub.library &+ o.library, upNext: hub.upNext &+ o.upNext,
                                   files: hub.files &+ o.files, spotifyHistory: hub.spotifyHistory &+ o.spotifyHistory)
        lastEmitted = out
        return out
    }
}

/// Estimates the hub's clock offset from request/response pairs (NTP-style, keeping the sample
/// with the smallest round trip among the recent ones), to re-base `positionAsOf`.
struct ClockSync {
    private var samples: [(rtt: TimeInterval, offset: TimeInterval)] = []
    static let keep = 8

    /// `sent`/`received` on our clock around a reply stamped `hubTime` on the hub's.
    mutating func add(sent: Date, received: Date, hubTime: Date) {
        let rtt = received.timeIntervalSince(sent)
        guard rtt >= 0 else { return }
        let offset = hubTime.timeIntervalSince(sent.addingTimeInterval(rtt / 2))
        samples.append((rtt, offset))
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
    }

    /// Hub clock minus ours, in seconds; 0 before any sample.
    var offset: TimeInterval { samples.min { $0.rtt < $1.rtt }?.offset ?? 0 }

    func toLocal(_ hubDate: Date) -> Date { hubDate.addingTimeInterval(-offset) }
}

/// The remote's copy of the hub's state, re-based for this device: its own revision sequence
/// (monotonic across reconnects and hub restarts), content counters via `ContentRebaser`, and
/// `positionAsOf` on the local clock. Out-of-order or unchanged states produce nothing.
struct StateMirror {
    private(set) var latest: HubState?
    private var revision: UInt64 = 0
    private var rebaser = ContentRebaser()
    private var lastHubRevision: UInt64?
    var clock = ClockSync()

    mutating func beginSession() {
        rebaser.beginSession()
        lastHubRevision = nil
        clock = ClockSync()
    }

    mutating func apply(_ incoming: HubState) -> HubState? {
        if let last = lastHubRevision, incoming.revision <= last { return nil }
        lastHubRevision = incoming.revision
        var s = incoming
        s.content = rebaser.map(incoming.content)
        if s.transport.positionAsOf != .distantPast {
            s.transport.positionAsOf = clock.toLocal(s.transport.positionAsOf)
        }
        if let latest, latest.hasSameContent(as: s) { return nil }
        revision += 1
        s.revision = revision
        latest = s
        return s
    }
}
