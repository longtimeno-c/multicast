import Foundation
import MulticastAudio
import MulticastHubModel

/// What the Apple Music player reports to the hub: now playing, transport and when its lists
/// changed. Published by `MusicPlayerProviding.statusUpdates()`.
public struct MusicPlayerStatus: Equatable, Sendable {
    public var nowPlaying: NowPlayingInfo?
    public var isPlaying: Bool
    /// Seconds into the item at `positionAsOf`, as PRODUCED by the player (the hub adds the
    /// speakers' group latency itself when it shows the audible position).
    public var position: TimeInterval
    public var positionAsOf: Date
    public var canSkip: Bool
    public var canSeek: Bool
    /// Bump when songs, playlists, playlist contents or search results change.
    public var libraryRevision: UInt64
    /// Bump when the up-next queue changes.
    public var upNextRevision: UInt64

    public init(nowPlaying: NowPlayingInfo? = nil, isPlaying: Bool = false, position: TimeInterval = 0,
                positionAsOf: Date = .distantPast, canSkip: Bool = true, canSeek: Bool = true,
                libraryRevision: UInt64 = 0, upNextRevision: UInt64 = 0) {
        self.nowPlaying = nowPlaying
        self.isPlaying = isPlaying
        self.position = position
        self.positionAsOf = positionAsOf
        self.canSkip = canSkip
        self.canSeek = canSeek
        self.libraryRevision = libraryRevision
        self.upNextRevision = upNextRevision
    }
}

/// The hub's Apple Music player, as `LocalHub` needs it. Implemented in MulticastAppleMusic and
/// injected with `LocalHub.setMusicPlayer(_:)`; until one is injected the Apple Music source
/// answers "not available yet".
///
/// Contract:
///  - Lists use the HubModel paged types; throw `HubCommandError(.permissionMissing, …)` when the
///    library cannot be read.
///  - Artwork ids are the provider's own; the hub passes any id it did not mint (its own start
///    with "hub.") to `artwork(id:maxPixel:)`.
///  - `makeAudioSource()` is called once each time Apple Music becomes the active source; the
///    hub sets it on the engine and keeps it until another source is chosen. The player renders
///    whatever it plays into that source; play/pause/skip/seek go through the methods below and
///    the hub flushes and re-anchors the speakers after a skip or seek when the source is live.
///  - `statusUpdates()` yields the current status at once, then on every change.
public protocol MusicPlayerProviding: AnyObject, Sendable {
    func authorizationStatus() async -> PermissionStatus
    /// Shows the system prompt when not determined; returns the resulting status.
    func requestAuthorization() async -> PermissionStatus
    /// The status without prompting, looked up afresh even when that means opening the
    /// provider's app hidden (`authorizationStatus()` never does, so a closed Music app reads as
    /// not determined after every launch).
    func refreshAuthorization() async -> PermissionStatus

    func statusUpdates() -> AsyncStream<MusicPlayerStatus>

    func songs(_ page: PageRequest) async throws -> Page<TrackItem>
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem>
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem>
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem>
    func upNext(_ page: PageRequest) async throws -> Page<TrackItem>
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data?

    /// Starts `trackID` with `context` deciding what follows (never `.files`).
    func play(trackID: String, context: TrackContext) async throws
    func play(playlistID: String) async throws
    /// Plays one library track and stops after it (the hub's queue decides what follows).
    func playOnce(trackID: String) async throws
    func play() async throws
    func pause() async
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws

    func makeAudioSource() throws -> AudioSource

    /// The System Settings privacy pane that holds the permission gating this player
    /// (`.appleMusic` for MusicKit, `.automation` for the Music app). `HubPermission.appleMusic`
    /// in `HubState` always reports this player's own gate, whichever pane it lives in.
    var settingsPermission: HubPermission { get }
}

public extension MusicPlayerProviding {
    /// Plays one library track and then stops (the hub's queue decides what follows). Players
    /// that can't stop after one track start it as a library song.
    func playOnce(trackID: String) async throws { try await play(trackID: trackID, context: .songs) }
}

public extension MusicPlayerProviding {
    var settingsPermission: HubPermission { .appleMusic }
}

public extension MusicPlayerProviding {
    func refreshAuthorization() async -> PermissionStatus { await authorizationStatus() }
}
