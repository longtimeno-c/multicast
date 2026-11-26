import Foundation

// MARK: - Play queue

/// One entry in the hub's play queue. `id` is unique within the queue (the same song may be
/// queued twice) and is what `removeFromQueue`, `moveInQueue` and `playTrack(…, .upNext)` name.
/// `source` says which app plays it: `.appleMusic` (the Music app), `.spotify` (the Spotify
/// app) or `.files`.
///
/// Wire form (synthesized): `{"id":"q7","source":"spotify","track":{…}}`.
public struct QueueItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public var source: SourceKind
    public var track: TrackItem

    public init(id: String, source: SourceKind, track: TrackItem) {
        self.id = id
        self.source = source
        self.track = track
    }
}

/// Where queued songs go.
public enum QueuePlacement: String, Equatable, Hashable, Sendable, Codable {
    /// Right after the current song ("Play Next").
    case next
    /// At the end of Up Next ("Add to Queue").
    case last
}

/// The queue, as `HubState` carries it: small. Up Next itself is the paged `HubQuery.upNext`.
public struct QueueStatus: Equatable, Hashable, Sendable, Codable {
    /// The queue entry playing (or paused), nil when the hub's queue isn't playing anything.
    public var currentID: String?
    /// Which app plays the current entry.
    public var currentSource: SourceKind?
    /// Songs in Up Next.
    public var upcomingCount: Int
    /// Someone played something directly in Music or Spotify: the hub follows that app and the
    /// queue waits. Next, or choosing a song in Up Next, carries on with the queue.
    public var isHeld: Bool
    /// Up Next plays in a random order (`HubCommand.setShuffle`).
    public var isShuffled: Bool

    public init(currentID: String? = nil, currentSource: SourceKind? = nil, upcomingCount: Int = 0, isHeld: Bool = false,
                isShuffled: Bool = false) {
        self.currentID = currentID
        self.currentSource = currentSource
        self.upcomingCount = upcomingCount
        self.isHeld = isHeld
        self.isShuffled = isShuffled
    }
}

// MARK: - Pinned playlists

/// A playlist pinned to the top of the library for one-tap play. Apple Music playlists pin by
/// their library id; Spotify playlists pin from a share link (`id` is then
/// `spotify:playlist:<id>`, and Spotify plays it: the hub can't list its songs without a
/// Spotify Client ID). `HubCommand.playPlaylist(id:shuffled:)` plays either kind.
public struct PinnedPlaylist: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public var source: SourceKind
    public var name: String
    public var artworkID: ArtworkID?
    /// Known for Apple Music playlists only.
    public var trackCount: Int?

    public init(id: String, source: SourceKind, name: String, artworkID: ArtworkID? = nil, trackCount: Int? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.artworkID = artworkID
        self.trackCount = trackCount
    }

    public static let limit = 24
}
