import Foundation
import Observation
import SwiftUI

/// A failed transport or source command, shown as an alert.
struct HubAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// The one object views read from and send intents to. It mirrors the backend's slices into
/// observable properties (so a level update only invalidates the meter), applies the obvious
/// result of a command at once, sends commands to the backend in order through one pipe, and
/// rolls back to the last published state when a command is refused.
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
    private(set) var capturedAppID: String?
    private(set) var library = LibrarySnapshot()
    private(set) var files: [TrackItem] = []
    private(set) var capturableApps: [CapturableApp] = []
    private(set) var spotify: SpotifyStatus = .notRunning
    private(set) var spotifyHistory: [TrackItem] = []
    private(set) var status = HubStatus()
    private(set) var levels: StereoLevels = .silent
    private(set) var artworkCache: [ArtworkID: Data] = [:]

    // Navigation that other surfaces (menu commands, the menu-bar panel) also drive.
    var browsingSource: SourceKind = .appleMusic
    /// A refused transport or source command. Speaker failures show in the speaker's row.
    var alert: HubAlert?
    /// Set by the root views from the environment; structural changes animate with it.
    @ObservationIgnored var reduceMotion = false

    @ObservationIgnored private let backend: HubBackend
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let commands: AsyncStream<Command>.Continuation
    @ObservationIgnored private let commandStream: AsyncStream<Command>
    @ObservationIgnored private var published = HubState()
    @ObservationIgnored private var artworkRequests: Set<ArtworkID> = []

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

    private struct Command: Sendable {
        var kind: Kind
        var run: @Sendable (HubBackend) async throws -> Void
        enum Kind { case speaker, transport, source }
    }

    nonisolated static let throttle: Duration = .milliseconds(50)
    nonisolated static let echoWindow: TimeInterval = 0.5

    init(backend: HubBackend) {
        self.backend = backend
        (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
    }

    /// For snapshots and previews: start from a fixed state without subscribing.
    convenience init(backend: HubBackend, state: HubState, artwork: [ArtworkID: Data] = [:],
                     levels: StereoLevels = .silent, browsing: SourceKind? = nil) {
        self.init(backend: backend)
        apply(state.speakers); apply(state.playback); apply(state.sources); apply(state.status)
        artworkCache = artwork
        self.levels = levels
        if let browsing { browsingSource = browsing }
    }

    func start() {
        guard tasks.isEmpty else { return }
        let backend = backend
        let commandStream = commandStream
        tasks.append(Task { [weak self] in
            for await s in await backend.speakerStates() { self?.apply(s) }
        })
        tasks.append(Task { [weak self] in
            for await s in await backend.playbackStates() { self?.apply(s) }
        })
        tasks.append(Task { [weak self] in
            for await s in await backend.sourceStates() { self?.apply(s) }
        })
        tasks.append(Task { [weak self] in
            for await s in await backend.statusStates() { self?.apply(s) }
        })
        tasks.append(Task { [weak self] in
            for await levels in await backend.levels() { self?.levels = levels }
        })
        // One consumer, so commands reach the backend in the order they were made.
        tasks.append(Task { [weak self] in
            for await command in commandStream {
                do { try await command.run(backend) } catch {
                    self?.refused(command.kind, error)
                }
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    // MARK: Applying backend state

    private var structural: Animation { MC.Motion.state(reduceMotion) }

    private func apply(_ s: SpeakersState) {
        published.speakers = s
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

    private func apply(_ s: PlaybackState) {
        published.playback = s
        let newTrack = nowPlaying?.identity != s.nowPlaying?.identity
        if newTrack || activeSource != s.activeSource || capturedAppID != s.capturedAppID {
            withAnimation(structural) {
                activeSource = s.activeSource
                capturedAppID = s.capturedAppID
                nowPlaying = s.nowPlaying
                transport = s.transport
            }
        } else {
            if nowPlaying != s.nowPlaying { nowPlaying = s.nowPlaying }
            if transport != s.transport { transport = s.transport }
        }
    }

    private func apply(_ s: SourcesState) {
        published.sources = s
        if library != s.library { library = s.library }
        if files != s.files { withAnimation(structural) { files = s.files } }
        if capturableApps != s.capturableApps { withAnimation(structural) { capturableApps = s.capturableApps } }
        if spotify != s.spotify { spotify = s.spotify }
        if spotifyHistory != s.spotifyHistory { withAnimation(structural) { spotifyHistory = s.spotifyHistory } }
    }

    private func apply(_ s: HubStatus) {
        published.status = s
        if status != s { withAnimation(structural) { status = s } }
    }

    /// A command was refused: drop optimistic edits and show the last state the backend published.
    private func refused(_ kind: Command.Kind, _ error: Error) {
        pendingVolume.removeAll(); pendingTrim.removeAll(); pendingMaster = nil
        let last = published
        apply(last.speakers); apply(last.playback); apply(last.sources)
        if kind != .speaker {
            alert = HubAlert(title: kind == .transport ? "Couldn\u{2019}t control playback" : "Couldn\u{2019}t switch source",
                             message: error.localizedDescription)
        }
    }

    // MARK: Artwork

    /// Cached artwork bytes; a miss asks the backend once and fills the cache when it answers.
    func artwork(_ id: ArtworkID?) -> Data? {
        guard let id else { return nil }
        if let hit = artworkCache[id] { return hit }
        if !artworkRequests.contains(id) {
            artworkRequests.insert(id)
            let backend = backend
            Task { [weak self] in
                let data = await backend.artwork(id: id)
                guard let self, let data else { return }
                self.artworkCache[id] = data
            }
        }
        return nil
    }

    // MARK: Derived

    var networkSpeakers: [SpeakerItem] { speakers.filter { $0.transport.isNetwork } }
    var localSpeakers: [SpeakerItem] { speakers.filter { !$0.transport.isNetwork } }
    var enabledCount: Int { speakers.filter(\.isEnabled).count }

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
    var needsLocalNetwork: Bool { status.permission(.localNetwork) == .denied }

    // MARK: Intents

    func togglePlayPause() {
        guard canPlay else { return }
        let playing = transport.isPlaying
        transport.position = transport.position(at: .now)
        transport.positionAsOf = .now
        transport.isPlaying.toggle()
        send(.transport) { playing ? try await $0.pause() : try await $0.play() }
    }

    func next() { send(.transport) { try await $0.next() } }
    func previous() { send(.transport) { try await $0.previous() } }

    func seek(to position: TimeInterval) {
        transport.position = position
        transport.positionAsOf = .now
        send(.transport) { try await $0.seek(to: position) }
    }

    func setEnabled(_ enabled: Bool, for id: SpeakerID) {
        mutateSpeaker(id) {
            $0.isEnabled = enabled
            $0.state = enabled ? .connecting : .off
        }
        send(.speaker) { try await $0.setSpeaker(id, enabled: enabled) }
    }

    func toggle(_ id: SpeakerID) {
        guard let s = speaker(id) else { return }
        setEnabled(!s.isEnabled, for: id)
    }

    /// Called at drag rate. The row moves at once; the backend hears at most every 50 ms.
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
        send(.speaker) { try await $0.setSpeaker(id, volume: v) }
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
        send(.speaker) { try await $0.setSpeaker(id, syncTrimMs: v) }
    }

    func retry(_ id: SpeakerID) {
        mutateSpeaker(id) { $0.state = .connecting }
        send(.speaker) { try await $0.retrySpeaker(id) }
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
        send(.speaker) { try await $0.setMasterVolume(v) }
    }

    func nudgeMasterVolume(_ delta: Double) {
        setMasterVolume(masterVolume + delta)
        commitMasterVolume()
    }

    func selectSource(_ source: SourceKind) {
        browsingSource = source
        send(.source) { try await $0.selectSource(source) }
    }

    func playTrack(_ id: String) { send(.source) { try await $0.playTrack(id: id) } }
    func playPlaylist(_ id: String) { send(.source) { try await $0.playPlaylist(id: id) } }

    func captureApp(_ bundleID: String) {
        withAnimation(structural) { capturedAppID = bundleID }
        send(.source) { try await $0.captureApp(bundleID: bundleID) }
    }

    func addFiles(_ urls: [URL]) { send(.source) { try await $0.addFiles(urls) } }
    func openSpotify() { send(.source) { try await $0.openSpotify() } }
    func requestPermission(_ p: HubPermission) { send(.source) { try await $0.requestPermission(p) } }

    // MARK: Plumbing

    private func mutateSpeaker(_ id: SpeakerID, _ change: (inout SpeakerItem) -> Void) {
        guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        change(&speakers[i])
    }

    private func send(_ kind: Command.Kind, _ run: @escaping @Sendable (HubBackend) async throws -> Void) {
        commands.yield(Command(kind: kind, run: run))
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

private extension NowPlayingInfo {
    /// What makes it a different item rather than an update to the same one.
    var identity: String { trackID ?? "\(title)\u{1F}\(artist)" }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
