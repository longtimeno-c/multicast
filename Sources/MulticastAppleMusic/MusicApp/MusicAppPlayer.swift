#if os(macOS)
import AppKit
import Carbon
import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastSources

/// Apple Music through the system Music app, driven by Apple Events. Music does the playing
/// (DRM, streaming, Up Next); Multicast taps the Music process and fans its sound out.
///
/// - Library: the whole song list is read in five bulk Apple Events, sorted by title and kept
///   in memory (`LibraryIndex`); songs, search and paging are then local. It is refreshed when
///   `libraryTTL` has passed and Music's track count changed, or on `invalidateLibrary()`.
/// - Playlists: user playlists (regular and smart, not folders), artwork from the first track.
/// - Up next: Music does not expose its queue to other apps. This reports the tracks after the
///   current one in the playlist Music is playing (nothing while shuffle is on), and
///   `insertNext` / `append` throw `.unsupported`.
/// - What follows a chosen track: Music continues in that list's own order (the library order
///   for `.songs` and `.search`, the playlist order for `.playlist`), not Multicast's sort.
/// - Never launches Music in the foreground. With `launchPolicy == .launchInBackground` a call
///   that needs Music opens it hidden first; with `.never` it throws `.unavailable`.
/// - Needs the Automation permission for Music (`NSAppleEventsUsageDescription`); the capture
///   needs System Audio Recording.
///
/// All Apple Events go through one serial queue (NSAppleScript is not thread-safe), which also
/// owns the caches.
private struct DescriptorBox: @unchecked Sendable {
    let items: [NSAppleEventDescriptor]
    init(_ items: [NSAppleEventDescriptor]) { self.items = items }
    static func one(_ d: NSAppleEventDescriptor) -> DescriptorBox { DescriptorBox([d]) }
}

@available(macOS 14.2, *)
public final class MusicAppPlayer: AppleMusicProviding, @unchecked Sendable {
    public enum LaunchPolicy: Sendable, Equatable {
        case never
        case launchInBackground
    }

    public static let bundleID = MediaApp.music.bundleID
    public let kind = AppleMusicBackendKind.musicApp
    public let supportsQueueEditing = false
    public let launchPolicy: LaunchPolicy
    /// How long a cached library list is trusted before Music's track count is checked again.
    public let libraryTTL: TimeInterval
    public let pollInterval: TimeInterval

    private let queue = DispatchQueue(label: "Multicast.MusicAppPlayer", qos: .userInitiated)
    private var script: NSAppleScript?
    private var library: (index: LibraryIndex, checkedAt: Date)?
    private var playlistCache: (items: [PlaylistItem], builtAt: Date)?
    private var playlistTracks: [String: (index: LibraryIndex, builtAt: Date)] = [:]
    private var searchCache = SearchCache()
    private var libraryRevision: UInt64 = 0
    private var upNextRevision: UInt64 = 0
    private var lastTrackID: String?
    private var lastLibraryCheck = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var notificationToken: NSObjectProtocol?
    private var lastPermission: PermissionStatus?
    private let artworkCache = LockedArtworkCache()
    /// Set once at the end of `init`, never replaced.
    private var fanout: SnapshotFanout<AppleMusicSnapshot>!

    public init(launchPolicy: LaunchPolicy = .launchInBackground, libraryTTL: TimeInterval = 60, pollInterval: TimeInterval = 1.5) {
        self.launchPolicy = launchPolicy
        self.libraryTTL = libraryTTL
        self.pollInterval = max(0.5, pollInterval)
        fanout = SnapshotFanout { [weak self] active in
            self?.queue.async { active ? self?.startObserving() : self?.stopObserving() }
        }
    }

    deinit {
        timer?.cancel()
        if let notificationToken { DistributedNotificationCenter.default().removeObserver(notificationToken) }
        fanout.finish()
    }

    public static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public static var isRunning: Bool { MediaAppController.isRunning(.music) }

    // MARK: Health

