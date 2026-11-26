import Foundation

/// Counters a backend bumps whenever a paged list changes, so clients know which pages to
/// fetch again. They live in `HubState` instead of the lists themselves.
public struct ContentRevisions: Equatable, Hashable, Sendable, Codable {
    /// Songs, playlists, playlist contents and search results (the Apple Music library).
    public var library: UInt64
    /// The hub's play queue (Up Next).
    public var upNext: UInt64
    /// The file queue.
    public var files: UInt64
    /// Tracks seen from Spotify this session.
    public var spotifyHistory: UInt64

    public init(library: UInt64 = 0, upNext: UInt64 = 0, files: UInt64 = 0, spotifyHistory: UInt64 = 0) {
        self.library = library
        self.upNext = upNext
        self.files = files
        self.spotifyHistory = spotifyHistory
    }
}

/// Everything a hub UI shows that is not a list: small enough to send whole on every change
/// (a few kilobytes with a dozen speakers), cheap to compare. No image bytes (artwork travels
/// by id) and no library or file lists (they are paged queries; `content` says when to refetch).
/// Levels stream separately (`HubBackend.levels()`) so a meter never resends the rest.
public struct HubState: Equatable, Hashable, Sendable, Codable {
    /// Increases by at least one with every published change. Lets a network client drop an
    /// out-of-order state and spot a gap.
    public var revision: UInt64

    // Speakers
    public var speakers: [SpeakerItem]
    /// 0…1. A speaker plays at its own volume × the master.
    public var masterVolume: Double
    /// Discovery is still browsing and may add speakers.
    public var isDiscovering: Bool

    // Playback
    /// The source audio currently comes from, if any.
    public var activeSource: SourceKind?
    public var nowPlaying: NowPlayingInfo?
    public var transport: TransportState

    // Sources
    public var capture: CaptureStatus
    public var spotify: SpotifyStatus
    public var content: ContentRevisions
    /// The play queue (Up Next itself is `HubQuery.upNext`).
    public var queue: QueueStatus
    /// Pinned playlists, in pin order.
    public var pins: [PinnedPlaylist]

    // Permissions and problems
    public var health: HubHealth

    public init(revision: UInt64 = 0, speakers: [SpeakerItem] = [], masterVolume: Double = 0.6,
                isDiscovering: Bool = false, activeSource: SourceKind? = nil, nowPlaying: NowPlayingInfo? = nil,
                transport: TransportState = TransportState(), capture: CaptureStatus = CaptureStatus(),
                spotify: SpotifyStatus = .notRunning, content: ContentRevisions = ContentRevisions(),
                queue: QueueStatus = QueueStatus(), pins: [PinnedPlaylist] = [],
                health: HubHealth = HubHealth()) {
        self.revision = revision
        self.speakers = speakers
        self.masterVolume = masterVolume
        self.isDiscovering = isDiscovering
        self.activeSource = activeSource
        self.nowPlaying = nowPlaying
        self.transport = transport
        self.capture = capture
        self.spotify = spotify
        self.content = content
        self.queue = queue
        self.pins = pins
        self.health = health
    }

    public func speaker(_ id: SpeakerID) -> SpeakerItem? { speakers.first { $0.id == id } }

    /// True when everything but `revision` is equal: whether a publish is worth sending.
    public func hasSameContent(as other: HubState) -> Bool {
        var a = self, b = other
        a.revision = 0; b.revision = 0
        return a == b
    }
}
