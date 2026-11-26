import CryptoKit
import Foundation
import MulticastHubModel
import Network
import Testing
@testable import MulticastRemote

@Suite struct FramingTests {
    @Test func headerLengthIsCheckedBeforeReading() throws {
        let framed = FrameCodec.frame(Data([1, 2, 3]))
        #expect(framed == Data([0, 0, 0, 3, 1, 2, 3]))
        #expect(try FrameCodec.payloadLength(header: framed.prefix(4), limit: 3) == 3)
        #expect(throws: RemoteLinkError.frameTooLarge(length: 4, limit: 3)) {
            try FrameCodec.payloadLength(header: Data([0, 0, 0, 4]), limit: 3)
        }
        #expect(throws: RemoteLinkError.frameTooLarge(length: Int(UInt32.max), limit: 100)) {
            try FrameCodec.payloadLength(header: Data([0xFF, 0xFF, 0xFF, 0xFF]), limit: 100)
        }
        #expect(throws: RemoteLinkError.malformed("empty frame")) {
            try FrameCodec.payloadLength(header: Data([0, 0, 0, 0]), limit: 100)
        }
    }

    @Test func sessionPayloadsRoundTripAndRejectJunk() throws {
        let cases: [SessionPayload] = [.json(Data("{}".utf8)), .artwork(requestID: 0x0102030405060708, data: Data([9, 9])),
                                       .artwork(requestID: 7, data: nil), .artwork(requestID: 8, data: Data())]
        for p in cases { #expect(try SessionPayload.decode(p.encoded()) == p) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data()) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data([3, 1, 2])) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data([1])) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data([2, 0, 0])) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data([2, 0, 0, 0, 0, 0, 0, 0, 1, 2])) }
        #expect(throws: RemoteLinkError.self) { try SessionPayload.decode(Data([2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 5])) }
    }

    @Test func messagesRoundTrip() throws {
        let messages: [HubMessage] = [
            .state(HubState(revision: 4, speakers: TestBackend.speakers)),
            .commandResult(id: 3, error: nil),
            .commandResult(id: 4, error: HubCommandError(.notFound, "Gone.")),
            .queryResult(id: 5, result: .tracks(page: Page(items: [], nextCursor: "100")), error: nil),
            .pong(id: 1, hubTime: Date(timeIntervalSinceReferenceDate: 12.5)),
        ]
        for m in messages { #expect(try WireJSON.decode(HubMessage.self, WireJSON.encode(m)) == m) }
        let c = ClientMessage.command(id: 9, command: .setSpeakerVolume(id: "542a1b001122", volume: 0.3))
        #expect(try WireJSON.decode(ClientMessage.self, WireJSON.encode(c)) == c)
    }

    /// Frozen across protocol versions (any two builds must be able to say "update"): pin them.
    @Test func versionRefusalAndHelloKeepTheirShape() throws {
        let refusal = HandshakeMessage.refused(HubRefusal(.incompatibleVersion, "Update.", hubMinVersion: 1, hubMaxVersion: 1))
        #expect(String(decoding: try WireJSON.encode(refusal), as: UTF8.self)
            == #"{"refused":{"_0":{"code":"incompatibleVersion","hubMaxVersion":1,"hubMinVersion":1,"message":"Update."}}}"#)
        let hello = Hello(minVersion: 1, maxVersion: 1, remoteID: "r", remoteName: "n", intent: .pair(publicKey: Data([1])))
        let object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encode(hello)) as? [String: Any])
        #expect(object["magic"] as? String == "multicast-hub-link")
        #expect(object["minVersion"] as? Int == 1 && object["maxVersion"] as? Int == 1)
    }

    @Test func helloProbeReadsVersionsOfAnyFutureHello() throws {
        let future = Data(#"{"magic":"multicast-hub-link","minVersion":7,"maxVersion":9,"somethingNew":{"x":1}}"#.utf8)
        let probe = try JSONDecoder().decode(HelloVersionProbe.self, from: future)
        #expect(probe.minVersion == 7 && probe.maxVersion == 9)
        #expect((try? WireJSON.decode(Hello.self, future)) == nil)
    }
}

@Suite struct VersionTests {
    @Test func agreesOnHighestCommonVersion() {
        #expect(VersionNegotiation.agree(1...3, 2...5) == 3)
        #expect(VersionNegotiation.agree(1...1, 1...1) == 1)
        #expect(VersionNegotiation.agree(1...1, 2...2) == nil)
        #expect(VersionNegotiation.agree(3...4, 1...2) == nil)
    }

