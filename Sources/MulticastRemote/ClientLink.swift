import CryptoKit
import Foundation
import MulticastHubModel

// The remote's side of the handshake and of one authenticated session.

struct RemoteIdentity: Sendable {
    var remoteID: String
    var remoteName: String
    var versions: ClosedRange<Int>
}

struct SessionInfo: Sendable {
    var version: Int
    var hubID: String
    var hubName: String
    var helloSent: Date
    var challengeReceived: Date
    var hubTime: Date
}

enum SessionOutcome: Sendable {
    case established(SessionInfo)
    /// This remote holds no key for the hub. `hubID`/`hubName` when the hub said who it is.
    case needsPairing(hubID: String?, hubName: String?, message: String?)
    /// This remote holds a key for `hubID`, but whoever answered couldn't prove it holds the same
    /// key (or said it doesn't know this remote). Nothing in that answer is authenticated: it may
    /// be the real Mac that lost the pairing, or any device on the network using the Mac's public
    /// id. So the key is kept and the remote keeps retrying; only the person (Forget, or pairing
    /// again with the code shown on the Mac) or a sealed `.revoked` message replaces it.
    case notRecognised(hubID: String, hubName: String?, message: String)
}

enum ClientHandshake {
    static func notRecognisedMessage(_ hubName: String?) -> String {
        "\(hubName ?? "The Mac") didn\u{2019}t recognise this pairing. If it was removed on the Mac, pair again."
    }

    private static func expect(_ message: HandshakeMessage) throws -> HandshakeMessage {
        if case .refused(let refusal) = message { throw refusal }
        return message
    }

    static func openSession(_ link: FramedConnection, identity: RemoteIdentity, keyStore: any PairingKeyStore,
                            expectedHubID: String?, timeout: TimeInterval) async throws -> SessionOutcome {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(SessionHandshake.nonceLength)
        let hello = Hello(minVersion: identity.versions.lowerBound, maxVersion: identity.versions.upperBound,
                          remoteID: identity.remoteID, remoteName: identity.remoteName,
                          intent: .session(nonce: nonce, ephemeralKey: ephemeral.publicKey.rawRepresentation))
        let sent = Date()
        try await link.send(WireJSON.encode(hello))
        let first = try await link.receiveHandshake(timeout: timeout, "the Mac's answer")
        let received = Date()
        if case .refused(let r) = first, r.code == .notPaired {
            // Plaintext and unauthenticated: with a key for the hub we were looking for, this
            // can't be told apart from a device answering with that hub's public id.
            if let expectedHubID, try keyStore.record(for: expectedHubID) != nil {
                return .notRecognised(hubID: expectedHubID, hubName: nil, message: Self.notRecognisedMessage(nil))
            }
            return .needsPairing(hubID: nil, hubName: nil, message: r.message)
        }
        guard case .sessionChallenge(let challenge) = try expect(first) else {
            throw RemoteLinkError.malformed("expected a session challenge")
        }
        guard identity.versions.contains(challenge.version), PeerText.isValidID(challenge.hubID),
              challenge.nonce.count == SessionHandshake.nonceLength, challenge.ephemeralKey.count == 32 else {
            throw RemoteLinkError.malformed("session challenge")
        }
        let hubName = PeerText.displayName(challenge.hubName, fallback: "Mac")
        if let expectedHubID, challenge.hubID != expectedHubID {
            throw RemoteLinkError.authenticationFailed("A different Mac answered at this address.")
        }
        guard let record = try keyStore.record(for: challenge.hubID) else {
            return .needsPairing(hubID: challenge.hubID, hubName: hubName, message: nil)
        }
        let transcript = SessionHandshake.transcript(
            version: challenge.version, remoteID: identity.remoteID, hubID: challenge.hubID, remoteNonce: nonce,
            remoteEphemeral: ephemeral.publicKey.rawRepresentation, hubNonce: challenge.nonce,
            hubEphemeral: challenge.ephemeralKey)
        guard SessionHandshake.verify(challenge.mac, longTermKey: record.symmetricKey, role: .hub, transcript: transcript) else {
            // Either the hub lost our pairing (reinstalled) or someone else answers with its id.
            // Neither may cost us the key: keep it, and let the person choose to pair again.
            return .notRecognised(hubID: challenge.hubID, hubName: hubName, message: Self.notRecognisedMessage(hubName))
        }
        try await link.sendHandshake(.sessionProof(
            mac: SessionHandshake.proof(longTermKey: record.symmetricKey, role: .remote, transcript: transcript)))
        let verdict = try await link.receiveHandshake(timeout: timeout, "the Mac's answer")
        if case .refused(let r) = verdict, r.code == .authenticationFailed || r.code == .notPaired {
            // Still plaintext: a relay could inject this after a genuine challenge.
            return .notRecognised(hubID: challenge.hubID, hubName: hubName, message: Self.notRecognisedMessage(hubName))
        }
        guard case .sessionAccepted = try expect(verdict) else { throw RemoteLinkError.malformed("expected acceptance") }
        let keys = try SessionHandshake.keys(ownEphemeral: ephemeral, peerEphemeral: challenge.ephemeralKey,
                                             longTermKey: record.symmetricKey, transcript: transcript)
        link.startEncryption(sendKey: keys.remoteToHub, sendLabel: Direction.remoteToHub,
                             receiveKey: keys.hubToRemote, receiveLabel: Direction.hubToRemote)
        return .established(SessionInfo(version: challenge.version, hubID: challenge.hubID, hubName: hubName,
                                        helloSent: sent, challengeReceived: received, hubTime: challenge.hubTime))
    }

