import Foundation
import MulticastAppleMusic
import MulticastAudio
import MulticastHubModel
import Testing
@testable import MulticastHub

/// An `AppleMusicProviding` that records what it is asked and counts subscriptions, so the
/// adapter's "never watch before access is granted" rule can be checked.
final class FakeAppleMusicProvider: AppleMusicProviding, @unchecked Sendable {
    let kind: AppleMusicBackendKind
    let supportsQueueEditing = false
    let permission = Locked<PermissionStatus>(.notDetermined)
    let requestAnswer = Locked<PermissionStatus>(.granted)
    let calls = Locked<[String]>([])
    /// Seconds `health()` takes, like the Music app's Automation check waiting on Music.
    let healthDelay = Locked<Double>(0)
    let healthCalls = Locked(0)
    let subscriptions = Locked(0)
    private let continuations = Locked<[AsyncStream<AppleMusicSnapshot>.Continuation]>([])

    init(kind: AppleMusicBackendKind = .musicApp) { self.kind = kind }

    func health() async -> AppleMusicHealth {
        healthCalls.update { $0 += 1 }
        let delay = healthDelay.get()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return AppleMusicHealth(backend: kind, permission: kind == .musicApp ? .automation : .appleMusic,
                         permissionStatus: permission.get())
    }
    func requestAccess() async -> PermissionStatus {
        calls.update { $0.append("requestAccess") }
        let answer = requestAnswer.get()
        permission.update { $0 = answer }
        return answer
    }
    func songs(_ page: PageRequest) async throws -> Page<TrackItem> {
        calls.update { $0.append("songs") }
        return .slice([TrackItem(id: "t1", title: "Low Tide", artist: "Harbour", album: "Coast", duration: 180)], page)
    }
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .empty }
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func upNext(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data? { Data("\(id)@\(maxPixel)".utf8) }
    func play(trackID: String, context: TrackContext) async throws { calls.update { $0.append("play \(trackID)") } }
    func play(playlistID: String, shuffled: Bool) async throws {
        calls.update { $0.append("playlist \(playlistID) shuffled=\(shuffled)") }
    }
    func insertNext(trackIDs: [String]) async throws { throw HubCommandError(.unsupported, "no") }
    func append(trackIDs: [String]) async throws { throw HubCommandError(.unsupported, "no") }
    func play() async throws { calls.update { $0.append("play") } }
    func pause() async throws { calls.update { $0.append("pause") } }
    func next() async throws { calls.update { $0.append("next") } }
    func previous() async throws { calls.update { $0.append("previous") } }
    func seek(to position: TimeInterval) async throws { calls.update { $0.append("seek \(Int(position))") } }
    func updates() -> AsyncStream<AppleMusicSnapshot> {
        subscriptions.update { $0 += 1 }
        let (stream, c) = AsyncStream.makeStream(of: AppleMusicSnapshot.self)
        continuations.update { $0.append(c) }
        return stream
    }
    func invalidateLibrary() async {}
    func makeAudioSource() -> AudioSource {
        calls.update { $0.append("makeAudioSource") }
        return FakeCaptureSource(bundleID: "com.apple.Music", name: "Apple Music")
    }

    func send(_ snapshot: AppleMusicSnapshot) {
        for c in continuations.get() { c.yield(snapshot) }
    }
}

@Suite("Apple Music adapter")
struct AppleMusicHubPlayerTests {
    @Test func doesNotWatchTheProviderUntilAccessIsGranted() async throws {
        let provider = FakeAppleMusicProvider()
        let player = AppleMusicHubPlayer(provider: provider)
        var it = player.statusUpdates().makeAsyncIterator()
        #expect(await it.next() == MusicPlayerStatus())       // the current (empty) status at once
        #expect(await player.authorizationStatus() == .notDetermined)
        #expect(provider.subscriptions.get() == 0)
        #expect(!player.isForwarding)

        // Granted in System Settings meanwhile: the next status check starts watching.
        provider.permission.update { $0 = .granted }
        #expect(await player.authorizationStatus() == .granted)
        #expect(provider.subscriptions.get() == 1)
        _ = await player.authorizationStatus()
        #expect(provider.subscriptions.get() == 1)               // once only

        let asOf = Date(timeIntervalSinceReferenceDate: 800_000_000)
        provider.send(AppleMusicSnapshot(
            nowPlaying: NowPlayingInfo(title: "Low Tide", artist: "Harbour", artworkID: "am.track.0A1B", duration: 180, trackID: "0A1B"),
            transport: TransportState(isPlaying: true, position: 12, positionAsOf: asOf, canSkip: true, canSeek: false),
            upNextRevision: 3, libraryRevision: 7))
        let status = try #require(await it.next())
        #expect(status.nowPlaying?.trackID == "0A1B")
        #expect(status.isPlaying && status.position == 12 && status.positionAsOf == asOf)
        #expect(status.canSkip && !status.canSeek)
        #expect(status.upNextRevision == 3 && status.libraryRevision == 7)
        player.close()
    }

