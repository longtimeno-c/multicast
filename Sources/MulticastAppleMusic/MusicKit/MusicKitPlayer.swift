#if os(macOS)
import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastSources
import MusicKit

/// Apple Music through MusicKit's `ApplicationMusicPlayer`, inside Multicast.
///
/// Needs (a) the app signed under the team whose App ID has the MusicKit service
/// (Apps/Config/Mac.xcconfig) and (b) the Apple Music permission, which a person must grant in
/// the system prompt. `ApplicationMusicPlayer` audio is rendered by the system process
/// `com.apple.MediaPlayer.RemotePlayerService`, not by Multicast, so the hub taps that
/// (`AppleMusicProviderFactory` passes `.apps([remotePlayerServiceBundleID])`). The tap waits
/// for the process, which starts with the first playback.
///
/// DRM: MusicKit never hands out samples; the sound reaches Multicast only through a process
/// tap on whichever process renders it (`makeAudioSource()`).
@available(macOS 14.2, *)
public final class MusicKitPlayer: AppleMusicProviding, @unchecked Sendable {
    /// Which process renders `ApplicationMusicPlayer` audio (what the tap must target).
    public enum Renderer: Sendable, Equatable {
        /// Multicast itself. A tap on it also hears (and mutes) Multicast's own delayed local
        /// output, so it can only be used when no local speaker plays on the same device.
        case thisProcess
        /// A separate process (a system helper), by bundle id.
        case apps(bundleIDs: [String])
    }

    /// The system process that renders `ApplicationMusicPlayer` audio on macOS (measured: a
    /// tap on it hears MusicKit playback; Multicast's own process stays silent).
    public static let remotePlayerServiceBundleID = "com.apple.MediaPlayer.RemotePlayerService"

    public let kind = AppleMusicBackendKind.musicKit
    public let supportsQueueEditing = true
    public let renderer: Renderer
    public let pollInterval: TimeInterval

    private let lock = NSLock()
    private var artworkByItem: [String: Artwork] = [:]
    private var playlistTracks: [String: (index: LibraryIndex, tracks: [Track], builtAt: Date)] = [:]
    private var upNextRevision: UInt64 = 0
    private var lastEntryID: String?
    private var timer: DispatchSourceTimer?
    private let artworkCache = LockedArtworkCache()
    private var fanout: SnapshotFanout<AppleMusicSnapshot>!

    public init(renderer: Renderer = .thisProcess, pollInterval: TimeInterval = 1) {
        self.renderer = renderer
        self.pollInterval = max(0.25, pollInterval)
        fanout = SnapshotFanout { [weak self] active in
            DispatchQueue.main.async { active ? self?.startObserving() : self?.stopObserving() }
        }
    }

    deinit {
        timer?.cancel()
        fanout.finish()
    }

    private var player: ApplicationMusicPlayer { ApplicationMusicPlayer.shared }

    // MARK: Health

    static func permission(_ status: MusicAuthorization.Status) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func health() async -> AppleMusicHealth {
        let status = Self.permission(MusicAuthorization.currentStatus)
        var h = AppleMusicHealth(backend: .musicKit, permission: .appleMusic, permissionStatus: status)
        if status != .granted {
            h.issues.append(.permissionMissing(permission: .appleMusic, status: status))
            return h
        }
        if let sub = try? await MusicSubscription.current, !sub.canPlayCatalogContent {
            h.notes.append("No Apple Music subscription on this Mac: only songs you own can play.")
        }
        return h
    }

    public func requestAccess() async -> PermissionStatus {
        Self.permission(await MusicAuthorization.request())
    }

    private func requireAuthorized() throws {
        let s = Self.permission(MusicAuthorization.currentStatus)
        guard s == .granted else {
            throw HubCommandError(.permissionMissing, "Multicast needs access to Apple Music. Allow it in System Settings › Privacy & Security › Media & Apple Music.")
        }
    }

