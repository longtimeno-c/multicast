import Foundation
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import MulticastKit
import MulticastSources
import os
@testable import MulticastHub

// Fakes for everything LocalHub touches. All values are made up (no real devices or rooms).

/// A thread-safe box.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
    @discardableResult func update<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// Many-subscriber stream helper.
final class Fanout<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let replay: (() -> Element)?
    init(replay: (() -> Element)? = nil) { self.replay = replay }

    func stream() -> AsyncStream<Element> {
        let (s, c) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        lock.withLock { subs[id] = c }
        c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.subs.removeValue(forKey: id) } }
        if let replay { c.yield(replay()) }
        return s
    }

    func send(_ e: Element) {
        let all = lock.withLock { Array(subs.values) }
        for c in all { c.yield(e) }
    }
}

enum Fixtures {
    static func local(_ id: String = "local:BuiltInSpeakerDevice", name: String = "Desk Speakers") -> SpeakerDescriptor {
        SpeakerDescriptor(id: id, name: name, transport: .local, localDeviceUID: String(id.dropFirst(6)), localKind: .builtIn)
    }

    static let mainBedroom = SpeakerDescriptor(
        id: "542a1b001122", name: "Main Bedroom", transport: .airplay1, host: "main-bedroom.local.", port: 5000,
        model: "AirPort10,115", raopTXT: ["am": "AirPort10,115", "md": "0,1,2"])
    static let hallSonos = SpeakerDescriptor(
        id: "542a1b003344", name: "Hall Sonos", transport: .airplay2, host: "192.0.2.20", port: 7000,
        raopTXT: ["am": "One"], airplayTXT: ["model": "One", "manufacturer": "Sonos"])
    /// An AirConnect bridge and the native advertisement of one made-up receiver.
    static let denonBridge = SpeakerDescriptor(
        id: "bbbb0a0b0c0d", name: "Lounge Receiver+", transport: .airplay1, host: "192.0.2.30", port: 49152,
        raopTXT: ["am": "airupnp"])
    static let denonNative = SpeakerDescriptor(
        id: "000a0b0c0d0e", name: "Lounge Receiver", transport: .airplay2, host: "192.0.2.31", port: 7000,
        airplayTXT: ["model": "AVR-X1000", "manufacturer": "Denon"])
}

/// A `MulticastSession` stand-in: selection, a fake engine transport and per-speaker outcomes.
final class FakeSession: HubSessionControlling, @unchecked Sendable {
    struct Inner {
        var speakers: [SpeakerDescriptor] = []
        var selected: [String] = []
        var sinks: [String: EngineSnapshot.SinkEntry] = [:]
        var transport: EngineSnapshot.TransportState = .stopped
        var master: Float = 1
        var source: AudioSource?
        var revision: UInt64 = 0
        var discoveryError: Int32?
        /// Speakers that fail to prepare (message) on the next play/join.
        var failing: [String: String] = [:]
        var selectErrors: [String: Error] = [:]
        var calls: [String] = []
        var seeks: [TimeInterval] = []
        var selectVolumes: [String: Float] = [:]
        var selectOffsets: [String: Int] = [:]
        var metadata: [(String, SpeakerMetadata)] = []
        var progress: [(String, TimeInterval, TimeInterval)] = []
    }

    let inner = Locked(Inner())
    private lazy var states = Fanout<SessionState>(replay: { [unowned self] in self.state })
    let meters = Fanout<MeterReading>()
    let events = Fanout<EngineEvent>()
    var latencySeconds: TimeInterval { 2 }

    var state: SessionState {
        inner.update { i in
            SessionState(speakers: i.speakers, selectedSpeakerIDs: i.selected,
                         engine: EngineSnapshot(revision: i.revision, transport: i.transport, sourceName: i.source?.displayName,
                                                sourceIsLive: i.source?.isLive ?? false, masterVolume: i.master,
                                                latencyMillis: 2000, sinks: i.selected.compactMap { i.sinks[$0] }),
                         revision: i.revision)
        }
    }

