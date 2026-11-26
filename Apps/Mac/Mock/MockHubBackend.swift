import AppKit

/// A believable hub with no audio behind it: speakers are discovered over the first couple of
/// seconds and take about a second to connect, Patio fails once with a reason, levels move
/// while playing, tracks advance at their end.
actor MockHubBackend: HubBackend {
    private var state: HubState
    private var published = HubState()
    private var speakerSubs: [UUID: AsyncStream<SpeakersState>.Continuation] = [:]
    private var playbackSubs: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var sourceSubs: [UUID: AsyncStream<SourcesState>.Continuation] = [:]
    private var statusSubs: [UUID: AsyncStream<HubStatus>.Continuation] = [:]
    private var levelSubs: [UUID: AsyncStream<StereoLevels>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var connecting: [SpeakerID: Task<Void, Never>] = [:]
    private var patioAttempts = 0
    private var phase: Double = 0

    // Drawn on the main thread by the caller so the actor never touches AppKit drawing.
    private let spotifyTracks: [TrackItem]
    private let appInfo: [String: NowPlayingInfo]
    private let artworkStore: [ArtworkID: Data]
    private var spotifyIndex = 0
    /// Speakers still to be "found" by the live mock's discovery.
    private var undiscovered: [SpeakerItem] = []

    init(state: HubState, artwork: [ArtworkID: Data], discoverGradually: Bool = false) {
        var s = state
        var later: [SpeakerItem] = []
        if discoverGradually {
            later = s.speakers.speakers
            s.speakers.speakers = []
            s.speakers.isDiscovering = true
        }
        self.state = s
        self.undiscovered = later
        self.spotifyTracks = MockData.spotifyTracks
        self.appInfo = Dictionary(uniqueKeysWithValues: MockData.apps.map { ($0.id, MockData.nowPlaying(app: $0)) })
        self.artworkStore = artwork
        self.published = s
    }

    /// The live app starts with Apple Music cued up and paused, and finds the house's speakers
    /// one by one over the first two seconds, all off.
    @MainActor static func live() -> MockHubBackend {
        var s = MockData.baseState
        s.playback.activeSource = .appleMusic
        s.playback.nowPlaying = MockData.nowPlaying(s.sources.library.songs[0])
        s.playback.transport = TransportState(isPlaying: false, position: 0, positionAsOf: .now)
        let backend = MockHubBackend(state: s, artwork: MockData.artwork, discoverGradually: true)
        Task { await backend.runDiscovery() }
        return backend
    }

    private func runDiscovery() async {
        // Local outputs are known at once; network speakers answer Bonjour over a moment.
        let local = undiscovered.filter { !$0.transport.isNetwork }
        let network = undiscovered.filter { $0.transport.isNetwork }
        state.speakers.speakers = local
        publish()
        for speaker in network {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 250...600)))
            let networkCount = state.speakers.speakers.filter { $0.transport.isNetwork }.count
            state.speakers.speakers.insert(speaker, at: networkCount)
            publish()
        }
        state.speakers.isDiscovering = false
        publish()
    }

    // MARK: Streams

    private func stream<T: Sendable>(_ initial: T, register: (UUID, AsyncStream<T>.Continuation) -> Void) -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream.makeStream(of: T.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        register(id, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        continuation.yield(initial)
        return stream
    }

    private func drop(_ id: UUID) {
        speakerSubs[id] = nil; playbackSubs[id] = nil; sourceSubs[id] = nil
        statusSubs[id] = nil; levelSubs[id] = nil
    }

    func speakerStates() -> AsyncStream<SpeakersState> { stream(state.speakers) { speakerSubs[$0] = $1 } }
    func playbackStates() -> AsyncStream<PlaybackState> { stream(state.playback) { playbackSubs[$0] = $1 } }
    func sourceStates() -> AsyncStream<SourcesState> { stream(state.sources) { sourceSubs[$0] = $1 } }
    func statusStates() -> AsyncStream<HubStatus> { stream(state.status) { statusSubs[$0] = $1 } }
    func levels() -> AsyncStream<StereoLevels> { stream(.silent) { levelSubs[$0] = $1 } }

    func artwork(id: ArtworkID) -> Data? { artworkStore[id] }

    /// Sends each slice that changed since the last publish, and only those.
    private func publish() {
        if state.speakers != published.speakers { for c in speakerSubs.values { c.yield(state.speakers) } }
        if state.playback != published.playback { for c in playbackSubs.values { c.yield(state.playback) } }
        if state.sources != published.sources { for c in sourceSubs.values { c.yield(state.sources) } }
        if state.status != published.status { for c in statusSubs.values { c.yield(state.status) } }
        published = state
    }

    private func publish(_ levels: StereoLevels) {
        for c in levelSubs.values { c.yield(levels) }
    }

    // MARK: Transport

    func play() {
        if state.playback.activeSource == nil {
            state.playback.activeSource = .appleMusic
            state.playback.nowPlaying = state.sources.library.songs.first.map(MockData.nowPlaying)
        }
        let t = state.playback.transport
        state.playback.transport.position = t.position(at: .now)
        state.playback.transport.positionAsOf = .now
        state.playback.transport.isPlaying = true
        for i in state.speakers.speakers.indices where state.speakers.speakers[i].state == .ready {
            state.speakers.speakers[i].state = .playing
        }
        publish()
        startTicker()
    }

    func pause() {
        let t = state.playback.transport
        state.playback.transport.position = t.position(at: .now)
        state.playback.transport.positionAsOf = .now
        state.playback.transport.isPlaying = false
        for i in state.speakers.speakers.indices where state.speakers.speakers[i].state == .playing {
            state.speakers.speakers[i].state = .ready
        }
        ticker?.cancel()
        ticker = nil
        publish()
        publish(.silent)
    }

    func next() { step(1) }
    func previous() {
        if state.playback.transport.position(at: .now) > 3 { seek(to: 0) } else { step(-1) }
    }

    func seek(to position: TimeInterval) {
        state.playback.transport.position = max(0, position)
        state.playback.transport.positionAsOf = .now
        publish()
    }

    private func step(_ delta: Int) {
        switch state.playback.activeSource {
        case .spotify:
            let old = spotifyTracks[spotifyIndex]
            spotifyIndex = (spotifyIndex + delta + spotifyTracks.count) % spotifyTracks.count
            if delta > 0 { state.sources.spotifyHistory.insert(old, at: 0) }
            load(MockData.nowPlaying(spotifyTracks[spotifyIndex]))
        case .appleMusic, .files:
            let list = state.playback.activeSource == .files ? state.sources.files : state.sources.library.songs
            guard !list.isEmpty else { return }
            let i = list.firstIndex { $0.id == state.playback.nowPlaying?.trackID } ?? 0
            load(MockData.nowPlaying(list[(i + delta + list.count) % list.count]))
        case .app, nil:
            return
        }
    }

    private func load(_ info: NowPlayingInfo?) {
        state.playback.nowPlaying = info
        state.playback.transport.position = 0
        state.playback.transport.positionAsOf = .now
        state.playback.transport.canSkip = state.playback.activeSource?.canSkip ?? false
        state.playback.transport.canSeek = state.playback.activeSource?.hasPosition ?? false
        publish()
    }

    // MARK: Sources

    func selectSource(_ source: SourceKind) {
        guard source != state.playback.activeSource else { return }
        switch source {
        case .appleMusic:
            state.playback.activeSource = .appleMusic
            load(state.sources.library.songs.first.map(MockData.nowPlaying))
        case .spotify:
            guard state.sources.spotify == .running else { return }
            state.playback.activeSource = .spotify
            load(MockData.nowPlaying(spotifyTracks[spotifyIndex]))
        case .files:
            guard let first = state.sources.files.first else { return }
            state.playback.activeSource = .files
            load(MockData.nowPlaying(first))
        case .app:
            // Choosing the app is a separate step; keep playing what we have until then.
            return
        }
    }

    func playTrack(id: String) {
        let lib = state.sources.library
        if let t = lib.songs.first(where: { $0.id == id }) ?? lib.upNext.first(where: { $0.id == id }) {
            state.playback.activeSource = .appleMusic
            load(MockData.nowPlaying(t))
        } else if let t = state.sources.files.first(where: { $0.id == id }) {
            state.playback.activeSource = .files
            load(MockData.nowPlaying(t))
        } else { return }
        play()
    }

    func playPlaylist(id: String) {
        guard let first = state.sources.library.songs.first else { return }
        playTrack(id: first.id)
    }

    func captureApp(bundleID: String) {
        guard let info = appInfo[bundleID] else { return }
        state.playback.activeSource = .app
        state.playback.capturedAppID = bundleID
        load(info)
        play()
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            state.sources.files.append(TrackItem(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent,
                                                 artist: "File", album: "", duration: 180, artwork: nil,
                                                 format: url.pathExtension.uppercased()))
        }
        publish()
    }

    func openSpotify() {
        state.sources.spotify = .running
        publish()
    }

    func requestPermission(_ permission: HubPermission) {
        // The mock grants whatever is asked; a real backend shows the system prompt.
        state.status.permissions[permission] = .granted
        if permission == .appleMusic, state.sources.library.songs.isEmpty {
            state.sources.library = MockData.baseState.sources.library
        }
        publish()
    }

    // MARK: Speakers

    func setSpeaker(_ id: SpeakerID, enabled: Bool) {
        guard let i = index(id) else { return }
        connecting[id]?.cancel()
        state.speakers.speakers[i].isEnabled = enabled
        if enabled {
            beginConnecting(id)
        } else {
            state.speakers.speakers[i].state = .off
            publish()
        }
    }

    func retrySpeaker(_ id: SpeakerID) {
        guard let i = index(id), state.speakers.speakers[i].isEnabled else { return }
        beginConnecting(id)
    }

    func setSpeaker(_ id: SpeakerID, volume: Double) {
        guard let i = index(id) else { return }
        state.speakers.speakers[i].volume = volume
        publish()
    }

    func setSpeaker(_ id: SpeakerID, syncTrimMs: Int) {
        guard let i = index(id) else { return }
        state.speakers.speakers[i].syncTrimMs = syncTrimMs
        publish()
    }

    func setMasterVolume(_ volume: Double) {
        state.speakers.masterVolume = volume
        publish()
    }

    private func index(_ id: SpeakerID) -> Int? { state.speakers.speakers.firstIndex { $0.id == id } }

    private func beginConnecting(_ id: SpeakerID) {
        guard let i = index(id) else { return }
        state.speakers.speakers[i].state = .connecting
        publish()
        let fails = id == MockData.patio && patioAttempts == 0
        let delay: Double = fails ? 3.0 : Double.random(in: 0.8...1.3)
        connecting[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.finishConnecting(id, failed: fails)
        }
    }

    private func finishConnecting(_ id: SpeakerID, failed: Bool) {
        guard let i = index(id), state.speakers.speakers[i].isEnabled else { return }
        if failed {
            patioAttempts += 1
            state.speakers.speakers[i].state = .failed(reason: "Not responding")
        } else {
            state.speakers.speakers[i].state = state.playback.transport.isPlaying ? .playing : .ready
        }
        connecting[id] = nil
        publish()
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
        guard state.playback.transport.isPlaying else { return }
        if let d = state.playback.nowPlaying?.duration, state.playback.transport.position(at: .now) >= d {
            step(1)
        }
        let audible = state.speakers.speakers.contains { $0.state == .playing }
        guard audible else { publish(.silent); return }
        phase += 0.05
        // Peaks of real music sit around -8 to -14 dBFS with transients above; this wanders there.
        func level(_ offset: Double) -> Float {
            let body = 0.26 + 0.12 * sin(phase * 1.7 + offset) + 0.07 * sin(phase * 5.3 + offset * 2)
            let peak = (body + Double.random(in: -0.05...0.08)) * (0.4 + state.speakers.masterVolume)
            return Float(max(0.02, min(0.98, peak)))
        }
        publish(StereoLevels(left: level(0), right: level(0.9)))
    }
}