    @Test func tellsWhichSideToUpdate() {
        let macTooOld = VersionNegotiation.updateMessage(local: 2...2, peer: 1...1, thisDevice: "iPhone", otherDevice: "Mac")
        #expect(macTooOld.hasSuffix("Update Multicast on the Mac."))
        let phoneTooOld = VersionNegotiation.updateMessage(local: 1...1, peer: 2...3, thisDevice: "iPhone", otherDevice: "Mac")
        #expect(phoneTooOld.hasSuffix("Update Multicast on this iPhone."))
    }
}

@Suite struct PairingCryptoTests {
    /// Runs both state machines against each other with possibly different codes and keys.
    private func run(remoteCode: UInt32, hubCode: UInt32, tamperRemoteKey: Bool = false) throws
        -> (remote: SymmetricKey, hub: SymmetricKey) {
        let rk = Curve25519.KeyAgreement.PrivateKey(), hk = Curve25519.KeyAgreement.PrivateKey()
        // A man in the middle substituting its own key for the remote's.
        let seenByHub = tamperRemoteKey ? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                                        : rk.publicKey.rawRepresentation
        var r = try PasskeyPairing(role: .remote, code: remoteCode, remoteID: "r", hubID: "h", ownKey: rk,
                                   peerPublicKey: hk.publicKey.rawRepresentation)
        var h = try PasskeyPairing(role: .hub, code: hubCode, remoteID: "r", hubID: "h", ownKey: hk,
                                   peerPublicKey: seenByHub)
        for i in 0..<PasskeyPairing.rounds {
            try h.receiveCommitment(i, try r.makeCommitment(i))
            try r.receiveCommitment(i, try h.makeCommitment(i))
            try h.verifyReveal(i, try r.reveal(i))
            try r.verifyReveal(i, try h.reveal(i))
        }
        let rKeys = try r.deriveKeys(), hKeys = try h.deriveKeys()
        try h.verifyConfirmation(r.confirmation(for: .remote, confirmKey: rKeys.confirmKey), confirmKey: hKeys.confirmKey)
        try r.verifyConfirmation(h.confirmation(for: .hub, confirmKey: hKeys.confirmKey), confirmKey: rKeys.confirmKey)
        return (rKeys.longTermKey, hKeys.longTermKey)
    }

    @Test func sameCodeGivesSameKey() throws {
        for code: UInt32 in [0, 1, 424_242, 999_999] {
            let keys = try run(remoteCode: code, hubCode: code)
            #expect(keys.remote == keys.hub)
        }
    }

    @Test func anyWrongDigitIsCaughtByTheHub() throws {
        for (typed, shown) in [(123_456, 123_457), (100_000, 900_000), (0, 524_288)] as [(UInt32, UInt32)] {
            #expect(throws: PairingError.codeMismatch) { try run(remoteCode: typed, hubCode: shown) }
        }
    }

    @Test func commitmentsBindThePublicKeys() {
        #expect(throws: PairingError.codeMismatch) { try run(remoteCode: 5555, hubCode: 5555, tamperRemoteKey: true) }
    }

    @Test func roundsMustArriveInOrder() throws {
        var r = try PasskeyPairing(role: .remote, code: 1, remoteID: "r", hubID: "h",
                                   ownKey: .init(), peerPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        #expect(throws: PairingError.outOfOrder) { try r.makeCommitment(1) }
        #expect(throws: PairingError.outOfOrder) { try r.reveal(0) }
        #expect(throws: PairingError.outOfOrder) { try r.deriveKeys() }
        #expect(throws: RemoteLinkError.self) {
            try PasskeyPairing(role: .hub, code: 1, remoteID: "r", hubID: "h", ownKey: .init(), peerPublicKey: Data([1]))
        }
    }

