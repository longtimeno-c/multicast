import Foundation
import MulticastHubModel
import Testing
@testable import MulticastRemote

// Tests that touch system services. Opt-in so `swift test` never advertises on the network or
// writes to the login keychain unasked:
//   MULTICAST_BONJOUR_TEST=1   advertise + browse + connect over real Bonjour (loopback interface)
//   MULTICAST_KEYCHAIN_TEST=1  round-trip KeychainPairingKeyStore (items removed afterwards)

private let env = ProcessInfo.processInfo.environment

@Suite(.serialized) struct SystemTests {
    @Test(.enabled(if: env["MULTICAST_BONJOUR_TEST"] == "1"))
    func advertisesBrowsesAndConnectsOverBonjour() async throws {
        let hubID = "test-hub-\(UUID().uuidString.prefix(8).lowercased())"
        let stores = (hub: InMemoryPairingKeyStore(), remote: InMemoryPairingKeyStore())
        let key = randomBytes(32)
        try stores.hub.save(PairingRecord(peerID: "remote-a", peerName: "Test Phone", key: key))
        try stores.remote.save(PairingRecord(peerID: hubID, peerName: "Multicast Test Hub", key: key))

        var config = HubServer.Configuration(hubID: hubID, name: "Multicast Test Hub")
        config.advertises = true
        config.loopbackOnly = true
        let backend = TestBackend(masterVolume: 0.42)
        let server = HubServer(backend: backend, configuration: config, keyStore: stores.hub)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // Browse: the advertisement carries the id, name and protocol version.
        let found = try await first(HubBrowser(loopbackOnly: true).hubs(), within: 10, "advertisement") {
            $0.contains { $0.id == hubID }
        }
        let hub = try #require(found.first { $0.id == hubID })
        #expect(hub.name == "Multicast Test Hub")
        #expect(hub.protocolVersion == RemoteProtocol.currentVersion)
        print("Bonjour: found \(hub.name) at \(hub.endpoint), listener port \(port)")

        // Connect by hub id: browse again, resolve, handshake, mirror.
        var remoteConfig = RemoteHubBackend.Configuration(remoteID: "remote-a", remoteName: "Test Phone", target: .hub(id: hubID))
        remoteConfig.loopbackBrowsing = true
        let remote = RemoteHubBackend(configuration: remoteConfig, keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        let state = try await first(await remote.states(), within: 10, "mirrored state") { $0.masterVolume == 0.42 }
        #expect(state.speakers.count == 2)
        guard case .connected(let connectedHub) = remote.connectionState else {
            Issue.record("not connected: \(remote.connectionState)")
            return
        }
        #expect(connectedHub.id == hubID)
        try await remote.play()
        #expect(backend.commands == [.play])
    }

    @Test(.enabled(if: env["MULTICAST_KEYCHAIN_TEST"] == "1"))
    func keychainStoreRoundTrips() throws {
        let store = KeychainPairingKeyStore(service: "io.github.longtimeno-c.multicast.tests.\(UUID().uuidString)")
        defer {
            for r in (try? store.allRecords()) ?? [] { try? store.remove(peerID: r.peerID) }
        }
        #expect(try store.record(for: "remote-a") == nil)
        let a = PairingRecord(peerID: "remote-a", peerName: "Phone A", key: randomBytes(32),
                              pairedAt: Date(timeIntervalSinceReferenceDate: 100))
        let b = PairingRecord(peerID: "remote-b", peerName: "Phone B", key: randomBytes(32),
                              pairedAt: Date(timeIntervalSinceReferenceDate: 200))
        try store.save(a)
        try store.save(b)
        #expect(try store.record(for: "remote-a") == a)
        var a2 = a
        a2.key = randomBytes(32)
        try store.save(a2)                                    // replaces, doesn't duplicate
        #expect(try store.record(for: "remote-a") == a2)
        #expect(try store.allRecords().map(\.peerID) == ["remote-a", "remote-b"])
        try store.remove(peerID: "remote-a")
        try store.remove(peerID: "remote-a")                  // removing twice is fine
        #expect(try store.allRecords() == [b])
    }
}
