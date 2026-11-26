import Foundation
import MulticastAudio
import MulticastHubModel
import Testing
@testable import MulticastAppleMusic

/// A scripted player: records what it was told and publishes what the test says.
private final class ScriptedPlayer: AppleMusicProviding, @unchecked Sendable {
    let kind: AppleMusicBackendKind
    let supportsQueueEditing = false
    private let lock = NSLock()
    private var log: [String] = []
    private var snapshot = AppleMusicSnapshot()
    private var continuations: [AsyncStream<AppleMusicSnapshot>.Continuation] = []
    var catalogHits: [TrackItem]?

    init(_ kind: AppleMusicBackendKind) { self.kind = kind }

    var calls: [String] { lock.withLock { log } }
    private func note(_ s: String) { lock.withLock { log.append(s) } }

    func publish(playing: Bool, trackID: String?, upNextRevision: UInt64 = 0, libraryRevision: UInt64 = 0) {
        let snap = AppleMusicSnapshot(
            nowPlaying: trackID.map { NowPlayingInfo(title: "Song \($0)", artist: "Lantern Fold", duration: 200, trackID: $0) },
            transport: TransportState(isPlaying: playing, position: 0, positionAsOf: Date(timeIntervalSince1970: 0)),
            upNextRevision: upNextRevision, libraryRevision: libraryRevision)
        let targets: [AsyncStream<AppleMusicSnapshot>.Continuation] = lock.withLock {
            snapshot = snap
            return continuations
        }
        for c in targets { c.yield(snap) }
    }

    func health() async -> AppleMusicHealth { AppleMusicHealth(backend: kind, permission: .automation, permissionStatus: .granted) }
    func requestAccess() async -> PermissionStatus { .granted }
    func songs(_ page: PageRequest) async throws -> Page<TrackItem> { note("songs"); return .empty }
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .empty }
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { note("search \(query)"); return .empty }
    func upNext(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        guard let catalogHits else { throw HubCommandError(.unsupported, "No catalog.") }
        note("catalog \(query)")
        return .slice(catalogHits, page)
    }
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data? { Data("\(kind.rawValue):\(id)".utf8) }
    func play(trackID: String, context: TrackContext) async throws { note("play \(trackID)") }
    func playOnce(trackID: String) async throws { note("once \(trackID)") }
    func play(playlistID: String, shuffled: Bool) async throws { note("playlist \(playlistID)") }
    func insertNext(trackIDs: [String]) async throws { note("insertNext") }
    func append(trackIDs: [String]) async throws { note("append") }
    func play() async throws { note("play") }
    func pause() async throws { note("pause") }
    func next() async throws { note("next") }
    func previous() async throws { note("previous") }
    func seek(to position: TimeInterval) async throws { note("seek \(Int(position))") }
    func updates() -> AsyncStream<AppleMusicSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            let current: AppleMusicSnapshot = lock.withLock {
                continuations.append(c)
                return snapshot
            }
            c.yield(current)
        }
    }
    func invalidateLibrary() async {}
    #if os(macOS)
    func makeAudioSource() -> AudioSource { fatalError("not used") }
    #endif
}

@Suite("Catalog songs route to MusicKit, the library to the Music app")
struct CatalogRoutingTests {
    private func make(grace: TimeInterval = 3) -> (CatalogRoutingProvider, ScriptedPlayer, ScriptedPlayer) {
        let library = ScriptedPlayer(.musicApp)
        let catalog = ScriptedPlayer(.musicKit)
        catalog.catalogHits = [TrackItem(id: "catalog:901", title: "Far Shore", artist: "Lantern Fold", album: "", duration: 200)]
        return (CatalogRoutingProvider(library: library, catalog: catalog, captureBundleIDs: ["a", "b"], takeoverGrace: grace),
                library, catalog)
    }

