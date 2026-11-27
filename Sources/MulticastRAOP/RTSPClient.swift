import Foundation

/// Errors a RAOP session reports.
public enum RAOPError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingAddress(String)
    case connectFailed(String)
    case passwordRequired
    case authenticationFailed
    case unexpectedStatus(method: String, status: Int, reason: String)
    case badResponse(String)
    case connectionClosed
    case latencyTooSmall(String)
    case volumeRejected(Int)
    case notConnected
    /// The receiver answered 403 Forbidden: it turns this sender away before any pairing or
    /// audio. Apple TVs and HomePods do this to every request, including transient pair-setup,
    /// when their AirPlay access setting doesn't admit this sender. Waiting doesn't change it.
    case accessRefused(method: String)

    public var description: String {
        switch self {
        case .missingAddress(let name): return "no host/port for speaker \(name)"
        case .connectFailed(let why): return "cannot connect: \(why)"
        case .passwordRequired: return "the speaker requires a password (401) and none was given"
        case .authenticationFailed: return "the speaker rejected the password (401 after digest)"
        case let .unexpectedStatus(method, status, reason): return "\(method) failed: \(status) \(reason)"
        case .badResponse(let why): return "bad RTSP response: \(why)"
        case .connectionClosed: return "the speaker closed the RTSP connection"
        case .latencyTooSmall(let why): return "timeline latency too small: \(why)"
        case .volumeRejected(let status): return "the speaker rejected SET_PARAMETER volume (\(status)); refusing to send audio at an unknown volume"
        case .notConnected: return "not connected"
        case .accessRefused(let method): return "the receiver refused access (403 Forbidden to \(method)): its AirPlay access setting does not admit this sender"
        }
    }
}

/// Blocking RTSP client over one TCP connection. Confined to a single serial queue.
final class RTSPClient {
    let connection: TCPConnection
    private(set) var cseq = 0
    var baseHeaders: [RTSPHeader]
    var password: String?
    var username = "iTunes"
    var timeout: TimeInterval
    var log: ((String) -> Void)?
    private var challenge: RTSPDigestChallenge?
    private var readBuffer = Data()

    init(connection: TCPConnection, baseHeaders: [RTSPHeader], password: String?, timeout: TimeInterval, log: ((String) -> Void)?) {
        self.connection = connection
        self.baseHeaders = baseHeaders
        self.password = password
        self.timeout = timeout
        self.log = log
    }

    /// Sends `request` (adding CSeq, common headers and Authorization) and waits for its response.
    /// Answers one 401 with HTTP Digest when a password is configured.
    func send(_ request: RTSPRequest, expectOK: Bool = true) throws -> RTSPResponse {
        var response = try exchange(request)
        if response.statusCode == 401 {
            guard let password, !password.isEmpty else { throw RAOPError.passwordRequired }
            guard let header = response.header("WWW-Authenticate"), let ch = RTSPDigestChallenge.parse(header) else {
                throw RAOPError.badResponse("401 without a Digest challenge")
            }
            challenge = ch
            response = try exchange(request)
            if response.statusCode == 401 { throw RAOPError.authenticationFailed }
        }
        if response.statusCode == 403 { throw RAOPError.accessRefused(method: request.method) }
        if expectOK && response.statusCode != 200 {
            throw RAOPError.unexpectedStatus(method: request.method, status: response.statusCode, reason: response.reason)
        }
        return response
    }

    private func exchange(_ original: RTSPRequest) throws -> RTSPResponse {
        cseq += 1
        var request = original
        var headers = [RTSPHeader("CSeq", String(cseq))]
        headers.append(contentsOf: baseHeaders)
        if let challenge, let password {
            headers.append(RTSPHeader("Authorization", challenge.authorization(method: request.method, uri: request.uri, username: username, password: password)))
        }
        headers.append(contentsOf: original.headers)
        request.headers = headers
        log?("-> \(request.method) \(request.uri) CSeq=\(cseq)\(request.body.isEmpty ? "" : " (\(request.body.count) B body)")")
        do {
            try connection.write(request.serialized(), timeout: timeout)
        } catch {
            throw RAOPError.connectFailed("\(request.method): \(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let (response, consumed) = try parseBuffered() {
                readBuffer.removeFirst(consumed)
                if let got = response.cseq, got != cseq {
                    // A stray response to an earlier request: skip it.
                    log?("   (skipping response for CSeq \(got))")
                    continue
                }
                var extra: [String] = []
                for key in ["audio-latency", "audio-jack-status", "session", "transport", "server"] {
                    if let v = response.header(key) { extra.append("\(key)=\(v)") }
                }
                log?("<- \(response.statusCode) \(response.reason) CSeq=\(response.cseq.map(String.init) ?? "?")\(extra.isEmpty ? "" : "  [" + extra.joined(separator: "; ") + "]")")
                return response
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RAOPError.badResponse("\(request.method): no response within \(timeout) s") }
            let n: Int
            do {
                n = try connection.read(appendingTo: &readBuffer, timeout: remaining)
            } catch {
                throw RAOPError.badResponse("\(request.method): \(error)")
            }
            if n == 0 { throw RAOPError.connectionClosed }
        }
    }

    private func parseBuffered() throws -> (RTSPResponse, Int)? {
        do {
            guard let parsed = try RTSPResponse.parse(readBuffer) else { return nil }
            return (parsed.response, parsed.consumed)
        } catch {
            throw RAOPError.badResponse("\(error)")
        }
    }

    func close() { connection.close() }
}