    func stateUpdates() -> AsyncStream<SessionState> { states.stream() }
    func meterUpdates() -> AsyncStream<MeterReading> { meters.stream() }
    func eventUpdates() -> AsyncStream<EngineEvent> { events.stream() }
    var discoveryErrorCode: Int32? { inner.get().discoveryError }
    var currentSource: AudioSource? { inner.get().source }

    private func change(_ call: String? = nil, _ body: (inout Inner) -> Void) {
        inner.update { i in
            if let call { i.calls.append(call) }
            body(&i)
            i.revision += 1
        }
        states.send(state)
    }

    // Test controls
    func setSpeakers(_ list: [SpeakerDescriptor]) { change { $0.speakers = list } }
    func setDiscoveryError(_ code: Int32?) { change { $0.discoveryError = code } }
    func failOnPrepare(_ id: String, _ message: String) { inner.update { $0.failing[id] = message } }
    func endOfStream() { events.send(.endOfStream(endFrame: 0, audibleUntilHostNanos: HostClock.nowNanos())) }
    var calls: [String] { inner.get().calls }
    var transport: EngineSnapshot.TransportState { inner.get().transport }

    private static func entry(_ id: String, _ state: EngineSnapshot.SinkStatus, error: String? = nil) -> EngineSnapshot.SinkEntry {
        EngineSnapshot.SinkEntry(id: id, name: id, state: state, error: error, volume: 0.5, muted: false, enabled: true,
                                 offsetMillis: 0, effectiveVolume: 0.5)
    }

    private static func join(_ i: inout Inner, _ id: String) {
        if let msg = i.failing.removeValue(forKey: id) {
            i.sinks[id] = entry(id, .failed, error: msg)
        } else {
            i.sinks[id] = entry(id, .playing)
        }
    }

    // HubSessionControlling
    func start() { change("start") { _ in } }
    func shutdown() async { change("shutdown") { $0.transport = .stopped; $0.selected = [] } }

    func select(_ speaker: SpeakerDescriptor, volume: Float, offsetMillis: Int) async throws {
        if let e = inner.update({ $0.selectErrors.removeValue(forKey: speaker.id) }) { throw e }
        change("select \(speaker.id)") { i in
            guard !i.selected.contains(speaker.id) else { return }
            i.selected.append(speaker.id)
            i.selectVolumes[speaker.id] = volume
            i.selectOffsets[speaker.id] = offsetMillis
            i.sinks[speaker.id] = Self.entry(speaker.id, .idle)
            if i.transport == .playing { Self.join(&i, speaker.id) }
        }
    }

    func deselect(speakerID: String) async {
        change("deselect \(speakerID)") { i in
            i.selected.removeAll { $0 == speakerID }
            i.sinks[speakerID] = nil
        }
    }

    func retry(speakerID: String) async {
        change("retry \(speakerID)") { i in
            guard i.selected.contains(speakerID) else { return }
            if i.transport == .playing { Self.join(&i, speakerID) } else { i.sinks[speakerID] = Self.entry(speakerID, .idle) }
        }
    }

    func setSource(_ source: AudioSource) async throws {
        change("setSource \(source.displayName)") { i in
            i.source = source
            if i.transport == .ended { i.transport = .playing }
        }
    }

    func play() async throws {
        change("play") { i in
            i.transport = .playing
            for id in i.selected where i.sinks[id]?.state != .failed { Self.join(&i, id) }
        }
    }

    func pause() async {
        change("pause") { i in
            guard i.transport == .playing else { return }
            i.transport = .paused
            for id in i.selected where i.sinks[id]?.state == .playing { i.sinks[id] = Self.entry(id, .idle) }
        }
    }

    func stop() async {
        change("stop") { i in
            i.transport = .stopped
            for id in i.selected where i.sinks[id]?.state == .playing { i.sinks[id] = Self.entry(id, .idle) }
        }
    }

    func markEnded() { change { $0.transport = .ended } }

    func seek(toSeconds seconds: TimeInterval) async throws {
        change("seek") { i in i.seeks.append(seconds) }
        (inner.get().source as? FakeFileSource)?.seek(to: seconds)
    }

