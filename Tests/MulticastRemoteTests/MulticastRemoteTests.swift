import CryptoKit
import Foundation
import MulticastHubModel
import Network
import Testing
@testable import MulticastRemote

// Loopback tests: a TestBackend served by a real HubServer on 127.0.0.1 and mirrored by real
// RemoteHubBackends over TCP, in process. Serialized: they open sockets and time things.

@Suite(.serialized) struct LoopbackTests {
    private func startServer(_ backend: TestBackend, store: InMemoryPairingKeyStore,
                             _ tweak: (inout HubServer.Configuration) -> Void = { _ in }) async throws -> (HubServer, UInt16) {
        let server = HubServer(backend: backend, configuration: Fixture.serverConfig(tweak), keyStore: store)
        let port = try await server.start()
        return (server, port)
    }

    private func connected(_ remote: RemoteHubBackend) async throws {
        _ = try await first(remote.connectionStates(), within: 5, "connected") { $0.isConnected }
    }

    // MARK: State, commands, queries

    @Test func mirrorsStateAndCarriesCommandsInOrder() async throws {
        let backend = TestBackend()
        let stores = Fixture.pairedStores()
        let (server, port) = try await startServer(backend, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }

        let states = await remote.states()
        let initial = try await first(states, "initial state") { _ in true }
        #expect(initial.speakers.map(\.name) == ["Main Bedroom", "Hall Sonos"])
        #expect(initial.masterVolume == 0.6)
        try await connected(remote)

        // A change on the hub arrives with a higher revision.
        backend.broadcaster.update { $0.masterVolume = 0.33 }
        let changed = try await first(states, "pushed change") { $0.masterVolume == 0.33 }
        #expect(changed.revision > initial.revision)

        // Commands arrive in the order issued, and their effects come back as state.
        let sequence: [HubCommand] = [.play, .setSpeakerVolume(id: "542a1b001122", volume: 0.2), .seek(position: 42),
                                      .next, .setSpeakerSyncTrim(id: "542a1b003344", milliseconds: -40), .pause,
                                      .selectSource(source: .spotify), .setMasterVolume(volume: 0.5)]
        for c in sequence { try await remote.perform(c) }
        #expect(backend.commands == sequence)
        _ = try await first(states, "echo") { $0.masterVolume == 0.5 && !$0.transport.isPlaying }

        // A refusal comes back as the same HubCommandError.
        await #expect(throws: HubCommandError(.unavailable, "Nothing to retry.")) {
            try await remote.retrySpeaker("542a1b001122")
        }
        // Files on the Mac can't be named from a remote.
        await #expect(throws: HubCommandError.self) { try await remote.addFiles([URL(fileURLWithPath: "/tmp/x.flac")]) }
        #expect(backend.commands.count == sequence.count + 1)
    }

    @Test func answersPagedQueriesAndArtwork() async throws {
        let backend = TestBackend()
        backend.searchError = HubCommandError(.permissionMissing, "Allow Apple Music access on the Mac.")
        let stores = Fixture.pairedStores()
        let (server, port) = try await startServer(backend, store: stores.hub) { $0.maxArtworkPixel = 800 }
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        try await connected(remote)

        // Walk every page with the cursors the hub hands out.
        var all: [TrackItem] = []
        var request: PageRequest? = PageRequest(limit: 100)
        while let r = request {
            let page = try await remote.songs(r)
            all += page.items
            #expect(page.totalCount == 250)
            request = page.nextCursor.map { PageRequest(cursor: $0, limit: 100) }
        }
        #expect(all.map(\.id) == backend.songsList.map(\.id))

        // Oversized limits are clamped on the hub.
        let big = try await remote.songs(PageRequest(limit: 100_000))
        #expect(big.items.count == 250)
        #expect(backend.limitsSeen.last == PageRequest.limitRange.upperBound)

        #expect(try await remote.playlists(.first).items.count == 3)
        #expect(try await remote.tracks(inPlaylist: "p1", .first).items.count == 10)
        #expect(try await remote.upNext(.first).items.count == 5)
        await #expect(throws: HubCommandError(.notFound, "No such playlist.")) {
            try await remote.tracks(inPlaylist: "p9", .first)
        }
        await #expect(throws: HubCommandError(.permissionMissing, "Allow Apple Music access on the Mac.")) {
            try await remote.search("Song", .first)
        }

        // Catalog search is its own query (protocol version 3).
        #expect(try await remote.searchCatalog("tide", .first).items.map(\.id) == ["catalog:900"])

        // Artwork travels as binary; unknown ids are nil; sizes are capped.
        #expect(await remote.artwork(id: "cover.0", maxPixel: 300) == backend.artworkStore["cover.0"])
        #expect(await remote.artwork(id: "cover.1", maxPixel: 0) == Data([1, 2, 3]))
        #expect(await remote.artwork(id: "nope", maxPixel: 99_999) == nil)
        #expect(backend.artworkRequests.map(\.1) == [300, 800, 800])

        // Many queries at once all get their own answers.
        let pages = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<20 {
                group.addTask { (i, try await remote.songs(PageRequest(cursor: String(i * 10), limit: 1)).items.first?.id) }
            }
            return try await group.reduce(into: [Int: String?]()) { $0[$1.0] = $1.1 }
        }
        for i in 0..<20 { #expect(pages[i] == .some("s\(i * 10)")) }
    }

    @Test func levelsGoOnlyToSubscribersAtAReducedRate() async throws {
        let backend = TestBackend()
        let hubStore = InMemoryPairingKeyStore()
        let keyA = randomBytes(32), keyB = randomBytes(32)
        try hubStore.save(PairingRecord(peerID: "remote-a", peerName: "A", key: keyA))
        try hubStore.save(PairingRecord(peerID: "remote-b", peerName: "B", key: keyB))
        let (server, port) = try await startServer(backend, store: hubStore) { $0.levelsInterval = 0.1 }
        defer { Task { await server.stop() } }
        let a = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port, id: "remote-a"),
                                 keyStore: InMemoryPairingKeyStore([PairingRecord(peerID: Fixture.hubID, peerName: "", key: keyA)]))
        let b = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port, id: "remote-b"),
                                 keyStore: InMemoryPairingKeyStore([PairingRecord(peerID: Fixture.hubID, peerName: "", key: keyB)]))
        defer { Task { await a.stop(); await b.stop() } }
        a.start()
        b.start()
        try await connected(a)
        try await connected(b)

        let levels = await a.levels()
        let collected = Locked<[StereoLevels]>([])
        let reader = Task { for await l in levels { collected.withLock { $0.append(l) } } }
        defer { reader.cancel() }
        try await eventually("hub subscribed A to levels") { backend.levelsOut.subscriberCount == 1 }

        // 100 Hz for 0.6 s from the hub's meter, then silence.
        for i in 0..<60 {
            backend.levelsOut.yield(StereoLevels(left: Float(i) / 60, right: 0.5))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        backend.levelsOut.yield(.silent)
        try await eventually("silence reaches A") { collected.value.last == .silent }
        let count = collected.value.count
        #expect(count >= 4 && count <= 10, "got \(count) level frames for 0.6 s at a 0.1 s interval")
        #expect(b.levelsReceivedInSession == 0)
        #expect(server.levelFramesSent(remoteID: "remote-b") == 0)

        // Unsubscribing stops the flow at the hub.
        reader.cancel()
        try await eventually("hub unsubscribed") { backend.levelsOut.subscriberCount == 0 }
    }

    @Test func twoRemotesAtOnce() async throws {
        let backend = TestBackend()
        let hubStore = InMemoryPairingKeyStore()
        let keyA = randomBytes(32), keyB = randomBytes(32)
        try hubStore.save(PairingRecord(peerID: "remote-a", peerName: "A", key: keyA))
        try hubStore.save(PairingRecord(peerID: "remote-b", peerName: "B", key: keyB))
        let (server, port) = try await startServer(backend, store: hubStore)
        defer { Task { await server.stop() } }
        let a = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port, id: "remote-a", name: "Phone A"),
                                 keyStore: InMemoryPairingKeyStore([PairingRecord(peerID: Fixture.hubID, peerName: "", key: keyA)]))
        let b = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port, id: "remote-b", name: "Phone B"),
                                 keyStore: InMemoryPairingKeyStore([PairingRecord(peerID: Fixture.hubID, peerName: "", key: keyB)]))
        defer { Task { await a.stop(); await b.stop() } }
        let statesA = await a.states(), statesB = await b.states()
        try await connected(a)
        try await connected(b)
        #expect(Set(server.connectedRemotes.map(\.remoteName)) == ["Phone A", "Phone B"])
        #expect(try server.pairedRemotes().allSatisfy(\.isConnected))

        try await a.setMasterVolume(0.21)
        _ = try await first(statesB, "B sees A's change") { $0.masterVolume == 0.21 }
        try await b.setSpeaker("542a1b003344", volume: 0.77)
        _ = try await first(statesA, "A sees B's change") { $0.speaker("542a1b003344")?.volume == 0.77 }

        // Interleaved commands from both remotes all land.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { try await a.perform(.setSpeakerSyncTrim(id: SpeakerID("a\(i)"), milliseconds: i)) }
                group.addTask { try await b.perform(.setSpeakerSyncTrim(id: SpeakerID("b\(i)"), milliseconds: i)) }
            }
            try await group.waitForAll()
        }
        let trims = backend.commands.compactMap { c -> String? in
            if case .setSpeakerSyncTrim(let id, _) = c { return id.rawValue }
            return nil
        }
        #expect(Set(trims).count == 20)
    }

    // MARK: Pairing

    private func pairingTest(policy: PairingPolicy = PairingPolicy()) async throws
        -> (TestBackend, HubServer, RemoteHubBackend, InMemoryPairingKeyStore, InMemoryPairingKeyStore) {
        let backend = TestBackend()
        let hubStore = InMemoryPairingKeyStore(), remoteStore = InMemoryPairingKeyStore()
        let (server, port) = try await startServer(backend, store: hubStore) { $0.pairingPolicy = policy }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: remoteStore)
        remote.start()
        _ = try await first(remote.connectionStates(), "pairing needed") { $0.pairingMessage != nil }
        return (backend, server, remote, hubStore, remoteStore)
    }

    /// Starts pairing and returns the code the Mac shows.
    private func requestCode(_ remote: RemoteHubBackend, _ server: HubServer) async throws -> PairingPrompt {
        let events = server.events()
        remote.startPairing()
        let event = try await first(events, "pairing prompt") {
            if case .pairingRequested = $0 { true } else { false }
        }
        guard case .pairingRequested(let prompt) = event else { throw Timeout(what: "prompt") }
        _ = try await first(remote.connectionStates(), "code entry") { $0.enterCodeMessage != nil }
        return prompt
    }

    private func wrongCode(_ code: String) -> String {
        PairingCode.format((PairingCode.parse(code)! + 1) % 1_000_000)
    }

    @Test func pairsWithTheCodeShownOnTheMac() async throws {
        let (_, server, remote, hubStore, remoteStore) = try await pairingTest()
        defer { Task { await remote.stop(); await server.stop() } }
        let events = server.events()
        let prompt = try await requestCode(remote, server)
        #expect(prompt.remoteName == "Test Phone" && prompt.remoteID == "remote-a" && prompt.code.count == 6)

        // A malformed entry is refused locally and the code can still be typed.
        remote.submitPairingCode("12ab")
        _ = try await first(remote.connectionStates(), "format hint") { $0.enterCodeMessage == .some("Enter the 6-digit code shown on the Mac.") }
        remote.submitPairingCode(prompt.code)
        try await connected(remote)

        let hubRecord = try #require(try hubStore.record(for: "remote-a"))
        let remoteRecord = try #require(try remoteStore.record(for: Fixture.hubID))
        #expect(hubRecord.key == remoteRecord.key && hubRecord.key.count == 32)
        #expect(remoteRecord.peerName == Fixture.hubName)
        _ = try await first(events, "paired event") { $0 == .pairingEnded(id: prompt.id, remoteName: "Test Phone", outcome: .paired) }
        #expect(try server.pairedRemotes().map(\.id) == ["remote-a"])
    }

    @Test func wrongCodeFailsAndTheSameCodeIsNeverSentAgain() async throws {
        let (_, server, remote, hubStore, remoteStore) = try await pairingTest()
        defer { Task { await remote.stop(); await server.stop() } }
        let events = server.events()
        let prompt = try await requestCode(remote, server)
        let wrong = wrongCode(prompt.code)
        remote.submitPairingCode(wrong)
        let state = try await first(remote.connectionStates(), "failure") { ($0.pairingMessage ?? nil)?.contains("didn't match") == true }
        #expect(state.pairingMessage != nil)
        _ = try await first(events, "failed event") {
            if case .pairingEnded(prompt.id, _, .failed) = $0 { true } else { false }
        }
        #expect(try hubStore.allRecords().isEmpty && remoteStore.allRecords().isEmpty)

        // Typing the burned code again is refused on the phone before anything is sent.
        let second = try await requestCode(remote, server)
        remote.submitPairingCode(wrong)
        _ = try await first(remote.connectionStates(), "burned code") {
            ($0.enterCodeMessage ?? nil)?.contains("already tried") == true
        }
        remote.submitPairingCode(second.code)
        try await connected(remote)
    }

    @Test func repeatedFailuresLockPairingOut() async throws {
        let (_, server, remote, _, _) = try await pairingTest(policy: PairingPolicy(failuresBeforeLockout: 2, lockout: 60))
        defer { Task { await remote.stop(); await server.stop() } }
        for _ in 0..<2 {
            let prompt = try await requestCode(remote, server)
            remote.submitPairingCode(wrongCode(prompt.code))
            _ = try await first(remote.connectionStates(), "failure") { ($0.pairingMessage ?? nil)?.contains("didn't match") == true }
        }
        let events = server.events()
        remote.startPairing()
        _ = try await first(remote.connectionStates(), "lockout") {
            ($0.pairingMessage ?? nil)?.contains("Too many pairing attempts") == true
        }
        // The Mac never showed a third code.
        let shown = try? await first(events, within: 0.5, "no prompt") {
            if case .pairingRequested = $0 { true } else { false }
        }
        #expect(shown == nil)
    }

    @Test func cancellingOnTheMacReachesThePhoneWhileItWaitsForTheCode() async throws {
        let (_, server, remote, _, _) = try await pairingTest()
        defer { Task { await remote.stop(); await server.stop() } }
        _ = try await requestCode(remote, server)
        server.cancelPairing()
        _ = try await first(remote.connectionStates(), "cancelled") { ($0.pairingMessage ?? nil)?.contains("cancelled on the Mac") == true }
        // Cancelling doesn't count against the lockout, and pairing works again.
        let prompt = try await requestCode(remote, server)
        remote.submitPairingCode(prompt.code)
        try await connected(remote)
    }

    @Test func mismatchedKeysAreRejectedBothWays() async throws {
        // The phone's key differs from the Mac's: the Mac's proof fails on the phone.
        let backend = TestBackend()
        let stores = Fixture.pairedStores(hubKey: randomBytes(32), remoteKey: randomBytes(32))
        let (server, port) = try await startServer(backend, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        // Unauthenticated: the phone keeps its key and keeps retrying (it never deletes it).
        _ = try await first(remote.connectionStates(), "not recognised") {
            $0.notRecognisedMessage?.contains("didn\u{2019}t recognise") == true
        }
        #expect(server.connectedRemotes.isEmpty)
        #expect(try stores.remote.record(for: Fixture.hubID) != nil)
        _ = try await first(remote.connectionStates(), "a retry") { if case .connecting = $0 { true } else { false } }
        _ = try await first(remote.connectionStates(), "not recognised again") { $0.notRecognisedMessage != nil }
        #expect(try stores.remote.record(for: Fixture.hubID) != nil)

        // The person may still choose to pair from there: the Mac shows a code.
        let events = server.events()
        remote.startPairing()
        _ = try await first(events, "pairing prompt") { if case .pairingRequested = $0 { true } else { false } }
        _ = try await first(remote.connectionStates(), "code entry") { $0.enterCodeMessage != nil }

        // A remote that can't prove the key is refused by the Mac (raw client, bad proof).
        let link = try await rawLink(port: port)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        try await link.send(WireJSON.encode(Hello(minVersion: RemoteProtocol.currentVersion, maxVersion: RemoteProtocol.currentVersion, remoteID: "remote-a", remoteName: "x",
                                                  intent: .session(nonce: randomBytes(32), ephemeralKey: eph.publicKey.rawRepresentation))))
        guard case .sessionChallenge = try await link.receiveHandshake(timeout: 2, "challenge") else {
            Issue.record("no challenge")
            return
        }
        try await link.sendHandshake(.sessionProof(mac: randomBytes(32)))
        guard case .refused(let refusal) = try await link.receiveHandshake(timeout: 2, "refusal") else {
            Issue.record("not refused")
            return
        }
        #expect(refusal.code == .authenticationFailed)
        #expect(await serverCloses(link))
    }

    @Test func revokingARemoteDisconnectsItAndRequiresPairing() async throws {
        let backend = TestBackend()
        let stores = Fixture.pairedStores()
        let (server, port) = try await startServer(backend, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        try await connected(remote)
        try server.revoke(remoteID: "remote-a")
        // The sealed revocation is the one signal the phone drops its key on.
        _ = try await first(remote.connectionStates(), "removed") { ($0.pairingMessage ?? nil)?.contains("removed this remote") == true }
        await #expect(throws: HubCommandError.self) { try await remote.play() }
        #expect(try server.pairedRemotes().isEmpty)
        #expect(try stores.remote.record(for: Fixture.hubID) == nil)
    }

    @Test func anUnauthenticatedNotPairedAnswerNeverCostsThePhoneItsKey() async throws {
        // Something answering with the hub's public id that doesn't hold the pairing: here a
        // real server with an empty store, which refuses `notPaired` in plaintext.
        let stores = Fixture.pairedStores()
        let spoof = HubServer(backend: TestBackend(), configuration: Fixture.serverConfig(), keyStore: InMemoryPairingKeyStore())
        let port = try await spoof.start()
        defer { Task { await spoof.stop() } }
        let identity = RemoteIdentity(remoteID: "remote-a", remoteName: "Test Phone", versions: RemoteProtocol.supportedVersions)

        let link = try await rawLink(port: port)
        let outcome = try await ClientHandshake.openSession(link, identity: identity, keyStore: stores.remote,
                                                            expectedHubID: Fixture.hubID, timeout: 2)
        link.cancel()
        guard case .notRecognised(let hubID, _, _) = outcome else {
            Issue.record("expected notRecognised, got \(outcome)")
            return
        }
        #expect(hubID == Fixture.hubID)
        #expect(try stores.remote.record(for: Fixture.hubID) != nil)

        // Without a key for that hub, the same answer simply means "pair first".
        let fresh = try await rawLink(port: port)
        let unpaired = try await ClientHandshake.openSession(fresh, identity: identity, keyStore: InMemoryPairingKeyStore(),
                                                             expectedHubID: Fixture.hubID, timeout: 2)
        fresh.cancel()
        guard case .needsPairing = unpaired else {
            Issue.record("expected needsPairing, got \(unpaired)")
            return
        }
    }

    // MARK: Resilience

    @Test func reconnectsAfterTheHubRestarts() async throws {
        let stores = Fixture.pairedStores()
        let backend1 = TestBackend(masterVolume: 0.4)
        let (server1, port) = try await startServer(backend1, store: stores.hub)
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        let states = await remote.states()
        let before = try await first(states, "first hub's state") { $0.masterVolume == 0.4 }
        try await connected(remote)

        await server1.stop()
        _ = try await first(remote.connectionStates(), "lost") { if case .lost = $0 { true } else { false } }
        await #expect(throws: HubCommandError.self) { try await remote.play() }

        let backend2 = TestBackend(masterVolume: 0.25)
        let (server2, port2) = try await startServer(backend2, store: stores.hub) { $0.port = port }
        defer { Task { await server2.stop() } }
        #expect(port2 == port)
        let after = try await first(states, within: 8, "second hub's state") { $0.masterVolume == 0.25 }
        #expect(after.revision > before.revision)
        #expect(after.content.library > before.content.library)
        try await connected(remote)
        try await remote.play()
        #expect(backend2.commands == [.play])
        #expect(backend1.commands.isEmpty)
    }

    /// A hub from before catalog search can't decode the query and would drop the link, so the
    /// remote answers it itself and the link stays up.
    @Test func catalogSearchIsNeverSentToAVersion2Hub() async throws {
        let stores = Fixture.pairedStores()
        let (server, port) = try await startServer(TestBackend(), store: stores.hub) { $0.supportedVersions = 2...2 }
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        try await connected(remote)
        do {
            _ = try await remote.searchCatalog("tide", .first)
            Issue.record("asked a version 2 hub")
        } catch {
            #expect((error as? HubCommandError)?.code == .unsupported)
        }
        await #expect(throws: HubCommandError.self) {
            try await remote.perform(.playTrack(id: "catalog:900", context: .catalog(query: "tide")))
        }
        #expect(remote.connectionState.isConnected)
        #expect(try await remote.playlists(.first).items.count == 3)
    }

    @Test func refusesIncompatibleVersionsWithAClearMessage() async throws {
        let stores = Fixture.pairedStores()
        // A hub newer than this remote.
        let (server, port) = try await startServer(TestBackend(), store: stores.hub) { $0.supportedVersions = (RemoteProtocol.currentVersion + 1)...(RemoteProtocol.currentVersion + 2) }
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        let state = try await first(remote.connectionStates(), "incompatible") {
            if case .incompatible = $0 { true } else { false }
        }
        #expect(state == .incompatible(message: "This version of Multicast is too old for the Mac. Update Multicast on this iPhone."))
        #expect(state.availability == .unreachable(reason: "This version of Multicast is too old for the Mac. Update Multicast on this iPhone."))

        // A remote newer than the hub (raw hello from the future).
        let (server1, port1) = try await startServer(TestBackend(), store: stores.hub)
        defer { Task { await server1.stop() } }
        let link = try await rawLink(port: port1)
        try await link.send(Data(#"{"magic":"multicast-hub-link","minVersion":50,"maxVersion":60,"future":true}"#.utf8))
        guard case .refused(let refusal) = try await link.receiveHandshake(timeout: 2, "refusal") else {
            Issue.record("not refused")
            return
        }
        #expect(refusal.code == .incompatibleVersion && refusal.hubMinVersion == RemoteProtocol.oldestVersion && refusal.hubMaxVersion == RemoteProtocol.currentVersion)
        #expect(refusal.message.hasSuffix("Update Multicast on the Mac."))
    }

    @Test func dropsMalformedAndOversizedInput() async throws {
        let stores = Fixture.pairedStores()
        let backend = TestBackend()
        let (server, port) = try await startServer(backend, store: stores.hub) { $0.handshakeTimeout = 1 }
        defer { Task { await server.stop() } }

        // A header announcing 4 GB: closed without reading or allocating it.
        let huge = try await rawLink(port: port)
        try await sendRaw(huge, Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(await serverCloses(huge))
        // A handshake frame over the 16 KB limit.
        let big = try await rawLink(port: port)
        try await sendRaw(big, FrameCodec.frame(Data(repeating: 0x20, count: 20_000)))
        #expect(await serverCloses(big))
        // Not JSON.
        let junk = try await rawLink(port: port)
        try await sendRaw(junk, FrameCodec.frame(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        #expect(await serverCloses(junk))
        // An unknown remote id with path characters.
        let path = try await rawLink(port: port)
        try await path.send(WireJSON.encode(Hello(minVersion: RemoteProtocol.currentVersion, maxVersion: RemoteProtocol.currentVersion, remoteID: "../../etc", remoteName: "x",
                                                  intent: .session(nonce: randomBytes(32), ephemeralKey: randomBytes(32)))))
        #expect(await serverCloses(path))
        // Silence: dropped after the handshake timeout.
        let silent = try await rawLink(port: port)
        let t0 = Date()
        #expect(await serverCloses(silent, within: 3))
        #expect(Date().timeIntervalSince(t0) < 2.5)

        // After authenticating: a sealed frame of junk, a frame that isn't sealed, an oversized frame.
        for attack in 0..<3 {
            let link = try await rawLink(port: port)
            let identity = RemoteIdentity(remoteID: "remote-a", remoteName: "Raw", versions: RemoteProtocol.supportedVersions)
            guard case .established = try await ClientHandshake.openSession(link, identity: identity, keyStore: stores.remote,
                                                                            expectedHubID: Fixture.hubID, timeout: 2) else {
                Issue.record("handshake failed")
                return
            }
            switch attack {
            case 0: try await link.send(Data([1]) + Data("{not json".utf8))
            case 1: try await sendRaw(link, FrameCodec.frame(randomBytes(64)))
            default: try await sendRaw(link, FrameCodec.frame(Data(repeating: 1, count: RemoteProtocol.maxRemoteFrame + 100)))
            }
            #expect(await serverCloses(link), "attack \(attack)")
        }

        // The hub still serves a well-behaved remote.
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        try await connected(remote)
        try await remote.pause()
        #expect(backend.commands == [.pause])
    }

    @Test func dropsADeadRemote() async throws {
        let stores = Fixture.pairedStores()
        let (server, port) = try await startServer(TestBackend(), store: stores.hub) {
            $0.heartbeatInterval = 0.2
            $0.deadAfter = 0.8
        }
        defer { Task { await server.stop() } }
        let events = server.events()
        // Authenticates, then never reads or writes again.
        let link = try await rawLink(port: port)
        let identity = RemoteIdentity(remoteID: "remote-a", remoteName: "Raw", versions: RemoteProtocol.supportedVersions)
        _ = try await ClientHandshake.openSession(link, identity: identity, keyStore: stores.remote,
                                                  expectedHubID: Fixture.hubID, timeout: 2)
        let event = try await first(events, within: 4, "disconnect") {
            if case .remoteDisconnected = $0 { true } else { false }
        }
        if case .remoteDisconnected(_, let reason) = event { #expect(reason == "The remote stopped responding.") }
        #expect(server.connectedRemotes.isEmpty)
        link.cancel()
    }

    @Test func heartbeatsKeepAQuietSessionAlive() async throws {
        // The hub never pings first here; the remote's pings and the hub's pongs keep it up.
        let stores = Fixture.pairedStores()
        let backend = TestBackend()
        let (server, port) = try await startServer(backend, store: stores.hub) { $0.heartbeatInterval = 60 }
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port) {
            $0.heartbeatInterval = 0.2
            $0.deadAfter = 0.8
        }, keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        try await connected(remote)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(remote.connectionState.isConnected)
    }
}
