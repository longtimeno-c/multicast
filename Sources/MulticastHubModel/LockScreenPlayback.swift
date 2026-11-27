import Foundation

/// What a device's system media controls (the lock screen, Control Centre, headphone buttons)
/// should show and accept for the hub's current item: a plain mapping from `HubState`, so the
/// platform layer only copies fields across.
///
/// Nil when the hub has nothing playing or paused: the controls should then be cleared.
public struct LockScreenPlayback: Equatable, Hashable, Sendable {
    public var title: String
    /// Nil when the hub has none (an empty string is not shown as a blank line).
    public var artist: String?
    public var album: String?
    public var artworkID: ArtworkID?
    /// What makes this a different item rather than an update to the same one.
    public var identity: String
    /// Seconds; nil for a source without a length (a captured app, the Mac output).
    public var duration: TimeInterval?
    /// Seconds into the item at `asOf`; nil when there is no position to show.
    public var elapsed: TimeInterval?
    /// The moment `elapsed` describes. The system advances it by `rate` from there.
    public var asOf: Date
    /// 1 while playing, 0 while paused.
    public var rate: Double
    public var commands: Commands

    /// Which controls are live. A disabled one is greyed out by the system.
    public struct Commands: Equatable, Hashable, Sendable {
        public var playPause: Bool
        public var next: Bool
        public var previous: Bool
        public var seek: Bool

        public init(playPause: Bool = false, next: Bool = false, previous: Bool = false, seek: Bool = false) {
            self.playPause = playPause
            self.next = next
            self.previous = previous
            self.seek = seek
        }

        public static let none = Commands()
    }

    /// What the system controls can ask for.
    public enum Action: Equatable, Hashable, Sendable {
        case play, pause, togglePlayPause, next, previous
        case seek(position: TimeInterval)
    }

    public var isPlaying: Bool { rate > 0 }
    /// No length: shown as live, without a progress bar.
    public var isLive: Bool { duration == nil }

    public init?(nowPlaying: NowPlayingInfo?, transport: TransportState, source: SourceKind?, at date: Date) {
        guard let nowPlaying, let source else { return nil }
        title = nowPlaying.title
        artist = nowPlaying.artist.isEmpty ? nil : nowPlaying.artist
        album = nowPlaying.album.flatMap { $0.isEmpty ? nil : $0 }
        artworkID = nowPlaying.artworkID
        identity = nowPlaying.identity
        asOf = date
        rate = transport.isPlaying ? 1 : 0

        let length = nowPlaying.duration.flatMap { $0 > 0 ? $0 : nil }
        if source.hasPosition, let length {
            duration = length
            elapsed = min(max(0, transport.position(at: date)), length)
        } else {
            duration = nil
            elapsed = nil
        }
        commands = Commands(playPause: true,
                            next: source.canSkip && transport.canSkip,
                            previous: source.canSkip && transport.canSkip,
                            seek: duration != nil && transport.canSeek)
    }

    public init?(state: HubState, at date: Date) {
        self.init(nowPlaying: state.nowPlaying, transport: state.transport, source: state.activeSource, at: date)
    }

    /// Where the item is at `date`, as the system extrapolates it.
    public func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsed, let duration else { return nil }
        return min(max(0, elapsed + rate * date.timeIntervalSince(asOf)), duration)
    }

    /// True when `earlier`, left alone, already shows what this says: the same item, state and
    /// controls, with the position where the system's own clock has carried it (within
    /// `tolerance` seconds). Publishing again would change nothing.
    public func continues(_ earlier: LockScreenPlayback, tolerance: TimeInterval = 0.75) -> Bool {
        var a = self, b = earlier
        a.elapsed = nil; b.elapsed = nil
        a.asOf = .distantPast; b.asOf = .distantPast
        guard a == b else { return false }
        switch (elapsed, earlier.elapsed(at: asOf)) {
        case (nil, nil): return true
        case (let now?, let carried?): return abs(now - carried) <= tolerance
        default: return false
        }
    }

    /// The hub command for something the system controls asked, or nil when it is already so,
    /// not possible right now, or its control is off (Play while playing, Next on a captured app).
    public func command(for action: Action) -> HubCommand? {
        switch action {
        case .play: return commands.playPause && !isPlaying ? .play : nil
        case .pause: return commands.playPause && isPlaying ? .pause : nil
        case .togglePlayPause:
            guard commands.playPause else { return nil }
            return isPlaying ? .pause : .play
        case .next: return commands.next ? .next : nil
        case .previous: return commands.previous ? .previous : nil
        case .seek(let position):
            guard commands.seek, let duration, position.isFinite else { return nil }
            return .seek(position: min(max(0, position), duration))
        }
    }
}
