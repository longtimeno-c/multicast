import Foundation
import MulticastAudio
import MulticastHubModel
#if os(macOS)
import MulticastSources
#endif

/// The Music app for the library, MusicKit for the Apple Music catalog, as one player.
///
/// The Music app can only be told to play tracks that are in the library (by persistent id),
/// so a catalog song (`CatalogTrackID`) is played by `catalog` instead, and everything else by
/// `library`. Exactly one of the two is the active player at a time:
///
///  - Starting a catalog song pauses the library player (if it was playing) and makes the
///    catalog player active; starting anything from the library stops the catalog player and
///    makes the library player active again.
///  - Transport (play, pause, skip, seek) and now playing follow the active player.
///  - Lists, artwork of library items, permissions and health are the library player's. Catalog
///    search needs the catalog player's own permission and reports its own errors.
///  - The capture source taps both rendering processes at once (`captureBundleIDs`), so the
///    hub keeps one source whichever of the two is playing.
///
/// If the library player starts playing by itself while a catalog song plays (someone pressed
/// play in Music), it becomes the active player and the catalog song stops, so the hub sees one
/// player and treats it as it treats any song started in Music directly.
public final class CatalogRoutingProvider: AppleMusicProviding, @unchecked Sendable {
    public let library: AppleMusicProviding
    public let catalog: AppleMusicProviding
    public let captureBundleIDs: [String]
    /// How long after a switch to the catalog player the library player's "playing" reports
    /// are taken for the tail of what was just paused rather than a new start.
    public let takeoverGrace: TimeInterval

    private enum Active { case library, catalog }

    private let lock = NSLock()
    private var active = Active.library
    private var switches: UInt64 = 0
    private var switchedAt = Date.distantPast
    private var lastLibrary = AppleMusicSnapshot()
    private var lastCatalog = AppleMusicSnapshot()
    private var libraryTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var listening = false
    private var fanout: SnapshotFanout<AppleMusicSnapshot>!

    public init(library: AppleMusicProviding, catalog: AppleMusicProviding, captureBundleIDs: [String],
                takeoverGrace: TimeInterval = 3) {
        self.library = library
        self.catalog = catalog
        self.captureBundleIDs = captureBundleIDs
        self.takeoverGrace = takeoverGrace
        fanout = SnapshotFanout { [weak self] on in self?.setListening(on) }
    }

    deinit {
        libraryTask?.cancel()
        catalogTask?.cancel()
        fanout.finish()
    }

    public var kind: AppleMusicBackendKind { library.kind }
    public var supportsQueueEditing: Bool { library.supportsQueueEditing }

    /// True while the catalog player is the one playing (tests, diagnostics).
    public var catalogIsActive: Bool { lock.withLock { active == .catalog } }

    private var current: AppleMusicProviding { lock.withLock { active == .catalog } ? catalog : library }

    // MARK: Health and lists (the library's)

