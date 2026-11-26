import Foundation
import MulticastAudio
import MulticastHubModel

/// Which machinery plays Apple Music for the hub.
public enum AppleMusicBackendKind: String, Sendable, Codable, CaseIterable {
    /// The system Music app, driven by Apple Events (`MusicAppPlayer`). Needs the Automation
    /// permission for Music; no developer team, no MusicKit entitlement. The safety net.
    case musicApp
    /// MusicKit's `ApplicationMusicPlayer` inside Multicast (`MusicKitPlayer`). Needs the app
    /// signed under the team that registered the bundle id with MusicKit, and the Apple Music
    /// permission.
    case musicKit

    public var title: String {
        switch self {
        case .musicApp: return "Music app"
        case .musicKit: return "MusicKit"
        }
    }
}

/// Whether the provider can browse and play right now, in the hub's vocabulary.
public struct AppleMusicHealth: Sendable, Equatable {
    public var backend: AppleMusicBackendKind
    /// The permission that gates the library: `.automation` (Music app) or `.appleMusic` (MusicKit).
    public var permission: HubPermission
    public var permissionStatus: PermissionStatus
    /// Blocking problems, ready to merge into `HubHealth.issues` (permission, app not running…).
    public var issues: [HubIssue]
    /// Non-blocking facts worth showing, e.g. "Music is sending audio to AirPlay speakers itself,
    /// so Multicast hears nothing". Plain sentences, no device names.
    public var notes: [String]

    public init(backend: AppleMusicBackendKind, permission: HubPermission, permissionStatus: PermissionStatus,
                issues: [HubIssue] = [], notes: [String] = []) {
        self.backend = backend
        self.permission = permission
        self.permissionStatus = permissionStatus
        self.issues = issues
        self.notes = notes
    }

    /// True when nothing blocks browsing and playing.
    public var isReady: Bool { permissionStatus == .granted && issues.isEmpty }
}

/// What is playing, in the hub's vocabulary. Published by `AppleMusicProviding.updates()`.
public struct AppleMusicSnapshot: Sendable, Equatable {
    public var nowPlaying: NowPlayingInfo?
    public var transport: TransportState
    /// Grows whenever the up-next list may have changed (track change, queue edit). The hub
    /// bumps `HubState.content.upNext` when it does.
    public var upNextRevision: UInt64
    /// Grows whenever the library index was rebuilt with different content. The hub bumps
    /// `HubState.content.library` when it does.
    public var libraryRevision: UInt64

    public init(nowPlaying: NowPlayingInfo? = nil, transport: TransportState = TransportState(),
                upNextRevision: UInt64 = 0, libraryRevision: UInt64 = 0) {
        self.nowPlaying = nowPlaying
        self.transport = transport
        self.upNextRevision = upNextRevision
        self.libraryRevision = libraryRevision
    }
}

/// The hub's Apple Music player: browse (paged), play, queue, transport, now playing, and the
/// capture `AudioSource` that carries the sound into the Multicast pipeline.
///
/// Errors are `HubCommandError` so the hub can pass them through unchanged:
/// `.permissionMissing` (Automation / Apple Music denied), `.unavailable` (Music not running and
/// not allowed to launch, no subscription…), `.notFound` (stale id), `.unsupported` (e.g. queue
/// editing on the Music app backend), `.failed` (anything else, with the system's message).
public protocol AppleMusicProviding: AnyObject, Sendable {
    var kind: AppleMusicBackendKind { get }

    // Health
    /// Current status without prompting.
    func health() async -> AppleMusicHealth
    /// Shows the system permission prompt if the status is not determined yet (once), and
    /// returns the resulting status.
    func requestAccess() async -> PermissionStatus
    /// Current status without ever prompting; unlike `health()` it may open the provider's
    /// app hidden first, since a closed app's Automation status cannot be read.
    func currentAccess() async -> PermissionStatus

    // Browse (cursor is opaque; nil `nextCursor` = last page)
    func songs(_ page: PageRequest) async throws -> Page<TrackItem>
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem>
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem>
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem>
    func upNext(_ page: PageRequest) async throws -> Page<TrackItem>
    /// Image bytes for an `ArtworkID` this provider handed out, scaled so neither side exceeds
    /// `maxPixel` (0 = original size). nil when the item has no artwork.
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data?

    // Play
    /// Plays `trackID`; what follows it depends on `context` (see each backend).
    func play(trackID: String, context: TrackContext) async throws
    func play(playlistID: String, shuffled: Bool) async throws
    /// Whether `insertNext` / `append` work on this backend.
    var supportsQueueEditing: Bool { get }
    func insertNext(trackIDs: [String]) async throws
    func append(trackIDs: [String]) async throws

    // Transport
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws

    /// The current snapshot at once, then each change (track, play/pause, seek, queue, library).
    /// Normal play progress is not a change: `TransportState.position(at:)` extrapolates.
    func updates() -> AsyncStream<AppleMusicSnapshot>

    /// Forget cached library lists (songs, playlists, playlist tracks); the next request
    /// rebuilds them.
    func invalidateLibrary() async

    #if os(macOS)
    /// The capture source for whichever process renders this backend's audio, muted locally
    /// while Multicast reads it (the speakers get it, in sync, instead). Requires the System
    /// Audio Recording permission; without it the tap delivers silence.
    func makeAudioSource() -> AudioSource
    #endif
}

/// Picks a backend. `MusicAppPlayer` works anywhere the Music app does; `MusicKitPlayer` only
/// in an app signed for MusicKit (see the module README in `MulticastAppleMusic.swift`).
public enum AppleMusicProviderFactory {
    #if os(macOS)
    @available(macOS 14.2, *)
    public static func make(_ kind: AppleMusicBackendKind) -> AppleMusicProviding {
        switch kind {
        case .musicApp: return MusicAppPlayer()
        case .musicKit: return MusicKitPlayer()
        }
    }
    #endif
}

public extension AppleMusicProviding {
    func currentAccess() async -> PermissionStatus { await health().permissionStatus }
}
