import Foundation
import MulticastHubModel

/// One entry in the hub's play queue. `id` is unique within the queue (the same song can be
/// queued twice); `source` says which app plays it (`.appleMusic`, `.spotify` or `.files`).
public struct PlayQueueEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var source: SourceKind
    public var track: TrackItem

    public init(id: String, source: SourceKind, track: TrackItem) {
        self.id = id
        self.source = source
        self.track = track
    }
}

/// Where queued items go.
public enum PlayQueuePlacement: String, Sendable, Equatable {
    /// Right after the current item ("Play Next").
    case next
    /// At the end ("Add to Queue").
    case last
}

/// The hub's play queue: played history, the current entry and what is up next. Pure value
/// type; the hub (`LocalHub`) drives the players from it.
///
/// Semantics:
///  - Playing a song from a context replaces Up Next with everything after it in that context
///    (`play(_:startingAt:)`); a shuffled playlist replaces it with the whole list shuffled.
///  - `insert(_:at:)` never interrupts what is playing.
///  - `advance()` moves the current entry to history and makes the first upcoming one current;
///    at the end of the queue there is no current entry and playback stops.
public struct PlayQueue: Equatable, Sendable {
    public private(set) var history: [PlayQueueEntry] = []
    public private(set) var current: PlayQueueEntry?
    public private(set) var upcoming: [PlayQueueEntry] = []
    /// Entries remembered for `goBack()`.
    public static let historyLimit = 200
    /// Largest Up Next the hub keeps (a whole library can be tens of thousands of songs).
    public static let upcomingLimit = 2000
    private var nextSerial = 1

    public init() {}

    public var isEmpty: Bool { current == nil && upcoming.isEmpty }

    private mutating func entries(_ tracks: [TrackItem], source: SourceKind) -> [PlayQueueEntry] {
        tracks.map { t in
            defer { nextSerial += 1 }
            return PlayQueueEntry(id: "q\(nextSerial)", source: source, track: t)
        }
    }

