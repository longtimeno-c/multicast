import Foundation

// MARK: - The backend seam
//
// `HubBackend` is the only thing a hub UI talks to. On the Mac the real one wraps MulticastKit
// (MulticastHub); the iOS remote implements it as a network client of the Mac (MulticastRemote);
// MockHubBackend implements it for previews and snapshots. Its whole surface is expressible as
// `HubCommand` + `HubQuery`, so a transport carries exactly this protocol and nothing else.
//
// Contract for implementers:
//  - `states()` returns an independent stream that yields the current `HubState` at once, then
//    again whenever anything in it changes (and only then), each with a higher `revision`. It
//    finishes on shutdown. Keep the latest value only (`.bufferingNewest(1)`): a slow reader
//    must skip states, never queue them.
//  - `levels()` streams the outgoing mix at about 20 Hz while audio flows and sends one
//    `.silent` when it stops. Separate from state so meters never resend the rest.
//  - `availability()` describes the link to the hub; in-process backends keep the default
//    (`.connected`, once).
//  - Artwork is referenced by `ArtworkID`; `artwork(id:maxPixel:)` returns encoded bytes and an
//    id always names the same image, so callers cache by id.
//  - Lists are paged queries (`PageRequest` → `Page`). When a list changes the backend bumps its
//    counter in `HubState.content`; clients then refetch from the first page. Throw only when
//    the list can't be read at all (permission missing: also reported in `HubState.health`).
//  - Commands arrive in order, one at a time (UIs serialise them). They return once the request
//    is accepted, not when it completes: enabling a speaker returns at once and the speaker then
//    moves through `.connecting` to `.playing` or `.failed(reason:)` in later states.
//  - Speaker failures belong in the speaker's state, not in a thrown error. Throw (preferably a
//    `HubCommandError`) only when a request can't be accepted at all; UIs then roll back their
//    optimistic change to the last published state and show the error for transport and source
//    commands.
//  - Volume and trim arrive at most every 50 ms during a drag plus a final value. Echo the value
//    you applied in the next state; UIs hold their own value until the echo matches (or 500 ms
//    pass), so a slider never snaps back under the pointer.
//  - Volume and trim are legal while a speaker is off: they are its preset, applied on connect.
//  - Volumes are 0…1. A speaker plays at its own volume × the master.
//
// Implement `perform(_:)` once; the named command methods (`play()`, `setSpeaker(_:volume:)`, …)
// in the extension below all route through it. `answer(_:)` maps a `HubQuery` onto the list
// methods, so a network server needs no switch of its own.
public protocol HubBackend: AnyObject, Sendable {
    // State
    func states() async -> AsyncStream<HubState>
    func levels() async -> AsyncStream<StereoLevels>
    func availability() async -> AsyncStream<HubAvailability>

    // Queries
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data?
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem>
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem>
    func songs(_ page: PageRequest) async throws -> Page<TrackItem>
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem>
    /// Apple Music catalog search (songs that need not be in the library). The default says
    /// this backend has no catalog.
    func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem>
    /// The hub's Up Next: the songs after the current one, in play order.
    func upNext(_ page: PageRequest) async throws -> Page<QueueItem>
    func files(_ page: PageRequest) async throws -> Page<TrackItem>
    func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem>

    // Commands
    func perform(_ command: HubCommand) async throws
}

public extension HubBackend {
    /// In-process backends are always reachable.
    func availability() async -> AsyncStream<HubAvailability> {
        AsyncStream { c in
            c.yield(.connected)
            c.finish()
        }
    }

    func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        throw HubCommandError(.unsupported, "Apple Music catalog search isn\u{2019}t available here.")
    }

    /// Answers any `HubQuery` with this backend's methods.
    func answer(_ query: HubQuery) async throws -> HubQueryResult {
        switch query {
        case .playlists(let page): .playlists(page: try await playlists(page))
        case .playlistTracks(let id, let page): .tracks(page: try await tracks(inPlaylist: id, page))
        case .songs(let page): .tracks(page: try await songs(page))
        case .search(let q, let page): .tracks(page: try await search(q, page))
        case .catalogSearch(let q, let page): .tracks(page: try await searchCatalog(q, page))
        case .upNext(let page): .queue(page: try await upNext(page))
        case .files(let page): .tracks(page: try await files(page))
        case .spotifyHistory(let page): .tracks(page: try await spotifyHistory(page))
        case .artwork(let id, let maxPixel): .artwork(data: await artwork(id: id, maxPixel: maxPixel))
        }
    }

    // MARK: Named commands, all through `perform(_:)`

    func play() async throws { try await perform(.play) }
    func pause() async throws { try await perform(.pause) }
    func next() async throws { try await perform(.next) }
    func previous() async throws { try await perform(.previous) }
    func seek(to position: TimeInterval) async throws { try await perform(.seek(position: position)) }

    func selectSource(_ source: SourceKind) async throws { try await perform(.selectSource(source: source)) }
    func playTrack(id: String, context: TrackContext) async throws { try await perform(.playTrack(id: id, context: context)) }
    func playPlaylist(id: String, shuffled: Bool = false) async throws {
        try await perform(.playPlaylist(id: id, shuffled: shuffled))
    }
    func captureApp(bundleID: String) async throws { try await perform(.captureApp(bundleID: bundleID)) }
    func addFiles(_ urls: [URL]) async throws { try await perform(.addFiles(urls: urls)) }
    func removeFiles(ids: [String]) async throws { try await perform(.removeFiles(ids: ids)) }
    func openSpotify() async throws { try await perform(.openSpotify) }
    func requestPermission(_ permission: HubPermission) async throws {
        try await perform(.requestPermission(permission: permission))
    }

    func setSpeaker(_ id: SpeakerID, enabled: Bool) async throws { try await perform(.setSpeakerEnabled(id: id, enabled: enabled)) }
    func setSpeaker(_ id: SpeakerID, volume: Double) async throws { try await perform(.setSpeakerVolume(id: id, volume: volume)) }
    func setSpeaker(_ id: SpeakerID, syncTrimMs: Int) async throws {
        try await perform(.setSpeakerSyncTrim(id: id, milliseconds: syncTrimMs))
    }
    func retrySpeaker(_ id: SpeakerID) async throws { try await perform(.retrySpeaker(id: id)) }
    func setMasterVolume(_ volume: Double) async throws { try await perform(.setMasterVolume(volume: volume)) }
}

/// The Bonjour service a Mac hub advertises for remotes.
public enum HubService {
    public static let bonjourType = "_multicast-hub._tcp"
}