    @Test func codesParseAndFormat() {
        #expect(PairingCode.parse("042917") == 42917)
        #expect(PairingCode.parse("042 917") == 42917)
        #expect(PairingCode.parse("42917") == nil)
        #expect(PairingCode.parse("0429170") == nil)
        #expect(PairingCode.parse("04291a") == nil)
        #expect(PairingCode.parse("٠٤٢٩١٧") == nil)
        #expect(PairingCode.format(42) == "000042")
        for _ in 0..<50 { #expect(PairingCode.parse(PairingCode.random()) != nil) }
    }
}

@Suite struct SessionCryptoTests {
    @Test func proofsNeedTheKeyAndTheRole() {
        let key = SymmetricKey(size: .bits256), other = SymmetricKey(size: .bits256)
        let t = SessionHandshake.transcript(version: 1, remoteID: "r", hubID: "h", remoteNonce: randomBytes(32),
                                            remoteEphemeral: randomBytes(32), hubNonce: randomBytes(32), hubEphemeral: randomBytes(32))
        let hubProof = SessionHandshake.proof(longTermKey: key, role: .hub, transcript: t)
        #expect(SessionHandshake.verify(hubProof, longTermKey: key, role: .hub, transcript: t))
        #expect(!SessionHandshake.verify(hubProof, longTermKey: other, role: .hub, transcript: t))
        #expect(!SessionHandshake.verify(hubProof, longTermKey: key, role: .remote, transcript: t))
        var t2 = t
        t2[t2.startIndex] ^= 1
        #expect(!SessionHandshake.verify(hubProof, longTermKey: key, role: .hub, transcript: t2))
    }

    @Test func bothSidesDeriveTheSameDirectionalKeys() throws {
        let ltk = SymmetricKey(size: .bits256)
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let t = Data(repeating: 7, count: 32)
        let ka = try SessionHandshake.keys(ownEphemeral: a, peerEphemeral: b.publicKey.rawRepresentation, longTermKey: ltk, transcript: t)
        let kb = try SessionHandshake.keys(ownEphemeral: b, peerEphemeral: a.publicKey.rawRepresentation, longTermKey: ltk, transcript: t)
        #expect(ka.remoteToHub == kb.remoteToHub && ka.hubToRemote == kb.hubToRemote)
        #expect(ka.remoteToHub != ka.hubToRemote)
        let other = try SessionHandshake.keys(ownEphemeral: a, peerEphemeral: b.publicKey.rawRepresentation,
                                              longTermKey: SymmetricKey(size: .bits256), transcript: t)
        #expect(other.remoteToHub != ka.remoteToHub)
        // A low-order (all-zero) peer key is refused.
        #expect(throws: (any Error).self) {
            try SessionHandshake.keys(ownEphemeral: a, peerEphemeral: Data(count: 32), longTermKey: ltk, transcript: t)
        }
    }

    @Test func sealedFramesRejectTamperReplayAndReorder() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = FrameSealer(key: key, direction: Direction.remoteToHub)
        let f0 = try sealer.seal(Data("zero".utf8)), f1 = try sealer.seal(Data("one".utf8)), f2 = try sealer.seal(Data("two".utf8))
        var other = FrameSealer(key: key, direction: Direction.remoteToHub)
        #expect(f0 != (try other.seal(Data("one".utf8))))

        var opener = FrameOpener(key: key, direction: Direction.remoteToHub)
        #expect(try opener.open(f0) == Data("zero".utf8))
        #expect(throws: RemoteLinkError.self) { try opener.open(f0) }      // replay
        #expect(throws: RemoteLinkError.self) { try opener.open(f2) }      // skipped one
        var tampered = f1
        tampered[tampered.startIndex] ^= 0x01
        #expect(throws: RemoteLinkError.self) { try opener.open(tampered) }
        #expect(try opener.open(f1) == Data("one".utf8))
        #expect(try opener.open(f2) == Data("two".utf8))

        var wrongDirection = FrameOpener(key: key, direction: Direction.hubToRemote)
        #expect(throws: RemoteLinkError.self) { try wrongDirection.open(f0) }
        #expect(throws: RemoteLinkError.self) { try wrongDirection.open(Data([1, 2])) }
    }
}

@Suite struct PairingGateTests {
    @Test func oneAttemptAtATime() throws {
        var gate = PairingGate(policy: PairingPolicy())
        let now = Date()
        let id = try gate.begin(now: now).get()
        #expect(gate.begin(now: now) == .failure(.busy))
        gate.end(id, succeeded: true, now: now)
        #expect((try? gate.begin(now: now).get()) != nil)
    }

