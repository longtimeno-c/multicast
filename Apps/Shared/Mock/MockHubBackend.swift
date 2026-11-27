import Foundation
import MulticastHubModel

/// A believable hub with no audio behind it: speakers are discovered over the first couple of
/// seconds and take about a second to connect, Patio fails once with a reason, the neighbour's
/// HomePod and the upstairs Apple TV turn the hub away (Check Again lets the Apple TV in),
/// levels move while playing, tracks advance at their end. Compiles for macOS and iOS.
actor MockHubBackend: HubBackend {
    private nonisolated let broadcaster: HubStateBroadcaster
    private var state: HubState {
        get { broadcaster.state }
    }
    private var content: MockContent
    private var levelSubs: [UUID: AsyncStream<StereoLevels>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var connecting: [SpeakerID: Task<Void, Never>] = [:]
    private var patioAttempts = 0
    /// Turned-away speakers that let the hub in when asked again.
    private var admittedAfterCheck: Set<SpeakerID> = []
    private var phase: Double = 0

    // Drawn on the main thread by the caller so the actor never touches drawing.
    private let spotifyTracks: [TrackItem]
    private let appInfo: [String: NowPlayingInfo]
    private let artworkStore: [ArtworkID: Data]
    private var spotifyIndex = 0
    private var queueSerial = 100
    /// Speakers still to be "found" by the live mock's discovery.
    private var undiscovered: [SpeakerItem] = []

    init(state: HubState, content: MockContent, artwork: [ArtworkID: Data], discoverGradually: Bool = false) {
        var s = state
        var later: [SpeakerItem] = []
        if discoverGradually {
            later = s.speakers
            s.speakers = []
            s.isDiscovering = true
        }
        self.broadcaster = HubStateBroadcaster(s)
        self.content = content
        self.undiscovered = later
        self.spotifyTracks = MockData.spotifyTracks
        self.appInfo = Dictionary(uniqueKeysWithValues: MockData.apps.map { ($0.id, MockData.nowPlaying(app: $0)) })
        self.artworkStore = artwork
    }

    /// The live app starts with Apple Music cued up and paused, and finds the house's speakers
    /// one by one over the first two seconds, all off.
    @MainActor static func live() -> MockHubBackend {
        var s = MockData.baseState
        let content = MockData.baseContent
        s.activeSource = .appleMusic
        s.nowPlaying = MockData.nowPlaying(content.songs[0])
        s.transport = TransportState(isPlaying: false, position: 0, positionAsOf: .now)
        let backend = MockHubBackend(state: s, content: content, artwork: MockData.artwork, discoverGradually: true)
        Task { await backend.runDiscovery() }
        return backend
    }

    private func update(_ change: (inout HubState) -> Void) {
        broadcaster.update(change)
    }

    private func runDiscovery() async {
        // Local outputs are known at once; network speakers answer Bonjour over a moment.
        let local = undiscovered.filter { !$0.transport.isNetwork }
        let network = undiscovered.filter { $0.transport.isNetwork }
        update { $0.speakers = local }
        for speaker in network {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 250...600)))
            update { s in
                let networkCount = s.speakers.filter { $0.transport.isNetwork }.count
                s.speakers.insert(speaker, at: networkCount)
            }
        }
        update { $0.isDiscovering = false }
    }

    // MARK: State and queries

    nonisolated func states() async -> AsyncStream<HubState> { broadcaster.stream() }

    func levels() -> AsyncStream<StereoLevels> {
        let (stream, continuation) = AsyncStream.makeStream(of: StereoLevels.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        levelSubs[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropLevels(id) } }
        continuation.yield(.silent)
        return stream
    }

    private func dropLevels(_ id: UUID) { levelSubs[id] = nil }

    func artwork(id: ArtworkID, maxPixel: Int) -> Data? { artworkStore[id] }

    func playlists(_ page: PageRequest) -> Page<PlaylistItem> { .slice(content.playlists, page) }

    func tracks(inPlaylist playlistID: String, _ page: PageRequest) throws -> Page<TrackItem> {
        guard let list = content.playlistTracks[playlistID] else {
            throw HubCommandError(.notFound, "That playlist is no longer in your library.")
        }
        return .slice(list, page)
    }

    func songs(_ page: PageRequest) throws -> Page<TrackItem> {
        guard state.health.permission(.appleMusic) == .granted else {
            throw HubCommandError(.permissionMissing, "Allow Apple Music access to see your library.")
        }
        return .slice(content.songs, page)
    }

    func search(_ query: String, _ page: PageRequest) -> Page<TrackItem> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .empty }
        let hits = content.songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        return .slice(hits, page)
    }

    func searchCatalog(_ query: String, _ page: PageRequest) throws -> Page<TrackItem> {
        guard state.health.permission(.appleMusic) == .granted else {
            throw HubCommandError(.permissionMissing, "Allow Apple Music access to search the catalog.")
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .empty }
        let hits = MockData.catalogSongs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
        return .slice(hits, page)
    }

    func upNext(_ page: PageRequest) -> Page<QueueItem> { .slice(content.upNext, page) }
    func files(_ page: PageRequest) -> Page<TrackItem> { .slice(content.files, page) }
    func spotifyHistory(_ page: PageRequest) -> Page<TrackItem> { .slice(content.spotifyHistory, page) }

    private func publish(_ levels: StereoLevels) {
        for c in levelSubs.values { c.yield(levels) }
    }

    // MARK: Commands

    func perform(_ command: HubCommand) throws {
        switch command {
        case .play: play()
        case .pause: pause()
        case .next: step(1)
        case .previous:
            if state.transport.position(at: .now) > 3 { seek(to: 0) } else { step(-1) }
        case .seek(let position): seek(to: position)
        case .selectSource(let source): try selectSource(source)
        case .playTrack(let id, let context): try playTrack(id: id, context: context)
        case .playPlaylist(let id, let shuffled):
            if id.hasPrefix("spotify:") {
                load(MockData.nowPlaying(spotifyTracks[spotifyIndex]), source: .spotify)
                update { $0.queue.isHeld = !self.content.upNext.isEmpty; $0.queue.currentID = nil }
                play()
                return
            }
            guard var list = content.playlistTracks[id], !list.isEmpty else {
                throw HubCommandError(.notFound, "That playlist is empty.")
            }
            if shuffled { list.shuffle() }
            startQueue(list, source: .appleMusic, at: 0)
        case .addToQueue(let tracks, let source, let placement):
            let items = tracks.map { t -> QueueItem in
                queueSerial += 1
                return QueueItem(id: "q\(queueSerial)", source: source, track: t)
            }
            if placement == .next { content.upNext.insert(contentsOf: items, at: 0) } else { content.upNext.append(contentsOf: items) }
            queueChanged()
        case .addSpotifyLink(let link, let placement):
            guard link.contains("track") else { throw HubCommandError(.notFound, "That isn\u{2019}t a link to a Spotify song.") }
            queueSerial += 1
            let item = QueueItem(id: "q\(queueSerial)", source: .spotify, track: TrackItem(
                id: "spotify:track:shared\(queueSerial)", title: "Shared song", artist: "Spotify", album: "", duration: 200))
            if placement == .next { content.upNext.insert(item, at: 0) } else { content.upNext.append(item) }
            queueChanged()
        case .removeFromQueue(let ids):
            content.upNext.removeAll { ids.contains($0.id) }
            queueChanged()
        case .moveInQueue(let ids, let offset):
            let set = Set(ids)
            let moving = content.upNext.filter { set.contains($0.id) }
            let target = min(max(0, offset), content.upNext.count)
            let before = content.upNext[..<target].filter { set.contains($0.id) }.count
            content.upNext.removeAll { set.contains($0.id) }
            content.upNext.insert(contentsOf: moving, at: target - before)
            queueChanged()
        case .setShuffle(let on):
            if on { content.upNext.shuffle() }
            update { $0.queue.isShuffled = on }
            queueChanged()
        case .clearQueue:
            content.upNext.removeAll()
            queueChanged()
        case .pinPlaylist(let id):
            guard let p = content.playlists.first(where: { $0.id == id }), state.pins.count < PinnedPlaylist.limit,
                  !state.pins.contains(where: { $0.id == id }) else { return }
            update { $0.pins.append(PinnedPlaylist(id: p.id, source: .appleMusic, name: p.name, artworkID: p.artworkID,
                                                   trackCount: p.trackCount)) }
        case .pinSpotifyLink(let link):
            guard link.contains("playlist") else { throw HubCommandError(.notFound, "That isn\u{2019}t a link to a Spotify playlist.") }
            queueSerial += 1
            update { $0.pins.append(PinnedPlaylist(id: "spotify:playlist:shared\(self.queueSerial)", source: .spotify,
                                                   name: "Shared playlist", artworkID: MockArtwork.id(.split))) }
        case .unpinPlaylist(let id):
            update { $0.pins.removeAll { $0.id == id } }
        case .captureApp(let bundleID): try captureApp(bundleID: bundleID)
        case .addFiles(let urls): addFiles(urls)
        case .removeFiles(let ids):
            content.files.removeAll { ids.contains($0.id) }
            update { $0.content.files &+= 1 }
        case .openSpotify:
            update {
                $0.spotify = .running
                $0.health.issues.removeAll { $0.blocks(.spotify) && !$0.isPermission }
            }
        case .requestPermission(let permission):
            // The mock grants whatever is asked; a real backend shows the system prompt.
            update {
                $0.health.permissions[permission] = .granted
                $0.health.issues.removeAll { $0 == .permissionMissing(permission: permission, status: .notDetermined)
                    || $0 == .permissionMissing(permission: permission, status: .denied) }
                if permission == .appleMusic { $0.content.library &+= 1 }
            }
            if permission == .appleMusic, content.songs.isEmpty {
                let base = MockData.baseContent
                content.songs = base.songs
                content.playlists = base.playlists
                content.playlistTracks = base.playlistTracks
                content.upNext = base.upNext
                update { $0.content.upNext &+= 1 }
            }
        case .setSpeakerEnabled(let id, let enabled): setSpeaker(id, enabled: enabled)
        case .setSpeakerVolume(let id, let volume): mutateSpeaker(id) { $0.volume = volume }
        case .setSpeakerSyncTrim(let id, let ms): mutateSpeaker(id) { $0.syncTrimMs = ms }
        case .retrySpeaker(let id):
            guard let s = state.speaker(id) else { return }
            if s.isRestricted { beginCheckingAccess(id); return }
            guard s.isEnabled else { return }
            beginConnecting(id)
        case .setMasterVolume(let volume): update { $0.masterVolume = volume }
        case .refreshSpeakers: break
        }
    }

    // MARK: Transport

    private func play() {
        update { s in
            if s.activeSource == nil {
                s.activeSource = .appleMusic
                s.nowPlaying = content.songs.first.map(MockData.nowPlaying)
            }
            s.transport.position = s.transport.position(at: .now)
            s.transport.positionAsOf = .now
            s.transport.isPlaying = true
            for i in s.speakers.indices where s.speakers[i].state == .ready {
                s.speakers[i].state = .playing
            }
        }
        startTicker()
    }

    private func pause() {
        update { s in
            s.transport.position = s.transport.position(at: .now)
            s.transport.positionAsOf = .now
            s.transport.isPlaying = false
            for i in s.speakers.indices where s.speakers[i].state == .playing {
                s.speakers[i].state = .ready
            }
        }
        ticker?.cancel()
        ticker = nil
        publish(.silent)
    }

    private func seek(to position: TimeInterval) {
        update {
            $0.transport.position = max(0, position)
            $0.transport.positionAsOf = .now
        }
    }

    private func step(_ delta: Int) {
        switch state.activeSource {
        case .spotify:
            let old = spotifyTracks[spotifyIndex]
            spotifyIndex = (spotifyIndex + delta + spotifyTracks.count) % spotifyTracks.count
            if delta > 0 {
                content.spotifyHistory.insert(old, at: 0)
                update { $0.content.spotifyHistory &+= 1 }
            }
            load(MockData.nowPlaying(spotifyTracks[spotifyIndex]))
        case .appleMusic, .files:
            if delta > 0, !content.upNext.isEmpty {
                let next = content.upNext.removeFirst()
                load(MockData.nowPlaying(next.track), source: next.source)
                update { $0.queue = QueueStatus(currentID: next.id, currentSource: next.source,
                                                upcomingCount: self.content.upNext.count) }
                queueChanged()
                return
            }
            let list = state.activeSource == .files ? content.files : content.songs
            guard !list.isEmpty else { return }
            let i = list.firstIndex { $0.id == state.nowPlaying?.trackID } ?? 0
            load(MockData.nowPlaying(list[(i + delta + list.count) % list.count]))
        case .app, .macOutput, nil:
            return
        }
    }

    private func load(_ info: NowPlayingInfo?, source: SourceKind? = nil) {
        update { s in
            if let source { s.activeSource = source }
            s.nowPlaying = info
            s.transport.position = 0
            s.transport.positionAsOf = .now
            s.transport.canSkip = s.activeSource?.canSkip ?? false
            s.transport.canSeek = s.activeSource?.hasPosition ?? false
        }
    }

    // MARK: Sources

    private func selectSource(_ source: SourceKind) throws {
        guard source != state.activeSource else { return }
        switch source {
        case .appleMusic:
            load(content.songs.first.map(MockData.nowPlaying), source: .appleMusic)
        case .spotify:
            guard state.spotify == .running else { throw HubCommandError(.unavailable, "Spotify isn\u{2019}t open.") }
            load(MockData.nowPlaying(spotifyTracks[spotifyIndex]), source: .spotify)
        case .files:
            guard let first = content.files.first else { throw HubCommandError(.unavailable, "There are no files to play.") }
            load(MockData.nowPlaying(first), source: .files)
        case .app:
            // Choosing the app is a separate step; keep playing what we have until then.
            return
        case .macOutput:
            load(NowPlayingInfo(title: "Mac output", artist: "Playing what the Mac plays", artworkID: nil), source: .macOutput)
        }
    }

    /// Like the hub: playing a song from a list queues everything after it.
    private func playTrack(id: String, context: TrackContext) throws {
        let list: [TrackItem]
        let source: SourceKind
        switch context {
        case .songs: list = content.songs; source = .appleMusic
        case .search(let q): list = search(q, PageRequest(limit: 500)).items; source = .appleMusic
        case .upNext:
            guard let i = content.upNext.firstIndex(where: { $0.id == id }) else {
                throw HubCommandError(.notFound, "That song is no longer in Up Next.")
            }
            let entry = content.upNext[i]
            content.upNext.removeFirst(i + 1)
            load(MockData.nowPlaying(entry.track), source: entry.source)
            update { $0.queue = QueueStatus(currentID: entry.id, currentSource: entry.source, upcomingCount: self.content.upNext.count) }
            queueChanged()
            play()
            return
        case .playlist(let pid): list = content.playlistTracks[pid] ?? []; source = .appleMusic
        case .files: list = content.files; source = .files
        case .spotifyHistory: list = content.spotifyHistory; source = .spotify
        case .catalog(let q): list = try searchCatalog(q, PageRequest(limit: 100)).items; source = .appleMusic
        }
        guard let i = list.firstIndex(where: { $0.id == id }) else {
            throw HubCommandError(.notFound, "That track is no longer available.")
        }
        startQueue(list, source: source, at: i)
    }

    private func startQueue(_ list: [TrackItem], source: SourceKind, at i: Int) {
        content.upNext = list[(i + 1)...].map { t in
            queueSerial += 1
            return QueueItem(id: "q\(queueSerial)", source: source, track: t)
        }
        queueSerial += 1
        let current = "q\(queueSerial)"
        load(MockData.nowPlaying(list[i]), source: source)
        update { $0.queue = QueueStatus(currentID: current, currentSource: source, upcomingCount: self.content.upNext.count) }
        queueChanged()
        play()
    }

    private func queueChanged() {
        let n = content.upNext.count
        update {
            $0.queue.upcomingCount = n
            if n == 0 { $0.queue.isHeld = false }
            $0.content.upNext &+= 1
        }
    }

    private func captureApp(bundleID: String) throws {
        guard let info = appInfo[bundleID] else { throw HubCommandError(.notFound, "That app isn\u{2019}t running.") }
        update { $0.capture.capturedAppID = bundleID }
        load(info, source: .app)
        play()
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            content.files.append(TrackItem(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent,
                                           artist: "File", album: "", duration: 180, artworkID: nil,
                                           format: url.pathExtension.uppercased()))
        }
        update { $0.content.files &+= 1 }
    }

    // MARK: Speakers

    private func mutateSpeaker(_ id: SpeakerID, _ change: @escaping (inout SpeakerItem) -> Void) {
        update { s in
            guard let i = s.speakers.firstIndex(where: { $0.id == id }) else { return }
            change(&s.speakers[i])
        }
    }

    private func setSpeaker(_ id: SpeakerID, enabled: Bool) {
        guard state.speaker(id) != nil else { return }
        connecting[id]?.cancel()
        if enabled {
            mutateSpeaker(id) { $0.isEnabled = true; $0.isRestricted = false; $0.isCheckingAccess = false }
            beginConnecting(id)
        } else {
            mutateSpeaker(id) { $0.isEnabled = false; $0.state = .off }
        }
    }

    private func beginConnecting(_ id: SpeakerID) {
        mutateSpeaker(id) { $0.state = .connecting }
        let fails = id == MockData.patio && patioAttempts == 0
        let delay: Double = fails ? 3.0 : Double.random(in: 0.8...1.3)
        connecting[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.finishConnecting(id, failed: fails)
        }
    }

    /// The neighbour's HomePod always turns the hub away; the upstairs Apple TV's owner lets
    /// the hub in once it has been refused once.
    private static func refuses(_ id: SpeakerID) -> Bool { id == MockData.neighbourHomePod || id == MockData.upstairsTV }

    private func beginCheckingAccess(_ id: SpeakerID) {
        guard connecting[id] == nil else { return }
        mutateSpeaker(id) { $0.isCheckingAccess = true }
        connecting[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.finishCheckingAccess(id)
        }
    }

    private func finishCheckingAccess(_ id: SpeakerID) {
        connecting[id] = nil
        let admitted = id == MockData.upstairsTV
        if admitted { admittedAfterCheck.insert(id) }
        mutateSpeaker(id) {
            $0.state = .off
            $0.isCheckingAccess = false
            $0.isRestricted = !admitted
        }
    }

    private func finishConnecting(_ id: SpeakerID, failed: Bool) {
        guard let s = state.speaker(id), s.isEnabled else { return }
        if Self.refuses(id), !admittedAfterCheck.contains(id) {
            // Turned away: the hub switches it off and lists it apart.
            connecting[id] = nil
            mutateSpeaker(id) { $0.isEnabled = false; $0.state = .off; $0.isRestricted = true }
            return
        }
        if failed { patioAttempts += 1 }
        let playing = state.transport.isPlaying
        mutateSpeaker(id) { $0.state = failed ? .failed(reason: "Not responding") : (playing ? .playing : .ready) }
        connecting[id] = nil
    }

    // MARK: Levels and position

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await self?.tick()
            }
        }
    }

    private func tick() {
        guard state.transport.isPlaying else { return }
        if let d = state.nowPlaying?.duration, state.transport.position(at: .now) >= d {
            step(1)
        }
        let audible = state.speakers.contains { $0.state == .playing }
        guard audible else { publish(.silent); return }
        phase += 0.05
        let master = state.masterVolume
        // Peaks of real music sit around -8 to -14 dBFS with transients above; this wanders there.
        func level(_ offset: Double) -> Float {
            let body = 0.26 + 0.12 * sin(phase * 1.7 + offset) + 0.07 * sin(phase * 5.3 + offset * 2)
            let peak = (body + Double.random(in: -0.05...0.08)) * (0.4 + master)
            return Float(max(0.02, min(0.98, peak)))
        }
        publish(StereoLevels(left: level(0), right: level(0.9)))
    }
}

private extension HubIssue {
    var isPermission: Bool {
        if case .permissionMissing = self { return true }
        return false
    }
}
