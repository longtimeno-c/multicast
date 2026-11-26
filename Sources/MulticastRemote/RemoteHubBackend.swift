import CryptoKit
import Foundation
import MulticastHubModel
import Network

/// A hub as the remote's UI sees it once connected.
public struct ConnectedHub: Sendable, Equatable {
    public let id: String
    public let name: String
    public let protocolVersion: Int
}

/// The link to the hub, for the remote's UI (richer than `HubAvailability`).
public enum RemoteConnectionState: Sendable, Equatable {
    public enum PairingStep: Sendable, Equatable {
        /// Asking the Mac to show a code.
        case contactingHub
        /// The Mac shows a code: call `submitPairingCode(_:)`. `message` explains a rejected entry.
        case enterCode(message: String?)
        /// Checking the code with the Mac.
        case verifying
    }

    case idle
    /// Browsing Bonjour for the hub.
    case searching
    case connecting(hubName: String?)
    /// Not paired (or the pairing no longer matches): call `startPairing()`. `message` says why
    /// when there is something to say (a wrong code, a lockout).
    case pairingNeeded(hubName: String?, message: String?)
    case pairing(hubName: String?, step: PairingStep)
    case connected(ConnectedHub)
    /// This remote holds a key for the hub, but whoever answered couldn't prove it holds the
    /// same key. The key is kept and the backend retries after `retryingIn` seconds; calling
    /// `startPairing()` meanwhile pairs again instead (it needs the code shown on the Mac).
    case notRecognised(hubName: String?, message: String, retryingIn: TimeInterval)
    /// Disconnected; retrying by itself after `retryingIn` seconds.
    case lost(reason: String, retryingIn: TimeInterval)
    /// The apps' versions don't overlap; `message` says which one to update. Retried slowly.
    case incompatible(message: String)

    public var availability: HubAvailability {
        switch self {
        case .connected: .connected
        case .idle, .searching, .connecting: .connecting
        case .pairingNeeded: .unreachable(reason: "Pair this device with the Mac.")
        case .pairing: .unreachable(reason: "Pairing with the Mac.")
        case .lost(let reason, _): .unreachable(reason: reason)
        case .notRecognised(_, let message, _): .unreachable(reason: message)
        case .incompatible(let message): .unreachable(reason: message)
        }
    }
}