    @Test func aSlowPermissionCheckNeitherBlocksNorPilesUp() async throws {
        let provider = FakeAppleMusicProvider()
        provider.permission.update { $0 = .granted }
        provider.healthDelay.update { $0 = 0.6 }
        let player = AppleMusicHubPlayer(provider: provider, statusWait: 0.05)
        let t0 = Date()
        #expect(await player.authorizationStatus() == .notDetermined)   // last known, not waited for
        #expect(await player.authorizationStatus() == .notDetermined)
        #expect(Date().timeIntervalSince(t0) < 0.5)
        #expect(provider.healthCalls.get() == 1)                         // one check in flight
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(player.isForwarding)                                     // the late answer still counts
        provider.healthDelay.update { $0 = 0 }
        #expect(await player.authorizationStatus() == .granted)
        player.close()
    }

    @Test func requestingAccessStartsWatchingOnlyWhenGranted() async {
        let provider = FakeAppleMusicProvider()
        provider.requestAnswer.update { $0 = .denied }
        let player = AppleMusicHubPlayer(provider: provider)
        #expect(await player.requestAuthorization() == .denied)
        #expect(provider.subscriptions.get() == 0)
        provider.requestAnswer.update { $0 = .granted }
        #expect(await player.requestAuthorization() == .granted)
        #expect(provider.subscriptions.get() == 1)
        player.close()
    }

    @Test func forwardsCommandsAndListsAndNamesTheRightSettingsPane() async throws {
        let provider = FakeAppleMusicProvider()
        let player = AppleMusicHubPlayer(provider: provider)
        // Nothing reaches the provider before access is known to be granted.
        await #expect(throws: HubCommandError.self) { try await player.songs(PageRequest(limit: 10)) }
        await player.pause()
        #expect(await player.artwork(id: "am.track.0A1B", maxPixel: 300) == nil)
        #expect(provider.calls.get().isEmpty)
        provider.permission.update { $0 = .granted }
        #expect(await player.authorizationStatus() == .granted)
        #expect(player.settingsPermission == .automation)
        #expect(AppleMusicHubPlayer(provider: FakeAppleMusicProvider(kind: .musicKit)).settingsPermission == .appleMusic)

        #expect(try await player.songs(PageRequest(limit: 10)).items.map(\.id) == ["t1"])
        try await player.play(playlistID: "P1")
        try await player.play(trackID: "t1", context: .songs)
        await player.pause()
        try await player.seek(to: 42)
        #expect(provider.calls.get() == ["songs", "playlist P1 shuffled=false", "play t1", "pause", "seek 42"])
        #expect(await player.artwork(id: "am.track.0A1B", maxPixel: 300) == Data("am.track.0A1B@300".utf8))
    }

    @Test func hubOpensTheBackendsOwnSettingsPaneWhenDenied() async throws {
        let rig = Rig()
        await rig.start()
        let provider = FakeAppleMusicProvider()
        provider.permission.update { $0 = .denied }
        await rig.hub.setMusicPlayer(AppleMusicHubPlayer(provider: provider))
        #expect(rig.state.health.permission(.appleMusic) == .denied)
        // Not selectable while denied: no capture tap is made for a player nobody may control.
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.selectSource(source: .appleMusic)) }
        #expect(provider.calls.get().isEmpty)
        try await rig.hub.perform(.requestPermission(permission: .appleMusic))
        await rig.hub.settle()
        #expect(rig.system.opened.get() == [.automation])
        #expect(!provider.calls.get().contains("requestAccess"))

        // Allowed in System Settings: the next health poll notices, without any prompt.
        provider.permission.update { $0 = .granted }
        await rig.hub.tick()
        #expect(rig.state.health.permission(.appleMusic) == .granted)
        #expect(provider.subscriptions.get() == 1)
        await rig.hub.shutdown()
    }
}