    /// Asks the hub to show a code. Returns once it does.
    static func beginPairing(_ link: FramedConnection, identity: RemoteIdentity, key: Curve25519.KeyAgreement.PrivateKey,
                             expectedHubID: String?, timeout: TimeInterval) async throws -> PairReady {
        let hello = Hello(minVersion: identity.versions.lowerBound, maxVersion: identity.versions.upperBound,
                          remoteID: identity.remoteID, remoteName: identity.remoteName,
                          intent: .pair(publicKey: key.publicKey.rawRepresentation))
        try await link.send(WireJSON.encode(hello))
        guard case .pairReady(let ready) = try expect(try await link.receiveHandshake(timeout: timeout, "the Mac")) else {
            throw RemoteLinkError.malformed("expected pairing to start")
        }
        guard identity.versions.contains(ready.version), PeerText.isValidID(ready.hubID), ready.publicKey.count == 32 else {
            throw RemoteLinkError.malformed("pairing start")
        }
        if let expectedHubID, ready.hubID != expectedHubID {
            throw RemoteLinkError.authenticationFailed("A different Mac answered at this address.")
        }
        return ready
    }

    /// Runs the 20 commit/reveal rounds and key confirmation. `firstHubMessage` delivers the hub's
    /// first message (read early, so a refusal while the person types is seen at once).
    static func completePairing(_ link: FramedConnection, ready: PairReady, key: Curve25519.KeyAgreement.PrivateKey,
                                code: UInt32, identity: RemoteIdentity, timeout: TimeInterval,
                                firstHubMessage: () async throws -> HandshakeMessage) async throws -> PairingRecord {
        var pairing = try PasskeyPairing(role: .remote, code: code, remoteID: identity.remoteID, hubID: ready.hubID,
                                         ownKey: key, peerPublicKey: ready.publicKey)
        for i in 0..<PasskeyPairing.rounds {
            try await link.sendHandshake(.pairCommit(index: i, commitment: try pairing.makeCommitment(i)))
            let reply = i == 0 ? try await firstHubMessage() : try await link.receiveHandshake(timeout: timeout, "pairing")
            guard case .pairCommit(i, let commitment) = try expect(reply) else {
                throw RemoteLinkError.malformed("pairing message out of order")
            }
            try pairing.receiveCommitment(i, commitment)
            try await link.sendHandshake(.pairReveal(index: i, nonce: try pairing.reveal(i)))
            guard case .pairReveal(i, let nonce) = try expect(try await link.receiveHandshake(timeout: timeout, "pairing")) else {
                throw RemoteLinkError.malformed("pairing message out of order")
            }
            try pairing.verifyReveal(i, nonce)
        }
        let keys = try pairing.deriveKeys()
        try await link.sendHandshake(.pairConfirm(mac: pairing.confirmation(for: .remote, confirmKey: keys.confirmKey)))
        guard case .pairConfirm(let mac) = try expect(try await link.receiveHandshake(timeout: timeout, "pairing confirmation")) else {
            throw RemoteLinkError.malformed("expected confirmation")
        }
        try pairing.verifyConfirmation(mac, confirmKey: keys.confirmKey)
        return PairingRecord(peerID: ready.hubID, peerName: PeerText.displayName(ready.hubName, fallback: "Mac"),
                             key: keys.longTermKey.withUnsafeBytes { Data($0) })
    }
}