    // MARK: Browse

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> {
        try requireAuthorized()
        var req = MusicLibraryRequest<Song>()
        req.sort(by: \.title, ascending: true)
        req.offset = page.offset
        req.limit = MusicKitMapping.fetchLimit(for: page)
        let res = try await wrap { try await req.response() }
        return MusicKitMapping.page(res.items.map(map), for: page)
    }

    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try requireAuthorized()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        var req = MusicLibraryRequest<Song>()
        req.filter(text: q)
        req.offset = page.offset
        req.limit = MusicKitMapping.fetchLimit(for: page)
        let res = try await wrap { try await req.response() }
        return MusicKitMapping.page(res.items.map(map), for: page)
    }

    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> {
        try requireAuthorized()
        var req = MusicLibraryRequest<Playlist>()
        req.sort(by: \.name, ascending: true)
        req.offset = page.offset
        req.limit = MusicKitMapping.fetchLimit(for: page)
        let res = try await wrap { try await req.response() }
        var items: [PlaylistItem] = []
        for p in res.items {
            // The track count needs the tracks relationship; one request per playlist on this page.
            let count = (try? await p.with([.tracks]).tracks?.count) ?? 0
            remember(p.artwork, for: p.id.rawValue)
            items.append(MusicKitMapping.playlist(id: p.id.rawValue, name: p.name, trackCount: count, hasArtwork: p.artwork != nil))
        }
        return MusicKitMapping.page(items, for: page)
    }

    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await playlistIndex(playlistID).index.page(page)
    }

    public func upNext(_ page: PageRequest) async throws -> Page<TrackItem> {
        let items: [TrackItem] = await MainActor.run {
            let entries = Array(player.queue.entries)
            let start = player.queue.currentEntry.flatMap { cur in entries.firstIndex { $0.id == cur.id } }.map { $0 + 1 } ?? 0
            return entries[min(start, entries.count)...].map { e in
                let id = e.item?.id.rawValue ?? e.id
                if let art = e.artwork { remember(art, for: id) }
                return MusicKitMapping.track(id: id, title: e.title, artist: e.subtitle ?? "", album: nil, duration: nil,
                                             hasArtwork: e.artwork != nil)
            }
        }
        return Page.slice(items, page)
    }

    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        guard case .musicKitItem(let itemID)? = AppleMusicArtworkRef(artworkID: id) else { return nil }
        let key = ArtworkCache.Key(id: id, maxPixel: max(0, maxPixel))
        if let hit = artworkCache.data(for: key) { return hit }
        let art: Artwork? = lock.withLock { artworkByItem[itemID] }
        guard let art else { return nil }
        let side = maxPixel > 0 ? maxPixel : max(art.maximumWidth, art.maximumHeight)
        // Catalog artwork is an https URL. Library artwork may use a private scheme that only
        // MusicKit's own views can load; those return nil here (unverified on macOS).
        guard let url = art.url(width: side, height: side), url.scheme == "https" || url.scheme == "http",
              let (data, _) = try? await URLSession.shared.data(from: url),
              let scaled = ArtworkScaler.scale(data, maxPixel: max(0, maxPixel)) else { return nil }
        artworkCache.insert(scaled, for: key)
        return scaled
    }

    public func invalidateLibrary() async {
        lock.withLock { playlistTracks = [:] }
    }

    // MARK: Play

    public func play(trackID: String, context: TrackContext) async throws {
        try requireAuthorized()
        switch context {
        case .songs, .search:
            let song = try await song(id: trackID)
            await MainActor.run { player.queue = [song] }
        case .playlist(let pid):
            let entry = try await playlistIndex(pid)
            guard let track = entry.tracks.first(where: { $0.id.rawValue == trackID }) else {
                throw HubCommandError(.notFound, "That song is no longer in the playlist.")
            }
            await MainActor.run { player.queue = ApplicationMusicPlayer.Queue(for: entry.tracks, startingAt: track) }
        case .upNext:
            let found: Bool = await MainActor.run {
                guard let e = player.queue.entries.first(where: { ($0.item?.id.rawValue ?? $0.id) == trackID }) else { return false }
                player.queue.currentEntry = e
                return true
            }
            guard found else { throw HubCommandError(.notFound, "That song is no longer in Up Next.") }
        case .files, .spotifyHistory:
            throw HubCommandError(.unsupported, "That isn't played through Apple Music.")
        }
        try await wrap { try await self.player.play() }
        bumpUpNext()
    }

    public func play(playlistID: String, shuffled: Bool) async throws {
        try requireAuthorized()
        let entry = try await playlistIndex(playlistID)
        guard !entry.tracks.isEmpty else { throw HubCommandError(.unavailable, "That playlist is empty.") }
        await MainActor.run {
            player.state.shuffleMode = shuffled ? .songs : .off
            player.queue = ApplicationMusicPlayer.Queue(for: entry.tracks)
        }
        try await wrap { try await self.player.play() }
        bumpUpNext()
    }

    public func insertNext(trackIDs: [String]) async throws {
        try await insert(trackIDs, position: .afterCurrentEntry)
    }

    public func append(trackIDs: [String]) async throws {
        try await insert(trackIDs, position: .tail)
    }

    private func insert(_ ids: [String], position: MusicPlayer.Queue.EntryInsertionPosition) async throws {
        try requireAuthorized()
        var songs: [Song] = []
        for id in ids { songs.append(try await song(id: id)) }
        guard !songs.isEmpty else { return }
        let toInsert = position == .afterCurrentEntry ? Array(songs.reversed()) : songs
        for s in toInsert {
            try await wrap { try await self.player.queue.insert(s, position: position) }
        }
        bumpUpNext()
    }

    // MARK: Transport

    public func play() async throws {
        try requireAuthorized()
        try await wrap { try await self.player.play() }
    }

    public func pause() async throws { await MainActor.run { player.pause() } }

    public func next() async throws {
        try await wrap { try await self.player.skipToNextEntry() }
        bumpUpNext()
    }

    public func previous() async throws {
        try await wrap { try await self.player.skipToPreviousEntry() }
        bumpUpNext()
    }

    public func seek(to position: TimeInterval) async throws {
        await MainActor.run { player.playbackTime = max(0, position) }
    }

    /// Stops playback and empties the queue (probes and teardown).
    public func stop() async {
        await MainActor.run {
            player.stop()
            player.queue = []
        }
    }

    // MARK: Updates

    public func updates() -> AsyncStream<AppleMusicSnapshot> { fanout.stream() }

    private func startObserving() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func stopObserving() {
        guard fanout.subscriberCount == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    private func bumpUpNext() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.upNextRevision &+= 1
            self.poll()
        }
    }

    /// Main queue only.
    private func poll() {
        let now = Date()
        let entry = player.queue.currentEntry
        if entry?.id != lastEntryID {
            lastEntryID = entry?.id
            upNextRevision &+= 1
        }
        let status = player.state.playbackStatus
        let playing: Bool
        switch status {
        case .playing, .seekingForward, .seekingBackward: playing = true
        default: playing = false
        }
        var np: NowPlayingInfo?
        var duration: TimeInterval?
        if let entry {
            let id = entry.item?.id.rawValue ?? entry.id
            if case .song(let s)? = entry.item { duration = s.duration }
            if let art = entry.artwork { remember(art, for: id) }
            np = NowPlayingInfo(title: entry.title, artist: entry.subtitle ?? "", album: nil,
                                artworkID: entry.artwork != nil ? AppleMusicArtworkRef.musicKitItem(id: id).artworkID : nil,
                                artworkIsIcon: false, duration: duration, trackID: id)
        }
        let snap = AppleMusicSnapshot(
            nowPlaying: np,
            transport: TransportState(isPlaying: playing && np != nil, position: player.playbackTime, positionAsOf: now,
                                      canSkip: np != nil, canSeek: duration != nil),
            upNextRevision: upNextRevision, libraryRevision: 0)
        if snap.isSignificantChange(from: fanout.current) { fanout.publish(snap) }
    }

    // MARK: Capture

    /// A tap on `renderer`. With `.thisProcess` the tap also captures and mutes Multicast's own
    /// local-speaker output, so the hub uses `.apps([remotePlayerServiceBundleID])`.
    public func makeAudioSource() -> AudioSource {
        switch renderer {
        case .thisProcess:
            let selfObject = AudioProcessDirectory.currentProcessObject().map { [$0] } ?? []
            return AppAudioTapSource(target: .processObjects(selfObject), muteBehavior: .mutedWhenTapped, displayName: "Apple Music")
        case .apps(let ids):
            return AppAudioTapSource(target: .apps(bundleIDs: ids), muteBehavior: .mutedWhenTapped, displayName: "Apple Music")
        }
    }

    // MARK: Helpers

    private func map(_ s: Song) -> TrackItem {
        remember(s.artwork, for: s.id.rawValue)
        return MusicKitMapping.track(id: s.id.rawValue, title: s.title, artist: s.artistName, album: s.albumTitle,
                                     duration: s.duration, hasArtwork: s.artwork != nil)
    }

    private func map(_ t: Track) -> TrackItem {
        remember(t.artwork, for: t.id.rawValue)
        return MusicKitMapping.track(id: t.id.rawValue, title: t.title, artist: t.artistName, album: t.albumTitle,
                                     duration: t.duration, hasArtwork: t.artwork != nil)
    }

    private func remember(_ art: Artwork?, for id: String) {
        guard let art else { return }
        lock.withLock {
            if artworkByItem.count > 5000 { artworkByItem.removeAll(keepingCapacity: true) }
            artworkByItem[id] = art
        }
    }

    private func song(id: String) async throws -> Song {
        var req = MusicLibraryRequest<Song>()
        req.filter(matching: \.id, equalTo: MusicItemID(id))
        req.limit = 1
        guard let s = try await wrap({ try await req.response() }).items.first else {
            throw HubCommandError(.notFound, "That song is no longer in your library.")
        }
        return s
    }

    private func playlistIndex(_ id: String) async throws -> (index: LibraryIndex, tracks: [Track]) {
        try requireAuthorized()
        if let hit = lock.withLock({ playlistTracks[id] }), Date().timeIntervalSince(hit.builtAt) < 60 {
            return (hit.index, hit.tracks)
        }
        var req = MusicLibraryRequest<Playlist>()
        req.filter(matching: \.id, equalTo: MusicItemID(id))
        req.limit = 1
        guard let playlist = try await wrap({ try await req.response() }).items.first else {
            throw HubCommandError(.notFound, "That playlist is no longer in your library.")
        }
        let loaded = try await wrap { try await playlist.with([.tracks]) }
        var tracks: [Track] = []
        if var batch = loaded.tracks {
            tracks.append(contentsOf: batch)
            while batch.hasNextBatch, tracks.count < 10_000, let next = try await wrap({ try await batch.nextBatch() }) {
                tracks.append(contentsOf: next)
                batch = next
            }
        }
        let index = LibraryIndex(tracks: tracks.map(map))
        lock.withLock {
            if playlistTracks.count >= 8, let oldest = playlistTracks.min(by: { $0.value.builtAt < $1.value.builtAt })?.key {
                playlistTracks[oldest] = nil
            }
            playlistTracks[id] = (index, tracks, Date())
        }
        return (index, tracks)
    }

    private func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as HubCommandError {
            throw e
        } catch {
            throw HubCommandError(.failed, error.localizedDescription)
        }
    }
}
#endif