    @Test func locksOutAndDoubles() throws {
        var gate = PairingGate(policy: PairingPolicy(failuresBeforeLockout: 2, lockout: 60, maxLockout: 150))
        var now = Date(timeIntervalSinceReferenceDate: 0)
        func fail() throws { gate.end(try gate.begin(now: now).get(), succeeded: false, now: now) }
        try fail()
        try fail()
        #expect(gate.begin(now: now) == .failure(.locked(retryAfter: 60)))
        now += 61
        try fail()
        try fail()
        #expect(gate.begin(now: now) == .failure(.locked(retryAfter: 120)))
        now += 121
        try fail()
        try fail()
        #expect(gate.begin(now: now) == .failure(.locked(retryAfter: 150)))   // capped
        now += 151
        let ok = try gate.begin(now: now).get()
        gate.end(ok, succeeded: true, now: now)
        try fail()
        #expect((try? gate.begin(now: now).get()) != nil)                    // success reset the count
    }

    @Test func cancelOnTheMacDoesNotCount() throws {
        var gate = PairingGate(policy: PairingPolicy(failuresBeforeLockout: 1))
        let now = Date()
        gate.cancel(try gate.begin(now: now).get())
        #expect((try? gate.begin(now: now).get()) != nil)
    }
}

@Suite struct MirrorTests {
    private struct NothingPublished: Error {}

    private func applied(_ m: inout StateMirror, _ s: HubState) throws -> HubState {
        guard let out = m.apply(s) else { throw NothingPublished() }
        return out
    }

    private func state(_ rev: UInt64, master: Double = 0.5, library: UInt64 = 0) -> HubState {
        HubState(revision: rev, masterVolume: master, content: ContentRevisions(library: library, upNext: 3))
    }

    @Test func revisionsStayMonotonicAcrossHubRestarts() throws {
        var m = StateMirror()
        m.beginSession()
        let a = try applied(&m, state(10, master: 0.1, library: 5))
        #expect(m.apply(state(9, master: 0.9)) == nil)                       // out of order
        #expect(m.apply(state(11, master: 0.1, library: 5)) == nil)         // nothing new
        let b = try applied(&m, state(12, master: 0.2, library: 6))
        #expect(b.revision > a.revision)
        #expect(b.content.library == a.content.library + 1)                 // moves with the hub
        // The hub restarts: its revisions and counters begin again.
        m.beginSession()
        let c = try applied(&m, state(1, master: 0.2, library: 0))
        #expect(c.revision > b.revision)
        #expect(c.content.library > b.content.library)                      // lists get refetched
        #expect(c.content.upNext > b.content.upNext)
        let d = try applied(&m, state(2, master: 0.3, library: 0))
        #expect(d.content == c.content)
    }

    @Test func positionIsRebasedToTheLocalClock() throws {
        var m = StateMirror()
        m.beginSession()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        // Hub clock 30 s ahead; 20 ms round trip.
        m.clock.add(sent: t0, received: t0 + 0.02, hubTime: t0 + 30.01)
        #expect(abs(m.clock.offset - 30) < 0.001)
        var s = state(1)
        s.transport = TransportState(isPlaying: true, position: 12, positionAsOf: t0 + 40)
        let out = try applied(&m, s)
        #expect(abs(out.transport.positionAsOf.timeIntervalSince(t0 + 10)) < 0.001)
    }

    @Test func clockKeepsTheFastestSample() {
        var c = ClockSync()
        let t = Date()
        c.add(sent: t, received: t + 1.0, hubTime: t + 5.9)        // slow: offset 5.4
        c.add(sent: t, received: t + 0.01, hubTime: t + 5.005)     // fast: offset 5.0
        #expect(abs(c.offset - 5.0) < 0.0001)
    }

