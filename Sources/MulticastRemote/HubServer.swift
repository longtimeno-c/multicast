import CryptoKit
import Foundation
import MulticastAudio
import MulticastHubModel
import Network

// MARK: - Public types for the hub UI

/// Shown on the Mac while a remote pairs: the code the person types on the remote.
public struct PairingPrompt: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let remoteID: String
    public let remoteName: String
    /// Six digits, e.g. "042917".
    public let code: String
    public let expiresAt: Date
}

public enum PairingOutcome: Sendable, Equatable {
    case paired
    case failed(reason: String)
    /// Cancelled on the Mac (`HubServer.cancelPairing()`).
    case cancelled
    case timedOut
}

/// A remote with a live, authenticated session.
public struct ConnectedRemote: Identifiable, Sendable, Equatable {
    /// This connection (a remote that reconnects gets a new one).
    public let id: UUID
    public let remoteID: String
    public let remoteName: String
    public let connectedAt: Date
}

/// A remote that holds a pairing key for this hub.
public struct PairedRemote: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let pairedAt: Date
    public let isConnected: Bool
}

public enum HubServerEvent: Sendable, Equatable {
    /// Show `prompt.code` until `pairingEnded` arrives with the same id.
    case pairingRequested(PairingPrompt)
    case pairingEnded(id: UUID, remoteName: String, outcome: PairingOutcome)
    case remoteConnected(ConnectedRemote)
    case remoteDisconnected(ConnectedRemote, reason: String)
    /// The listener failed after it had started (for example Bonjour advertising refused with
    /// "NoAuth" when Local Network access is off). The server is no longer serving; `start()`
    /// may be called again.
    case stopped(reason: String)
}

/// How the server hands a phone that offered itself to whatever plays the audio (the Mac app
/// wires these to `LocalHub`). The server itself only knows `HubBackend`, which has no sinks.
public struct RemoteSpeakerHost: Sendable {
    /// A phone offers itself, or says its output changed (same `descriptor.id`, same sink).
    public var add: @Sendable (_ descriptor: SpeakerDescriptor, _ sink: any AudioSink) async -> Void
    /// The phone withdrew or disconnected.
    public var remove: @Sendable (_ speakerID: String) async -> Void

    public init(add: @escaping @Sendable (SpeakerDescriptor, any AudioSink) async -> Void,
                remove: @escaping @Sendable (String) async -> Void) {
        self.add = add
        self.remove = remove
    }

    /// The speaker a phone's offer becomes.
    public static func descriptor(remoteID: String, remoteName: String, route: PhoneRoute) -> SpeakerDescriptor {
        let kind: SpeakerDescriptor.LocalKind
        switch route.kind {
        case .builtIn: kind = .builtIn
        case .bluetooth, .headphones, .car: kind = .bluetooth
        case .airPlay: kind = .airplaySystem
        case .usb: kind = .usb
        case .other: kind = .other
        }
        return SpeakerDescriptor(id: PhoneSpeakerSink.speakerID(remoteID: remoteID), name: remoteName, transport: .remote,
                                 model: route.name, localDeviceUID: route.kind.rawValue, localKind: kind)
    }
}

// MARK: - HubServer

