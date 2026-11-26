import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastAppleMusic

/// Connects a MulticastAppleMusic provider (the Music app over Apple Events, or MusicKit) to
/// `LocalHub` as its `MusicPlayerProviding`.
///
/// The mapping is one to one except for two rules:
///  - The provider's status stream is only subscribed once its permission is granted. Watching
///    the Music app sends it Apple Events, and the first event from an app that was never
///    allowed is what puts up the Automation prompt; the hub must never prompt unasked.
///    `authorizationStatus()` (which `LocalHub.tick()` calls while access is missing) and
///    `requestAuthorization()` start the subscription as soon as they see `.granted`.
///  - A playlist is always played in order (`HubCommand.playPlaylist` has no shuffle).
public final class AppleMusicHubPlayer: MusicPlayerProviding, @unchecked Sendable {
    public let provider: AppleMusicProviding

    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<MusicPlayerStatus>.Continuation] = [:]
    private var latest = MusicPlayerStatus()
    private var forwarding: Task<Void, Never>?
    private var isClosed = false
    private var statusCheck: Task<PermissionStatus, Never>?
    private var lastStatus: PermissionStatus = .notDetermined
    /// How long `authorizationStatus()` waits for a slow check before answering from memory.
    public let statusWait: TimeInterval

    public init(provider: AppleMusicProviding, statusWait: TimeInterval = 2) {
        self.provider = provider
        self.statusWait = statusWait
    }

    deinit { forwarding?.cancel() }

    /// The System Settings pane that holds this backend's permission: Automation for the Music
    /// app, Media & Apple Music for MusicKit.
    public var settingsPermission: HubPermission {
        switch provider.kind {
        case .musicApp: .automation
        case .musicKit: .appleMusic
        }
    }

    // MARK: Status

    /// The provider's permission without prompting. Reading it can block for a long time (the
    /// system call behind the Music app's Automation status waits on Music), so at most one
    /// check runs at a time and a caller waits at most `statusWait` for it; otherwise it gets
    /// the last known status and the running check updates it later.
    public func authorizationStatus() async -> PermissionStatus {
        let started = MulticastTiming.now
        defer { MulticastTiming.log.debug("hub.music authorizationStatus \(MulticastTiming.ms(since: started))ms") }
        let check: Task<PermissionStatus, Never> = lock.withLock {
            if let running = statusCheck { return running }
            let provider = provider
            let t = Task<PermissionStatus, Never> { [weak self] in
                let status = await provider.health().permissionStatus
                self?.finishedCheck(status)
                return status
            }
            statusCheck = t
            return t
        }
        // Whichever comes first: the check's answer, or the wait running out. (A task group
        // would wait for the check anyway before returning.)
        let wait = statusWait
        let once = OnceFlag()
        return await withCheckedContinuation { (c: CheckedContinuation<PermissionStatus, Never>) in
            Task {
                let status = await check.value
                if once.claim() { c.resume(returning: status) }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if once.claim() { c.resume(returning: self?.lock.withLock { self?.lastStatus } ?? .notDetermined) }
            }
        }
    }

    private func finishedCheck(_ status: PermissionStatus) {
        lock.withLock {
            statusCheck = nil
            lastStatus = status
        }
        if status == .granted { startForwarding() }
    }

    public func refreshAuthorization() async -> PermissionStatus {
        let started = MulticastTiming.now
        let status = await provider.currentAccess()
        MulticastTiming.log.debug("hub.music refreshAuthorization \(MulticastTiming.ms(since: started))ms")
        lock.withLock { lastStatus = status }
        if status == .granted { startForwarding() }
        return status
    }

    public func requestAuthorization() async -> PermissionStatus {
        let status = await provider.requestAccess()
        lock.withLock { lastStatus = status }
        if status == .granted { startForwarding() }
        return status
    }

    public func statusUpdates() -> AsyncStream<MusicPlayerStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: MusicPlayerStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.lock()
        let closed = isClosed
        if !closed { subscribers[id] = continuation }
        let current = latest
        lock.unlock()
        continuation.yield(current)
        if closed { continuation.finish(); return stream }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    /// Stops forwarding and finishes every status stream.
    public func close() {
        lock.lock()
        isClosed = true
        let task = forwarding
        forwarding = nil
        let subs = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        task?.cancel()
        for s in subs { s.finish() }
    }

    /// Whether the provider's own stream is being followed (it is once access is granted).
    public var isForwarding: Bool {
        lock.lock(); defer { lock.unlock() }
        return forwarding != nil
    }

    private func startForwarding() {
        lock.lock()
        guard forwarding == nil, !isClosed else { lock.unlock(); return }
        let updates = provider.updates()
        forwarding = Task { [weak self] in
            for await snapshot in updates {
                self?.publish(Self.status(from: snapshot))
            }
        }
        lock.unlock()
    }

    private func publish(_ status: MusicPlayerStatus) {
        lock.lock()
        latest = status
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s.yield(status) }
    }

    /// One snapshot in the hub's terms.
    public static func status(from snapshot: AppleMusicSnapshot) -> MusicPlayerStatus {
        MusicPlayerStatus(nowPlaying: snapshot.nowPlaying,
                          isPlaying: snapshot.transport.isPlaying,
                          position: snapshot.transport.position,
                          positionAsOf: snapshot.transport.positionAsOf,
                          canSkip: snapshot.transport.canSkip,
                          canSeek: snapshot.transport.canSeek,
                          libraryRevision: snapshot.libraryRevision,
                          upNextRevision: snapshot.upNextRevision)
    }

    // MARK: Lists and playback
    //
    // Every one of these reaches the provider only once access is known to be granted: for the
    // Music app, the first Apple Event an undecided app sends IS the Automation prompt, and the
    // event then blocks until someone answers it.

    private func requireAccess() throws {
        let status = lock.withLock { lastStatus }
        guard status == .granted else {
            throw HubCommandError(.permissionMissing, status == .denied
                ? "Multicast isn\u{2019}t allowed to use Apple Music. Allow it in Privacy & Security."
                : "Allow Multicast to use Apple Music first.")
        }
    }

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> { try requireAccess(); return try await provider.songs(page) }
    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { try requireAccess(); return try await provider.playlists(page) }
    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try requireAccess()
        return try await provider.tracks(inPlaylist: playlistID, page)
    }
    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { try requireAccess(); return try await provider.search(query, page) }
    public func upNext(_ page: PageRequest) async throws -> Page<TrackItem> { try requireAccess(); return try await provider.upNext(page) }
    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        guard (try? requireAccess()) != nil else { return nil }
        return await provider.artwork(id: id, maxPixel: maxPixel)
    }

    public func play(trackID: String, context: TrackContext) async throws { try requireAccess(); try await provider.play(trackID: trackID, context: context) }
    public func play(playlistID: String) async throws { try requireAccess(); try await provider.play(playlistID: playlistID, shuffled: false) }
    public func play() async throws { try requireAccess(); try await provider.play() }
    public func pause() async {
        guard (try? requireAccess()) != nil else { return }
        try? await provider.pause()
    }
    public func next() async throws { try requireAccess(); try await provider.next() }
    public func previous() async throws { try requireAccess(); try await provider.previous() }
    public func seek(to position: TimeInterval) async throws { try requireAccess(); try await provider.seek(to: position) }

    public func makeAudioSource() throws -> AudioSource {
        #if os(macOS)
        return provider.makeAudioSource()
        #else
        throw HubCommandError(.unsupported, "Apple Music plays on the Mac.")
        #endif
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