    @Test func dragCommandsCoalesceWithoutReordering() {
        var q = CommandQueue<Int>()
        q.enqueue(.setSpeakerVolume(id: "a", volume: 0.1), 1)
        q.enqueue(.setSpeakerVolume(id: "a", volume: 0.2), 2)
        q.enqueue(.setSpeakerVolume(id: "b", volume: 0.3), 3)
        q.enqueue(.play, 4)
        q.enqueue(.setSpeakerVolume(id: "a", volume: 0.4), 5)
        q.enqueue(.setSpeakerVolume(id: "a", volume: 0.5), 6)
        q.enqueue(.play, 7)
        q.enqueue(.play, 8)
        #expect(q.entries.map(\.command) == [
            .setSpeakerVolume(id: "a", volume: 0.2), .setSpeakerVolume(id: "b", volume: 0.3), .play,
            .setSpeakerVolume(id: "a", volume: 0.5), .play, .play,
        ])
        #expect(q.entries.map(\.waiters) == [[1, 2], [3], [4], [5, 6], [7], [8]])
        #expect(q.popFirst()?.waiters == [1, 2])
        #expect(q.drain().count == 5)
        #expect(q.popFirst() == nil)
    }

    @Test func backoffGrowsAndCaps() {
        let b = Backoff(range: 0.5...8)
        #expect(b.delay(attempt: 1, jitter: 0) == 0.5)
        #expect(b.delay(attempt: 3, jitter: 0) == 2)
        #expect(b.delay(attempt: 50, jitter: 0) == 8)
        #expect(b.delay(attempt: 50, jitter: 0.2) == 9.6)
    }
}

@Suite struct InputPolicyTests {
    @Test func commandsFromRemotesAreClampedOrRefused() throws {
        #expect(try RemoteInputPolicy.sanitize(.setMasterVolume(volume: 3)).get() == .setMasterVolume(volume: 1))
        #expect(try RemoteInputPolicy.sanitize(.setSpeakerVolume(id: "a", volume: -1)).get() == .setSpeakerVolume(id: "a", volume: 0))
        #expect(try RemoteInputPolicy.sanitize(.setSpeakerSyncTrim(id: "a", milliseconds: 99_999)).get()
            == .setSpeakerSyncTrim(id: "a", milliseconds: 500))
        #expect(try RemoteInputPolicy.sanitize(.seek(position: -5)).get() == .seek(position: 0))
        #expect(throws: HubCommandError.self) {
            try RemoteInputPolicy.sanitize(.addFiles(urls: [URL(fileURLWithPath: "/etc/passwd")])).get()
        }
        #expect(throws: HubCommandError.self) { try RemoteInputPolicy.sanitize(.playTrack(id: "", context: .songs)).get() }
        #expect(try RemoteInputPolicy.sanitize(.captureApp(bundleID: "com.example.player")).get()
            == .captureApp(bundleID: "com.example.player"))
        for bad in ["", "com.example/../x", "com example", "com.exämple", String(repeating: "a", count: 256)] {
            #expect(throws: HubCommandError.self) { try RemoteInputPolicy.sanitize(.captureApp(bundleID: bad)).get() }
        }
        #expect(throws: HubCommandError.self) {
            try RemoteInputPolicy.sanitize(.playPlaylist(id: String(repeating: "x", count: 10_000))).get()
        }
        #expect(throws: HubCommandError.self) {
            try RemoteInputPolicy.sanitize(.removeFiles(ids: Array(repeating: "f", count: 5000))).get()
        }
    }

    @Test func queriesAreClamped() throws {
        #expect(try RemoteInputPolicy.sanitize(.songs(page: PageRequest(limit: 100_000)), maxArtworkPixel: 1024).get()
            == .songs(page: PageRequest(limit: 500)))
        #expect(try RemoteInputPolicy.sanitize(.artwork(id: "a", maxPixel: 0), maxArtworkPixel: 1024).get()
            == .artwork(id: "a", maxPixel: 1024))
        #expect(try RemoteInputPolicy.sanitize(.artwork(id: "a", maxPixel: 1 << 30), maxArtworkPixel: 1024).get()
            == .artwork(id: "a", maxPixel: 1024))
        #expect(try RemoteInputPolicy.sanitize(.artwork(id: "a", maxPixel: 300), maxArtworkPixel: 1024).get()
            == .artwork(id: "a", maxPixel: 300))
        #expect(throws: HubCommandError.self) {
            try RemoteInputPolicy.sanitize(.songs(page: PageRequest(cursor: String(repeating: "9", count: 1000))),
                                           maxArtworkPixel: 1024).get()
        }
        let long = try RemoteInputPolicy.sanitize(.search(query: String(repeating: "q", count: 5000), page: .first),
                                                  maxArtworkPixel: 1024).get()
        if case .search(let q, _) = long { #expect(q.count == 256) } else { Issue.record("not a search") }
    }

    @Test func peerTextIsTamed() {
        #expect(PeerText.isValidID("remote-A_1.x"))
        #expect(!PeerText.isValidID(""))
        #expect(!PeerText.isValidID("../keys"))
        #expect(!PeerText.isValidID("a b"))
        #expect(!PeerText.isValidID(String(repeating: "a", count: 129)))
        #expect(PeerText.displayName("  Phone\u{0}\n ", fallback: "x") == "Phone")
        #expect(PeerText.displayName("\u{7}", fallback: "Remote") == "Remote")
        #expect(PeerText.displayName(String(repeating: "n", count: 500), fallback: "x").count == 64)
    }
}