    public func health() async -> AppleMusicHealth {
        var h = AppleMusicHealth(backend: .musicApp, permission: .automation, permissionStatus: .notDetermined)
        guard Self.isInstalled else {
            h.issues = [.sourceAppNotInstalled(source: .appleMusic, bundleID: Self.bundleID, name: "Music")]
            return h
        }
        guard Self.isRunning else {
            h.permissionStatus = queue.sync { lastPermission } ?? .notDetermined
            if launchPolicy == .never {
                h.issues.append(.sourceAppNotRunning(source: .appleMusic, bundleID: Self.bundleID, name: "Music"))
            }
            if h.permissionStatus != .granted {
                h.issues.append(.permissionMissing(permission: .automation, status: h.permissionStatus))
            }
            return h
        }
        h.permissionStatus = await automationStatus(ask: false)
        if h.permissionStatus != .granted {
            h.issues.append(.permissionMissing(permission: .automation, status: h.permissionStatus))
        } else if let elsewhere = try? await call("airplayelsewhere"), (MusicAppParsing.int(elsewhere) ?? 0) > 0 {
            h.notes.append("Music is sending its sound to AirPlay speakers itself, so Multicast can't hear it. Choose this Mac in Music's AirPlay menu.")
        }
        return h
    }

    public func requestAccess() async -> PermissionStatus {
        do { try await ensureRunning() } catch { return queue.sync { lastPermission } ?? .notDetermined }
        return await automationStatus(ask: true)
    }

    /// The Automation status without ever prompting (opens Music hidden first when the launch
    /// policy allows, since the status of a closed app cannot be read).
    public func currentAccess() async -> PermissionStatus {
        do { try await ensureRunning() } catch { return queue.sync { lastPermission } ?? .notDetermined }
        return await automationStatus(ask: false)
    }