    /// The next snapshot matching `condition` (bounded).
    private func next(_ stream: AsyncStream<AppleMusicSnapshot>, _ condition: @escaping @Sendable (AppleMusicSnapshot) -> Bool) async -> AppleMusicSnapshot? {
        await withTaskGroup(of: AppleMusicSnapshot?.self) { group in
            group.addTask { for await s in stream where condition(s) { return s }; return nil }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func listsAndSearchAreTheLibrarysAndCatalogSearchIsMusicKits() async throws {
        let (both, library, catalog) = make()
        #expect(both.kind == .musicApp)
        _ = try await both.songs(.first)
        _ = try await both.search("tide", .first)
        #expect(try await both.searchCatalog("tide", .first).items.map(\.id) == ["catalog:901"])
        #expect(library.calls == ["songs", "search tide"])
        #expect(catalog.calls == ["catalog tide"])
        #expect(await both.artwork(id: "am.track.0A1B", maxPixel: 0) == Data("musicApp:am.track.0A1B".utf8))
        #expect(await both.artwork(id: "mk.item.901", maxPixel: 0) == Data("musicKit:mk.item.901".utf8))
    }

    @Test func aCatalogSongPausesMusicOnlyIfItWasPlayingAndTransportFollows() async throws {
        let (both, library, catalog) = make()
        let updates = both.updates()
        // Music idle: starting a catalog song must not send it anything (pausing would open it).
        try await both.playOnce(trackID: "catalog:901")
        #expect(both.catalogIsActive)
        #expect(library.calls.isEmpty && catalog.calls == ["once catalog:901"])
        catalog.publish(playing: true, trackID: "catalog:901")
        #expect(await next(updates) { $0.nowPlaying?.trackID == "catalog:901" && $0.transport.isPlaying } != nil)
        try await both.pause()
        try await both.seek(to: 30)
        #expect(catalog.calls == ["once catalog:901", "pause", "seek 30"])

        // Back to the library: the catalog player stops, Music plays, transport follows it.
        try await both.playOnce(trackID: "0A1B2C3D4E5F6071")
        #expect(!both.catalogIsActive)
        #expect(catalog.calls.last == "pause" && library.calls == ["once 0A1B2C3D4E5F6071"])
        library.publish(playing: true, trackID: "0A1B2C3D4E5F6071")
        #expect(await next(updates) { $0.nowPlaying?.trackID == "0A1B2C3D4E5F6071" } != nil)

        // Music playing: now a catalog song pauses it.
        try await both.playOnce(trackID: "catalog:901")
        #expect(library.calls == ["once 0A1B2C3D4E5F6071", "pause"])
        try await both.next()
        #expect(catalog.calls.last == "next")
    }

    @Test func musicStartedByHandTakesOverFromACatalogSong() async throws {
        let (both, library, catalog) = make(grace: 0)
        let updates = both.updates()
        try await both.playOnce(trackID: "catalog:901")
        catalog.publish(playing: true, trackID: "catalog:901")
        #expect(await next(updates) { $0.nowPlaying?.trackID == "catalog:901" } != nil)
        library.publish(playing: true, trackID: "0A1B2C3D4E5F6071")
        #expect(await next(updates) { $0.nowPlaying?.trackID == "0A1B2C3D4E5F6071" } != nil)
        #expect(!both.catalogIsActive)
        for _ in 0..<100 where catalog.calls.last != "pause" { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(catalog.calls.last == "pause")
    }

    @Test func musicsOwnQueueRefusesCatalogSongs() async throws {
        let (both, library, _) = make()
        await #expect(throws: HubCommandError.self) { try await both.insertNext(trackIDs: ["catalog:901"]) }
        try await both.append(trackIDs: ["0A1B2C3D4E5F6071"])
        #expect(library.calls == ["append"])
    }
}

@Suite struct CatalogMappingTests {
    @Test func catalogTracksCarryCatalogIDsAndPlainArtworkKeys() {
        let t = MusicKitMapping.catalogTrack(catalogID: "901", title: "Far Shore", artist: "Lantern Fold", album: nil,
                                             duration: 201.5, hasArtwork: true)
        #expect(t.id == "catalog:901" && t.artworkID == "mk.item.901" && t.album == "" && t.duration == 201.5)
        #expect(CatalogTrackID.catalogID(from: t.id) == "901")
    }

    @Test func catalogPagingStopsAtTheLimit() {
        #expect(MusicKitMapping.catalogNextCursor(offset: 0, count: 25, hasMore: true) == "25")
        #expect(MusicKitMapping.catalogNextCursor(offset: 0, count: 25, hasMore: false) == nil)
        #expect(MusicKitMapping.catalogNextCursor(offset: 25, count: 0, hasMore: true) == nil)
        #expect(MusicKitMapping.catalogNextCursor(offset: 75, count: 25, hasMore: true) == nil)
    }
}