/// Serves any `HubBackend` to remotes on the local network: advertises `_multicast-hub._tcp`
/// over Bonjour, pairs new remotes with a 6-digit code, and runs an encrypted session per
/// remote that pushes `HubState` and levels and answers `HubCommand`/`HubQuery`.
public final class HubServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Stable across launches (published in the TXT record; remotes store their key under it).
        public var hubID: String
        /// Shown in remotes' hub lists.
        public var name: String
        /// 0 picks a free port (Bonjour tells remotes which).
        public var port: UInt16 = 0
        public var advertises = true
        /// Accept connections on the loopback interface only (tests).
        public var loopbackOnly = false
        public var pairingPolicy = PairingPolicy()
        /// Each handshake message (pairing rounds included) must arrive within this.
        public var handshakeTimeout: TimeInterval = 10
        /// How long the person has to type the code.
        public var pairingTimeout: TimeInterval = 120
        public var heartbeatInterval: TimeInterval = 5
        /// A remote silent this long (or not reading this long) is dropped.
        public var deadAfter: TimeInterval = 20
        /// Minimum spacing of level frames to a subscribed remote (10 Hz by default).
        public var levelsInterval: TimeInterval = 0.1
        /// Largest artwork side served; requests for more (or for the original, 0) get this.
        public var maxArtworkPixel = 1024
        public var maxRemotes = 8
        /// Connections still in the handshake at once; more are closed at once.
        public var maxPendingConnections = 8
        public var maxConcurrentQueriesPerRemote = 16
        /// Overridable in tests only.
        var supportedVersions = RemoteProtocol.supportedVersions

        public init(hubID: String, name: String) {
            self.hubID = hubID
            self.name = name
        }
    }

    public enum ServerError: Error, Equatable, LocalizedError {
        case invalidHubID
        case alreadyRunning
        case listenerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidHubID: "The hub id must be 1–128 letters, digits, '-', '_' or '.'."
            case .alreadyRunning: "The server is already running."
            case .listenerFailed(let why): "Couldn't listen for remotes: \(why)"
            }
        }
    }

    private struct ActivePairing {
        var prompt: PairingPrompt
        var link: FramedConnection
        var cancelled = false
    }

    private struct Inner {
        var listener: NWListener?
        var running = false
        var pending = 0
        var sessions: [UUID: HubSession] = [:]
        var gate: PairingGate
        var activePairing: ActivePairing?
        var listenerCancelled: CheckedContinuation<Void, Never>?
    }

    public let configuration: Configuration
    private let backend: any HubBackend
    /// Where pairing keys live (the apps wrap the Keychain in a `CachingPairingKeyStore`).
    public let keyStore: any PairingKeyStore
    private let inner: Locked<Inner>
    private let queue = DispatchQueue(label: "multicast.hub-server")
    private let eventBroadcast = Broadcast<HubServerEvent>(replaysLatest: false, policy: .unbounded)
    private let commandMutex = AsyncMutex()
    private let speakerMutex = AsyncMutex()
    /// nil: this hub takes no phone speakers (offers are refused).
    private let speakerHost: RemoteSpeakerHost?

    public init(backend: any HubBackend, configuration: Configuration, keyStore: any PairingKeyStore,
                speakerHost: RemoteSpeakerHost? = nil) {
        self.speakerHost = speakerHost
        self.backend = backend
        self.configuration = configuration
        self.keyStore = keyStore
        self.inner = Locked(Inner(gate: PairingGate(policy: configuration.pairingPolicy)))
    }

    /// Pairing prompts and connections, as they happen. Each call is an independent stream.
    public func events() -> AsyncStream<HubServerEvent> { eventBroadcast.stream() }

    /// Starts listening (and advertising). Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard PeerText.isValidID(configuration.hubID) else { throw ServerError.invalidHubID }
        let params = FramedConnection.tcpParameters(loopbackOnly: configuration.loopbackOnly)
        params.allowLocalEndpointReuse = true
        let port = configuration.port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }
        let alreadyRunning = inner.withLock { s -> Bool in
            if s.running { return true }
            s.running = true
            s.listener = listener
            return false
        }
        if alreadyRunning { throw ServerError.alreadyRunning }

        if configuration.advertises {
            var txt = NWTXTRecord()
            txt[RemoteProtocol.TXTKey.version] = String(RemoteProtocol.currentVersion)
            txt[RemoteProtocol.TXTKey.hubID] = configuration.hubID
            txt[RemoteProtocol.TXTKey.name] = PeerText.displayName(configuration.name, fallback: "Mac")
            listener.service = NWListener.Service(name: PeerText.displayName(configuration.name, fallback: "Mac"),
                                                  type: HubService.bonjourType, domain: nil, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let started = Locked(false)
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if started.withLock({ let was = $0; $0 = true; return !was }) {
                            c.resume(returning: listener.port?.rawValue ?? 0)
                        }
                    case .failed(let error):
                        listener.cancel()
                        if started.withLock({ let was = $0; $0 = true; return !was }) {
                            c.resume(throwing: ServerError.listenerFailed(FramedConnection.describe(error)))
                        } else {
                            self?.listenerFailedAfterStart(listener, reason: FramedConnection.describe(error))
                        }
                    case .cancelled:
                        if started.withLock({ let was = $0; $0 = true; return !was }) {
                            c.resume(throwing: ServerError.listenerFailed("cancelled"))
                        }
                        let waiter = self?.inner.withLock { s -> CheckedContinuation<Void, Never>? in
                            defer { s.listenerCancelled = nil }
                            return s.listenerCancelled
                        }
                        waiter?.resume()
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            inner.withLock {
                $0.running = false
                $0.listener = nil
            }
            throw error
        }
    }

    private func listenerFailedAfterStart(_ listener: NWListener, reason: String) {
        let current = inner.withLock { s -> Bool in
            guard s.listener === listener else { return false }
            s.running = false
            s.listener = nil
            return true
        }
        if current { eventBroadcast.yield(.stopped(reason: reason)) }
    }

    /// The port being listened on, once started.
    public var port: UInt16? { inner.value.listener?.port?.rawValue }

    /// Stops advertising, closes every session and any pairing in progress.
    public func stop() async {
        let (listener, sessions, pairing): (NWListener?, [HubSession], FramedConnection?) = inner.withLock { s in
            s.running = false
            defer {
                s.listener = nil
                s.sessions.removeAll()
            }
            s.activePairing?.cancelled = true
            return (s.listener, Array(s.sessions.values), s.activePairing?.link)
        }
        for session in sessions { session.close(reason: "The Mac stopped sharing.", notifyRemote: true) }
        pairing?.cancel()
        if let listener {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                inner.withLock { $0.listenerCancelled = c }
                listener.cancel()
            }
        }
    }

    // MARK: Paired and connected remotes

    public var connectedRemotes: [ConnectedRemote] {
        inner.value.sessions.values.map(\.info).sorted { $0.connectedAt < $1.connectedAt }
    }

    public func pairedRemotes() throws -> [PairedRemote] {
        let connected = Set(connectedRemotes.map(\.remoteID))
        return try keyStore.allRecords().map {
            PairedRemote(id: $0.peerID, name: $0.peerName, pairedAt: $0.pairedAt, isConnected: connected.contains($0.peerID))
        }
    }

    /// Forgets a remote's key and drops its sessions. It must pair again to reconnect.
    public func revoke(remoteID: String) throws {
        try keyStore.remove(peerID: remoteID)
        let sessions = inner.withLock { $0.sessions.values.filter { $0.info.remoteID == remoteID } }
        for s in sessions { s.close(reason: "\(configuration.name) removed this remote.", notifyRemote: true, revoked: true) }
    }

    /// Ends the pairing in progress (the person closed the code window on the Mac).
    public func cancelPairing() {
        let link = inner.withLock { s -> FramedConnection? in
            s.activePairing?.cancelled = true
            return s.activePairing?.link
        }
        guard let link else { return }
        Task { await link.refuse(HubRefusal(.pairingCancelled, "Pairing was cancelled on the Mac.")) }
    }

    /// For tests: level frames sent to each remote id so far.
    func levelFramesSent(remoteID: String) -> Int {
        inner.value.sessions.values.filter { $0.info.remoteID == remoteID }.reduce(0) { $0 + $1.levelFramesSent }
    }

    // MARK: Accepting

    private func accept(_ connection: NWConnection) {
        let admitted = inner.withLock { s -> Bool in
            guard s.running, s.pending < configuration.maxPendingConnections else { return false }
            s.pending += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        Task { await self.serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        let link = FramedConnection(connection, label: "hub")
        let released = Locked(false)
        let release = { [inner] in
            if released.withLock({ let was = $0; $0 = true; return !was }) { inner.withLock { $0.pending -= 1 } }
        }
        defer { release() }
        do {
            try await link.start(timeout: configuration.handshakeTimeout)
            guard let session = try await handshake(link) else {
                link.cancel()
                return
            }
            release()
            await run(session)
        } catch {
            link.cancel()
        }
    }

    private func refuseVersion(_ link: FramedConnection, remote: ClosedRange<Int>) async {
        let hub = configuration.supportedVersions
        await link.refuse(HubRefusal(
            .incompatibleVersion,
            VersionNegotiation.updateMessage(local: remote, peer: hub, thisDevice: "iPhone", otherDevice: "Mac"),
            hubMinVersion: hub.lowerBound, hubMaxVersion: hub.upperBound))
    }

    /// Returns an authenticated session, or nil when the connection ended in the handshake
    /// (refused, or a pairing that finished: the remote reconnects to start its session).
    private func handshake(_ link: FramedConnection) async throws -> HubSession? {
        let first = try await withDeadline(configuration.handshakeTimeout, "hello", onTimeout: { link.cancel() }) {
            try await link.receiveFrame(limit: RemoteProtocol.maxHandshakeFrame)
        }
        // Anything that isn't our hello is closed without an answer.
        guard let probe = try? JSONDecoder().decode(HelloVersionProbe.self, from: first),
              probe.magic == RemoteProtocol.magic, probe.minVersion <= probe.maxVersion else { return nil }
        let remoteVersions = probe.minVersion...probe.maxVersion
        guard let version = VersionNegotiation.agree(configuration.supportedVersions, remoteVersions) else {
            await refuseVersion(link, remote: remoteVersions)
            return nil
        }
        guard let hello = try? WireJSON.decode(Hello.self, first), PeerText.isValidID(hello.remoteID) else {
            await link.refuse(HubRefusal(.malformed, "The Mac didn't understand this remote."))
            return nil
        }
        let name = PeerText.displayName(hello.remoteName, fallback: "Remote")
        switch hello.intent {
        case .pair(let publicKey):
            await pair(link, remoteID: hello.remoteID, remoteName: name, version: version, publicKey: publicKey)
            return nil
        case .session(let nonce, let ephemeralKey):
            return try await authenticate(link, remoteID: hello.remoteID, remoteName: name, version: version,
                                          remoteNonce: nonce, remoteEphemeral: ephemeralKey)
        }
    }

    private func authenticate(_ link: FramedConnection, remoteID: String, remoteName: String, version: Int,
                              remoteNonce: Data, remoteEphemeral: Data) async throws -> HubSession? {
        guard remoteNonce.count == SessionHandshake.nonceLength, remoteEphemeral.count == 32 else {
            await link.refuse(HubRefusal(.malformed, "The Mac didn't understand this remote."))
            return nil
        }
        guard let record = try keyStore.record(for: remoteID) else {
            await link.refuse(HubRefusal(.notPaired, "This remote isn't paired with \(configuration.name). Pair it again."))
            return nil
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hubNonce = randomBytes(SessionHandshake.nonceLength)
        let transcript = SessionHandshake.transcript(
            version: version, remoteID: remoteID, hubID: configuration.hubID, remoteNonce: remoteNonce,
            remoteEphemeral: remoteEphemeral, hubNonce: hubNonce, hubEphemeral: ephemeral.publicKey.rawRepresentation)
        let challenge = SessionChallenge(
            version: version, hubID: configuration.hubID, hubName: configuration.name, nonce: hubNonce,
            ephemeralKey: ephemeral.publicKey.rawRepresentation, hubTime: Date(),
            mac: SessionHandshake.proof(longTermKey: record.symmetricKey, role: .hub, transcript: transcript))
        try await link.sendHandshake(.sessionChallenge(challenge))

        let reply = try await link.receiveHandshake(timeout: configuration.handshakeTimeout, "authentication")
        guard case .sessionProof(let mac) = reply,
              SessionHandshake.verify(mac, longTermKey: record.symmetricKey, role: .remote, transcript: transcript) else {
            await link.refuse(HubRefusal(.authenticationFailed, "\(configuration.name) couldn't verify this remote. Pair it again."))
            return nil
        }
        let keys = try SessionHandshake.keys(ownEphemeral: ephemeral, peerEphemeral: remoteEphemeral,
                                             longTermKey: record.symmetricKey, transcript: transcript)
        let full = inner.withLock { $0.sessions.count >= configuration.maxRemotes || !$0.running }
        if full {
            await link.refuse(HubRefusal(.tooManyConnections, "Too many remotes are connected to \(configuration.name)."))
            return nil
        }
        try await link.sendHandshake(.sessionAccepted)
        link.startEncryption(sendKey: keys.hubToRemote, sendLabel: Direction.hubToRemote,
                             receiveKey: keys.remoteToHub, receiveLabel: Direction.remoteToHub)
        let info = ConnectedRemote(id: UUID(), remoteID: remoteID, remoteName: remoteName, connectedAt: Date())
        return HubSession(info: info, link: link, version: version, backend: backend, configuration: configuration,
                          commandMutex: commandMutex, speakers: self)
    }

    // MARK: Phone speakers

    /// One offer or withdrawal at a time across all remotes, so a phone that reconnects never
    /// has its new speaker removed by its old session's goodbye.
    func offerSpeaker(from session: HubSession, route: PhoneRoute) async throws -> (port: UInt16, salt: Data, speakerID: String) {
        guard let host = speakerHost else {
            throw HubCommandError(.unsupported, "\(configuration.name) can\u{2019}t play to an iPhone.")
        }
        return try await withSpeakerLock { [self] in try await offerSpeakerLocked(host, from: session, route: route) }
    }

    private func withSpeakerLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await speakerMutex.lock()
        do {
            let result = try await body()
            await speakerMutex.unlock()
            return result
        } catch {
            await speakerMutex.unlock()
            throw error
        }
    }

    private func offerSpeakerLocked(_ host: RemoteSpeakerHost, from session: HubSession,
                                    route: PhoneRoute) async throws -> (port: UInt16, salt: Data, speakerID: String) {
        let route = route.sanitized
        let descriptor = RemoteSpeakerHost.descriptor(remoteID: session.info.remoteID, remoteName: session.info.remoteName, route: route)
        // The same phone on an older connection: that speaker goes first.
        let others = inner.withLock { $0.sessions.values.filter { $0 !== session && $0.info.remoteID == session.info.remoteID } }
        for other in others {
            if let old = other.takeSpeaker() {
                await host.remove(descriptor.id)
                old.stop()
            }
        }
        if let old = session.takeSpeaker() {
            await host.remove(descriptor.id)
            old.stop()
        }
        let salt = randomBytes(AudioChannel.saltLength)
        guard let keys = session.audioChannelKeys(salt: salt) else {
            throw HubCommandError(.failed, "The session isn\u{2019}t ready.")
        }
        let sink = PhoneSpeakerSink(id: descriptor.id, displayName: descriptor.name, keys: keys)
        let channel = HubAudioChannel(sink: sink, loopbackOnly: configuration.loopbackOnly)
        let port: UInt16
        do {
            port = try await channel.start()
        } catch {
            channel.stop()
            throw HubCommandError(.failed, "Couldn\u{2019}t open the audio channel.")
        }
        guard session.setSpeaker(channel) else {
            channel.stop()
            throw HubCommandError(.unreachable, "The remote disconnected.")
        }
        await host.add(descriptor, sink)
        return (port, salt, descriptor.id)
    }

    func updateSpeakerRoute(from session: HubSession, route: PhoneRoute) async {
        guard let host = speakerHost else { return }
        await withSpeakerLock {
            guard let channel = session.currentSpeaker else { return }
            await host.add(RemoteSpeakerHost.descriptor(remoteID: session.info.remoteID, remoteName: session.info.remoteName,
                                                        route: route.sanitized), channel.sink)
        }
    }

    func withdrawSpeaker(from session: HubSession) async {
        await withSpeakerLock { [speakerHost] in
            guard let channel = session.takeSpeaker() else { return }
            await speakerHost?.remove(channel.sink.id)
            channel.stop()
        }
    }

    // MARK: Pairing (hub side; protocol in Crypto.swift)

    private func pair(_ link: FramedConnection, remoteID: String, remoteName: String, version: Int,
                      publicKey: Data) async {
        let admission = inner.withLock { $0.gate.begin(now: Date()) }
        let attempt: UUID
        switch admission {
        case .failure(.busy):
            await link.refuse(HubRefusal(.pairingBusy, "\(configuration.name) is pairing with another device. Try again in a moment."))
            return
        case .failure(.locked(let seconds)):
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            await link.refuse(HubRefusal(
                .pairingLocked,
                "Too many pairing attempts. Try again in \(minutes) minute\(minutes == 1 ? "" : "s").",
                retryAfter: seconds))
            return
        case .success(let id):
            attempt = id
        }

        let codeText = PairingCode.random()
        let hubKey = Curve25519.KeyAgreement.PrivateKey()
        let prompt = PairingPrompt(id: attempt, remoteID: remoteID, remoteName: remoteName, code: codeText,
                                   expiresAt: Date().addingTimeInterval(configuration.pairingTimeout))
        inner.withLock { $0.activePairing = ActivePairing(prompt: prompt, link: link) }

        var outcome: PairingOutcome
        do {
            var pairing = try PasskeyPairing(role: .hub, code: PairingCode.parse(codeText) ?? 0, remoteID: remoteID,
                                             hubID: configuration.hubID, ownKey: hubKey, peerPublicKey: publicKey)
            try await link.sendHandshake(.pairReady(PairReady(version: version, hubID: configuration.hubID,
                                                              hubName: configuration.name,
                                                              publicKey: hubKey.publicKey.rawRepresentation)))
            eventBroadcast.yield(.pairingRequested(prompt))
            for i in 0..<PasskeyPairing.rounds {
                let wait = i == 0 ? configuration.pairingTimeout : configuration.handshakeTimeout
                guard case .pairCommit(i, let commitment) = try await link.receiveHandshake(timeout: wait, "pairing code") else {
                    throw RemoteLinkError.malformed("pairing message out of order")
                }
                try pairing.receiveCommitment(i, commitment)
                try await link.sendHandshake(.pairCommit(index: i, commitment: try pairing.makeCommitment(i)))
                guard case .pairReveal(i, let nonce) = try await link.receiveHandshake(
                    timeout: configuration.handshakeTimeout, "pairing") else {
                    throw RemoteLinkError.malformed("pairing message out of order")
                }
                try pairing.verifyReveal(i, nonce)
                try await link.sendHandshake(.pairReveal(index: i, nonce: try pairing.reveal(i)))
            }
            let keys = try pairing.deriveKeys()
            guard case .pairConfirm(let mac) = try await link.receiveHandshake(
                timeout: configuration.handshakeTimeout, "pairing confirmation") else {
                throw RemoteLinkError.malformed("pairing message out of order")
            }
            try pairing.verifyConfirmation(mac, confirmKey: keys.confirmKey)
            try keyStore.save(PairingRecord(peerID: remoteID, peerName: remoteName,
                                            key: keys.longTermKey.withUnsafeBytes { Data($0) }))
            try await link.sendHandshake(.pairConfirm(mac: pairing.confirmation(for: .hub, confirmKey: keys.confirmKey)))
            outcome = .paired
            // Let the remote read the confirmation and hang up first.
            _ = try? await link.receiveHandshake(timeout: 2, "goodbye")
        } catch PairingError.codeMismatch {
            outcome = .failed(reason: "The code didn't match.")
            await link.refuse(HubRefusal(.pairingFailed,
                                         "That code didn't match. Try again with the new code shown on \(configuration.name)."))
        } catch {
            let cancelled = inner.withLock { $0.activePairing?.cancelled ?? false }
            if cancelled {
                outcome = .cancelled
            } else if case RemoteLinkError.timedOut = error {
                outcome = .timedOut
                await link.refuse(HubRefusal(.pairingTimedOut, "The code wasn't entered in time. Try again."))
            } else {
                outcome = .failed(reason: error.localizedDescription)
                await link.refuse(HubRefusal(.pairingFailed, "Pairing didn't complete. Try again."))
            }
        }
        link.cancel()
        inner.withLock { s in
            let cancelled = s.activePairing?.cancelled ?? false
            s.activePairing = nil
            if cancelled && outcome != .paired {
                s.gate.cancel(attempt)
            } else {
                s.gate.end(attempt, succeeded: outcome == .paired, now: Date())
            }
        }
        eventBroadcast.yield(.pairingEnded(id: attempt, remoteName: remoteName, outcome: outcome))
    }

    // MARK: Sessions

    private func run(_ session: HubSession) async {
        let admitted = inner.withLock { s -> Bool in
            guard s.running else { return false }
            s.sessions[session.info.id] = session
            return true
        }
        guard admitted else {
            session.close(reason: "The Mac stopped sharing.", notifyRemote: true)
            return
        }
        eventBroadcast.yield(.remoteConnected(session.info))
        let reason = await session.run()
        await withdrawSpeaker(from: session)
        inner.withLock { _ = $0.sessions.removeValue(forKey: session.info.id) }
        eventBroadcast.yield(.remoteDisconnected(session.info, reason: reason))
    }
}

// MARK: - One remote's session (hub side)

final class HubSession: @unchecked Sendable {
    let info: ConnectedRemote
    let version: Int
    private let link: FramedConnection
    private let backend: any HubBackend
    private let configuration: HubServer.Configuration
    private let commandMutex: AsyncMutex
    private weak var speakers: HubServer?

    private struct Inner {
        var speaker: HubAudioChannel?
        var tasks: [UUID: Task<Void, Never>] = [:]
        var levelsTask: Task<Void, Never>?
        var lastHeard = Date()
        var closeReason: String?
        var activeQueries = 0
        var levelFramesSent = 0
        var pingCounter: UInt64 = 0
    }

    private let inner = Locked(Inner())

    init(info: ConnectedRemote, link: FramedConnection, version: Int, backend: any HubBackend,
         configuration: HubServer.Configuration, commandMutex: AsyncMutex, speakers: HubServer? = nil) {
        self.speakers = speakers
        self.info = info
        self.link = link
        self.version = version
        self.backend = backend
        self.configuration = configuration
        self.commandMutex = commandMutex
    }

    var levelFramesSent: Int { inner.value.levelFramesSent }

    // MARK: This remote as a speaker

    var currentSpeaker: HubAudioChannel? { inner.value.speaker }

    func audioChannelKeys(salt: Data) -> AudioChannelKeys? { link.audioChannelKeys(salt: salt, asHub: true) }

    /// False when the session has already ended (the channel must then be stopped by the caller).
    func setSpeaker(_ channel: HubAudioChannel) -> Bool {
        inner.withLock { s in
            guard s.closeReason == nil else { return false }
            s.speaker = channel
            return true
        }
    }

    func takeSpeaker() -> HubAudioChannel? {
        inner.withLock { s in
            defer { s.speaker = nil }
            return s.speaker
        }
    }

    private func speakerOffered(_ id: UInt64, _ route: PhoneRoute) async {
        do {
            guard version >= RemoteProtocol.phoneSpeakerVersion, let speakers else {
                throw HubCommandError(.unsupported, "This Mac can\u{2019}t play to an iPhone.")
            }
            let accepted = try await speakers.offerSpeaker(from: self, route: route)
            try? await send(.speakerAccepted(id: id, port: accepted.port, salt: accepted.salt, speakerID: accepted.speakerID))
        } catch {
            let e = error as? HubCommandError ?? HubCommandError(.failed, error.localizedDescription)
            try? await send(.commandResult(id: id, error: e))
        }
    }

    private func spawn(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        inner.withLock { s in
            guard s.closeReason == nil else { return }
            s.tasks[id] = Task { [weak self] in
                await body()
                _ = self?.inner.withLock { $0.tasks.removeValue(forKey: id) }
            }
        }
    }

    /// Runs until the remote leaves or is dropped; returns why.
    func run() async -> String {
        let (commands, commandInput) = AsyncStream.makeStream(of: (UInt64, HubCommand).self, bufferingPolicy: .bufferingOldest(64))
        spawn { [self] in await pushStates() }
        spawn { [self] in await execute(commands) }
        spawn { [self] in await heartbeat() }

        var reason: String
        do {
            while true {
                let raw = try await link.receiveFrame(limit: RemoteProtocol.maxRemoteFrame)
                inner.withLock { $0.lastHeard = Date() }
                guard case .json(let body) = try SessionPayload.decode(raw) else {
                    throw RemoteLinkError.malformed("binary payload from a remote")
                }
                switch try WireJSON.decode(ClientMessage.self, body) {
                case .command(let id, let command):
                    if case .dropped = commandInput.yield((id, command)) {
                        throw RemoteLinkError.malformed("too many queued commands")
                    }
                case .query(let id, let query):
                    startQuery(id, query)
                case .levels(let subscribe):
                    setLevels(subscribe)
                case .ping(let id):
                    spawn { [self] in try? await send(.pong(id: id, hubTime: Date())) }
                case .pong:
                    break
                case .bye:
                    throw RemoteLinkError.closed("The remote disconnected.")
                case .speakerOffer(let id, let route):
                    spawn { [self] in await speakerOffered(id, route) }
                case .speakerRoute(let route):
                    spawn { [self] in await speakers?.updateSpeakerRoute(from: self, route: route) }
                case .speakerWithdraw:
                    spawn { [self] in await speakers?.withdrawSpeaker(from: self) }
                }
            }
        } catch {
            reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if let set = inner.value.closeReason { reason = set }
        commandInput.finish()
        let tasks: [Task<Void, Never>] = inner.withLock { s in
            if s.closeReason == nil { s.closeReason = reason }
            defer {
                s.tasks.removeAll()
                s.levelsTask = nil
            }
            return Array(s.tasks.values) + (s.levelsTask.map { [$0] } ?? [])
        }
        for t in tasks { t.cancel() }
        link.cancel()
        return reason
    }

    /// Ends the session; `notifyRemote` sends a goodbye first (best effort, not waited for long).
    /// `revoked` makes that goodbye the sealed `.revoked` message: the remote then drops its key.
    func close(reason: String, notifyRemote: Bool, revoked: Bool = false) {
        let first = inner.withLock { s -> Bool in
            guard s.closeReason == nil else { return false }
            s.closeReason = reason
            return true
        }
        guard first else { return }
        if notifyRemote {
            let goodbye: HubMessage = revoked ? .revoked(reason: reason) : .bye(reason: reason)
            Task { [link] in
                _ = try? await withDeadline(1, "goodbye", onTimeout: {}) {
                    try await link.send(SessionPayload.json(try WireJSON.encode(goodbye)).encoded())
                }
                link.cancel()
            }
        } else {
            link.cancel()
        }
    }

    private func send(_ message: HubMessage) async throws {
        try await link.send(SessionPayload.json(try WireJSON.encode(message)).encoded())
    }

    /// Every state change, newest only: the backend's stream keeps one pending state and this
    /// loop waits for each send to be taken by the network stack, so a slow remote skips states.
    private func pushStates() async {
        for await state in await backend.states() {
            if Task.isCancelled { break }
            do {
                try await send(.state(state.downgraded(forRemoteVersion: version)))
            } catch {
                link.cancel()
                break
            }
        }
    }

    private func execute(_ commands: AsyncStream<(UInt64, HubCommand)>) async {
        for await (id, command) in commands {
            let outcome: HubCommandError?
            switch RemoteInputPolicy.sanitize(command) {
            case .failure(let refusal):
                outcome = refusal
            case .success(let safe):
                // One command at a time across all remotes: backends expect serial commands.
                await commandMutex.lock()
                do {
                    try await backend.perform(safe)
                    outcome = nil
                } catch let e as HubCommandError {
                    outcome = e
                } catch {
                    outcome = HubCommandError(.failed, error.localizedDescription)
                }
                await commandMutex.unlock()
            }
            if Task.isCancelled { break }
            try? await send(.commandResult(id: id, error: outcome))
        }
    }

    private func startQuery(_ id: UInt64, _ query: HubQuery) {
        let admitted = inner.withLock { s -> Bool in
            guard s.activeQueries < configuration.maxConcurrentQueriesPerRemote else { return false }
            s.activeQueries += 1
            return true
        }
        guard admitted else {
            spawn { [self] in
                try? await send(.queryResult(id: id, result: nil,
                                             error: HubCommandError(.unavailable, "Too many requests at once.")))
            }
            return
        }
        spawn { [self] in
            defer { inner.withLock { $0.activeQueries -= 1 } }
            switch RemoteInputPolicy.sanitize(query, maxArtworkPixel: configuration.maxArtworkPixel) {
            case .failure(let error):
                if case .artwork = query {
                    try? await link.send(SessionPayload.artwork(requestID: id, data: nil).encoded())
                } else {
                    try? await send(.queryResult(id: id, result: nil, error: error))
                }
            case .success(.artwork(let artworkID, let maxPixel)):
                var data = await backend.artwork(id: artworkID, maxPixel: maxPixel)
                if let d = data, d.count > RemoteProtocol.maxHubFrame - 64 { data = nil }
                try? await link.send(SessionPayload.artwork(requestID: id, data: data).encoded())
            case .success(let safe):
                do {
                    let result = try await backend.answer(safe)
                    try? await send(.queryResult(id: id, result: result, error: nil))
                } catch {
                    let e = error as? HubCommandError ?? HubCommandError(.failed, error.localizedDescription)
                    try? await send(.queryResult(id: id, result: nil, error: e))
                }
            }
        }
    }

    private func setLevels(_ subscribe: Bool) {
        let old: Task<Void, Never>? = inner.withLock { s in
            if subscribe {
                guard s.levelsTask == nil, s.closeReason == nil else { return nil }
                s.levelsTask = Task { [weak self] in await self?.pumpLevels() }
                return nil
            }
            defer { s.levelsTask = nil }
            return s.levelsTask
        }
        old?.cancel()
    }

    /// Levels at most every `levelsInterval`, always including the final `.silent`.
    private func pumpLevels() async {
        var lastSent = Date.distantPast
        for await levels in await backend.levels() {
            if Task.isCancelled { break }
            let now = Date()
            guard levels == .silent || now.timeIntervalSince(lastSent) >= configuration.levelsInterval else { continue }
            lastSent = now
            do {
                try await send(.levels(levels))
                inner.withLock { $0.levelFramesSent += 1 }
            } catch {
                break
            }
        }
    }

    private func heartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(configuration.heartbeatInterval * 1_000_000_000))
            if Task.isCancelled { return }
            let now = Date()
            let silent = now.timeIntervalSince(inner.value.lastHeard)
            if silent > configuration.deadAfter || link.sendStallSeconds(now: now) > configuration.deadAfter {
                close(reason: "The remote stopped responding.", notifyRemote: false)
                return
            }
            let id = inner.withLock { $0.pingCounter += 1; return $0.pingCounter }
            // Never wait on a ping: a stalled send must not stall the watchdog.
            if !link.hasSendsInFlight || silent > configuration.heartbeatInterval {
                spawn { [self] in try? await send(.ping(id: id)) }
            }
        }
    }
}