@Suite struct BrowserParsingTests {
    @Test func readsTheTXTRecord() throws {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["id"] = "hub-0001"
        txt["n"] = "Studio Mac"
        let endpoint = NWEndpoint.service(name: "Studio Mac", type: HubService.bonjourType, domain: "local.", interface: nil)
        let hub = try #require(HubBrowser.hub(txt: txt, endpoint: endpoint))
        #expect(hub.id == "hub-0001" && hub.name == "Studio Mac" && hub.protocolVersion == 1 && hub.isCompatible)
        var bad = NWTXTRecord()
        bad["id"] = "../../x"
        #expect(HubBrowser.hub(txt: bad, endpoint: endpoint) == nil)
    }
}

@Suite struct FileKeyStoreTests {
    @Test func roundTripsAndIsPrivateToThisUser() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("keys.json")
        let store = FilePairingKeyStore(url: url)
        #expect(try store.allRecords().isEmpty)
        let a = PairingRecord(peerID: "remote-a", peerName: "Test Phone", key: Data(repeating: 7, count: 32),
                              pairedAt: Date(timeIntervalSinceReferenceDate: 1))
        let b = PairingRecord(peerID: "remote-b", peerName: "Other Phone", key: Data(repeating: 9, count: 32),
                              pairedAt: Date(timeIntervalSinceReferenceDate: 2))
        try store.save(b)
        try store.save(a)
        #expect(try FilePairingKeyStore(url: url).record(for: "remote-a") == a)
        #expect(try store.allRecords().map(\.peerID) == ["remote-a", "remote-b"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try store.remove(peerID: "remote-a")
        #expect(try store.record(for: "remote-a") == nil)
        #expect(try store.allRecords().map(\.peerID) == ["remote-b"])
    }
}

// MARK: - Caching key store

/// A store whose reads block until released, like a Keychain read waiting on an access prompt.
private final class BlockingStore: PairingKeyStore, @unchecked Sendable {
    let inner = InMemoryPairingKeyStore()
    let gate = DispatchSemaphore(value: 0)
    func record(for peerID: String) throws -> PairingRecord? {
        gate.wait(); gate.signal()
        return try inner.record(for: peerID)
    }
    func save(_ record: PairingRecord) throws { try inner.save(record) }
    func remove(peerID: String) throws { try inner.remove(peerID: peerID) }
    func allRecords() throws -> [PairingRecord] {
        gate.wait(); gate.signal()
        return try inner.allRecords()
    }
}

struct CachingKeyStoreTests {
    @Test func neverBlocksItsCallerAndKeepsWritesMadeWhileLoading() async throws {
        let backing = BlockingStore()
        try backing.inner.save(PairingRecord(peerID: "remote-a", peerName: "Phone A", key: randomBytes(32)))
        let store = CachingPairingKeyStore(wrapping: backing)

        // The backing read is stuck (a prompt nobody answers): callers are refused at once.
        let started = Date()
        #expect(throws: CachingPairingKeyStore.NotReady.self) { _ = try store.record(for: "remote-a") }
        #expect(throws: CachingPairingKeyStore.NotReady.self) { _ = try store.allRecords() }
        #expect(Date().timeIntervalSince(started) < 0.5)

        // A pairing completed meanwhile is served from memory and survives the load.
        try store.save(PairingRecord(peerID: "remote-b", peerName: "Phone B", key: randomBytes(32)))
        #expect(try store.record(for: "remote-b")?.peerName == "Phone B")

        backing.gate.signal()   // the prompt is answered
        await store.load()
        #expect(store.isLoaded)
        #expect(try store.record(for: "remote-a")?.peerName == "Phone A")
        #expect(try store.allRecords().map(\.peerID).sorted() == ["remote-a", "remote-b"])

        try store.remove(peerID: "remote-a")
        #expect(try store.record(for: "remote-a") == nil)
        await store.flush()
        #expect(try backing.inner.allRecords().map(\.peerID) == ["remote-b"])
    }
}
