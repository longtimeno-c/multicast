import Foundation
import MulticastHubModel
import Observation
import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case songs = "Songs", playlists = "Playlists", upNext = "Up Next"
    var id: String { rawValue }
}

/// A failed transport or source command, shown as an alert.
struct HubAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// The one object views read from and send intents to. It mirrors the backend's state into
/// observable properties (so a level update only invalidates the meter), applies the obvious
/// result of a command at once, sends commands to the backend in order through one pipe, rolls
/// back to the last published state when a command is refused, caches artwork, and loads the
/// library and file lists page by page.
@Observable
@MainActor
final class HubModel {
    // Mirrored backend state
    private(set) var speakers: [SpeakerItem] = []
    private(set) var masterVolume: Double = 0.6
    private(set) var isDiscovering = false
    private(set) var activeSource: SourceKind?
    private(set) var nowPlaying: NowPlayingInfo?
    private(set) var transport = TransportState()
    private(set) var capture = CaptureStatus()
    private(set) var spotify: SpotifyStatus = .notRunning
    private(set) var health = HubHealth()
    private(set) var queue = QueueStatus()
    private(set) var pins: [PinnedPlaylist] = []
    private(set) var availability: HubAvailability = .connected
    private(set) var levels: StereoLevels = .silent

    // Paged lists, fetched on demand and refetched when `HubState.content` says they changed.
    private(set) var songs = PagedList<TrackItem>()
    private(set) var playlists = PagedList<PlaylistItem>()
    /// The hub's Up Next: Apple Music, Spotify and file songs in play order.
    private(set) var upNext = PagedList<QueueItem>()
    private(set) var files = PagedList<TrackItem>()
    private(set) var spotifyHistory = PagedList<TrackItem>()
    /// Library search results for `searchQuery`.
    private(set) var searchResults = PagedList<TrackItem>()
    private(set) var searchQuery = ""
    /// The contents of the playlist last opened with `openPlaylist(_:)`.
    private(set) var openPlaylistID: String?
    private(set) var playlistTracks = PagedList<TrackItem>()

    // Navigation that other surfaces (menu commands, the menu-bar panel) also drive.
    var browsingSource: SourceKind = .appleMusic
    /// Which part of the library is showing (Mac).
    var librarySection: LibrarySection = .songs
    /// A refused transport or source command. Speaker failures show in the speaker's row.
    var alert: HubAlert?
    /// Set by the root views from the environment; structural changes animate with it.
    @ObservationIgnored var reduceMotion = false

    @ObservationIgnored private let backend: HubBackend
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let commands: AsyncStream<HubCommand>.Continuation
    @ObservationIgnored private let commandStream: AsyncStream<HubCommand>
    @ObservationIgnored private var published = HubState()
    @ObservationIgnored private var content = ContentRevisions()

    // Artwork: bytes live outside observation; views observe `artworkGeneration`, which moves
    // when bytes arrive.
    private var artworkGeneration = 0
    @ObservationIgnored private var artworkCache = ArtworkCache()
    @ObservationIgnored private var artworkRequests: Set<ArtworkCache.Key> = []

    @ObservationIgnored private var loadsInFlight: Set<ListKey> = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // Optimistic values held until the backend echoes them (or they go stale).
    @ObservationIgnored private var pendingVolume: [SpeakerID: Pending<Double>] = [:]
    @ObservationIgnored private var pendingTrim: [SpeakerID: Pending<Int>] = [:]
    @ObservationIgnored private var pendingMaster: Pending<Double>?
    @ObservationIgnored private var flushes: [String: Task<Void, Never>] = [:]

    private struct Pending<Value: Equatable> {
        var value: Value
        var at: Date
        var isStale: Bool { Date().timeIntervalSince(at) > HubModel.echoWindow }
    }

    /// The paged lists, as keys for in-flight bookkeeping.
    enum ListKey: Hashable, Sendable {
        case songs, playlists, upNext, files, spotifyHistory, search, playlist
    }

    /// Lists already in hand, for snapshots and previews that render without fetching.
    struct Preload {
        var songs: [TrackItem] = []
        var playlists: [PlaylistItem] = []
        var upNext: [QueueItem] = []
        var files: [TrackItem] = []
        var spotifyHistory: [TrackItem] = []
    }