    private func automationStatus(ask: Bool) async -> PermissionStatus {
        let status: PermissionStatus = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
                let s = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
                switch s {
                case noErr: c.resume(returning: .granted)
                case OSStatus(errAEEventNotPermitted): c.resume(returning: .denied)
                default: c.resume(returning: .notDetermined)
                }
            }
        }
        queue.sync { lastPermission = status }
        return status
    }

    // MARK: Browse

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> {
        try await libraryIndex().page(page)
    }

    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        let index = try await libraryIndex()
        let results = queue.sync { searchCache.results(for: query, revision: libraryRevision) { index.search(query) } }
        return Page.slice(results, page)
    }

    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> {
        try await ensureRunning()
        if let cached = queue.sync(execute: { playlistCache }), Date().timeIntervalSince(cached.builtAt) < libraryTTL {
            return Page.slice(cached.items, page)
        }
        let items = try MusicAppParsing.playlists(try await call("playlistlist"))
        queue.sync { playlistCache = (items, Date()) }
        return Page.slice(items, page)
    }

    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try Self.validate(id: playlistID)
        try await ensureRunning()
        if let cached = queue.sync(execute: { playlistTracks[playlistID] }), Date().timeIntervalSince(cached.builtAt) < libraryTTL {
            return cached.index.page(page)
        }
        let index = LibraryIndex(tracks: try MusicAppParsing.trackColumns(try await call("playlisttracks", .init(string: playlistID))))
        queue.sync {
            if playlistTracks.count >= 8, let oldest = playlistTracks.min(by: { $0.value.builtAt < $1.value.builtAt })?.key {
                playlistTracks[oldest] = nil
            }
            playlistTracks[playlistID] = (index, Date())
        }
        return index.page(page)
    }

    public func upNext(_ page: PageRequest) async throws -> Page<TrackItem> {
        guard Self.isRunning else { return .empty }
        let start = page.offset
        let reply = try await call("upnext", .init(int32: Int32(clamping: start + 1)), .init(int32: Int32(clamping: start + page.clampedLimit)))
        switch try MusicAppParsing.upNext(reply) {
        case .tracks(let items, let remaining):
            let end = start + items.count
            return Page(items: items, nextCursor: end < remaining ? String(end) : nil, totalCount: remaining)
        case .stopped, .shuffled, .unknown:
            return .empty
        }
    }

    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        guard case .musicAppTrack(let pid)? = AppleMusicArtworkRef(artworkID: id) else { return nil }
        let key = ArtworkCache.Key(id: id, maxPixel: max(0, maxPixel))
        if let hit = artworkCache.data(for: key) { return hit }
        guard Self.isRunning, let reply = try? await call("artworkdata", .init(string: pid)) else { return nil }
        if reply.descriptorType == typeUnicodeText || reply.descriptorType == typeUTF8Text || MusicAppParsing.isMissing(reply) {
            return nil
        }
        let raw = reply.data
        guard !raw.isEmpty, let scaled = ArtworkScaler.scale(raw, maxPixel: max(0, maxPixel)) else { return nil }
        artworkCache.insert(scaled, for: key)
        return scaled
    }

    public func invalidateLibrary() async {
        queue.sync {
            library = nil
            playlistCache = nil
            playlistTracks = [:]
        }
    }

    /// The song index, rebuilt when stale and Music's track count changed.
    private func libraryIndex() async throws -> LibraryIndex {
        try await ensureRunning()
        if let cached = queue.sync(execute: { library }) {
            if Date().timeIntervalSince(cached.checkedAt) < libraryTTL { return cached.index }
            let count = MusicAppParsing.int(try await call("librarycount")) ?? -1
            if count == cached.index.count {
                queue.sync { library?.checkedAt = Date() }
                return cached.index
            }
        }
        let tracks = try MusicAppParsing.trackColumns(try await call("librarytracks"))
        let index = LibraryIndex(tracks: tracks, order: .title)
        let changed: Bool = queue.sync {
            let changed = library.map { $0.index != index } ?? false
            library = (index, Date())
            if changed {
                libraryRevision &+= 1
                playlistCache = nil
                playlistTracks = [:]
            }
            return changed
        }
        if changed { queue.async { self.poll(force: true) } }
        return index
    }

    // MARK: Play

    public func play(trackID: String, context: TrackContext) async throws {
        try Self.validate(id: trackID)
        try await ensureRunning()
        switch context {
        case .songs, .search:
            _ = try await call("playtrack", .init(string: trackID), .init(string: ""))
        case .playlist(let pid):
            try Self.validate(id: pid)
            _ = try await call("playtrack", .init(string: trackID), .init(string: pid))
        case .upNext:
            _ = try await call("playincurrent", .init(string: trackID))
        case .files:
            throw HubCommandError(.unsupported, "Files aren't played through Apple Music.")
        }
        refreshSoon()
    }

    public func play(playlistID: String, shuffled: Bool) async throws {
        try Self.validate(id: playlistID)
        try await ensureRunning()
        _ = try await call("playplaylist", .init(string: playlistID), .init(boolean: shuffled))
        refreshSoon()
    }

    public func insertNext(trackIDs: [String]) async throws {
        throw HubCommandError(.unsupported, "The Music app doesn't let other apps change Up Next.")
    }

    public func append(trackIDs: [String]) async throws {
        throw HubCommandError(.unsupported, "The Music app doesn't let other apps change Up Next.")
    }

    // MARK: Transport

    public func play() async throws { try await transport("play") }
    public func pause() async throws { try await transport("pause") }
    public func next() async throws { try await transport("next") }
    public func previous() async throws { try await transport("previous") }
    public func seek(to position: TimeInterval) async throws { try await transport("seek", position: position) }
    /// Stops Music's playback (not part of the hub vocabulary; used by probes and teardown).
    public func stop() async throws { try await transport("stop") }

    private func transport(_ cmd: String, position: TimeInterval = 0) async throws {
        guard Self.isRunning else { throw HubCommandError(.unavailable, "Music isn't open.") }
        _ = try await call("transport", .init(string: cmd), .init(double: max(0, position)))
        refreshSoon()
    }

    /// Music's own volume, 0…100. The tap hears Music after this volume is applied.
    public func musicVolume() async throws -> Int {
        guard Self.isRunning else { throw HubCommandError(.unavailable, "Music isn't open.") }
        return MusicAppParsing.int(try await call("getvolume")) ?? 0
    }

    public func setMusicVolume(_ volume: Int) async throws {
        guard Self.isRunning else { throw HubCommandError(.unavailable, "Music isn't open.") }
        _ = try await call("setvolume", .init(int32: Int32(min(max(volume, 0), 100))))
    }

    /// The player right now (one Apple Event).
    public func playerState() async throws -> MusicAppParsing.PlayerState {
        guard Self.isRunning else { throw HubCommandError(.unavailable, "Music isn't open.") }
        return try MusicAppParsing.playerState(try await call("playerstate"))
    }

    /// How many AirPlay devices other than this Mac Music is currently sending to itself.
    public func airPlayDevicesElsewhere() async throws -> Int {
        guard Self.isRunning else { throw HubCommandError(.unavailable, "Music isn't open.") }
        return MusicAppParsing.int(try await call("airplayelsewhere")) ?? 0
    }

    // MARK: Updates

    public func updates() -> AsyncStream<AppleMusicSnapshot> {
        fanout.stream()
    }

    private func startObserving() {
        guard timer == nil else { return }
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(MediaApp.music.playbackNotificationName), object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.poll(force: false) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll(force: false) }
        t.resume()
        timer = t
    }

    private func stopObserving() {
        guard fanout.subscriberCount == 0 else { return }
        timer?.cancel()
        timer = nil
        if let notificationToken { DistributedNotificationCenter.default().removeObserver(notificationToken) }
        notificationToken = nil
    }

    private func refreshSoon() {
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in self?.poll(force: false) }
    }

    /// Reads the player and publishes when something changed. Queue only.
    private func poll(force: Bool) {
        let sampled = Date()
        var state: MusicAppParsing.PlayerState?
        if Self.isRunning, let reply = try? runSync("playerstate", []) {
            state = try? MusicAppParsing.playerState(reply)
        }
        if Self.isRunning, library != nil, sampled.timeIntervalSince(lastLibraryCheck) > max(libraryTTL, 30) {
            lastLibraryCheck = sampled
            if let reply = try? runSync("librarycount", []), let count = MusicAppParsing.int(reply), count != library?.index.count {
                library = nil
                playlistCache = nil
                playlistTracks = [:]
                libraryRevision &+= 1
            }
        }
        let trackID = state?.track?.persistentID
        if trackID != lastTrackID {
            lastTrackID = trackID
            upNextRevision &+= 1
        }
        let snap = state.map { MusicAppParsing.snapshot($0, sampledAt: sampled, upNextRevision: upNextRevision, libraryRevision: libraryRevision) }
            ?? AppleMusicSnapshot(nowPlaying: nil, transport: TransportState(isPlaying: false, position: 0, positionAsOf: sampled, canSkip: false, canSeek: false),
                                  upNextRevision: upNextRevision, libraryRevision: libraryRevision)
        if force || snap.isSignificantChange(from: fanout.current) {
            fanout.publish(snap)
        }
    }

    // MARK: Capture

    /// A tap on the Music process (and any helper it uses), muted on the Mac while Multicast
    /// reads it.
    public func makeAudioSource() -> AudioSource {
        AppAudioTapSource(target: .apps(bundleIDs: [Self.bundleID]), muteBehavior: .mutedWhenTapped, displayName: "Apple Music")
    }

    // MARK: Apple Events

    /// Opens Music hidden when allowed, and waits until it answers.
    private func ensureRunning() async throws {
        if Self.isRunning { return }
        guard launchPolicy == .launchInBackground else {
            throw HubCommandError(.unavailable, "Music isn't open.")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw HubCommandError(.unavailable, "Music isn't installed.")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } catch {
            throw HubCommandError(.unavailable, "Music couldn't be opened.")
        }
        // Wait for launch to finish without sending Apple Events: an event here could be the
        // one that raises the Automation prompt, which `requestAccess` should own.
        for _ in 0..<60 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains(where: { $0.isFinishedLaunching }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw HubCommandError(.unavailable, "Music didn't finish opening.")
    }

    private func call(_ handler: String, _ params: NSAppleEventDescriptor...) async throws -> NSAppleEventDescriptor {
        // Descriptors are created here and used only on the queue afterwards.
        let boxed = DescriptorBox(params)
        let enqueued = MulticastTiming.now
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                let started = MulticastTiming.now
                let result = Result { try self.runSync(handler, boxed.items) }
                MulticastTiming.log.debug("music.ae \(handler, privacy: .public) wait=\((started &- enqueued) / 1_000_000)ms run=\(MulticastTiming.ms(since: started))ms ok=\((try? result.get()) != nil)")
                c.resume(with: result.map(DescriptorBox.one))
            }
        }.items[0]
    }

    /// Calls one handler of `MusicAppScript`. Queue only.
    private func runSync(_ handler: String, _ params: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        let s = try compiledScript()
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, p) in params.enumerated() { list.insert(p, at: i + 1) }
        event.setDescriptor(list, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        let result = s.executeAppleEvent(event, error: &err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = (err[NSAppleScript.errorMessage] as? String) ?? ""
            if code == -1743 || code == -1744 { lastPermission = code == -1743 ? .denied : .notDetermined }
            throw MusicAppParsing.commandError(code: code, message: message)
        }
        return result
    }

    private func compiledScript() throws -> NSAppleScript {
        if let script { return script }
        guard let s = NSAppleScript(source: MusicAppScript.source) else {
            throw HubCommandError(.failed, "The Music script could not be created.")
        }
        var err: NSDictionary?
        guard s.compileAndReturnError(&err) else {
            let message = (err?[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw HubCommandError(.failed, "The Music script did not compile: \(message)")
        }
        script = s
        return s
    }

    /// Ids go to Music as descriptor values (never into script text); still refuse anything
    /// that cannot be a Music persistent id.
    static func validate(id: String) throws {
        guard AppleMusicArtworkRef.isPersistentID(id) else {
            throw HubCommandError(.notFound, "That item is no longer in your Music library.")
        }
    }
}
#endif