    public func health() async -> AppleMusicHealth { await library.health() }
    public func requestAccess() async -> PermissionStatus { await library.requestAccess() }
    public func currentAccess() async -> PermissionStatus { await library.currentAccess() }

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> { try await library.songs(page) }
    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { try await library.playlists(page) }
    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await library.tracks(inPlaylist: playlistID, page)
    }
    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { try await library.search(query, page) }
    public func upNext(_ page: PageRequest) async throws -> Page<TrackItem> { try await library.upNext(page) }
    public func invalidateLibrary() async { await library.invalidateLibrary() }

    public func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await catalog.searchCatalog(query, page)
    }

    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        if case .musicKitItem? = AppleMusicArtworkRef(artworkID: id) { return await catalog.artwork(id: id, maxPixel: maxPixel) }
        return await library.artwork(id: id, maxPixel: maxPixel)
    }

    // MARK: Play

    public func play(trackID: String, context: TrackContext) async throws {
        if CatalogTrackID.isCatalog(trackID) {
            await useCatalog()
            try await catalog.play(trackID: trackID, context: .catalog(query: ""))
        } else {
            await useLibrary()
            try await library.play(trackID: trackID, context: context)
        }
    }

    public func playOnce(trackID: String) async throws {
        if CatalogTrackID.isCatalog(trackID) {
            await useCatalog()
            try await catalog.playOnce(trackID: trackID)
        } else {
            await useLibrary()
            try await library.playOnce(trackID: trackID)
        }
    }

    public func play(playlistID: String, shuffled: Bool) async throws {
        await useLibrary()
        try await library.play(playlistID: playlistID, shuffled: shuffled)
    }

    public func insertNext(trackIDs: [String]) async throws {
        try requireLibraryIDs(trackIDs)
        try await library.insertNext(trackIDs: trackIDs)
    }

    public func append(trackIDs: [String]) async throws {
        try requireLibraryIDs(trackIDs)
        try await library.append(trackIDs: trackIDs)
    }

    private func requireLibraryIDs(_ ids: [String]) throws {
        guard !ids.contains(where: CatalogTrackID.isCatalog) else {
            throw HubCommandError(.unsupported, "The Music app\u{2019}s own queue only takes songs in your library.")
        }
    }

    // MARK: Transport (the active player's)

    public func play() async throws { try await current.play() }
    public func pause() async throws { try await current.pause() }
    public func next() async throws { try await current.next() }
    public func previous() async throws { try await current.previous() }
    public func seek(to position: TimeInterval) async throws { try await current.seek(to: position) }

    // MARK: Switching

    private func useCatalog() async {
        let (wasLibrary, libraryPlaying): (Bool, Bool) = lock.withLock {
            let was = active == .library
            active = .catalog
            if was { switches &+= 1 }
            switchedAt = Date()
            return (was, lastLibrary.transport.isPlaying)
        }
        followCatalog()
        republish()
        // Only when it is playing: pausing a closed Music app would open it.
        if wasLibrary, libraryPlaying { try? await library.pause() }
    }

    private func useLibrary() async {
        let wasCatalog: Bool = lock.withLock {
            let was = active == .catalog
            active = .library
            if was { switches &+= 1 }
            return was
        }
        guard wasCatalog else { return }
        republish()
        try? await catalog.pause()
    }

    // MARK: Updates

    public func updates() -> AsyncStream<AppleMusicSnapshot> { fanout.stream() }

    private func setListening(_ on: Bool) {
        lock.lock()
        if on {
            listening = true
            let needsLibrary = libraryTask == nil
            lock.unlock()
            if needsLibrary { followLibrary() }
            // The catalog player is only watched once it has been used: watching it reads
            // MusicKit's player, which nothing should touch in a build that never plays with it.
            if lock.withLock({ switches > 0 }) { followCatalog() }
        } else {
            listening = fanout.subscriberCount > 0
            let stop = !listening
            let tasks = stop ? [libraryTask, catalogTask] : []
            if stop { libraryTask = nil; catalogTask = nil }
            lock.unlock()
            tasks.forEach { $0?.cancel() }
        }
    }

    private func followLibrary() {
        let stream = library.updates()
        let task = Task { [weak self] in
            for await s in stream { self?.received(s, from: .library) }
        }
        lock.withLock {
            if libraryTask == nil, listening { libraryTask = task } else { task.cancel() }
        }
    }

    private func followCatalog() {
        guard lock.withLock({ catalogTask == nil && listening }) else { return }
        let stream = catalog.updates()
        let task = Task { [weak self] in
            for await s in stream { self?.received(s, from: .catalog) }
        }
        lock.withLock {
            if catalogTask == nil, listening { catalogTask = task } else { task.cancel() }
        }
    }

    private func received(_ s: AppleMusicSnapshot, from source: Active) {
        var stopCatalog = false
        lock.lock()
        switch source {
        case .library:
            lastLibrary = s
            // Music is playing under a catalog song, and not as the tail of what was paused
            // for it: someone started it, so it takes over.
            if active == .catalog, s.transport.isPlaying, Date().timeIntervalSince(switchedAt) > takeoverGrace {
                active = .library
                switches &+= 1
                stopCatalog = true
            }
        case .catalog:
            lastCatalog = s
        }
        lock.unlock()
        republish()
        if stopCatalog { Task { [catalog] in try? await catalog.pause() } }
    }

    private func republish() {
        let merged: AppleMusicSnapshot = lock.withLock {
            var m = active == .catalog ? lastCatalog : lastLibrary
            m.libraryRevision = lastLibrary.libraryRevision
            m.upNextRevision = lastLibrary.upNextRevision &+ lastCatalog.upNextRevision &+ switches
            return m
        }
        if merged != fanout.current { fanout.publish(merged) }
    }

    // MARK: Capture

    #if os(macOS)
    /// One tap on every process that renders either player's sound, muted on the Mac while
    /// Multicast reads it. A process that isn't running yet joins the tap when it starts.
    public func makeAudioSource() -> AudioSource {
        if #available(macOS 14.2, *) {
            return AppAudioTapSource(target: .apps(bundleIDs: captureBundleIDs), muteBehavior: .mutedWhenTapped,
                                     displayName: "Apple Music")
        }
        return library.makeAudioSource()
    }
    #endif
}