// MARK: - One authenticated session (remote side)

final class RemoteSession: @unchecked Sendable {
    enum Reply: Sendable {
        case command(HubCommandError?)
        case query(HubQueryResult?, HubCommandError?)
        case artwork(Data?)
    }

    struct Callbacks: Sendable {
        var state: @Sendable (HubState) -> Void
        var levels: @Sendable (StereoLevels) -> Void
        var clockSample: @Sendable (_ sent: Date, _ received: Date, _ hubTime: Date) -> Void
    }

    private struct PendingRequest {
        var continuation: CheckedContinuation<Reply, Error>
        var deadline: Date
    }

    private struct Inner {
        var nextID: UInt64 = 0
        var pending: [UInt64: PendingRequest] = [:]
        var commands = CommandQueue<CheckedContinuation<Void, Error>>()
        var endReason: String?
        var pings: [UInt64: Date] = [:]
        var lastHeard = Date()
        var levelsSubscribed = false
        var tasks: [Task<Void, Never>] = []
        var levelsReceived = 0
        var revoked = false
    }

    let info: SessionInfo
    private let link: FramedConnection
    private let callbacks: Callbacks
    private let requestTimeout: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let deadAfter: TimeInterval
    private let inner = Locked(Inner())
    private let wake: AsyncStream<Void>.Continuation
    private let wakeStream: AsyncStream<Void>