// MARK: - Input from remotes

/// What a remote may ask for. Everything a remote sends is untrusted: sizes are clamped, ids and
/// strings capped, and commands that name the hub's own files are refused.
enum RemoteInputPolicy {
    static let maxIDLength = 512
    static let maxCursorLength = 256
    static let maxSearchLength = 256
    static let maxRemovedFiles = 1000
    static let maxQueuedTracks = 1000
    static let maxTextLength = 512
    static let maxLinkLength = 1024

    /// Reverse-DNS characters only, as bundle identifiers are.
    static func isBundleID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 255
            && s.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    static func sanitize(_ command: HubCommand) -> Result<HubCommand, HubCommandError> {
        func idOK(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= maxIDLength }
        func clamp01(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
        let notFound = HubCommandError(.notFound, "That item isn't on the Mac.")
        switch command {
        case .play, .pause, .next, .previous, .openSpotify, .requestPermission, .selectSource:
            return .success(command)
        case .seek(let position):
            guard position.isFinite else { return .failure(HubCommandError(.unsupported, "Invalid position.")) }
            return .success(.seek(position: max(0, position)))
        case .playTrack(let id, let context):
            guard idOK(id) else { return .failure(notFound) }
            switch context {
            case .playlist(let pid) where !idOK(pid): return .failure(notFound)
            case .search(let q): return .success(.playTrack(id: id, context: .search(query: String(q.prefix(maxSearchLength)))))
            case .catalog(let q): return .success(.playTrack(id: id, context: .catalog(query: String(q.prefix(maxSearchLength)))))
            default: return .success(command)
            }
        case .playPlaylist(let id, _), .pinPlaylist(let id), .unpinPlaylist(let id):
            return idOK(id) ? .success(command) : .failure(notFound)
        case .addToQueue(let tracks, let source, let placement):
            guard source != .app, tracks.count <= maxQueuedTracks, tracks.allSatisfy({ idOK($0.id) }) else {
                return .failure(notFound)
            }
            func cap(_ s: String) -> String { String(s.prefix(maxTextLength)) }
            let safe = tracks.map {
                TrackItem(id: $0.id, title: cap($0.title), artist: cap($0.artist), album: cap($0.album),
                          duration: $0.duration.isFinite ? max(0, $0.duration) : 0,
                          artworkID: $0.artworkID.flatMap { idOK($0) ? $0 : nil }, format: $0.format.map(cap))
            }
            return .success(.addToQueue(tracks: safe, source: source, placement: placement))
        case .addSpotifyLink(let link, _), .pinSpotifyLink(let link):
            return link.utf8.count <= maxLinkLength ? .success(command) : .failure(notFound)
        case .removeFromQueue(let ids), .moveInQueue(let ids, _):
            guard ids.count <= maxQueuedTracks, ids.allSatisfy(idOK) else { return .failure(notFound) }
            return .success(command)
        case .clearQueue, .setShuffle:
            return .success(command)
        case .captureApp(let bundleID):
            return isBundleID(bundleID) ? .success(command) : .failure(notFound)
        case .addFiles:
            return .failure(HubCommandError(.unsupported, "Add files on the Mac."))
        case .removeFiles(let ids):
            guard ids.count <= maxRemovedFiles, ids.allSatisfy(idOK) else { return .failure(notFound) }
            return .success(command)
        case .setSpeakerEnabled(let id, _), .retrySpeaker(let id):
            return idOK(id.rawValue) ? .success(command) : .failure(notFound)
        case .setSpeakerVolume(let id, let volume):
            guard idOK(id.rawValue) else { return .failure(notFound) }
            return .success(.setSpeakerVolume(id: id, volume: clamp01(volume)))
        case .setSpeakerSyncTrim(let id, let ms):
            guard idOK(id.rawValue) else { return .failure(notFound) }
            let r = SpeakerItem.syncTrimRange
            return .success(.setSpeakerSyncTrim(id: id, milliseconds: min(r.upperBound, max(r.lowerBound, ms))))
        case .setMasterVolume(let volume):
            return .success(.setMasterVolume(volume: clamp01(volume)))
        case .refreshSpeakers, .calibrateSync, .cancelSyncCalibration:
            return .success(command)
        }
    }

    static func sanitize(_ query: HubQuery, maxArtworkPixel: Int) -> Result<HubQuery, HubCommandError> {
        let bad = HubCommandError(.notFound, "Invalid request.")
        func page(_ p: PageRequest) -> PageRequest? {
            if let c = p.cursor, c.utf8.count > maxCursorLength { return nil }
            return PageRequest(cursor: p.cursor, limit: p.clampedLimit)
        }
        switch query {
        case .playlists(let p): return page(p).map { .success(.playlists(page: $0)) } ?? .failure(bad)
        case .songs(let p): return page(p).map { .success(.songs(page: $0)) } ?? .failure(bad)
        case .upNext(let p): return page(p).map { .success(.upNext(page: $0)) } ?? .failure(bad)
        case .files(let p): return page(p).map { .success(.files(page: $0)) } ?? .failure(bad)
        case .spotifyHistory(let p): return page(p).map { .success(.spotifyHistory(page: $0)) } ?? .failure(bad)
        case .playlistTracks(let id, let p):
            guard !id.isEmpty, id.utf8.count <= maxIDLength, let p = page(p) else { return .failure(bad) }
            return .success(.playlistTracks(playlistID: id, page: p))
        case .search(let q, let p):
            guard let p = page(p) else { return .failure(bad) }
            return .success(.search(query: String(q.prefix(maxSearchLength)), page: p))
        case .catalogSearch(let q, let p):
            guard let p = page(p) else { return .failure(bad) }
            return .success(.catalogSearch(query: String(q.prefix(maxSearchLength)), page: p))
        case .artwork(let id, let maxPixel):
            guard !id.isEmpty, id.utf8.count <= maxIDLength else { return .failure(bad) }
            let px = maxPixel <= 0 || maxPixel > maxArtworkPixel ? maxArtworkPixel : maxPixel
            return .success(.artwork(id: id, maxPixel: px))
        }
    }
}
