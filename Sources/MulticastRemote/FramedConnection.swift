import CryptoKit
import Foundation
import Network

/// One TCP connection carrying length-prefixed frames, plaintext during the handshake and sealed
/// once `startEncryption` is called. One reader at a time; any number of concurrent senders
/// (sealing and enqueueing happen together under a lock, so counters match the byte order).
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue

    private struct ReadyState {
        var waiter: CheckedContinuation<Void, Error>?
        var outcome: Result<Void, RemoteLinkError>?
    }

    private struct SendState {
        var sealer: FrameSealer?
        var inFlight = 0
        /// Last time a send was enqueued while idle or completed: lets a watchdog spot a peer
        /// that stopped reading.
        var lastProgress = Date()
    }

    private let ready = Locked(ReadyState())
    private let sendState = Locked(SendState())
    private let opener = Locked<FrameOpener?>(nil)

    init(_ connection: NWConnection, label: String) {
        self.connection = connection
        self.queue = DispatchQueue(label: "multicast.link.\(label)")
    }

    static func tcpParameters(loopbackOnly: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        return params
    }

    /// Starts the connection and waits until it is ready (or fails, or `timeout` passes).
    func start(timeout: TimeInterval) async throws {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
        try await withTaskCancellationHandler {
            try await withDeadline(timeout, "connecting", onTimeout: { [weak self] in self?.cancel() }) { [self] in
                try await waitReady()
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    private func handle(_ state: NWConnection.State) {
        let outcome: Result<Void, RemoteLinkError>?
        switch state {
        case .ready: outcome = .success(())
        case .waiting(let e): outcome = .failure(.closed(Self.describe(e)))
        case .failed(let e): outcome = .failure(.closed(Self.describe(e)))
        case .cancelled: outcome = .failure(.closed("Connection closed."))
        default: outcome = nil
        }
        guard let outcome else { return }
        if case .waiting = state { connection.cancel() }   // we run our own retry loop
        let waiter: CheckedContinuation<Void, Error>? = ready.withLock {
            guard $0.outcome == nil else { return nil }
            $0.outcome = outcome
            defer { $0.waiter = nil }
            return $0.waiter
        }
        waiter?.resume(with: outcome.mapError { $0 as Error })
    }

    private func waitReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let done: Result<Void, RemoteLinkError>? = ready.withLock {
                if let o = $0.outcome { return o }
                $0.waiter = c
                return nil
            }
            if let done { c.resume(with: done.mapError { $0 as Error }) }
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: "The Mac refused the connection."
        case .posix(let code) where code == .ECANCELED: "Connection closed."
        case .posix(let code) where code == .ETIMEDOUT: "The connection timed out."
        // kDNSServiceErr_NoAuth / kDNSServiceErr_PolicyDenied: Local Network privacy said no.
        case .dns(let code) where code == -65555 || code == -65570: "Local Network access is off (NoAuth)."
        default: error.localizedDescription
        }
    }

    func cancel() { connection.cancel() }

    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint ?? connection.endpoint }

    // MARK: Receiving

    private func receive(exactly n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let data, data.count == n {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: RemoteLinkError.closed(Self.describe(error)))
                } else {
                    c.resume(throwing: RemoteLinkError.closed(isComplete ? "The other side closed the connection." : "Short read."))
                }
            }
        }
    }

    /// The next frame's payload, opened if the session is sealed.
    /// Cancelling the waiting task closes the connection (a pending read can't be withdrawn).
    func receiveFrame(limit: Int) async throws -> Data {
        let (header, body) = try await withTaskCancellationHandler {
            let header = try await receive(exactly: FrameCodec.headerLength)
            let n = try FrameCodec.payloadLength(header: header, limit: limit + 16)
            return (header, try await receive(exactly: n))
        } onCancel: { [connection] in
            connection.cancel()
        }
        _ = header
        return try opener.withLock { o in
            guard o != nil else { return body }
            return try o!.open(body)
        }
    }

    // MARK: Sending

    /// Sends one frame (sealed if the session is) and waits until the stack has taken it.
    func send(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do {
                try sendState.withLock { s in
                    let body = s.sealer != nil ? try s.sealer!.seal(payload) : payload
                    if s.inFlight == 0 { s.lastProgress = Date() }
                    s.inFlight += 1
                    connection.send(content: FrameCodec.frame(body), completion: .contentProcessed { [weak self] error in
                        self?.sendState.withLock {
                            $0.inFlight -= 1
                            $0.lastProgress = Date()
                        }
                        if let error {
                            c.resume(throwing: RemoteLinkError.closed(Self.describe(error)))
                        } else {
                            c.resume()
                        }
                    })
                }
            } catch {
                c.resume(throwing: error)
            }
        }
    }

    /// Seconds a send has been stuck in the stack (0 when nothing is pending).
    func sendStallSeconds(now: Date = Date()) -> TimeInterval {
        sendState.withLock { $0.inFlight > 0 ? now.timeIntervalSince($0.lastProgress) : 0 }
    }

    var hasSendsInFlight: Bool { sendState.value.inFlight > 0 }

    /// From now on every frame is sealed/opened. Call between frames, with no send in progress.
    func startEncryption(sendKey: SymmetricKey, sendLabel: String, receiveKey: SymmetricKey, receiveLabel: String) {
        sendState.withLock { $0.sealer = FrameSealer(key: sendKey, direction: sendLabel) }
        opener.withLock { $0 = FrameOpener(key: receiveKey, direction: receiveLabel) }
    }

    // MARK: Handshake helpers

    func sendHandshake(_ message: HandshakeMessage) async throws {
        try await send(WireJSON.encode(message))
    }

    func receiveHandshake(timeout: TimeInterval, _ what: String) async throws -> HandshakeMessage {
        let data = try await withDeadline(timeout, what, onTimeout: { [weak self] in self?.cancel() }) { [self] in
            try await receiveFrame(limit: RemoteProtocol.maxHandshakeFrame)
        }
        return try WireJSON.decode(HandshakeMessage.self, data)
    }

    /// Sends a refusal, then closes (best effort; the peer may already be gone).
    func refuse(_ refusal: HubRefusal) async {
        _ = try? await withDeadline(1, "refusing", onTimeout: {}) { [self] in
            try await sendHandshake(.refused(refusal))
        }
        cancel()
    }
}