    nonisolated static let throttle: Duration = .milliseconds(50)
    nonisolated static let echoWindow: TimeInterval = 0.5
    nonisolated static let searchDebounce: Duration = .milliseconds(250)
    /// Artwork is requested at this size unless a view asks for another.
    nonisolated static let defaultArtworkPixels = 600

    init(backend: HubBackend) {
        self.backend = backend
        (commandStream, commands) = AsyncStream.makeStream(of: HubCommand.self)
    }

    /// For snapshots and previews: start from a fixed state without subscribing.
    convenience init(backend: HubBackend, state: HubState, preload: Preload = Preload(),
                     artwork: [ArtworkID: Data] = [:], levels: StereoLevels = .silent, browsing: SourceKind? = nil,
                     section: LibrarySection? = nil) {
        self.init(backend: backend)
        apply(state)
        let r = state.content
        songs = PagedList(items: preload.songs, revision: r.library)
        playlists = PagedList(items: preload.playlists, revision: r.library)
        upNext = PagedList(items: preload.upNext, revision: r.upNext)
        files = PagedList(items: preload.files, revision: r.files)
        spotifyHistory = PagedList(items: preload.spotifyHistory, revision: r.spotifyHistory)
        for (id, data) in artwork {
            artworkCache.insert(data, for: .init(id: id, maxPixel: Self.defaultArtworkPixels))
        }
        self.levels = levels
        if let browsing { browsingSource = browsing }
        if let section { librarySection = section }
    }

    func start() {
        guard tasks.isEmpty else { return }
        let backend = backend
        let commandStream = commandStream
        tasks.append(Task { [weak self] in
            for await s in await backend.states() { self?.apply(s) }
        })
        tasks.append(Task { [weak self] in
            for await levels in await backend.levels() { self?.levels = levels }
        })
        tasks.append(Task { [weak self] in
            for await a in await backend.availability() {
                guard let self else { return }
                if self.availability != a { withAnimation(self.structural) { self.availability = a } }
            }
        })
        // One consumer, so commands reach the backend in the order they were made.
        tasks.append(Task { [weak self] in
            for await command in commandStream {
                do { try await backend.perform(command) } catch {
                    self?.refused(command, error)
                }
            }
        })
        for key in [ListKey.songs, .playlists, .upNext, .files, .spotifyHistory] { loadFirstPage(key) }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        searchTask?.cancel()
    }

    // MARK: Applying backend state

    private var structural: Animation { MC.Motion.state(reduceMotion) }

    private func apply(_ s: HubState) {
        // A network client may deliver a state late; never step backwards.
        if s.revision < published.revision, published.revision != 0 { return }
        published = s
        applySpeakers(s)
        applyPlayback(s)
        if capture != s.capture { withAnimation(structural) { capture = s.capture } }
        if spotify != s.spotify { spotify = s.spotify }
        if health != s.health { withAnimation(structural) { health = s.health } }
        if queue != s.queue { queue = s.queue }
        if pins != s.pins { withAnimation(structural) { pins = s.pins } }
        applyContent(s.content)
    }

    private func applySpeakers(_ s: HubState) {
        var incoming = s.speakers
        for i in incoming.indices {
            let id = incoming[i].id
            if let p = pendingVolume[id] {
                if p.value == incoming[i].volume || p.isStale { pendingVolume[id] = nil }
                else { incoming[i].volume = p.value }
            }
            if let p = pendingTrim[id] {
                if p.value == incoming[i].syncTrimMs || p.isStale { pendingTrim[id] = nil }
                else { incoming[i].syncTrimMs = p.value }
            }
        }
        var master = s.masterVolume
        if let p = pendingMaster {
            if p.value == master || p.isStale { pendingMaster = nil } else { master = p.value }
        }

        // A speaker found or lost moves its neighbours; a state or volume change animates in its row.
        if speakers.map(\.id) != incoming.map(\.id) {
            withAnimation(structural) { speakers = incoming }
        } else if speakers != incoming {
            speakers = incoming
        }
        if masterVolume != master { masterVolume = master }
        if isDiscovering != s.isDiscovering { withAnimation(structural) { isDiscovering = s.isDiscovering } }
    }

