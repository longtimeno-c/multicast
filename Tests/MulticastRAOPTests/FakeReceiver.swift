import Darwin
import Foundation
@testable import MulticastRAOP

/// A loopback RAOP receiver for integration tests: answers RTSP, captures RTP audio and
/// control traffic, and can send timing/resend requests back to the sender.
final class FakeReceiver: @unchecked Sendable {
    struct Request {
        var method: String
        var uri: String
        var headers: [String: String]
        var body: Data
    }

    let lock = NSLock()
    private var _requests: [Request] = []
    private var _audio: [[UInt8]] = []
    private var _control: [[UInt8]] = []
    var password: String?
    /// Status to answer the first N ANNOUNCEs with (then 200).
    var failAnnounces = 0
    var failStatus = 453
    /// Answer every request 403 Forbidden, as an Apple TV or HomePod does when its AirPlay
    /// access setting doesn't admit the sender.
    var refuseAccess = false
    /// When set, OPTIONS is answered with this status line instead of 200 OK
    /// (for example "453 Not Enough Bandwidth" from a receiver busy with another sender).
    var optionsStatus: String?

    private let listenFD: Int32
    let port: UInt16
    let audio: UDPSocket
    let control: UDPSocket
    private var stopped = false
    private var clientFD: Int32 = -1
    /// Sender's control/timing ports from its SETUP request.
    private(set) var senderControlPort: UInt16 = 0
    private(set) var senderTimingPort: UInt16 = 0

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var audioPackets: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _audio }
    var controlPackets: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _control }

    init() throws {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        self.listenFD = listenFD
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listenFD, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        audio = try UDPSocket(family: AF_INET)
        control = try UDPSocket(family: AF_INET)
        Thread { [self] in acceptLoop() }.start()
        Thread { [self] in udpLoop() }.start()
    }

    func shutdown() {
        lock.lock(); stopped = true; lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        if clientFD >= 0 { Darwin.shutdown(clientFD, SHUT_RDWR) }
    }

    /// Simulates the receiver dropping the RTSP connection (e.g. another sender took over).
    func dropConnection() {
        if clientFD >= 0 { Darwin.shutdown(clientFD, SHUT_RDWR) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        while !isStopped {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            clientFD = fd
            serve(fd)
            close(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            // Parse complete requests in the buffer.
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for l in lines { if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.endIndex - end.upperBound >= length else { break }
                let body = Data(buffer[end.upperBound..<(end.upperBound + length)])
                buffer = Data(buffer[(end.upperBound + length)...])
                let request = Request(method: String(first[0]), uri: String(first[1]), headers: headers, body: body)
                let response = respond(to: request)
                _ = response.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func respond(to request: Request) -> Data {
        let cseq = request.headers["cseq"] ?? "0"
        if refuseAccess {
            lock.lock(); _requests.append(request); lock.unlock()
            return Data("RTSP/1.0 403 Forbidden\r\nCSeq: \(cseq)\r\nServer: AirTunes/1005.13.2\r\n\r\n".utf8)
        }
        var status = "200 OK"
        var extra = ""
        if let password {
            let challenge = RTSPDigestChallenge(realm: "raop", nonce: "fakenonce")
            let expected = challenge.authorization(method: request.method, uri: request.uri, username: "iTunes", password: password)
            if request.headers["authorization"] != expected {
                lock.lock(); _requests.append(request); lock.unlock()
                return Data("RTSP/1.0 401 Unauthorized\r\nCSeq: \(cseq)\r\nWWW-Authenticate: Digest realm=\"raop\", nonce=\"fakenonce\"\r\n\r\n".utf8)
            }
        }
        lock.lock()
        _requests.append(request)
        let fail = request.method == "ANNOUNCE" && failAnnounces > 0
        if fail { failAnnounces -= 1 }
        lock.unlock()
        switch request.method {
        case "ANNOUNCE" where fail:
            status = "\(failStatus) Not Enough Bandwidth"
        case "OPTIONS" where optionsStatus != nil:
            status = optionsStatus ?? status
        case "SETUP":
            let params = RTSPHeaderValue.parseParameters(request.headers["transport"] ?? "")
            senderControlPort = UInt16(params["control_port"] ?? "0") ?? 0
            senderTimingPort = UInt16(params["timing_port"] ?? "0") ?? 0
            extra = "Session: 1\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=\(audio.localPort);control_port=\(control.localPort);timing_port=\(control.localPort)\r\n"
        case "RECORD":
            extra = "Audio-Latency: 11025\r\n"
        default: break
        }
        return Data("RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\n\(extra)\r\n".utf8)
    }

    private func udpLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            var fds = [pollfd(fd: audio.fd, events: Int16(POLLIN), revents: 0), pollfd(fd: control.fd, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, 50) <= 0 { continue }
            for (i, sock) in [audio, control].enumerated() where fds[i].revents & Int16(POLLIN) != 0 {
                if let (n, _) = buf.withUnsafeMutableBytes({ sock.receive(into: $0) }) {
                    lock.lock()
                    if i == 0 { _audio.append(Array(buf[0..<n])) } else { _control.append(Array(buf[0..<n])) }
                    lock.unlock()
                }
            }
        }
        audio.close()
        control.close()
    }

    private func loopback(_ port: UInt16) -> SocketAddress {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress($0, length: socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }

    /// Sends a timing request from a fresh socket and returns the reply (or nil after 1 s).
    func timingRoundTrip(transmit: UInt64) throws -> [UInt8]? {
        let s = try UDPSocket(family: AF_INET)
        defer { s.close() }
        s.send(TimingPacket.request(transmit: transmit), to: loopback(senderTimingPort))
        var pfd = pollfd(fd: s.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 1000) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 64)
        guard let (n, _) = buf.withUnsafeMutableBytes({ s.receive(into: $0) }) else { return nil }
        return Array(buf[0..<n])
    }

    /// Asks the sender (from our control socket) to resend `count` packets from `seq`.
    func requestResend(seq: UInt16, count: UInt16) {
        let req: [UInt8] = [0x80, 0xD5, 0x00, 0x01, UInt8(seq >> 8), UInt8(seq & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)]
        control.send(req, to: loopback(senderControlPort))
    }

    /// Polls until `condition` holds or `timeout` elapses.
    func wait(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}
