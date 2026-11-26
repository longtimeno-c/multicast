import CryptoKit
import Foundation
import MulticastHubModel
import Network
import Testing
@testable import MulticastRemote

// MARK: - A backend to serve

/// An in-memory hub: records commands, serves pages and artwork, and lets tests drive state and levels.
final class TestBackend: HubBackend, @unchecked Sendable {
    let broadcaster: HubStateBroadcaster
    let levelsOut = Broadcast<StereoLevels>(replaysLatest: false, policy: .bufferingNewest(1))
    private let recorded = Locked<[HubCommand]>([])
    private let artworkAsks = Locked<[(String, Int)]>([])
    private let queryLimits = Locked<[Int]>([])
    let performDelay: TimeInterval
    let songsList: [TrackItem]
    let playlistList: [PlaylistItem]
    let artworkStore: [ArtworkID: Data]
    var searchError: HubCommandError?

    static let speakers = [
        SpeakerItem(id: "542a1b001122", name: "Main Bedroom", transport: .airPlay1, glyph: .airportExpress, volume: 0.4),
        SpeakerItem(id: "542a1b003344", name: "Hall Sonos", transport: .airPlay2, glyph: .smartSpeaker, volume: 0.5),
    ]

    init(masterVolume: Double = 0.6, performDelay: TimeInterval = 0) {
        broadcaster = HubStateBroadcaster(HubState(speakers: Self.speakers, masterVolume: masterVolume))
        self.performDelay = performDelay
        songsList = (0..<250).map {
            TrackItem(id: "s\($0)", title: "Song \($0)", artist: "Artist", album: "Album", duration: 180,
                      artworkID: "cover.\($0 % 3)")
        }
        playlistList = (0..<3).map { PlaylistItem(id: "p\($0)", name: "Playlist \($0)", trackCount: 10) }
        artworkStore = ["cover.0": Data(repeating: 0xAB, count: 50_000), "cover.1": Data([1, 2, 3])]
    }

    var commands: [HubCommand] { recorded.value }
    var artworkRequests: [(String, Int)] { artworkAsks.value }
    var limitsSeen: [Int] { queryLimits.value }

    func states() async -> AsyncStream<HubState> { broadcaster.stream() }
    func levels() async -> AsyncStream<StereoLevels> { levelsOut.stream() }

    func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        artworkAsks.withLock { $0.append((id, maxPixel)) }
        return artworkStore[id]
    }

    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .slice(playlistList, page) }
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        guard playlistID == "p1" else { throw HubCommandError(.notFound, "No such playlist.") }
        return .slice(Array(songsList.prefix(10)), page)
    }
    func songs(_ page: PageRequest) async throws -> Page<TrackItem> {
        queryLimits.withLock { $0.append(page.limit) }
        return .slice(songsList, page)
    }
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        if let searchError { throw searchError }
        return .slice(songsList.filter { $0.title.contains(query) }, page)
    }
    func searchCatalog(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        .slice([TrackItem(id: CatalogTrackID.make("900"), title: "Catalog \(query)", artist: "Far Shore", album: "", duration: 180)], page)
    }
    func upNext(_ page: PageRequest) async throws -> Page<QueueItem> {
        .slice(songsList.prefix(5).enumerated().map { QueueItem(id: "q\($0.offset)", source: .appleMusic, track: $0.element) }, page)
    }
    func files(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }

    func perform(_ command: HubCommand) async throws {
        if performDelay > 0 { try await Task.sleep(nanoseconds: UInt64(performDelay * 1e9)) }
        recorded.withLock { $0.append(command) }
        switch command {
        case .setMasterVolume(let v): broadcaster.update { $0.masterVolume = v }
        case .play: broadcaster.update { $0.transport.isPlaying = true }
        case .pause: broadcaster.update { $0.transport.isPlaying = false }
        case .setSpeakerVolume(let id, let v):
            broadcaster.update { s in
                if let i = s.speakers.firstIndex(where: { $0.id == id }) { s.speakers[i].volume = v }
            }
        case .retrySpeaker:
            throw HubCommandError(.unavailable, "Nothing to retry.")
        default: break
        }
    }
}