    private func applyPlayback(_ s: HubState) {
        let newTrack = nowPlaying?.identity != s.nowPlaying?.identity
        if newTrack || activeSource != s.activeSource {
            withAnimation(structural) {
                activeSource = s.activeSource
                nowPlaying = s.nowPlaying
                transport = s.transport
            }
        } else {
            if nowPlaying != s.nowPlaying { nowPlaying = s.nowPlaying }
            if transport != s.transport { transport = s.transport }
        }
    }

    /// Lists whose revision moved start again from their first page.
    private func applyContent(_ r: ContentRevisions) {
        let old = content
        content = r
        if r.library != old.library {
            songs.invalidate(revision: r.library); loadFirstPage(.songs)
            playlists.invalidate(revision: r.library); loadFirstPage(.playlists)
            if !searchQuery.isEmpty { searchResults.invalidate(revision: r.library); loadFirstPage(.search) }
            if openPlaylistID != nil { playlistTracks.invalidate(revision: r.library); loadFirstPage(.playlist) }
        }
        if r.upNext != old.upNext { upNext.invalidate(revision: r.upNext); loadFirstPage(.upNext) }
        if r.files != old.files { files.invalidate(revision: r.files); loadFirstPage(.files) }
        if r.spotifyHistory != old.spotifyHistory {
            spotifyHistory.invalidate(revision: r.spotifyHistory); loadFirstPage(.spotifyHistory)
        }
    }

    /// A command was refused: drop optimistic edits and show the last state the backend published.
    private func refused(_ command: HubCommand, _ error: Error) {
        pendingVolume.removeAll(); pendingTrim.removeAll(); pendingMaster = nil
        let last = published
        applySpeakers(last)
        applyPlayback(last)
        if capture != last.capture { withAnimation(structural) { capture = last.capture } }
        switch command.category {
        case .speaker: break
        case .transport:
            alert = HubAlert(title: "Couldn\u{2019}t control playback", message: error.localizedDescription)
        case .source:
            alert = HubAlert(title: "Couldn\u{2019}t switch source", message: error.localizedDescription)
        case .queue:
            // An optimistic edit of Up Next goes back to what the hub has.
            upNext.invalidate(revision: content.upNext &+ 1)
            upNext.invalidate(revision: content.upNext)
            loadFirstPage(.upNext)
            alert = HubAlert(title: "Couldn\u{2019}t change the queue", message: error.localizedDescription)
        }
    }

    // MARK: Artwork

    /// Cached artwork bytes; a miss asks the backend once and fills the cache when it answers.
    /// Safe to call from a view body.
    func artwork(_ id: ArtworkID?, maxPixel: Int = HubModel.defaultArtworkPixels) -> Data? {
        guard let id else { return nil }
        _ = artworkGeneration   // observe arrivals
        let key = ArtworkCache.Key(id: id, maxPixel: maxPixel)
        if let hit = artworkCache.data(for: key) { return hit }
        if !artworkRequests.contains(key) {
            artworkRequests.insert(key)
            let backend = backend
            Task { [weak self] in
                let data = await backend.artwork(id: id, maxPixel: maxPixel)
                // An unknown id stays marked as requested, so it is not asked for on every render.
                guard let self, let data else { return }
                self.artworkRequests.remove(key)
                self.artworkCache.insert(data, for: key)
                self.artworkGeneration &+= 1
            }
        }
        return nil
    }

    // MARK: Paged lists

    /// Call as rows appear: fetches the next page when `itemID` is near the end of `list`.
    func loadMoreIfNeeded(_ list: ListKey, after itemID: String) {
        let near: Bool
        switch list {
        case .songs: near = songs.shouldLoadMore(after: itemID)
        case .playlists: near = playlists.shouldLoadMore(after: itemID)
        case .upNext: near = upNext.shouldLoadMore(after: itemID)
        case .files: near = files.shouldLoadMore(after: itemID)
        case .spotifyHistory: near = spotifyHistory.shouldLoadMore(after: itemID)
        case .search: near = searchResults.shouldLoadMore(after: itemID)
        case .playlist: near = playlistTracks.shouldLoadMore(after: itemID)
        }
        if near { loadNextPage(list) }
    }

