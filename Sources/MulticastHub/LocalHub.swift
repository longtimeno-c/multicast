import Foundation
import MulticastAppleMusic
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import MulticastKit
import MulticastSources

/// The real hub: a `HubBackend` over MulticastKit's `MulticastSession`.
///
/// - Speakers mirror the session's directory and engine. Enabling selects the speaker's sink
///   live (mid-stream included); volume and sync trim are presets kept while it is off and
///   applied when it joins; two advertisements of one physical receiver are never enabled
///   together (the second shows a failed state saying why). Presets, the enabled set and the
///   master volume persist through `HubSettingsStore`.
/// - The engine runs only while the active source wants to play AND at least one speaker is
///   selected; it stops when the last speaker goes.
/// - Sources: Files (a queue over `FileSource`), Spotify (its audio tapped, muted on the Mac
///   while tapped; now playing and transport over Apple Events), any other app (tapped), and
///   Apple Music through an injected `MusicPlayerProviding`.
/// - State: one `HubStateBroadcaster` (newest-only, current replayed to new subscribers, the
///   revision bumped only on real change). Commands return once accepted; the work they start
///   runs in order on an internal queue and shows up in later states.
public actor LocalHub: HubBackend {
    public struct Configuration: Sendable {
        /// Volume a speaker starts at the first time it is seen.
        public var defaultSpeakerVolume: Double = 0.5
        /// Discovery is reported as finished once the speaker list has been quiet this long…
        public var discoveryQuietSeconds: TimeInterval = 3
        /// …or this long after start at the latest.
        public var discoveryMaxSeconds: TimeInterval = 10
        /// Minimum spacing of published levels (~20 Hz).
        public var levelInterval: TimeInterval = 0.045
        /// Health / app-presence polling period (0 disables the internal timer; tests call `tick()`).
        public var pollSeconds: TimeInterval = 2
        /// `previous` restarts the current file instead when it is further in than this.
        public var restartThreshold: TimeInterval = 3
        public var spotifyHistoryLimit: Int = 200
        /// At quit, how long pausing a playing Spotify or Music may take (the app quits within 5 s).
        public var quitPauseSeconds: TimeInterval = 1.5

        public init() {}
    }

    public static let spotifyBundleID = "com.spotify.client"
    public static let appleMusicUnavailable = "Apple Music isn\u{2019}t available in this version of Multicast yet."
    static let needsSpeaker = "Turn on a speaker first."

    nonisolated let broadcaster: HubStateBroadcaster
    nonisolated let deps: HubDependencies
    public let configuration: Configuration

    // Speakers
    var settings: HubSettings
    private var descriptors: [String: SpeakerDescriptor] = [:]
    private var discoveredOrder: [String] = []
    /// The user's enabled speakers, in the order they were enabled.
    private var enabledOrder: [String] = []
    /// Enabled but refused: same physical receiver as an enabled speaker. id → reason.
    private var blocked: [String: String] = [:]
    /// Enabled but the sink could not be created. id → plain reason.
    private var selectFailures: [String: String] = [:]
    /// Remembered-enabled speakers restored this launch (each at most once).
    private var restored: Set<String> = []
    private var startedAt: Date
    private var lastSpeakerListChange: Date
    private var discovering = false

    // Playback
    var activeSource: SourceKind?
    var wantsPlay = false
    /// Position bookkeeping for sources the hub times itself (files, captured app).
    private var position: TimeInterval = 0
    private var positionAsOf: Date = .distantPast
    /// The source set on the session, and for which kind.
    private var engineSource: AudioSource?
    private var engineSourceKind: SourceKind?
    private var lastEngineTransport: EngineSnapshot.TransportState = .stopped

    // Files
    var queue = FileQueue()
    /// A finished file must be reopened (or seeked) before it plays again.
    var fileNeedsReload = true
    var endingTask: Task<Void, Never>?

    // Play queue (LocalHub+Queue.swift)
    var playQueue = PlayQueue()
    /// Someone played something in Music or Spotify directly: the queue waits.
    var queueHeld = false
    /// The queue is starting a song: the app's play state isn't followed meanwhile.
    var queueAdvancing = false
    var queueStartedAt: Date = .distantPast
    var queueSample: QueueSample?
    var queueEndTimer: Task<Void, Never>?

    // Spotify
    private var spotifyStatus: SpotifyStatus = .notRunning
    var spotifyNow: NowPlaying?
    /// An Apple Music permission request waiting on the person at the Mac.
    private var musicPermissionRequest: Task<Void, Never>?
    private var spotifyObserver: Task<Void, Never>?
    var spotifyHistory: [TrackItem] = []
    /// A running look-up of the Automation permission for Spotify. It can take most of a minute
    /// (the system asks Spotify itself, and a Spotify that stopped handling its scripting only
    /// answers when that times out), so nothing ever waits for it.
    private var spotifyAutomationCheck: Task<Void, Never>?
    /// Bumped whenever the Automation status is learned some other way (a refused command, an
    /// answered prompt); a background check started before that is stale and is ignored.
    private var automationEvidence = 0

    // Captured app
    private var capturable: [CapturableApp] = []
    private var capturedApp: (id: String, name: String)?
    private var captureEvidence: Task<Void, Never>?

    // Apple Music
    private var musicPlayer: MusicPlayerProviding?
    var musicStatus = MusicPlayerStatus()
    private var musicObserver: Task<Void, Never>?
    /// When the last play-a-track command arrived (timing logs).
    private var playRequestedAt: UInt64?

    // Health and content
    private var permissions = PermissionSet()
    var content = ContentRevisions()

    // Levels
    private var levelSubscribers: [UUID: AsyncStream<StereoLevels>.Continuation] = [:]
    private var lastLevelsAt: Date = .distantPast

    // Speaker displays
    private var pushedMetadata: [String: String] = [:]
    private var pushedProgress: [String: String] = [:]
    private var metadataTail: Task<Void, Never>?

    // Work
    private var workTail: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var isStarted = false
    private var isShutDown = false
    private var artwork = ArtworkStore()

    public init(dependencies: HubDependencies, configuration: Configuration = Configuration()) {
        deps = dependencies
        self.configuration = configuration
        let loaded = dependencies.settings.load()
        settings = loaded
        let now = dependencies.now()
        startedAt = now
        lastSpeakerListChange = now
        broadcaster = HubStateBroadcaster(HubState(masterVolume: loaded.masterVolume))
    }

    // MARK: - Lifecycle

    /// Starts discovery, the engine's state streams and the app/permission monitors. Idempotent.
    public func start() {
        guard !isStarted, !isShutDown else { return }
        isStarted = true
        let now = deps.now()
        startedAt = now
        lastSpeakerListChange = now
        discovering = true
        let session = deps.session
        session.setMasterVolume(Float(settings.masterVolume))
        session.start()

        let sessionStates = session.stateUpdates()
        let meters = session.meterUpdates()
        let events = session.eventUpdates()
        let apps = deps.capturableApps.updates()
        let presence = deps.apps.changes()
        tasks.append(Task { [weak self] in for await s in sessionStates { await self?.sessionChanged(s) } })
        tasks.append(Task { [weak self] in for await m in meters { await self?.meter(m) } })
        tasks.append(Task { [weak self] in for await e in events { await self?.engineEvent(e) } })
        tasks.append(Task { [weak self] in for await list in apps { await self?.capturableChanged(list) } })
        tasks.append(Task { [weak self] in for await _ in presence { await self?.refreshApps() } })
        if configuration.pollSeconds > 0 {
            let period = UInt64(configuration.pollSeconds * 1e9)
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: period)
                    await self?.tick()
                }
            })
        }
        refreshApps()
        publish()
        enqueue { [self] in await self.tick() }
    }

    /// Stops playback, releases every speaker and ends all streams. Terminal.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        spotifyObserver?.cancel()
        spotifyAutomationCheck?.cancel()
        musicObserver?.cancel()
        captureEvidence?.cancel()
        endingTask?.cancel()
        queueEndTimer?.cancel()
        musicPermissionRequest?.cancel()
        await workTail?.value
        // Removing the tap unmutes a media app: one still playing would carry on out of the
        // Mac's own speakers. Pause it first, within a bound that fits the app's quit cap.
        await pauseMediaAppForQuit()
        await deps.session.shutdown()
        sendLevels(.silent)
        for c in levelSubscribers.values { c.finish() }
        levelSubscribers.removeAll()
        broadcaster.finish()
    }

    /// Connects the Apple Music player (MulticastAppleMusic). Until then the Apple Music source
    /// and its lists answer `appleMusicUnavailable`.
    public func setMusicPlayer(_ player: MusicPlayerProviding?) async {
        musicObserver?.cancel()
        musicObserver = nil
        musicPlayer = player
        musicStatus = MusicPlayerStatus()
        guard let player else {
            permissions.appleMusic = .notDetermined
            publish()
            return
        }
        permissions.appleMusic = await player.authorizationStatus()
        let updates = player.statusUpdates()
        musicObserver = Task { [weak self] in for await s in updates { await self?.musicChanged(s) } }
        content.library &+= 1
        content.upNext &+= 1
        publish()
    }

    // MARK: - HubBackend: state

    public nonisolated func states() async -> AsyncStream<HubState> { broadcaster.stream() }

    public func levels() async -> AsyncStream<StereoLevels> {
        let (stream, continuation) = AsyncStream.makeStream(of: StereoLevels.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        if isShutDown {
            continuation.finish()
            return stream
        }
        levelSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropLevels(id) } }
        continuation.yield(.silent)
        return stream
    }

    private func dropLevels(_ id: UUID) { levelSubscribers[id] = nil }

    /// The last published state (tests, diagnostics).
    public nonisolated var currentState: HubState { broadcaster.state }

    // MARK: - HubBackend: queries

    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        if id.hasPrefix("hub.icon:") {
            return deps.apps.iconPNG(bundleID: String(id.dropFirst("hub.icon:".count)), maxPixel: maxPixel)
        }
        if id.hasPrefix("hub.url:") {
            if artwork.original(id) == nil {
                // Only URLs this hub put in its own state (Spotify's artwork): a remote must not
                // be able to make the Mac fetch addresses of its choosing.
                guard isMintedArtworkID(id), let url = URL(string: String(id.dropFirst("hub.url:".count))), url.scheme == "https",
                      let data = await deps.system.fetchImage(url) else { return nil }
                artwork.insert(data, for: id)
            }
            return artwork.data(for: id, maxPixel: maxPixel)
        }
        if id.hasPrefix("hub.") { return artwork.data(for: id, maxPixel: maxPixel) }
        return await musicPlayer?.artwork(id: id, maxPixel: maxPixel)
    }

    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> {
        try await requireMusicPlayer().playlists(page)
    }

    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await requireMusicPlayer().tracks(inPlaylist: playlistID, page)
    }

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> { try await requireMusicPlayer().songs(page) }

    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await requireMusicPlayer().search(query, page)
    }

    public func upNext(_ page: PageRequest) async throws -> Page<QueueItem> { queuePage(page) }

    public func files(_ page: PageRequest) async throws -> Page<TrackItem> { .slice(queue.tracks, page) }

    public func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem> { .slice(spotifyHistoryListed(), page) }

    func requireMusicPlayer() throws -> MusicPlayerProviding {
        guard let musicPlayer else { throw HubCommandError(.unavailable, Self.appleMusicUnavailable) }
        return musicPlayer
    }

    // MARK: - HubBackend: commands

    public func perform(_ command: HubCommand) async throws {
        guard !isShutDown else { throw HubCommandError(.unavailable, "The hub has shut down.") }
        let started = MulticastTiming.now
        let name = Self.timingName(command)
        MulticastTiming.log.debug("hub.perform \(name, privacy: .public) begin")
        defer { MulticastTiming.log.debug("hub.perform \(name, privacy: .public) end \(MulticastTiming.ms(since: started))ms") }
        if case .playTrack = command { playRequestedAt = started }
        if case .playPlaylist = command { playRequestedAt = started }
        switch command {
        case .play: try await queueAwarePlay()
        case .pause: await pause()
        case .next: try await queueSkip(forward: true)
        case .previous: try await queueSkip(forward: false)
        case .seek(let p): try await seek(to: p)
        case .selectSource(let s):
            if s != activeSource, s != .app { holdQueue() }
            try await selectSource(s)
        case .playTrack(let id, let context): try await queuePlayTrack(id: id, context: context)
        case .playPlaylist(let id, let shuffled): try await queuePlayPlaylist(id: id, shuffled: shuffled)
        case .captureApp(let bundleID):
            holdQueue()
            try await captureApp(bundleID: bundleID)
        case .addToQueue(let tracks, let source, let placement): try addToQueue(tracks, source: source, placement: placement)
        case .addSpotifyLink(let link, let placement): try await addSpotifyLink(link, placement: placement)
        case .removeFromQueue(let ids): removeFromQueue(ids)
        case .moveInQueue(let ids, let offset): moveInQueue(ids, toOffset: offset)
        case .clearQueue: clearQueue()
        case .pinPlaylist(let id): try await pinPlaylist(id: id)
        case .pinSpotifyLink(let link): try await pinSpotifyLink(link)
        case .unpinPlaylist(let id): unpinPlaylist(id: id)
        case .addFiles(let urls): await addFiles(urls)
        case .removeFiles(let ids): try await removeFiles(ids: ids)
        case .openSpotify: try await openSpotify()
        case .requestPermission(let p): try await requestPermission(p)
        case .setSpeakerEnabled(let id, let enabled): try setSpeaker(id.rawValue, enabled: enabled)
        case .setSpeakerVolume(let id, let volume): try setSpeakerVolume(id.rawValue, volume)
        case .setSpeakerSyncTrim(let id, let ms): try setSpeakerTrim(id.rawValue, ms)
        case .retrySpeaker(let id): try retrySpeaker(id.rawValue)
        case .setMasterVolume(let v): setMaster(v)
        case .refreshSpeakers: refreshSpeakers()
        }
    }

    /// The command's case name, for timing logs (no ids or names).
    static func timingName(_ command: HubCommand) -> String {
        let text = String(describing: command)
        return String(text.prefix { $0 != "(" })
    }

    /// Waits until every queued operation (and any they queued) has run. For tests and live checks.
    public func settle() async {
        while let tail = workTail {
            await tail.value
            if workTail == tail { break }
        }
        while let tail = metadataTail {
            await tail.value
            if metadataTail == tail { break }
        }
        await spotifyAutomationCheck?.value
    }

    func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let previous = workTail
        let enqueued = MulticastTiming.now
        workTail = Task {
            await previous?.value
            let started = MulticastTiming.now
            await op()
            MulticastTiming.log.debug("hub.queue op wait=\((started &- enqueued) / 1_000_000)ms run=\(MulticastTiming.ms(since: started))ms")
        }
    }

    // MARK: - Speakers

    private func preset(for id: String) -> HubSettings.SpeakerPreset {
        settings.speakers[id] ?? HubSettings.SpeakerPreset(volume: configuration.defaultSpeakerVolume)
    }

    private func updatePreset(_ id: String, _ change: (inout HubSettings.SpeakerPreset) -> Void) {
        var p = preset(for: id)
        change(&p)
        settings.speakers[id] = p
        deps.settings.save(settings)
    }

    var hasPlayableSpeaker: Bool {
        enabledOrder.contains { blocked[$0] == nil && selectFailures[$0] == nil }
    }

    private func setSpeaker(_ id: String, enabled: Bool) throws {
        guard descriptors[id] != nil else { throw HubCommandError(.notFound, "That speaker is no longer on the network.") }
        if enabled { enable(id, remember: true) } else { disable(id) }
    }

    private func enable(_ id: String, remember: Bool) {
        guard let d = descriptors[id], !enabledOrder.contains(id) else { return }
        enabledOrder.append(id)
        selectFailures[id] = nil
        if let other = physicalConflict(for: d) {
            blocked[id] = "Same receiver as \u{201C}\(other.name)\u{201D}. Turn that one off to use this one."
            publish()
            return
        }
        blocked[id] = nil
        if remember { updatePreset(id) { $0.isEnabled = true } }
        publish()
        enqueue { [self] in await self.selectNow(id) }
    }

    private func physicalConflict(for d: SpeakerDescriptor) -> SpeakerDescriptor? {
        let others = enabledOrder.filter { $0 != d.id && blocked[$0] == nil }.compactMap { descriptors[$0] }
        return SpeakerMatching.physicalConflict(for: d, among: others)
    }

    private func selectNow(_ id: String) async {
        guard enabledOrder.contains(id), blocked[id] == nil, let d = descriptors[id] else { return }
        let p = preset(for: id)
        do {
            try await deps.session.select(d, volume: Float(p.volume), offsetMillis: p.syncTrimMs)
        } catch {
            selectFailures[id] = FailureWording.plain(String(describing: error))
        }
        guard enabledOrder.contains(id) else {
            // Turned off while the select was in flight.
            await deps.session.deselect(speakerID: id)
            return
        }
        followMediaApp()
        // Presets changed while the select was in flight are applied now.
        let latest = preset(for: id)
        if latest != p {
            deps.session.setVolume(Float(latest.volume), forSpeaker: id)
            deps.session.setOffset(millis: latest.syncTrimMs, forSpeaker: id)
        }
        await reconcileEngine()
        publish()
    }

    /// For a media-app source, the hub plays exactly when the app plays and a speaker is on
    /// (an app that started with no speaker on is picked up when one joins).
    private func followMediaApp() {
        switch activeSource {
        case .appleMusic: wantsPlay = musicStatus.isPlaying && hasPlayableSpeaker
        case .spotify: wantsPlay = spotifyNow?.state == .playing && hasPlayableSpeaker
        default: break
        }
    }

    private func disable(_ id: String) {
        guard enabledOrder.contains(id) else { return }
        enabledOrder.removeAll { $0 == id }
        blocked[id] = nil
        selectFailures[id] = nil
        pushedMetadata[id] = nil
        pushedProgress[id] = nil
        updatePreset(id) { $0.isEnabled = false }
        if !hasPlayableSpeaker, wantsPlay { stopForNoSpeakers() }
        publish()
        enqueue { [self] in
            await self.deps.session.deselect(speakerID: id)
            await self.reconcileEngine()
            await self.publish()
        }
    }

    /// The last speaker went: playback pauses (the media app too) so nothing plays unheard.
    private func stopForNoSpeakers() {
        freezePosition()
        wantsPlay = false
        let source = activeSource
        enqueue { [self] in await self.pauseMediaApp(source) }
    }

    /// Browse again; the list shows it is searching until it settles.
    private func refreshSpeakers() {
        let now = deps.now()
        startedAt = now
        lastSpeakerListChange = now
        discovering = true
        deps.session.refreshSpeakers()
        publish()
    }

    private func retrySpeaker(_ id: String) throws {
        guard descriptors[id] != nil else { throw HubCommandError(.notFound, "That speaker is no longer on the network.") }
        guard enabledOrder.contains(id) else { return }
        if blocked[id] != nil {
            guard let d = descriptors[id], physicalConflict(for: d) == nil else { publish(); return }
            blocked[id] = nil
            updatePreset(id) { $0.isEnabled = true }
            publish()
            enqueue { [self] in await self.selectNow(id) }
        } else if selectFailures[id] != nil {
            selectFailures[id] = nil
            publish()
            enqueue { [self] in await self.selectNow(id) }
        } else {
            enqueue { [self] in
                await self.deps.session.retry(speakerID: id)
                await self.reconcileEngine()
                await self.publish()
            }
        }
    }

    private func setSpeakerVolume(_ id: String, _ volume: Double) throws {
        guard descriptors[id] != nil else { throw HubCommandError(.notFound, "That speaker is no longer on the network.") }
        let v = volume.isFinite ? min(1, max(0, volume)) : 0
        updatePreset(id) { $0.volume = v }
        deps.session.setVolume(Float(v), forSpeaker: id)
        publish()
    }

    private func setSpeakerTrim(_ id: String, _ ms: Int) throws {
        guard descriptors[id] != nil else { throw HubCommandError(.notFound, "That speaker is no longer on the network.") }
        let r = SpeakerItem.syncTrimRange
        let t = min(r.upperBound, max(r.lowerBound, ms))
        updatePreset(id) { $0.syncTrimMs = t }
        deps.session.setOffset(millis: t, forSpeaker: id)
        publish()
    }

    private func setMaster(_ volume: Double) {
        let v = volume.isFinite ? min(1, max(0, volume)) : 0
        settings.masterVolume = v
        deps.settings.save(settings)
        deps.session.setMasterVolume(Float(v))
        publish()
    }

    // MARK: - Session events

    private func sessionChanged(_ s: SessionState) {
        var listChanged = false
        for d in s.speakers where descriptors[d.id] != d {
            descriptors[d.id] = d
            listChanged = true
        }
        let order = s.speakers.map(\.id)
        if order != discoveredOrder {
            discoveredOrder = order
            listChanged = true
        }
        if listChanged { lastSpeakerListChange = deps.now() }
        for d in s.speakers where settings.speakers[d.id]?.isEnabled == true && !restored.contains(d.id) {
            restored.insert(d.id)
            enable(d.id, remember: false)
        }
        if s.engine.transport != lastEngineTransport {
            if lastEngineTransport == .playing { sendLevels(.silent) }
            lastEngineTransport = s.engine.transport
        }
        updateLocalNetworkPermission()
        publish()
    }

    private func meter(_ m: MeterReading) {
        let now = deps.now()
        guard now.timeIntervalSince(lastLevelsAt) >= configuration.levelInterval else { return }
        lastLevelsAt = now
        let master = Float(settings.masterVolume)
        sendLevels(StereoLevels(left: min(1, m.peakLeft * master), right: min(1, m.peakRight * master)))
    }

    private func sendLevels(_ levels: StereoLevels) {
        for c in levelSubscribers.values { c.yield(levels) }
    }

    private func engineEvent(_ e: EngineEvent) {
        switch e {
        case .endOfStream(_, let until):
            fileEnded(audibleUntilHostNanos: until)
        case .sinkJoined(let id, _):
            pushedMetadata[id] = nil
            pushedProgress[id] = nil
            publish()
        case .sinkFailed, .timelineChanged:
            publish()
        }
    }

    // MARK: - Engine policy

    /// Runs the engine exactly when the active source wants to play and a speaker is selected.
    private func reconcileEngine() async {
        let s = deps.session.state
        let hasSpeakers = !s.selectedSpeakerIDs.isEmpty
        let haveSource = engineSource != nil && engineSourceKind == activeSource && activeSource != nil
        let shouldRun = wantsPlay && haveSource && hasSpeakers
        switch s.engine.transport {
        case .playing:
            if !shouldRun {
                if hasSpeakers && haveSource { await deps.session.pause() } else { await stopEngine() }
            }
        case .paused, .stopped:
            if shouldRun {
                await startEngine()
            } else if s.engine.transport == .paused, !hasSpeakers || !haveSource {
                await stopEngine()
            }
        case .ended:
            if shouldRun, endingTask == nil { await startEngine() }
        }
    }

    private func startEngine() async {
        let started = MulticastTiming.now
        defer {
            MulticastTiming.log.debug("hub.engine start took \(MulticastTiming.ms(since: started))ms\(self.playRequestedAt.map { ", \(MulticastTiming.ms(since: $0))ms after play command" } ?? "", privacy: .public)")
        }
        do {
            try await deps.session.play()
            if activeSource == .files || activeSource == .app {
                // Resumed audio is heard one group latency from now.
                positionAsOf = deps.now().addingTimeInterval(deps.session.latencySeconds)
            }
        } catch {
            wantsPlay = false
            freezePosition()
        }
    }

    /// Stops the engine; a file keeps its heard position for the next play.
    private func stopEngine() async {
        let heard = currentPosition()
        await deps.session.stop()
        if engineSourceKind == .files, engineSource != nil {
            try? await deps.session.seek(toSeconds: heard)
        }
    }

    /// Flushes the speakers and re-anchors (after a skip in a live source).
    func reanchor() async {
        guard deps.session.state.engine.transport == .playing else { return }
        await deps.session.pause()
        await startEngine()
    }

    func currentPosition() -> TimeInterval {
        var p = position
        if wantsPlay { p += max(0, deps.now().timeIntervalSince(positionAsOf)) }
        if let d = queue.current?.track.duration, activeSource == .files, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    func freezePosition() {
        position = currentPosition()
        positionAsOf = deps.now()
    }

    func setPosition(_ p: TimeInterval, audibleIn delay: TimeInterval = 0) {
        position = p
        positionAsOf = deps.now().addingTimeInterval(delay)
    }

    private var engineIsPlaying: Bool { deps.session.state.engine.transport == .playing }

    // MARK: - Transport

    func play() async throws {
        if activeSource == nil {
            if !queue.isEmpty { try await selectSource(.files) } else {
                throw HubCommandError(.unavailable, "Choose something to play first.")
            }
        }
        // A media app plays on the Mac meanwhile and is captured once a speaker is on; the hub's
        // own sources have nowhere else to play.
        if activeSource == .files || activeSource == .app, !hasPlayableSpeaker {
            throw HubCommandError(.unavailable, Self.needsSpeaker)
        }
        switch activeSource {
        case .files:
            guard !wantsPlay else { return }
            // Open first: a file that can't be opened leaves the transport stopped.
            if fileNeedsReload { try await loadCurrentFile() }
            guard !wantsPlay else { return }
            freezePosition()
            wantsPlay = true
            positionAsOf = deps.now().addingTimeInterval(deps.session.latencySeconds)
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case .spotify:
            let spotify = deps.spotify
            try await mediaCommand { try await spotify.play() }
            wantsPlay = true
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case .app:
            wantsPlay = true
            setPosition(0)
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case .appleMusic:
            let player = try requireMusicPlayer()
            try await player.play()
            wantsPlay = true
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case nil:
            return
        }
    }

    private func pause() async {
        guard wantsPlay else { return }
        freezePosition()
        wantsPlay = false
        let source = activeSource
        publish()
        enqueue { [self] in
            await self.pauseMediaApp(source)
            await self.reconcileAndPublish()
        }
    }

    private func pauseMediaAppForQuit() async {
        let source = activeSource
        let playing: Bool
        switch source {
        case .spotify:
            playing = (wantsPlay || spotifyNow?.state == .playing) && deps.apps.isRunning(Self.spotifyBundleID)
        case .appleMusic:
            playing = wantsPlay || musicStatus.isPlaying
        default:
            playing = false
        }
        guard playing else { return }
        let seconds = configuration.quitPauseSeconds
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in await self.pauseMediaApp(source) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            await group.next()
            group.cancelAll()
        }
    }

    func pauseMediaApp(_ source: SourceKind?) async {
        switch source {
        case .spotify:
            do { try await deps.spotify.pause() } catch {
                MulticastTiming.log.error("hub.pause Spotify failed: \(String(describing: error), privacy: .public)")
            }
        case .appleMusic: await musicPlayer?.pause()
        default: break
        }
    }

    func reconcileAndPublish() async {
        await reconcileEngine()
        publish()
    }

    func skip(forward: Bool) async throws {
        switch activeSource {
        case .files:
            guard !queue.isEmpty else { throw HubCommandError(.unavailable, "There are no files to play.") }
            if forward {
                if queue.advance() {
                    try await loadCurrentFile()
                } else {
                    // Past the last file: back to the start, stopped (like a CD player).
                    queue.rewind()
                    wantsPlay = false
                    try await loadCurrentFile()
                }
            } else if currentPosition() > configuration.restartThreshold || !queue.goBack() {
                try await seek(to: 0)
                return
            } else {
                try await loadCurrentFile()
            }
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case .spotify:
            let spotify = deps.spotify
            try await mediaCommand {
                if forward { try await spotify.next() } else { try await spotify.previous() }
            }
            enqueue { [self] in
                await self.reanchor()
                await self.publish()
            }
        case .appleMusic:
            let player = try requireMusicPlayer()
            if forward { try await player.next() } else { try await player.previous() }
            enqueue { [self] in
                await self.reanchor()
                await self.publish()
            }
        case .app:
            throw HubCommandError(.unsupported, "A captured app can\u{2019}t skip from here.")
        case nil:
            throw HubCommandError(.unavailable, "Nothing is playing.")
        }
    }

    func seek(to target: TimeInterval) async throws {
        switch activeSource {
        case .files:
            guard let current = queue.current else { throw HubCommandError(.unavailable, "Nothing is playing.") }
            let t = min(max(0, target.isFinite ? target : 0), max(0, current.track.duration))
            setPosition(t, audibleIn: wantsPlay ? deps.session.latencySeconds : 0)
            publish()
            let reload = fileNeedsReload
            enqueue { [self] in
                // While paused the engine holds the not-yet-heard audio for the resume; a seek
                // must drop it, and setting a fresh source is what does (MulticastSession.seek
                // only drops it while playing).
                if reload || self.deps.session.state.engine.transport == .paused {
                    try? await self.loadCurrentFileNow(at: t)
                } else {
                    try? await self.deps.session.seek(toSeconds: t)
                }
                if await self.wantsPlay { await self.setPositionAfterSeek(t) }
                await self.reconcileAndPublish()
            }
        case .appleMusic:
            let player = try requireMusicPlayer()
            guard musicStatus.canSeek else { throw HubCommandError(.unsupported, "This item can\u{2019}t seek.") }
            try await player.seek(to: max(0, target))
            enqueue { [self] in
                await self.reanchor()
                await self.publish()
            }
        case .spotify:
            guard spotifyStatus == .running, spotifyNow?.duration != nil else {
                throw HubCommandError(.unsupported, "This item can\u{2019}t seek.")
            }
            let spotify = deps.spotify
            try await mediaCommand { try await spotify.seek(to: max(0, target)) }
            enqueue { [self] in
                await self.reanchor()
                await self.publish()
            }
        case .app:
            throw HubCommandError(.unsupported, "A live source can\u{2019}t seek.")
        case nil:
            throw HubCommandError(.unavailable, "Nothing is playing.")
        }
    }

    private func setPositionAfterSeek(_ t: TimeInterval) {
        setPosition(t, audibleIn: deps.session.latencySeconds)
    }

    // MARK: - Sources

    func selectSource(_ kind: SourceKind) async throws {
        guard kind != activeSource else { return }
        switch kind {
        case .app:
            return  // `captureApp` picks the app.
        case .files:
            guard !queue.isEmpty else { throw HubCommandError(.unavailable, "Add some files first.") }
            let keepPlaying = wantsPlay && hasPlayableSpeaker
            leaveActiveSource()
            activeSource = .files
            wantsPlay = keepPlaying
            try await loadCurrentFile()
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
        case .spotify:
            guard deps.apps.isInstalled(Self.spotifyBundleID) else {
                throw HubCommandError(.unavailable, "Spotify isn\u{2019}t installed on this Mac.")
            }
            if !deps.apps.isRunning(Self.spotifyBundleID) {
                // Choosing Spotify means wanting it: open it (behind this window). The capture
                // waits for its process, and now playing follows once it answers.
                do { try await deps.apps.launch(Self.spotifyBundleID) } catch {
                    throw HubCommandError(.failed, "Spotify didn\u{2019}t open.")
                }
                refreshApps()
                guard activeSource != .spotify else { return }
            }
            let source = try makeCapture(bundleID: Self.spotifyBundleID, name: "Spotify")
            leaveActiveSource()
            observeCapture(source)
            activeSource = .spotify
            startSpotifyObserver()
            wantsPlay = spotifyNow?.state == .playing && hasPlayableSpeaker
            publish()
            setEngineSource(source, kind: .spotify)
        case .appleMusic:
            let player = try requireMusicPlayer()
            if permissions.appleMusic == .notDetermined {
                // Music closed since launch reads as not determined: look it up (never prompts)
                // instead of refusing a choice the person may have allowed long ago.
                let status = await player.refreshAuthorization()
                if musicPlayer === player, status != permissions.appleMusic {
                    permissions.appleMusic = status
                    if status == .granted {
                        content.library &+= 1
                        content.upNext &+= 1
                    }
                }
            }
            // Capturing a player that can't be controlled would only put up permission prompts.
            guard permissions.appleMusic == .granted else {
                throw HubCommandError(.permissionMissing, permissions.appleMusic == .denied
                    ? "Apple Music is turned off for Multicast. Allow it in Privacy & Security."
                    : "Allow Multicast to use Apple Music first.")
            }
            let source: AudioSource
            do { source = try player.makeAudioSource() } catch {
                throw HubCommandError(.failed, "Apple Music couldn\u{2019}t start: \(error.localizedDescription)")
            }
            leaveActiveSource()
            // The Music tap reports the System Audio Recording permission like any capture (a
            // silent tap on another app must not leave a stale "turned off" behind).
            if let capture = source as? HubCaptureSource { observeCapture(capture) }
            activeSource = .appleMusic
            wantsPlay = musicStatus.isPlaying && hasPlayableSpeaker
            publish()
            setEngineSource(source, kind: .appleMusic)
        }
    }

    /// What leaving the current source means: a media app is paused (it would otherwise go on
    /// playing on the Mac, un-delayed, once no longer tapped).
    func leaveActiveSource() {
        let old = activeSource
        let oldPlaying = (old == .spotify && spotifyNow?.state == .playing) || (old == .appleMusic && musicStatus.isPlaying)
        if old == .files || old == .app { freezePosition() }
        captureEvidence?.cancel()
        captureEvidence = nil
        if old != .app { capturedApp = nil }
        endingTask?.cancel()
        endingTask = nil
        MulticastTiming.log.debug("hub.leaveSource old=\(old.map { "\($0)" } ?? "none", privacy: .public) playing=\(oldPlaying) spotify=\(self.spotifyNow?.state.rawValue ?? "nil", privacy: .public)")
        // Not on the work queue: a media app slow to answer must not hold up the new source.
        if oldPlaying { Task { [weak self] in await self?.pauseMediaApp(old) } }
    }

    private func setEngineSource(_ source: AudioSource, kind: SourceKind) {
        enqueue { [self] in await self.applyEngineSource(source, kind: kind) }
    }

    func applyEngineSource(_ source: AudioSource, kind: SourceKind) async {
        guard activeSource == kind else { return }
        do {
            try await deps.session.setSource(source)
            engineSource = source
            engineSourceKind = kind
        } catch {
            engineSource = nil
            engineSourceKind = nil
            wantsPlay = false
        }
        await reconcileEngine()
        publish()
    }

    private func makeCapture(bundleID: String, name: String) throws -> HubCaptureSource {
        do { return try deps.sources.makeCapture(bundleID: bundleID, name: name) } catch {
            throw HubCommandError(.unsupported, "Capturing \(name) needs macOS 14.2 or later.")
        }
    }

    /// Follows what the tap says about the System Audio Recording permission (after
    /// `leaveActiveSource`, which ends the previous source's observation).
    private func observeCapture(_ source: HubCaptureSource) {
        let evidence = source.permissionEvidence()
        captureEvidence?.cancel()
        captureEvidence = Task { [weak self] in for await e in evidence { await self?.captureEvidenceChanged(e) } }
    }

    private func captureEvidenceChanged(_ e: CapturePermissionEvidence) {
        switch e {
        case .granted: permissions.audioCapture = .granted
        case .denied: permissions.audioCapture = .denied
        case .unknown: break
        }
        publish()
    }

    private func captureApp(bundleID: String) async throws {
        // Only an app the capturable list offers (it leaves this process out on purpose): a
        // tap mutes its target, and tapping Multicast itself would mute or loop its own output.
        guard bundleID != Bundle.main.bundleIdentifier,
              let name = capturable.first(where: { $0.id == bundleID })?.name else {
            throw HubCommandError(.notFound, "That app isn\u{2019}t running.")
        }
        if activeSource == .app, capturedApp?.id == bundleID {
            if !wantsPlay { try await play() }
            return
        }
        let source = try makeCapture(bundleID: bundleID, name: name)
        leaveActiveSource()
        observeCapture(source)
        activeSource = .app
        capturedApp = (bundleID, name)
        setPosition(0)
        wantsPlay = hasPlayableSpeaker
        publish()
        setEngineSource(source, kind: .app)
        if !hasPlayableSpeaker { throw HubCommandError(.unavailable, Self.needsSpeaker) }
    }

    private func capturableChanged(_ list: [CapturableApp]) {
        capturable = list
        publish()
    }

    // MARK: Files

    private func addFiles(_ urls: [URL]) async {
        let files = AudioFileFilter.expand(urls)
        var inspected: [(URL, InspectedFile)] = []
        for url in files {
            if let info = await deps.sources.inspect(url) { inspected.append((url, info)) }
        }
        guard !inspected.isEmpty else { return }
        let added = queue.append(inspected)
        for (track, (_, info)) in zip(added, inspected) {
            if let art = info.artwork { artwork.insert(art, for: FileQueue.artworkID(forTrack: track.id)) }
        }
        content.files &+= 1
        publish()
    }

    private func removeFiles(ids: [String]) async throws {
        let set = Set(ids)
        let removedTracks = queue.tracks.filter { set.contains($0.id) }
        guard !removedTracks.isEmpty else { return }
        let currentGone = queue.remove(ids: set)
        dropQueuedFiles(set)
        for t in removedTracks { artwork.remove(FileQueue.artworkID(forTrack: t.id)) }
        content.files &+= 1
        if currentGone, activeSource == .files {
            if queue.isEmpty {
                activeSource = nil
                wantsPlay = false
                setPosition(0)
                publish()
                enqueue { [self] in
                    await self.stopEngine()
                    await self.clearEngineSource()
                    await self.publish()
                }
            } else {
                try? await loadCurrentFile()
                publish()
                enqueue { [self] in await self.reconcileAndPublish() }
            }
        } else {
            if currentGone { fileNeedsReload = true; setPosition(0) }
            publish()
        }
    }

    private func clearEngineSource() {
        engineSource = nil
        engineSourceKind = nil
    }

    // Playing a track or a playlist goes through the play queue (LocalHub+Queue.swift).

    /// Opens the queue's current file and makes it the engine's source (queued, in order).
    /// Position resets to 0, heard one latency after the engine (re)starts.
    func loadCurrentFile() async throws {
        guard let entry = queue.current else { throw HubCommandError(.unavailable, "There are no files to play.") }
        let source: HubFileSource
        do { source = try await deps.sources.openFile(entry.url) } catch {
            // Moved, deleted, on an ejected drive: whatever the caller had set up, the transport
            // must not claim to play it. Stopped at its start; Play tries to open it again.
            if activeSource == .files {
                wantsPlay = false
                fileNeedsReload = true
                setPosition(0)
                publish()
                enqueue { [self] in await self.reconcileAndPublish() }
            }
            throw HubCommandError(.failed, "\u{201C}\(entry.track.title)\u{201D} can\u{2019}t be played.")
        }
        endingTask?.cancel()
        endingTask = nil
        fileNeedsReload = false
        setPosition(0, audibleIn: wantsPlay ? deps.session.latencySeconds : 0)
        setEngineSource(source, kind: .files)
    }

    /// Reopen and seek (after the queue played to its end), inside the work queue.
    private func loadCurrentFileNow(at seconds: TimeInterval) async throws {
        guard let entry = queue.current else { return }
        let source = try await deps.sources.openFile(entry.url)
        source.seek(to: seconds)
        fileNeedsReload = false
        await applyEngineSource(source, kind: .files)
    }

    /// The engine reported the end of the current file: go on with the next one (the engine
    /// continues on the same timeline when it can), or, after the last, stop once the tail has
    /// been heard and cue the first file again.
    private func fileEnded(audibleUntilHostNanos until: UInt64) {
        guard activeSource == .files, let ours = engineSource, let current = deps.session.currentSource,
              ours === current else { return }
        let nowNanos = HostClock.nowNanos()
        let delay = until > nowNanos ? Double(until - nowNanos) / 1e9 : 0
        if queueHandlesFileEnd(audibleIn: delay) { return }
        if queue.advance(), let entry = queue.current {
            setPosition(0, audibleIn: delay)
            publish()
            enqueue { [self] in
                do {
                    let source = try await self.deps.sources.openFile(entry.url)
                    await self.applyEngineSource(source, kind: .files)
                } catch {
                    await self.fileFailedToOpen()
                }
            }
            return
        }
        let wait = UInt64(delay * 1e9)
        endingTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            guard !Task.isCancelled else { return }
            await self?.finishQueue()
        }
    }

    private func finishQueue() async {
        endingTask = nil
        guard activeSource == .files else { return }
        queue.rewind()
        wantsPlay = false
        fileNeedsReload = true
        setPosition(0)
        await deps.session.stop()
        publish()
    }

    func fileFailedToOpen() async {
        wantsPlay = false
        freezePosition()
        await reconcileEngine()
        publish()
    }

    // MARK: Spotify

    private func startSpotifyObserver() {
        guard spotifyObserver == nil else { return }
        let changes = deps.spotify.changes()
        spotifyObserver = Task { [weak self] in
            for await np in changes { await self?.spotifyChanged(np) }
            await self?.spotifyObserverEnded()
        }
    }

    private func spotifyObserverEnded() { spotifyObserver = nil }

    private func spotifyChanged(_ np: NowPlaying?) {
        let previous = spotifyNow
        spotifyNow = np
        if np != nil, permissions.automation != .granted {
            permissions.automation = .granted
            automationEvidence += 1
        }
        if previous.map(spotifyTrackKey) != np.map(spotifyTrackKey) { content.spotifyHistory &+= 1 }
        if let previous, previous.hasTrack, spotifyTrackKey(previous) != np.map(spotifyTrackKey) {
            let item = spotifyTrack(previous)
            spotifyHistory.removeAll { $0.id == item.id }
            spotifyHistory.insert(item, at: 0)
            if spotifyHistory.count > configuration.spotifyHistoryLimit { spotifyHistory.removeLast() }
            content.spotifyHistory &+= 1
        }
        queueObserve()
        if activeSource == .spotify, !queueSuppressesFollow {
            let playing = np?.state == .playing
            if playing != wantsPlay {
                if playing && !hasPlayableSpeaker {
                    wantsPlay = false
                } else {
                    wantsPlay = playing
                    enqueue { [self] in await self.reconcileAndPublish() }
                }
            }
        }
        publish()
    }

    private func isMintedArtworkID(_ id: ArtworkID) -> Bool {
        if let np = spotifyNow, spotifyTrack(np).artworkID == id { return true }
        if queueMintedArtwork(id) { return true }
        return spotifyHistory.contains { $0.artworkID == id }
    }

    func spotifyTrackKey(_ np: NowPlaying) -> String { np.trackID ?? "\(np.title ?? "")\u{1F}\(np.artist ?? "")" }

    func spotifyTrack(_ np: NowPlaying) -> TrackItem {
        TrackItem(id: spotifyTrackKey(np), title: np.title ?? "Unknown", artist: np.artist ?? "", album: np.album ?? "",
                  duration: np.duration ?? 0, artworkID: np.artworkURL.map { "hub.url:\($0.absoluteString)" })
    }

    func mediaCommand(_ body: @escaping @Sendable () async throws -> Void) async throws {
        do { try await body() } catch let e as HubCommandError {
            if e.code == .permissionMissing {
                permissions.automation = .denied
                automationEvidence += 1
                publish()
            }
            if e.code == .unavailable { refreshApps() }
            throw e
        }
    }

    private func openSpotify() async throws {
        guard deps.apps.isInstalled(Self.spotifyBundleID) else {
            throw HubCommandError(.unavailable, "Spotify isn\u{2019}t installed on this Mac.")
        }
        // Asked for by the person: bring it to the front, running or not.
        do { try await deps.apps.open(Self.spotifyBundleID) } catch {
            throw HubCommandError(.failed, "Spotify didn\u{2019}t open.")
        }
        refreshApps()
    }

    // MARK: Apple Music

    private func musicChanged(_ s: MusicPlayerStatus) {
        if s.isPlaying, !musicStatus.isPlaying, let at = playRequestedAt {
            MulticastTiming.log.debug("hub.music reports playing \(MulticastTiming.ms(since: at))ms after play command")
        }
        if s.libraryRevision != musicStatus.libraryRevision { content.library &+= 1 }
        if s.upNextRevision != musicStatus.upNextRevision { content.upNext &+= 1 }
        musicStatus = s
        queueObserve()
        if activeSource == .appleMusic, !queueSuppressesFollow {
            let playing = s.isPlaying && hasPlayableSpeaker
            if playing != wantsPlay {
                wantsPlay = playing
                enqueue { [self] in await self.reconcileAndPublish() }
            }
        }
        publish()
    }

    // MARK: - Apps, permissions, health

    func refreshApps() {
        let installed = deps.apps.isInstalled(Self.spotifyBundleID)
        let running = installed && deps.apps.isRunning(Self.spotifyBundleID)
        let status: SpotifyStatus = !installed ? .notInstalled : (running ? .running : .notRunning)
        if status != spotifyStatus {
            spotifyStatus = status
            if status != .running {
                spotifyNow = nil
                if activeSource == .spotify, wantsPlay {
                    wantsPlay = false
                    enqueue { [self] in await self.reconcileAndPublish() }
                }
            }
        }
        publish()
    }

    /// Periodic: discovery settling, local network evidence, app presence, Automation status.
    public func tick() async {
        refreshApps()
        updateLocalNetworkPermission()
        let now = deps.now()
        if discovering,
           now.timeIntervalSince(lastSpeakerListChange) >= configuration.discoveryQuietSeconds
            || now.timeIntervalSince(startedAt) >= configuration.discoveryMaxSeconds {
            discovering = false
        }
        if spotifyStatus == .running, permissions.automation != .granted || spotifyObserver == nil,
           spotifyAutomationCheck == nil {
            let spotify = deps.spotify
            let evidence = automationEvidence
            spotifyAutomationCheck = Task { [weak self] in
                let status = await spotify.automationStatus(ask: false)
                await self?.spotifyAutomationChecked(status, evidence: evidence)
            }
        }
        // Access granted in System Settings while the hub runs: pick it up without prompting.
        if let musicPlayer, permissions.appleMusic != .granted {
            let status = await musicPlayer.authorizationStatus()
            if status != permissions.appleMusic, self.musicPlayer === musicPlayer {
                permissions.appleMusic = status
                if status == .granted {
                    content.library &+= 1
                    content.upNext &+= 1
                }
            }
        }
        publish()
    }

    private func spotifyAutomationChecked(_ status: PermissionStatus?, evidence: Int) {
        spotifyAutomationCheck = nil
        guard let status, spotifyStatus == .running, evidence == automationEvidence else { return }
        permissions.automation = status
        // Observing sends Apple Events; start it unprompted only once it is allowed.
        if status == .granted { startSpotifyObserver() }
        publish()
    }

    private func updateLocalNetworkPermission() {
        // -65570 PolicyDenied, -65555 NoAuth: both are how mDNSResponder refuses an app that has
        // Local Network access turned off.
        if let code = deps.session.discoveryErrorCode, code == -65570 || code == -65555 {
            permissions.localNetwork = .denied
        } else if descriptors.values.contains(where: { $0.transport != .local }) {
            permissions.localNetwork = .granted
        }
    }

    private func requestPermission(_ p: HubPermission) async throws {
        if permissions[p] == .denied, p != .appleMusic {
            deps.system.openPrivacySettings(for: p)
            return
        }
        switch p {
        case .localNetwork:
            // Discovery itself asks; there is nothing more to trigger.
            return
        case .audioCapture:
            if permissions.audioCapture == .granted { return }
            let system = deps.system
            enqueue { await system.requestAudioCapturePermission() }
        case .automation:
            guard deps.apps.isRunning(Self.spotifyBundleID) else {
                throw HubCommandError(.unavailable, "Open Spotify first, then allow Multicast to control it.")
            }
            let spotify = deps.spotify
            Task { [weak self] in
                let status = await spotify.automationStatus(ask: true)
                await self?.automationAnswered(status)
            }
        case .appleMusic:
            let player = try requireMusicPlayer()
            if permissions.appleMusic == .denied {
                deps.system.openPrivacySettings(for: player.settingsPermission)
                return
            }
            // Asking can wait on a person at the Mac (the Automation prompt) for as long as they
            // like, while remotes' commands run one at a time: answer the command at once and
            // report the outcome through the state, like the Spotify case.
            guard musicPermissionRequest == nil else { return }
            musicPermissionRequest = Task { [weak self] in
                let status = await player.requestAuthorization()
                await self?.appleMusicAnswered(status, from: player)
            }
        }
    }

    private func appleMusicAnswered(_ status: PermissionStatus, from player: MusicPlayerProviding) {
        musicPermissionRequest = nil
        guard musicPlayer === player else { return }
        permissions.appleMusic = status
        content.library &+= 1
        content.upNext &+= 1
        publish()
    }

    private func automationAnswered(_ status: PermissionStatus?) {
        guard let status else { return }
        permissions.automation = status
        automationEvidence += 1
        if status == .granted, spotifyStatus == .running { startSpotifyObserver() }
        publish()
    }

    // MARK: - Rendering

    func publish() {
        let rendered = render()
        let published = broadcaster.update { $0 = rendered }
        pushToSpeakerDisplays(published)
    }

    func render() -> HubState {
        let session = deps.session.state
        var entries: [String: EngineSnapshot.SinkEntry] = [:]
        for e in session.engine.sinks where entries[e.id] == nil { entries[e.id] = e }
        let selected = Set(session.selectedSpeakerIDs)
        var ids = discoveredOrder
        let known = Set(ids)
        ids += enabledOrder.filter { !known.contains($0) }
        let laptop = deps.system.hostIsLaptop
        let speakers: [SpeakerItem] = ids.compactMap { id in
            guard let d = descriptors[id] else { return nil }
            let p = preset(for: id)
            let enabled = enabledOrder.contains(id)
            let state: SpeakerState
            if !enabled {
                state = .off
            } else if let reason = blocked[id] ?? selectFailures[id] {
                state = .failed(reason: reason)
            } else if selected.contains(id) {
                state = SpeakerPresentation.state(for: entries[id])
            } else {
                state = .connecting
            }
            return SpeakerItem(id: SpeakerID(id), name: d.name, transport: SpeakerPresentation.transport(for: d),
                               glyph: SpeakerPresentation.glyph(for: d, hostIsLaptop: laptop),
                               model: SpeakerPresentation.modelName(for: d), address: SpeakerPresentation.address(for: d),
                               isEnabled: enabled, volume: p.volume, state: state, syncTrimMs: p.syncTrimMs,
                               notSeenSince: session.notSeenSince[id])
        }
        var extra: [HubIssue] = []
        switch spotifyStatus {
        case .notInstalled:
            extra.append(.sourceAppNotInstalled(source: .spotify, bundleID: Self.spotifyBundleID, name: "Spotify"))
        case .notRunning:
            extra.append(.sourceAppNotRunning(source: .spotify, bundleID: Self.spotifyBundleID, name: "Spotify"))
        case .running:
            break
        }
        if activeSource == .app, let app = capturedApp, !deps.apps.isRunning(app.id) {
            extra.append(.sourceAppNotRunning(source: .app, bundleID: app.id, name: app.name))
        }
        return HubState(
            speakers: speakers,
            masterVolume: settings.masterVolume,
            isDiscovering: discovering,
            activeSource: activeSource,
            nowPlaying: renderNowPlaying(),
            transport: renderTransport(),
            capture: CaptureStatus(apps: capturable, capturedAppID: activeSource == .app ? capturedApp?.id : nil),
            spotify: spotifyStatus,
            content: content,
            queue: renderQueue(),
            pins: settings.pins,
            health: HubHealth(permissions: permissions, extraIssues: extra)
        )
    }

    private func renderNowPlaying() -> NowPlayingInfo? {
        switch activeSource {
        case .files:
            guard let t = queue.current?.track else { return nil }
            return NowPlayingInfo(title: t.title, artist: t.artist, album: t.album.isEmpty ? nil : t.album,
                                  artworkID: t.artworkID, duration: t.duration, trackID: t.id)
        case .spotify:
            guard let np = spotifyNow else {
                guard spotifyStatus == .running else { return nil }
                return NowPlayingInfo(title: "Spotify", artist: "", artworkID: "hub.icon:\(Self.spotifyBundleID)",
                                      artworkIsIcon: true)
            }
            guard np.hasTrack else {
                return NowPlayingInfo(title: "Spotify", artist: "", artworkID: "hub.icon:\(Self.spotifyBundleID)",
                                      artworkIsIcon: true)
            }
            let t = spotifyTrack(np)
            return NowPlayingInfo(title: t.title, artist: t.artist, album: np.album, artworkID: t.artworkID,
                                  duration: np.duration, trackID: t.id)
        case .app:
            guard let app = capturedApp else { return nil }
            return NowPlayingInfo(title: app.name, artist: "Capturing app audio", artworkID: "hub.icon:\(app.id)",
                                  artworkIsIcon: true)
        case .appleMusic:
            return musicStatus.nowPlaying
        case nil:
            return nil
        }
    }

    private func renderTransport() -> TransportState {
        let latency = engineIsPlaying ? deps.session.latencySeconds : 0
        switch activeSource {
        case .files:
            return TransportState(isPlaying: wantsPlay, position: position, positionAsOf: positionAsOf,
                                  canSkip: !queue.isEmpty, canSeek: queue.current != nil)
        case .app:
            return TransportState(isPlaying: wantsPlay, position: 0, positionAsOf: positionAsOf, canSkip: false, canSeek: false)
        case .spotify:
            let np = spotifyNow
            return TransportState(isPlaying: np?.state == .playing, position: np?.position ?? 0,
                                  positionAsOf: (np?.sampledAt ?? .distantPast).addingTimeInterval(latency),
                                  canSkip: spotifyStatus == .running,
                                  canSeek: spotifyStatus == .running && (np?.duration ?? 0) > 0)
        case .appleMusic:
            let s = musicStatus
            return TransportState(isPlaying: s.isPlaying, position: s.position,
                                  positionAsOf: s.positionAsOf.addingTimeInterval(latency),
                                  canSkip: s.canSkip, canSeek: s.canSeek)
        case nil:
            return TransportState(isPlaying: false, position: 0, positionAsOf: .distantPast, canSkip: false, canSeek: false)
        }
    }

    // MARK: - Speaker displays (AirPlay now-playing text, cover and progress)

    private func pushToSpeakerDisplays(_ state: HubState) {
        let playing = state.speakers.filter { $0.state == .playing && $0.transport.isNetwork }.map(\.id.rawValue)
        let playingSet = Set(playing)
        for id in pushedMetadata.keys where !playingSet.contains(id) { pushedMetadata[id] = nil }
        for id in pushedProgress.keys where !playingSet.contains(id) { pushedProgress[id] = nil }
        guard let np = state.nowPlaying, !playing.isEmpty else { return }
        let metaKey = "\(np.identity)\u{1F}\(np.title)\u{1F}\(np.artist)\u{1F}\(np.artworkID ?? "")"
        let metaTargets = playing.filter { pushedMetadata[$0] != metaKey }
        let t = state.transport
        var progressTargets: [String] = []
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
        if let d = np.duration, d > 0 {
            elapsed = min(d, t.position(at: deps.now()))
            duration = d
            let progressKey = "\(np.identity)\u{1F}\(t.isPlaying)\u{1F}\(t.position)\u{1F}\(t.positionAsOf.timeIntervalSinceReferenceDate)"
            progressTargets = playing.filter { pushedProgress[$0] != progressKey }
            for id in progressTargets { pushedProgress[id] = progressKey }
        }
        guard !metaTargets.isEmpty || !progressTargets.isEmpty else { return }
        for id in metaTargets { pushedMetadata[id] = metaKey }
        let session = deps.session
        let artworkID = np.artworkID
        let previous = metadataTail
        metadataTail = Task { [weak self] in
            await previous?.value
            if !metaTargets.isEmpty {
                var jpeg: Data?
                if let artworkID, let self, let data = await self.artwork(id: artworkID, maxPixel: 600) {
                    jpeg = ArtworkImaging.jpeg(data)
                }
                let meta = SpeakerMetadata(title: np.title, artist: np.artist.isEmpty ? nil : np.artist,
                                           album: np.album, artworkJPEG: jpeg)
                for id in metaTargets { _ = await session.sendNowPlaying(meta, toSpeaker: id) }
            }
            for id in progressTargets { _ = await session.sendProgress(elapsed: elapsed, duration: duration, toSpeaker: id) }
        }
    }
}