// MARK: - Fixtures

enum Fixture {
    static let hubID = "hub-0001"
    static let hubName = "Studio Mac"

    static func serverConfig(_ tweak: (inout HubServer.Configuration) -> Void = { _ in }) -> HubServer.Configuration {
        var c = HubServer.Configuration(hubID: hubID, name: hubName)
        c.advertises = false
        c.loopbackOnly = true
        c.handshakeTimeout = 2
        c.pairingTimeout = 5
        c.heartbeatInterval = 0.5
        c.deadAfter = 3
        tweak(&c)
        return c
    }

    static func remoteConfig(port: UInt16, id: String = "remote-a", name: String = "Test Phone",
                             _ tweak: (inout RemoteHubBackend.Configuration) -> Void = { _ in }) -> RemoteHubBackend.Configuration {
        var c = RemoteHubBackend.Configuration(remoteID: id, remoteName: name, target: .host("127.0.0.1", port: port))
        c.connectTimeout = 2
        c.handshakeTimeout = 2
        c.requestTimeout = 3
        c.heartbeatInterval = 0.5
        c.deadAfter = 3
        c.pairingTimeout = 6
        c.reconnectDelay = 0.05...0.3
        tweak(&c)
        return c
    }

    /// Hub and remote stores that already share a key (skips pairing).
    static func pairedStores(remoteID: String = "remote-a", hubKey: Data? = nil, remoteKey: Data? = nil)
        -> (hub: InMemoryPairingKeyStore, remote: InMemoryPairingKeyStore) {
        let key = randomBytes(32)
        return (InMemoryPairingKeyStore([PairingRecord(peerID: remoteID, peerName: "Test Phone", key: hubKey ?? key)]),
                InMemoryPairingKeyStore([PairingRecord(peerID: hubID, peerName: hubName, key: remoteKey ?? key)]))
    }
}

struct Timeout: Error, CustomStringConvertible {
    var what: String
    var description: String { "timed out waiting for \(what)" }
}

/// The first element of `stream` that satisfies `predicate`, or throws after `seconds`.
func first<T: Sendable>(_ stream: AsyncStream<T>, within seconds: TimeInterval = 5, _ what: String = "value",
                        where predicate: @escaping @Sendable (T) -> Bool) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return nil
        }
        defer { group.cancelAll() }
        guard let result = try await group.next(), let value = result else { throw Timeout(what: what) }
        return value
    }
}

/// Polls `condition` until true or throws after `seconds`.
func eventually(within seconds: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if !condition() { throw Timeout(what: what) }
}

extension RemoteConnectionState {
    var isConnected: Bool { if case .connected = self { true } else { false } }
    var pairingMessage: String?? {
        if case .pairingNeeded(_, let m) = self { return .some(m) }
        return nil
    }
    var notRecognisedMessage: String? {
        if case .notRecognised(_, let m, _) = self { return m }
        return nil
    }
    var enterCodeMessage: String?? {
        if case .pairing(_, .enterCode(let m)) = self { return .some(m) }
        return nil
    }
}

/// A raw TCP connection to a server, for feeding it bytes no real remote would send.
func rawLink(port: UInt16) async throws -> FramedConnection {
    let link = FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp),
                                label: "test")
    try await link.start(timeout: 2)
    return link
}

/// Sends raw bytes (no framing).
func sendRaw(_ link: FramedConnection, _ bytes: Data) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        link.connection.send(content: bytes, completion: .contentProcessed { e in
            if let e { c.resume(throwing: e) } else { c.resume() }
        })
    }
}

/// True if the server closes `link` (a read fails) within `seconds`.
func serverCloses(_ link: FramedConnection, within seconds: TimeInterval = 3) async -> Bool {
    do {
        _ = try await withDeadline(seconds, "close", onTimeout: { link.cancel() }) {
            while !Task.isCancelled { _ = try await link.receiveFrame(limit: RemoteProtocol.maxHubFrame) }
            return ()
        }
        return false
    } catch RemoteLinkError.timedOut {
        return false
    } catch {
        return true
    }
}

func stateStream(_ backend: RemoteHubBackend) async -> AsyncStream<HubState> { await backend.states() }