/// `HubBackend` as a network client of a Mac hub: mirrors its state, carries commands (in order)
/// and queries, reconnects by itself with backoff, and pairs when the hub doesn't know it.
public final class RemoteHubBackend: HubBackend, @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        /// A hub found by `HubBrowser`, looked up again by id before every connection attempt
        /// (so a changed address doesn't matter).
        case hub(id: String)
        /// A fixed address (entered by hand). Any hub answering there is accepted only if it
        /// proves it holds this remote's pairing key.
        case endpoint(NWEndpoint)

        public static func host(_ host: String, port: UInt16) -> Target {
            .endpoint(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any))
        }
    }

    public struct Configuration: Sendable {
        /// Stable for this installation (the hub stores its pairing under it).
        public var remoteID: String
        /// Shown on the Mac (the device's name); not secret.
        public var remoteName: String
        public var target: Target
        /// How this device calls itself in messages ("iPhone", "iPad").
        public var deviceKind = "iPhone"
        public var connectTimeout: TimeInterval = 10
        public var handshakeTimeout: TimeInterval = 10
        public var requestTimeout: TimeInterval = 15
        public var heartbeatInterval: TimeInterval = 5
        public var deadAfter: TimeInterval = 20
        /// Must outlast the hub's own pairing timeout.
        public var pairingTimeout: TimeInterval = 130
        public var reconnectDelay: ClosedRange<TimeInterval> = 0.5...15
        /// Overridable in tests only.
        var supportedVersions = RemoteProtocol.supportedVersions
        var loopbackBrowsing = false

        public init(remoteID: String, remoteName: String, target: Target) {
            self.remoteID = remoteID
            self.remoteName = remoteName
            self.target = target
        }
    }

    private enum PairingInput: Sendable {
        case code(String)
        case cancelled
        case hubEnded(attempt: UUID)
    }

    private struct Inner {
        var runTask: Task<Void, Never>?
        var session: RemoteSession?
        var mirror = StateMirror()
        var pairingRequested = false
        var intentWaiter: CheckedContinuation<Bool, Never>?
        var inputWaiter: (attempt: UUID, continuation: CheckedContinuation<PairingInput, Never>)?
        /// The hub ended this pairing attempt while nobody was waiting for input.
        var hubEndedAttempt: UUID?
        /// "hubID:code" pairs that already failed: never sent again (see Crypto.swift).
        var burnedCodes: Set<String> = []
    }

    public let configuration: Configuration
    private let keyStore: any PairingKeyStore
    private let inner = Locked(Inner())
    private let stateBroadcast = Broadcast<HubState>(replaysLatest: true)
    private let levelsBroadcast = Broadcast<StereoLevels>(replaysLatest: false)
    private let connectionBroadcast = Broadcast<RemoteConnectionState>(replaysLatest: true)
    private let availabilityBroadcast = Broadcast<HubAvailability>(replaysLatest: true)

    public init(configuration: Configuration, keyStore: any PairingKeyStore) {
        self.configuration = configuration
        self.keyStore = keyStore
        connectionBroadcast.yield(.idle)
        availabilityBroadcast.yield(.connecting)
        levelsBroadcast.onSubscriberCountChange = { [weak self] count in
            self?.inner.value.session?.setLevels(count > 0)
        }
    }

    private var identity: RemoteIdentity {
        RemoteIdentity(remoteID: configuration.remoteID, remoteName: configuration.remoteName,
                       versions: configuration.supportedVersions)
    }

    // MARK: Lifecycle and UI hooks

    /// Starts connecting (idempotent). `states()` and `availability()` start it too.
    public func start() {
        inner.withLock { s in
            guard s.runTask == nil else { return }
            s.runTask = Task { [weak self] in await self?.runLoop() }
        }
    }

    /// Disconnects and stops retrying. `start()` begins again.
    public func stop() async {
        let (task, session, intent, input) = inner.withLock { s in
            defer {
                s.runTask = nil
                s.session = nil
                s.intentWaiter = nil
                s.inputWaiter = nil
                s.pairingRequested = false
            }
            return (s.runTask, s.session, s.intentWaiter, s.inputWaiter?.continuation)
        }
        task?.cancel()
        intent?.resume(returning: false)
        input?.resume(returning: .cancelled)
        if let session {
            await session.sayGoodbye()
            session.end("Disconnected.")
        }
        await task?.value
        setConnection(.idle)
    }

    public var connectionState: RemoteConnectionState { connectionBroadcast.latest ?? .idle }

    /// The link state, current at once and then every change.
    public func connectionStates() -> AsyncStream<RemoteConnectionState> { connectionBroadcast.stream() }

    /// The person chose to pair (from `.pairingNeeded` or `.notRecognised`): asks the Mac to
    /// show a code.
    public func startPairing() {
        let waiter = inner.withLock { s -> CheckedContinuation<Bool, Never>? in
            defer { s.intentWaiter = nil }
            if s.intentWaiter == nil { s.pairingRequested = true }
            return s.intentWaiter
        }
        waiter?.resume(returning: true)
    }

    /// The code the person typed (in `.pairing(step: .enterCode)`).
    public func submitPairingCode(_ code: String) { deliver(.code(code)) }

    /// Abandons the pairing in progress.
    public func cancelPairing() {
        inner.withLock { $0.pairingRequested = false }
        deliver(.cancelled)
    }

    /// Deletes this device's key for `hubID` (it must pair again).
    public func forgetHub(id hubID: String) throws { try keyStore.remove(peerID: hubID) }

    /// For tests: level frames received in the current session.
    var levelsReceivedInSession: Int { inner.value.session?.levelsReceived ?? 0 }

    private func deliver(_ input: PairingInput) {
        let waiter = inner.withLock { s -> CheckedContinuation<PairingInput, Never>? in
            if case .hubEnded(let attempt) = input, s.inputWaiter?.attempt != attempt {
                s.hubEndedAttempt = attempt   // seen by the next wait for this attempt
                return nil
            }
            guard let w = s.inputWaiter else { return nil }
            s.inputWaiter = nil
            return w.continuation
        }
        waiter?.resume(returning: input)
    }

    private func waitForPairingIntent() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let ready = inner.withLock { s -> Bool? in
                    if Task.isCancelled { return false }
                    if s.pairingRequested {
                        s.pairingRequested = false
                        return true
                    }
                    s.intentWaiter = c
                    return nil
                }
                if let ready { c.resume(returning: ready) }
            }
        } onCancel: {
            let w = inner.withLock { s -> CheckedContinuation<Bool, Never>? in
                defer { s.intentWaiter = nil }
                return s.intentWaiter
            }
            w?.resume(returning: false)
        }
    }

    /// Waits for the person (or the hub ending the attempt). `announcing` is published only once
    /// the wait is registered, so input sent in reaction to it is never lost.
    private func waitForPairingInput(attempt: UUID, announcing state: RemoteConnectionState) async -> PairingInput {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<PairingInput, Never>) in
                let immediate = inner.withLock { s -> PairingInput? in
                    if Task.isCancelled { return .cancelled }
                    if s.hubEndedAttempt == attempt { return .hubEnded(attempt: attempt) }
                    s.inputWaiter = (attempt, c)
                    return nil
                }
                if let immediate {
                    c.resume(returning: immediate)
                } else {
                    setConnection(state)
                }
            }
        } onCancel: {
            let w = inner.withLock { s -> CheckedContinuation<PairingInput, Never>? in
                defer { s.inputWaiter = nil }
                return s.inputWaiter?.continuation
            }
            w?.resume(returning: .cancelled)
        }
    }

    private func setConnection(_ state: RemoteConnectionState) {
        connectionBroadcast.yield(state)
        if availabilityBroadcast.latest != state.availability { availabilityBroadcast.yield(state.availability) }
    }

    // MARK: Connection loop

    private struct Stopped: Error {}
    private struct PairingCancelled: Error {}

    private func resolve() async throws -> (NWEndpoint, expectedHubID: String?, name: String?) {
        switch configuration.target {
        case .endpoint(let endpoint):
            return (endpoint, nil, nil)
        case .hub(let id):
            setConnection(.searching)
            for await hubs in HubBrowser(loopbackOnly: configuration.loopbackBrowsing).hubs() {
                if let hub = hubs.first(where: { $0.id == id }) { return (hub.endpoint, id, hub.name) }
            }
            throw Task.isCancelled ? Stopped() : RemoteLinkError.closed("Couldn't browse the local network.")
        }
    }

    private func connect(_ endpoint: NWEndpoint) async throws -> FramedConnection {
        let link = FramedConnection(NWConnection(to: endpoint, using: FramedConnection.tcpParameters(loopbackOnly: false)),
                                    label: "remote")
        try await link.start(timeout: configuration.connectTimeout)
        return link
    }

    private func runLoop() async {
        var failures = 0
        while !Task.isCancelled {
            var reason = "Lost the connection to the Mac."
            var incompatible: String?
            do {
                let (endpoint, expectedHubID, knownName) = try await resolve()
                setConnection(.connecting(hubName: knownName))
                let link = try await connect(endpoint)
                let outcome: SessionOutcome
                do {
                    outcome = try await ClientHandshake.openSession(link, identity: identity, keyStore: keyStore,
                                                                    expectedHubID: expectedHubID,
                                                                    timeout: configuration.handshakeTimeout)
                } catch {
                    link.cancel()
                    throw error
                }
                switch outcome {
                case .established(let info):
                    failures = 0
                    let (ended, revoked) = await runSession(info, link: link)
                    reason = ended
                    if revoked {
                        // Authenticated (sealed in the session): the Mac removed this remote.
                        try? keyStore.remove(peerID: info.hubID)
                        try await pairUntilPaired(endpoint: endpoint, expectedHubID: info.hubID,
                                                  hubName: info.hubName, message: ended)
                        continue
                    }
                case .needsPairing(let hubID, let hubName, let message):
                    link.cancel()
                    try await pairUntilPaired(endpoint: endpoint, expectedHubID: expectedHubID ?? hubID,
                                              hubName: hubName ?? knownName, message: message)
                    continue   // paired: connect again at once
                case .notRecognised(let hubID, let hubName, let message):
                    // Unauthenticated: keep the key, keep trying, pair only if the person asks.
                    link.cancel()
                    failures += 1
                    let delay = Backoff(range: configuration.reconnectDelay).delay(attempt: failures)
                    setConnection(.notRecognised(hubName: hubName ?? knownName, message: message, retryingIn: delay))
                    if await sleepOrPairingIntent(delay) {
                        try await pairUntilPaired(endpoint: endpoint, expectedHubID: expectedHubID ?? hubID,
                                                  hubName: hubName ?? knownName, message: nil, alreadyAsked: true)
                    }
                    if Task.isCancelled { return }
                    continue
                }
            } catch is Stopped {
                return
            } catch let refusal as HubRefusal where refusal.code == .incompatibleVersion {
                let hub = (refusal.hubMinVersion ?? 0)...(refusal.hubMaxVersion ?? 0)
                incompatible = VersionNegotiation.updateMessage(local: configuration.supportedVersions, peer: hub,
                                                                thisDevice: configuration.deviceKind, otherDevice: "Mac")
            } catch {
                reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if Task.isCancelled { return }
            failures += 1
            let delay: TimeInterval
            if let incompatible {
                delay = configuration.reconnectDelay.upperBound
                setConnection(.incompatible(message: incompatible))
            } else {
                delay = Backoff(range: configuration.reconnectDelay).delay(attempt: failures)
                setConnection(.lost(reason: reason, retryingIn: delay))
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Returns why the session ended, and whether the hub revoked this remote's pairing.
    private func runSession(_ info: SessionInfo, link: FramedConnection) async -> (String, revoked: Bool) {
        let session = RemoteSession(
            info: info, link: link,
            callbacks: RemoteSession.Callbacks(
                state: { [weak self] in self?.receive($0) },
                levels: { [weak self] in self?.levelsBroadcast.yield($0) },
                clockSample: { [weak self] sent, received, hubTime in
                    self?.inner.withLock { $0.mirror.clock.add(sent: sent, received: received, hubTime: hubTime) }
                }),
            requestTimeout: configuration.requestTimeout, heartbeatInterval: configuration.heartbeatInterval,
            deadAfter: configuration.deadAfter)
        let installed = inner.withLock { s -> Bool in
            guard !Task.isCancelled, s.runTask != nil else { return false }
            s.mirror.beginSession()
            s.mirror.clock.add(sent: info.helloSent, received: info.challengeReceived, hubTime: info.hubTime)
            s.session = session
            return true
        }
        guard installed else {
            session.end("Disconnected.")
            return ("Disconnected.", false)
        }
        setConnection(.connected(ConnectedHub(id: info.hubID, name: info.hubName, protocolVersion: info.version)))
        if levelsBroadcast.subscriberCount > 0 { session.setLevels(true) }
        let reason = await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            session.end("Disconnected.")
        }
        inner.withLock { s in if s.session === session { s.session = nil } }
        return (reason, session.wasRevoked)
    }

    /// Sleeps `delay` seconds, cut short when the person asks to pair. True when they did.
    private func sleepOrPairingIntent(_ delay: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return false
            }
            group.addTask { [weak self] in await self?.waitForPairingIntent() ?? false }
            var asked = await group.next() ?? false
            group.cancelAll()
            // The other child may have consumed an intent as it was cancelled: never lose it.
            for await other in group where other { asked = true }
            return asked && !Task.isCancelled
        }
    }

    private func receive(_ state: HubState) {
        let next = inner.withLock { $0.mirror.apply(state) }
        if let next { stateBroadcast.yield(next) }
    }

    /// Waits for the person to ask, then pairs; repeats after a failure. Returns once paired.
    /// `alreadyAsked`: the person's request was already taken (skip the first wait).
    private func pairUntilPaired(endpoint: NWEndpoint, expectedHubID: String?, hubName: String?,
                                 message: String?, alreadyAsked: Bool = false) async throws {
        var message = message
        var hubName = hubName
        var asked = alreadyAsked
        while true {
            if !asked {
                setConnection(.pairingNeeded(hubName: hubName, message: message))
                guard await waitForPairingIntent(), !Task.isCancelled else { throw Stopped() }
            }
            asked = false
            do {
                let record = try await pairOnce(endpoint: endpoint, expectedHubID: expectedHubID, hubName: &hubName)
                try keyStore.save(record)
                return
            } catch is PairingCancelled {
                message = nil
            } catch let refusal as HubRefusal {
                if refusal.code == .incompatibleVersion { throw refusal }
                message = refusal.message
            } catch PairingError.codeMismatch {
                message = "That code didn't match. Try again with the new code shown on the Mac."
            } catch {
                if Task.isCancelled { throw Stopped() }
                message = "Pairing didn't complete: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func pairOnce(endpoint: NWEndpoint, expectedHubID: String?, hubName: inout String?) async throws -> PairingRecord {
        setConnection(.pairing(hubName: hubName, step: .contactingHub))
        let link = try await connect(endpoint)
        defer { link.cancel() }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ready = try await ClientHandshake.beginPairing(link, identity: identity, key: key, expectedHubID: expectedHubID,
                                                           timeout: configuration.handshakeTimeout)
        hubName = PeerText.displayName(ready.hubName, fallback: "Mac")

        // Read the hub's next message now: a refusal (cancelled or timed out on the Mac) then
        // shows while the person is still typing. Its round-0 commitment is used below.
        let attempt = UUID()
        let timeout = configuration.pairingTimeout
        let firstReply = Task { try await link.receiveHandshake(timeout: timeout, "the Mac") }
        let watcher = Task { [weak self] in
            _ = await firstReply.result
            self?.deliver(.hubEnded(attempt: attempt))
        }
        defer { watcher.cancel() }

        var step: RemoteConnectionState.PairingStep = .enterCode(message: nil)
        var code: (value: UInt32, text: String)?
        while code == nil {
            switch await waitForPairingInput(attempt: attempt, announcing: .pairing(hubName: hubName, step: step)) {
            case .code(let text):
                guard let value = PairingCode.parse(text) else {
                    step = .enterCode(message: "Enter the 6-digit code shown on the Mac.")
                    continue
                }
                let canonical = PairingCode.format(value)
                if inner.value.burnedCodes.contains("\(ready.hubID):\(canonical)") {
                    step = .enterCode(message: "That code was already tried. Use the new code shown on the Mac.")
                    continue
                }
                code = (value, canonical)
            case .cancelled:
                throw PairingCancelled()
            case .hubEnded:
                // The hub spoke (or hung up) before we sent anything: a refusal or a link error.
                if case .refused(let refusal) = try await firstReply.value { throw refusal }
                throw RemoteLinkError.malformed("pairing message out of order")
            }
        }
        guard let code else { throw PairingCancelled() }
        // Burn the code before anything about it leaves this device.
        inner.withLock { _ = $0.burnedCodes.insert("\(ready.hubID):\(code.text)") }
        setConnection(.pairing(hubName: hubName, step: .verifying))
        return try await ClientHandshake.completePairing(
            link, ready: ready, key: key, code: code.value, identity: identity, timeout: configuration.handshakeTimeout,
            firstHubMessage: { try await firstReply.value })
    }

    // MARK: HubBackend

    public func states() async -> AsyncStream<HubState> {
        start()
        return stateBroadcast.stream()
    }

    public func levels() async -> AsyncStream<StereoLevels> { levelsBroadcast.stream() }

    public func availability() async -> AsyncStream<HubAvailability> {
        start()
        return availabilityBroadcast.stream()
    }

    private func liveSession() throws -> RemoteSession {
        guard let session = inner.value.session else { throw RemoteSession.unreachable() }
        return session
    }

    public func perform(_ command: HubCommand) async throws {
        if case .addFiles = command { throw HubCommandError(.unsupported, "Add files on the Mac.") }
        try await liveSession().submit(command)
    }

    private func query(_ query: HubQuery) async throws -> HubQueryResult {
        switch try await liveSession().request({ .query(id: $0, query: query) }) {
        case .query(let result?, nil): return result
        case .query(_, let error?): throw error
        default: throw HubCommandError(.failed, "Unexpected answer from the Mac.")
        }
    }

    private func tracks(_ q: HubQuery) async throws -> Page<TrackItem> {
        guard let page = try await query(q).tracks else { throw HubCommandError(.failed, "Unexpected answer from the Mac.") }
        return page
    }

    public func artwork(id: ArtworkID, maxPixel: Int) async -> Data? {
        guard let session = try? liveSession(),
              case .artwork(let data)? = try? await session.request({ .query(id: $0, query: .artwork(id: id, maxPixel: maxPixel)) })
        else { return nil }
        return data
    }

    public func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> {
        guard let p = try await query(.playlists(page: page)).playlists else {
            throw HubCommandError(.failed, "Unexpected answer from the Mac.")
        }
        return p
    }

    public func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await tracks(.playlistTracks(playlistID: playlistID, page: page))
    }

    public func songs(_ page: PageRequest) async throws -> Page<TrackItem> { try await tracks(.songs(page: page)) }
    public func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        try await tracks(.search(query: query, page: page))
    }
    public func upNext(_ page: PageRequest) async throws -> Page<QueueItem> {
        guard let p = try await query(.upNext(page: page)).queue else {
            throw HubCommandError(.failed, "Unexpected answer from the Mac.")
        }
        return p
    }
    public func files(_ page: PageRequest) async throws -> Page<TrackItem> { try await tracks(.files(page: page)) }
    public func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem> {
        try await tracks(.spotifyHistory(page: page))
    }
}