    func setMasterVolume(_ volume: Float) { change { $0.master = volume } }
    func setVolume(_ volume: Float, forSpeaker id: String) { inner.update { $0.calls.append("volume \(id) \(volume)") } }
    func setOffset(millis: Int, forSpeaker id: String) { inner.update { $0.calls.append("offset \(id) \(millis)") } }

    func sendNowPlaying(_ metadata: SpeakerMetadata, toSpeaker id: String) async -> Bool {
        inner.update { $0.metadata.append((id, metadata)) }
        return true
    }

    func sendProgress(elapsed: TimeInterval, duration: TimeInterval, toSpeaker id: String) async -> Bool {
        inner.update { $0.progress.append((id, elapsed, duration)) }
        return true
    }
}

final class FakeFileSource: HubFileSource, @unchecked Sendable {
    let url: URL
    let displayName: String
    let duration: TimeInterval
    let seeks = Locked<[TimeInterval]>([])
    var isLive: Bool { false }
    init(url: URL, duration: TimeInterval) {
        self.url = url
        displayName = url.lastPathComponent
        self.duration = duration
    }
    func seek(to seconds: TimeInterval) { seeks.update { $0.append(seconds) } }
    func start() async throws {}
    func stop() async {}
    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? { 0 }
}

final class FakeCaptureSource: HubCaptureSource, @unchecked Sendable {
    let displayName: String
    let bundleID: String
    let evidence = Fanout<CapturePermissionEvidence>()
    var isLive: Bool { true }
    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        displayName = name
    }
    func permissionEvidence() -> AsyncStream<CapturePermissionEvidence> { evidence.stream() }
    func start() async throws {}
    func stop() async {}
    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? { 0 }
}

final class FakeSources: HubSourceMaking, @unchecked Sendable {
    /// file name → inspected info; files not listed are not audio.
    let files = Locked<[String: InspectedFile]>([:])
    let opened = Locked<[FakeFileSource]>([])
    let captures = Locked<[FakeCaptureSource]>([])
    let unopenable = Locked<Set<String>>([])

    func openFile(_ url: URL) async throws -> any HubFileSource {
        if unopenable.get().contains(url.lastPathComponent) { throw CocoaError(.fileReadCorruptFile) }
        let s = FakeFileSource(url: url, duration: files.get()[url.lastPathComponent]?.duration ?? 100)
        opened.update { $0.append(s) }
        return s
    }

    func makeCapture(bundleID: String, name: String) throws -> any HubCaptureSource {
        let s = FakeCaptureSource(bundleID: bundleID, name: name)
        captures.update { $0.append(s) }
        return s
    }

    func inspect(_ url: URL) async -> InspectedFile? { files.get()[url.lastPathComponent] }
}

final class FakeApps: AppPresenceMonitoring, @unchecked Sendable {
    let installed = Locked<Set<String>>([])
    let running = Locked<Set<String>>([])
    let launched = Locked<[String]>([])
    /// Apps opened in front (`open`), in order.
    let opened = Locked<[String]>([])
    let fanout = Fanout<Void>()

    func isInstalled(_ bundleID: String) -> Bool { installed.get().contains(bundleID) }
    func isRunning(_ bundleID: String) -> Bool { running.get().contains(bundleID) }
    func changes() -> AsyncStream<Void> { fanout.stream() }
    func launch(_ bundleID: String) async throws {
        launched.update { $0.append(bundleID) }
        running.update { _ = $0.insert(bundleID) }
        fanout.send(())
    }
    func open(_ bundleID: String) async throws {
        opened.update { $0.append(bundleID) }
        running.update { _ = $0.insert(bundleID) }
        fanout.send(())
    }
    func iconPNG(bundleID: String, maxPixel: Int) -> Data? { Data("icon:\(bundleID)".utf8) }

    func setRunning(_ id: String, _ on: Bool) {
        running.update { if on { $0.insert(id) } else { $0.remove(id) } }
        fanout.send(())
    }
}