    /// Searches the library, debounced; an empty query clears the results.
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != searchQuery else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.searchQuery = q
            self.searchResults = PagedList(revision: self.content.library)
            if !q.isEmpty { self.loadFirstPage(.search) }
        }
    }

    func openPlaylist(_ id: String) {
        guard openPlaylistID != id else { return }
        openPlaylistID = id
        playlistTracks = PagedList(revision: content.library)
        loadFirstPage(.playlist)
    }

    private func loadFirstPage(_ key: ListKey) {
        // A first page supersedes whatever page was in flight.
        loadsInFlight.remove(key)
        loadNextPage(key, first: true)
    }

    private func loadNextPage(_ key: ListKey, first: Bool = false) {
        guard !loadsInFlight.contains(key) else { return }
        let backend = backend
        switch key {
        case .songs: fetch(key, \.songs, first: first) { try await backend.songs($0) }
        case .playlists: fetch(key, \.playlists, first: first) { try await backend.playlists($0) }
        case .upNext: fetch(key, \.upNext, first: first) { try await backend.upNext($0) }
        case .files: fetch(key, \.files, first: first) { try await backend.files($0) }
        case .spotifyHistory: fetch(key, \.spotifyHistory, first: first) { try await backend.spotifyHistory($0) }
        case .search:
            let q = searchQuery
            guard !q.isEmpty else { return }
            fetch(key, \.searchResults, first: first, while: { [weak self] in self?.searchQuery == q }) {
                try await backend.search(q, $0)
            }
        case .playlist:
            guard let id = openPlaylistID else { return }
            fetch(key, \.playlistTracks, first: first, while: { [weak self] in self?.openPlaylistID == id }) {
                try await backend.tracks(inPlaylist: id, $0)
            }
        }
    }

    /// Fetches the first or next page into `list`. The page is dropped if, when it arrives, the
    /// list moved to another revision or `stillWanted` says its query or playlist changed.
    private func fetch<Item>(_ key: ListKey, _ list: ReferenceWritableKeyPath<HubModel, PagedList<Item>>, first: Bool,
                             while stillWanted: @escaping @MainActor () -> Bool = { true },
                             _ load: @escaping @Sendable (PageRequest) async throws -> Page<Item>) {
        let current = self[keyPath: list]
        guard let request = first ? PageRequest.first : current.nextRequest() else { return }
        let revision = current.revision
        loadsInFlight.insert(key)
        Task { [weak self] in
            let page = try? await load(request)
            guard let self else { return }
            self.loadsInFlight.remove(key)
            // Errors (no permission yet, hub gone) leave the list as it was; `health` explains why.
            guard let page, stillWanted() else { return }
            var updated = self[keyPath: list]
            guard updated.receive(page, for: request, revision: revision) else { return }
            if request.cursor == nil, self[keyPath: list].items.map(\.id) != updated.items.map(\.id) {
                withAnimation(self.structural) { self[keyPath: list] = updated }
            } else {
                self[keyPath: list] = updated
            }
        }
    }

    // MARK: Derived

    var networkSpeakers: [SpeakerItem] { speakers.filter { $0.transport.isNetwork } }
    var localSpeakers: [SpeakerItem] { speakers.filter { !$0.transport.isNetwork } }
    var enabledCount: Int { speakers.filter(\.isEnabled).count }
    var capturableApps: [CapturableApp] { capture.apps }
    var capturedAppID: String? { capture.capturedAppID }

    func speaker(_ id: SpeakerID) -> SpeakerItem? { speakers.first { $0.id == id } }

    struct SpeakerCounts: Equatable {
        var playing = 0, ready = 0, connecting = 0, failed = 0
        var isEmpty: Bool { playing + ready + connecting + failed == 0 }
    }

    var speakerCounts: SpeakerCounts {
        var c = SpeakerCounts()
        for s in speakers {
            switch s.state {
            case .playing: c.playing += 1
            case .ready: c.ready += 1
            case .connecting: c.connecting += 1
            case .failed: c.failed += 1
            case .off: break
            }
        }
        return c
    }

    var canPlay: Bool { activeSource != nil && nowPlaying != nil }
    var hasPosition: Bool { (activeSource?.hasPosition ?? false) && nowPlaying?.duration != nil }
    var needsLocalNetwork: Bool { health.permission(.localNetwork) == .denied }

    // MARK: Intents

    func togglePlayPause() {
        guard canPlay else { return }
        let playing = transport.isPlaying
        transport.position = transport.position(at: .now)
        transport.positionAsOf = .now
        transport.isPlaying.toggle()
        send(playing ? .pause : .play)
    }

    func next() { send(.next) }
    func previous() { send(.previous) }

    func seek(to position: TimeInterval) {
        transport.position = position
        transport.positionAsOf = .now
        send(.seek(position: position))
    }

    func setEnabled(_ enabled: Bool, for id: SpeakerID) {
        mutateSpeaker(id) {
            $0.isEnabled = enabled
            $0.state = enabled ? .connecting : .off
        }
        send(.setSpeakerEnabled(id: id, enabled: enabled))
    }

    func toggle(_ id: SpeakerID) {
        guard let s = speaker(id) else { return }
        setEnabled(!s.isEnabled, for: id)
    }

    /// Called at drag rate. The row moves at once; the backend hears at most every 50 ms.
    /// Works while the speaker is off: the value is its preset.
    func setVolume(_ volume: Double, for id: SpeakerID) {
        let v = volume.clamped(to: 0...1)
        mutateSpeaker(id) { $0.volume = v }
        pendingVolume[id] = Pending(value: v, at: .now)
        throttle("volume.\(id)") { [weak self] in self?.sendVolume(id) }
    }

    /// The end of a drag: send the final value now.
    func commitVolume(for id: SpeakerID) {
        flush("volume.\(id)") { [weak self] in self?.sendVolume(id) }
    }

    private func sendVolume(_ id: SpeakerID) {
        guard let v = pendingVolume[id]?.value else { return }
        pendingVolume[id]?.at = .now
        send(.setSpeakerVolume(id: id, volume: v))
    }

    func nudgeVolume(_ delta: Double, for id: SpeakerID) {
        guard let s = speaker(id) else { return }
        setVolume(s.volume + delta, for: id)
        commitVolume(for: id)
    }

    func setSyncTrim(_ ms: Int, for id: SpeakerID) {
        let v = ms.clamped(to: SpeakerItem.syncTrimRange)
        mutateSpeaker(id) { $0.syncTrimMs = v }
        pendingTrim[id] = Pending(value: v, at: .now)
        throttle("trim.\(id)") { [weak self] in self?.sendTrim(id) }
    }

    func commitSyncTrim(for id: SpeakerID) {
        flush("trim.\(id)") { [weak self] in self?.sendTrim(id) }
    }

    private func sendTrim(_ id: SpeakerID) {
        guard let v = pendingTrim[id]?.value else { return }
        pendingTrim[id]?.at = .now
        send(.setSpeakerSyncTrim(id: id, milliseconds: v))
    }

    func retry(_ id: SpeakerID) {
        mutateSpeaker(id) { $0.state = .connecting }
        send(.retrySpeaker(id: id))
    }

    func setMasterVolume(_ volume: Double) {
        let v = volume.clamped(to: 0...1)
        masterVolume = v
        pendingMaster = Pending(value: v, at: .now)
        throttle("master") { [weak self] in self?.sendMaster() }
    }

    func commitMasterVolume() {
        flush("master") { [weak self] in self?.sendMaster() }
    }

    private func sendMaster() {
        guard let v = pendingMaster?.value else { return }
        pendingMaster?.at = .now
        send(.setMasterVolume(volume: v))
    }

    func nudgeMasterVolume(_ delta: Double) {
        setMasterVolume(masterVolume + delta)
        commitMasterVolume()
    }

    func selectSource(_ source: SourceKind) {
        browsingSource = source
        send(.selectSource(source: source))
    }

    func playTrack(_ id: String, context: TrackContext) { send(.playTrack(id: id, context: context)) }
    func playPlaylist(_ id: String, shuffled: Bool = false) { send(.playPlaylist(id: id, shuffled: shuffled)) }

    // MARK: Queue

    /// Plays an Up Next entry now (the entries before it are dropped).
    func playQueued(_ entryID: String) {
        withAnimation(structural) { upNext.removeThrough(entryID) }
        send(.playTrack(id: entryID, context: .upNext))
    }

    func playNext(_ tracks: [TrackItem], from source: SourceKind) {
        send(.addToQueue(tracks: tracks, source: source, placement: .next))
    }

    func addToQueue(_ tracks: [TrackItem], from source: SourceKind) {
        send(.addToQueue(tracks: tracks, source: source, placement: .last))
    }

    /// A pasted `open.spotify.com/track/…` link. Returns false (sending nothing) when the text
    /// isn't one, so the field can say so at once.
    @discardableResult
    func addSpotifyLink(_ text: String, placement: QueuePlacement = .last) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeSpotifyLink(t, kind: "track") else { return false }
        send(.addSpotifyLink(link: t, placement: placement))
        return true
    }

    func removeFromQueue(_ ids: [String]) {
        withAnimation(structural) { upNext.removeAll(ids: Set(ids)) }
        send(.removeFromQueue(ids: ids))
    }

    /// SwiftUI's `onMove`: the rows move at once, the hub hears the same move.
    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        let ids = offsets.compactMap { upNext.items.indices.contains($0) ? upNext.items[$0].id : nil }
        guard !ids.isEmpty else { return }
        upNext.move(fromOffsets: offsets, toOffset: destination)
        send(.moveInQueue(ids: ids, toOffset: destination))
    }

    func clearQueue() {
        withAnimation(structural) { upNext.removeAll(ids: Set(upNext.items.map(\.id))) }
        send(.clearQueue)
    }

    // MARK: Pins

    func isPinned(_ playlistID: String) -> Bool { pins.contains { $0.id == playlistID } }

    func pin(_ playlistID: String) { send(.pinPlaylist(id: playlistID)) }

    /// A pasted `open.spotify.com/playlist/…` link. Returns false when the text isn't one.
    @discardableResult
    func pinSpotifyLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeSpotifyLink(t, kind: "playlist") else { return false }
        send(.pinSpotifyLink(link: t))
        return true
    }

    func unpin(_ playlistID: String) {
        withAnimation(structural) { pins.removeAll { $0.id == playlistID } }
        send(.unpinPlaylist(id: playlistID))
    }

    /// A first check before sending; the hub checks properly.
    nonisolated static func looksLikeSpotifyLink(_ text: String, kind: String) -> Bool {
        text.hasPrefix("spotify:\(kind):") || text.contains("open.spotify.com/\(kind)/")
            || (text.contains("open.spotify.com/") && text.contains("/\(kind)/"))
    }

    func captureApp(_ bundleID: String) {
        withAnimation(structural) { capture.capturedAppID = bundleID }
        send(.captureApp(bundleID: bundleID))
    }

    func addFiles(_ urls: [URL]) { send(.addFiles(urls: urls)) }
    func removeFiles(_ ids: [String]) { send(.removeFiles(ids: ids)) }
    func openSpotify() { send(.openSpotify) }
    func requestPermission(_ p: HubPermission) { send(.requestPermission(permission: p)) }

    // MARK: Plumbing

    private func mutateSpeaker(_ id: SpeakerID, _ change: (inout SpeakerItem) -> Void) {
        guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        change(&speakers[i])
    }

    private func send(_ command: HubCommand) {
        commands.yield(command)
    }

    /// Runs `action` at most once per throttle interval, on the trailing edge.
    private func throttle(_ key: String, _ action: @escaping @MainActor () -> Void) {
        guard flushes[key] == nil else { return }
        flushes[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.throttle)
            guard !Task.isCancelled else { return }
            self?.flushes[key] = nil
            action()
        }
    }

    private func flush(_ key: String, _ action: @MainActor () -> Void) {
        flushes[key]?.cancel()
        flushes[key] = nil
        action()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