    /// Plays `tracks[index of startID]` now with everything after it as Up Next. Returns false
    /// (queue unchanged) when `startID` is not in `tracks`.
    @discardableResult
    public mutating func play(_ tracks: [TrackItem], source: SourceKind, startingAt startID: String) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == startID }) else { return false }
        let made = entries(Array(tracks[i...].prefix(Self.upcomingLimit + 1)), source: source)
        replace(with: made)
        return true
    }

    /// Plays a whole list from the top, in order or shuffled.
    public mutating func play<G: RandomNumberGenerator>(_ tracks: [TrackItem], source: SourceKind, shuffled: Bool,
                                                        using rng: inout G) {
        let ordered = shuffled ? tracks.shuffled(using: &rng) : tracks
        replace(with: entries(Array(ordered.prefix(Self.upcomingLimit + 1)), source: source))
    }

    private mutating func replace(with made: [PlayQueueEntry]) {
        if let current { pushHistory(current) }
        current = made.first
        upcoming = Array(made.dropFirst())
    }

    /// Queues tracks after the current item or at the end. Returns the new entries.
    @discardableResult
    public mutating func insert(_ tracks: [TrackItem], source: SourceKind, at placement: PlayQueuePlacement) -> [PlayQueueEntry] {
        let room = max(0, Self.upcomingLimit - upcoming.count)
        let made = entries(Array(tracks.prefix(room)), source: source)
        switch placement {
        case .next: upcoming.insert(contentsOf: made, at: 0)
        case .last: upcoming.append(contentsOf: made)
        }
        return made
    }

    /// Moves to the next entry. Returns it, or nil at the end of the queue (nothing current then).
    @discardableResult
    public mutating func advance() -> PlayQueueEntry? {
        if let current { pushHistory(current) }
        current = upcoming.isEmpty ? nil : upcoming.removeFirst()
        return current
    }

    /// Back to the previous entry (the current one goes back to the front of Up Next).
    @discardableResult
    public mutating func goBack() -> PlayQueueEntry? {
        guard let previous = history.popLast() else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = previous
        return previous
    }

    /// Jumps to an upcoming entry; the ones before it are dropped (as in Music's Up Next).
    @discardableResult
    public mutating func jump(to id: String) -> PlayQueueEntry? {
        guard let i = upcoming.firstIndex(where: { $0.id == id }) else { return nil }
        upcoming.removeFirst(i)
        return advance()
    }

    /// Removes upcoming entries (never the current one).
    public mutating func remove(ids: Set<String>) {
        upcoming.removeAll { ids.contains($0.id) }
    }

    /// Moves upcoming entries with SwiftUI's `onMove` meaning: `offset` is an index into the
    /// list before the move.
    public mutating func move(ids: [String], toOffset offset: Int) {
        let set = Set(ids)
        let moving = upcoming.filter { set.contains($0.id) }
        guard !moving.isEmpty else { return }
        let target = min(max(0, offset), upcoming.count)
        let before = upcoming[..<target].filter { set.contains($0.id) }.count
        upcoming.removeAll { set.contains($0.id) }
        upcoming.insert(contentsOf: moving, at: target - before)
    }

    /// Empties Up Next (the current entry keeps playing).
    public mutating func clearUpcoming() { upcoming.removeAll() }

    /// Forgets the current entry without advancing (an outside app took over).
    public mutating func dropCurrent() {
        if let current { pushHistory(current) }
        current = nil
    }

    private mutating func pushHistory(_ e: PlayQueueEntry) {
        history.append(e)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

// MARK: - Advance policy

/// What the owning app reports about the item the hub started.
public struct QueuePlayerObservation: Equatable, Sendable {
    public enum State: Equatable, Sendable { case playing, paused, stopped }
    public var state: State
    /// Music persistent id or Spotify URI; nil when the app has no current track.
    public var trackID: String?
    public var position: TimeInterval
    public var duration: TimeInterval?

    public init(state: State, trackID: String?, position: TimeInterval, duration: TimeInterval?) {
        self.state = state
        self.trackID = trackID
        self.position = position
        self.duration = duration
    }
}

/// Decides, from polled player state, when the current queue item has ended. Pure.
///
///  - Same track, stopped, or paused within `endTolerance` of its end → ended (Music plays a
///    queued track `once`; Spotify pauses at the end of a lone track).
///  - Another track (or none) after the start grace: ended if the last sample was near the
///    end (the app moved on by itself), otherwise someone played something in the app
///    directly → external takeover, and the hub queue is held.
///  - Same track playing → wait; the hub schedules the next start at the extrapolated end
///    (`remaining`) so there is no poll-interval gap.
public enum QueueAdvancePolicy {
    public enum Decision: Equatable, Sendable {
        case wait
        case ended
        case externalTakeover
    }

    public static let endTolerance: TimeInterval = 2
    /// How long after starting an item the app may still report the previous track.
    public static let startGrace: TimeInterval = 4

    public static func decide(expectedTrackID: String, observation o: QueuePlayerObservation,
                              lastPosition: TimeInterval?, lastDuration: TimeInterval?,
                              sinceStart: TimeInterval) -> Decision {
        if o.trackID == expectedTrackID {
            switch o.state {
            case .playing: return .wait
            case .stopped: return sinceStart < startGrace ? .wait : .ended
            case .paused:
                if let d = o.duration, d > 0, o.position >= d - endTolerance { return .ended }
                if let lp = lastPosition, let d = lastDuration ?? o.duration, d > 0, lp >= d - endTolerance,
                   o.position < 1 { return .ended }
                return .wait
            }
        }
        if sinceStart < startGrace { return .wait }
        if o.trackID == nil, o.state == .stopped { return .ended }
        if let lp = lastPosition, let d = lastDuration, d > 0, lp >= d - endTolerance { return .ended }
        return .externalTakeover
    }

    /// Seconds until the current item ends, from a sample, or nil when unknown.
    public static func remaining(position: TimeInterval, duration: TimeInterval?, sampledAt: Date,
                                 isPlaying: Bool, now: Date) -> TimeInterval? {
        guard let d = duration, d > 0 else { return nil }
        let p = position + (isPlaying ? max(0, now.timeIntervalSince(sampledAt)) : 0)
        return max(0, d - p)
    }
}

// MARK: - Spotify links

public enum SpotifyLink {
    /// `https://open.spotify.com/track/<id>?si=…`, `open.spotify.com/intl-xx/track/<id>` or
    /// `spotify:track:<id>` → `spotify:track:<id>`; nil for anything else.
    public static func trackURI(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ id: Substring) -> String? {
            guard (16...32).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return "spotify:track:\(id)"
        }
        if s.hasPrefix("spotify:track:") { return valid(s.dropFirst("spotify:track:".count)) }
        guard let url = URL(string: s.hasPrefix("http") ? s : "https://\(s)"), url.host == "open.spotify.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(of: "track"), i + 1 < parts.count else { return nil }
        return valid(Substring(parts[i + 1]))
    }
}