final class FakeCapturableApps: CapturableAppsProviding, @unchecked Sendable {
    let current = Locked<[CapturableApp]>([])
    lazy var fanout = Fanout<[CapturableApp]>(replay: { [unowned self] in self.current.get() })
    func updates() -> AsyncStream<[CapturableApp]> { fanout.stream() }
    func set(_ apps: [CapturableApp]) {
        current.set(apps)
        fanout.send(apps)
    }
}

final class FakeSpotify: MediaAppControlling, @unchecked Sendable {
    let fanout = Fanout<NowPlaying?>()
    let commands = Locked<[String]>([])
    let failWith = Locked<HubCommandError?>(nil)
    let automation = Locked<PermissionStatus?>(.granted)
    let askCount = Locked(0)
    /// While closed, silent permission checks and pauses wait (a Spotify that stopped answering).
    let checkGate = Gate()
    let pauseGate = Gate()

    func changes() -> AsyncStream<NowPlaying?> { fanout.stream() }
    private func run(_ name: String) throws {
        if let e = failWith.get() { throw e }
        commands.update { $0.append(name) }
    }
    func play() async throws { try run("play") }
    func pause() async throws {
        await pauseGate.wait()
        try run("pause")
    }
    func next() async throws { try run("next") }
    func previous() async throws { try run("previous") }
    func seek(to seconds: TimeInterval) async throws { try run("seek \(Int(seconds))") }
    func play(uri: String, shuffled: Bool?) async throws {
        try run(shuffled.map { "play \(uri) shuffled \($0)" } ?? "play \(uri)")
    }
    func automationStatus(ask: Bool) async -> PermissionStatus? {
        if ask { askCount.update { $0 += 1 } } else { await checkGate.wait() }
        return automation.get()
    }
}

/// Open by default; `close()` makes `wait()` block until `open()`.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { lock.withLock { isOpen = false } }
    func open() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        w.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

final class FakeSystem: HubSystemServices, @unchecked Sendable {
    let opened = Locked<[HubPermission]>([])
    let captureRequests = Locked(0)
    let images = Locked<[URL: Data]>([:])
    var hostIsLaptop: Bool { true }
    func openPrivacySettings(for permission: HubPermission) { opened.update { $0.append(permission) } }
    func requestAudioCapturePermission() async { captureRequests.update { $0 += 1 } }
    func fetchImage(_ url: URL) async -> Data? { images.get()[url] }
    let embeds = Locked<[URL: SpotifyEmbedInfo]>([:])
    func spotifyEmbed(for page: URL) async -> SpotifyEmbedInfo? { embeds.get()[page] }
}

final class FakeMusicPlayer: MusicPlayerProviding, @unchecked Sendable {
    let status = Locked(MusicPlayerStatus())
    lazy var fanout = Fanout<MusicPlayerStatus>(replay: { [unowned self] in self.status.get() })
    let commands = Locked<[String]>([])
    let auth = Locked<PermissionStatus>(.granted)
    let songList = [TrackItem(id: "s1", title: "Tide", artist: "Harbour", album: "Coast", duration: 200)]
    /// Playlist id → tracks.
    let playlistTracks = Locked<[String: [TrackItem]]>([:])
    let playlistList = Locked<[PlaylistItem]>([])

    /// What `refreshAuthorization()` finds (opening Music hidden); nil: the same as `auth`.
    let refreshed = Locked<PermissionStatus?>(nil)
    /// When set, `requestAuthorization()` waits (a prompt on the Mac nobody answers) until released.
    let holdsRequests = Locked(false)
    let pendingRequest = Locked<CheckedContinuation<Void, Never>?>(nil)