    init(info: SessionInfo, link: FramedConnection, callbacks: Callbacks, requestTimeout: TimeInterval,
         heartbeatInterval: TimeInterval, deadAfter: TimeInterval) {
        self.info = info
        self.link = link
        self.callbacks = callbacks
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.deadAfter = deadAfter
        (wakeStream, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    var levelsReceived: Int { inner.value.levelsReceived }
    /// The hub ended this session with a sealed `.revoked`: it removed this remote's pairing.
    var wasRevoked: Bool { inner.value.revoked }

    static func unreachable(_ message: String = "Not connected to the Mac.") -> HubCommandError {
        HubCommandError(.unreachable, message)
    }

    // MARK: Running

    /// Reads until the session ends; returns why.
    func run() async -> String {
        let sender = Task { await sendCommands() }
        let beat = Task { await heartbeat() }
        inner.withLock { $0.tasks = [sender, beat] }
        var reason: String
        do {
            while true {
                let raw = try await link.receiveFrame(limit: RemoteProtocol.maxHubFrame)
                inner.withLock { $0.lastHeard = Date() }
                switch try SessionPayload.decode(raw) {
                case .artwork(let id, let data):
                    resolve(id, .artwork(data))
                case .json(let body):
                    switch try WireJSON.decode(HubMessage.self, body) {
                    case .state(let state): callbacks.state(state)
                    case .levels(let levels):
                        inner.withLock { $0.levelsReceived += 1 }
                        callbacks.levels(levels)
                    case .commandResult(let id, let error): resolve(id, .command(error))
                    case .queryResult(let id, let result, let error): resolve(id, .query(result, error))
                    case .ping(let id): Task { try? await self.send(.pong(id: id)) }
                    case .pong(let id, let hubTime):
                        let now = Date()
                        if let sent = inner.withLock({ $0.pings.removeValue(forKey: id) }) {
                            callbacks.clockSample(sent, now, hubTime)
                        }
                    case .bye(let why): throw RemoteLinkError.closed(why)
                    case .revoked(let why):
                        inner.withLock { $0.revoked = true }
                        throw RemoteLinkError.closed(why)
                    }
                }
            }
        } catch {
            reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        end(reason)
        return inner.value.endReason ?? reason
    }

    /// Ends the session: fails everything waiting and closes the connection.
    func end(_ reason: String) {
        let (pending, queued, tasks): ([PendingRequest], [CommandQueue<CheckedContinuation<Void, Error>>.Entry], [Task<Void, Never>]) =
            inner.withLock { s in
                if s.endReason == nil { s.endReason = reason }
                defer {
                    s.pending.removeAll()
                    s.tasks.removeAll()
                }
                return (Array(s.pending.values), s.commands.drain(), s.tasks)
            }
        let error = Self.unreachable("Lost the connection to the Mac.")
        for p in pending { p.continuation.resume(throwing: error) }
        for e in queued { for w in e.waiters { w.resume(throwing: error) } }
        for t in tasks { t.cancel() }
        wake.finish()
        link.cancel()
    }

    func sayGoodbye() async {
        _ = try? await withDeadline(0.5, "goodbye", onTimeout: {}) { [self] in try await send(.bye) }
    }

    private func send(_ message: ClientMessage) async throws {
        try await link.send(SessionPayload.json(try WireJSON.encode(message)).encoded())
    }

    // MARK: Requests

    private func resolve(_ id: UInt64, _ reply: Reply) {
        inner.withLock { $0.pending.removeValue(forKey: id) }?.continuation.resume(returning: reply)
    }

    private func fail(_ id: UInt64, _ error: Error) {
        inner.withLock { $0.pending.removeValue(forKey: id) }?.continuation.resume(throwing: error)
    }

    /// Sends a request and waits for its reply (or the timeout, or the end of the session).
    func request(_ make: @escaping @Sendable (UInt64) -> ClientMessage) async throws -> Reply {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Reply, Error>) in
            let id: UInt64? = inner.withLock { s in
                guard s.endReason == nil else { return nil }
                s.nextID += 1
                s.pending[s.nextID] = PendingRequest(continuation: c, deadline: Date().addingTimeInterval(requestTimeout))
                return s.nextID
            }
            guard let id else {
                c.resume(throwing: Self.unreachable())
                return
            }
            Task {
                do { try await self.send(make(id)) } catch { self.fail(id, Self.unreachable("Lost the connection to the Mac.")) }
            }
        }
    }

    // MARK: Commands

    /// Queues `command` behind earlier ones; returns when the hub accepted it.
    func submit(_ command: HubCommand) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let accepted = inner.withLock { s -> Bool in
                guard s.endReason == nil else { return false }
                s.commands.enqueue(command, c)
                return true
            }
            if accepted {
                wake.yield()
            } else {
                c.resume(throwing: Self.unreachable())
            }
        }
    }

    /// One command in flight at a time, in order: the hub sees commands exactly as issued.
    private func sendCommands() async {
        for await _ in wakeStream {
            while let entry = inner.withLock({ $0.commands.popFirst() }) {
                let outcome: Result<Void, Error>
                do {
                    let command = entry.command
                    switch try await request({ .command(id: $0, command: command) }) {
                    case .command(nil): outcome = .success(())
                    case .command(let error?): outcome = .failure(error)
                    default: outcome = .failure(HubCommandError(.failed, "Unexpected answer from the Mac."))
                    }
                } catch {
                    outcome = .failure(error)
                }
                for w in entry.waiters { w.resume(with: outcome) }
            }
        }
    }

    // MARK: Levels and heartbeat

    func setLevels(_ subscribe: Bool) {
        let changed = inner.withLock { s -> Bool in
            guard s.levelsSubscribed != subscribe, s.endReason == nil else { return false }
            s.levelsSubscribed = subscribe
            return true
        }
        if changed { Task { try? await self.send(.levels(subscribe: subscribe)) } }
    }

    private func heartbeat() async {
        var n: UInt64 = 0
        let tick = min(heartbeatInterval, max(0.05, requestTimeout / 4))
        var sinceBeat: TimeInterval = heartbeatInterval   // ping right away for a first clock sample
        while !Task.isCancelled {
            let now = Date()
            // Requests past their deadline fail; the session goes on.
            let expired: [PendingRequest] = inner.withLock { s in
                let ids = s.pending.filter { $0.value.deadline <= now }.map(\.key)
                return ids.compactMap { s.pending.removeValue(forKey: $0) }
            }
            for p in expired { p.continuation.resume(throwing: Self.unreachable("The Mac didn't answer in time.")) }

            if now.timeIntervalSince(inner.value.lastHeard) > deadAfter
                || link.sendStallSeconds(now: now) > deadAfter {
                end("The Mac stopped responding.")
                return
            }
            if sinceBeat >= heartbeatInterval {
                sinceBeat = 0
                n += 1
                let id = n
                inner.withLock { s in
                    s.pings[id] = now
                    s.pings = s.pings.filter { now.timeIntervalSince($0.value) < 60 }
                }
                Task { try? await self.send(.ping(id: id)) }
            }
            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            sinceBeat += tick
        }
    }
}