    func authorizationStatus() async -> PermissionStatus { auth.get() }
    func refreshAuthorization() async -> PermissionStatus { refreshed.get() ?? auth.get() }
    func requestAuthorization() async -> PermissionStatus {
        if holdsRequests.get() { await withCheckedContinuation { c in pendingRequest.set(c) } }
        return auth.get()
    }
    func answerRequest() { pendingRequest.update { c in c?.resume(); c = nil } }
    func statusUpdates() -> AsyncStream<MusicPlayerStatus> { fanout.stream() }
    func songs(_ page: PageRequest) async throws -> Page<TrackItem> { .slice(songList, page) }
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .slice(playlistList.get(), page) }
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        .slice(playlistTracks.get()[playlistID] ?? [], page)
    }
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    /// Catalog results by query; nil: this player has no catalog.
    let catalog = Locked<[String: [TrackItem]]?>(nil)
    let catalogSearches = Locked<[String]>([])
    func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        guard let catalog = catalog.get() else { throw HubCommandError(.unsupported, "No catalog.") }
        catalogSearches.update { $0.append(query) }
        return .slice(catalog[query] ?? [], page)
    }
    func upNext(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data? { Data("art:\(id)".utf8) }
    func play(trackID: String, context: TrackContext) async throws { commands.update { $0.append("play \(trackID)") } }
    func play(playlistID: String) async throws { commands.update { $0.append("playlist \(playlistID)") } }
    func playOnce(trackID: String) async throws { commands.update { $0.append("once \(trackID)") } }
    func play() async throws { commands.update { $0.append("play") } }
    func pause() async { commands.update { $0.append("pause") } }
    func next() async throws { commands.update { $0.append("next") } }
    func previous() async throws { commands.update { $0.append("previous") } }
    func seek(to position: TimeInterval) async throws { commands.update { $0.append("seek \(Int(position))") } }
    func makeAudioSource() throws -> AudioSource { FakeCaptureSource(bundleID: "music", name: "Apple Music") }

    func publish(_ change: (inout MusicPlayerStatus) -> Void) {
        let s = status.update { change(&$0); return $0 }
        fanout.send(s)
    }
}

/// A settable clock.
final class ManualClock: @unchecked Sendable {
    private let t = Locked(Date(timeIntervalSinceReferenceDate: 800_000_000))
    var now: Date { t.get() }
    func advance(_ s: TimeInterval) { t.update { $0 = $0.addingTimeInterval(s) } }
}

/// A LocalHub wired to fakes.
struct Rig {
    let session = FakeSession()
    let sources = FakeSources()
    let apps = FakeApps()
    let capturable = FakeCapturableApps()
    let spotify = FakeSpotify()
    let system = FakeSystem()
    let settings: InMemorySettingsStore
    let clock = ManualClock()
    let hub: LocalHub

    init(settings: InMemorySettingsStore = InMemorySettingsStore(), speakers: [SpeakerDescriptor] = [Fixtures.local(), Fixtures.mainBedroom, Fixtures.hallSonos]) {
        self.settings = settings
        var config = LocalHub.Configuration()
        config.pollSeconds = 0
        config.levelInterval = 0
        let clock = self.clock
        let deps = HubDependencies(session: session, sources: sources, apps: apps, capturableApps: capturable,
                                   spotify: spotify, system: system, settings: settings, now: { clock.now })
        hub = LocalHub(dependencies: deps, configuration: config)
        session.setSpeakers(speakers)
    }

    func start() async {
        await hub.start()
        try? await waitFor { $0.speakers.count == session.inner.get().speakers.count }
    }

    var state: HubState { hub.currentState }

    /// Waits (bounded) until `condition` holds on the published state.
    func waitFor(_ what: String = "condition", timeout: TimeInterval = 2,
                 _ condition: (HubState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await hub.settle()
            if condition(hub.currentState) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TimeoutError(what: what, state: hub.currentState)
    }

    func speaker(_ d: SpeakerDescriptor) -> SpeakerItem? { state.speaker(SpeakerID(d.id)) }

    /// Adds files named `names` (each 100 s unless given) to the queue.
    func addFiles(_ names: [String], durations: [TimeInterval]? = nil, in dir: URL) async throws {
        var urls: [URL] = []
        for (i, n) in names.enumerated() {
            let url = dir.appendingPathComponent(n)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            sources.files.update { $0[n] = InspectedFile(title: n.replacingOccurrences(of: ".m4a", with: ""), artist: "Tester",
                                                       album: "Fixtures", duration: durations?[i] ?? 100, format: "AAC") }
            urls.append(url)
        }
        try await hub.perform(.addFiles(urls: urls))
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    var what: String
    var state: HubState
    var description: String { "timed out waiting for \(what); state revision \(state.revision)" }
}

func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
