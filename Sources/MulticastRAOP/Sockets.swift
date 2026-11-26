import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Error raised by the thin BSD socket layer below.
public struct RAOPSocketError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let code: Int32

    init(_ what: String, code: Int32 = errno) {
        self.code = code
        self.description = "\(what): \(String(cString: strerror(code))) (errno \(code))"
    }

    init(message: String) {
        self.code = 0
        self.description = message
    }
}

/// An IPv4 / IPv6 socket address (value type wrapper around `sockaddr_storage`).
struct SocketAddress: CustomStringConvertible {
    var storage = sockaddr_storage()
    var length: socklen_t = 0

    init() {}

    init(_ addr: UnsafePointer<sockaddr>, length: socklen_t) {
        self.length = length
        withUnsafeMutableBytes(of: &storage) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: addr, count: Int(length)))
        }
    }

    var family: Int32 { Int32(storage.ss_family) }

    var port: UInt16 {
        get {
            withUnsafeBytes(of: storage) { raw in
                if family == AF_INET6 {
                    return UInt16(bigEndian: raw.load(as: sockaddr_in6.self).sin6_port)
                }
                return UInt16(bigEndian: raw.load(as: sockaddr_in.self).sin_port)
            }
        }
        set {
            let isV6 = family == AF_INET6
            withUnsafeMutableBytes(of: &storage) { raw in
                if isV6 {
                    var sin6 = raw.load(as: sockaddr_in6.self)
                    sin6.sin6_port = newValue.bigEndian
                    raw.storeBytes(of: sin6, as: sockaddr_in6.self)
                } else {
                    var sin = raw.load(as: sockaddr_in.self)
                    sin.sin_port = newValue.bigEndian
                    raw.storeBytes(of: sin, as: sockaddr_in.self)
                }
            }
        }
    }

    func withPort(_ port: UInt16) -> SocketAddress {
        var copy = self
        copy.port = port
        return copy
    }

    /// Numeric address without port or scope (what SDP wants).
    var ipString: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        withUnsafeBytes(of: storage) { raw in
            if family == AF_INET6 {
                var sin6 = raw.load(as: sockaddr_in6.self)
                _ = inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(buffer.count))
            } else {
                var sin = raw.load(as: sockaddr_in.self)
                _ = inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count))
            }
        }
        return String(cString: buffer)
    }

    var description: String {
        family == AF_INET6 ? "[\(ipString)]:\(port)" : "\(ipString):\(port)"
    }

    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: storage) { raw in
            try body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), length)
        }
    }

    /// Resolve `host` (DNS, mDNS `.local`, or literal). IPv4 results first.
    static func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            let msg = rc == 0 ? "no addresses" : String(cString: gai_strerror(rc))
            throw RAOPSocketError(message: "cannot resolve \(host): \(msg)")
        }
        defer { freeaddrinfo(first) }
        var v4: [SocketAddress] = []
        var v6: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            if let addr = ai.pointee.ai_addr {
                let sa = SocketAddress(addr, length: ai.pointee.ai_addrlen)
                if ai.pointee.ai_family == AF_INET { v4.append(sa) } else if ai.pointee.ai_family == AF_INET6 { v6.append(sa) }
            }
            cursor = ai.pointee.ai_next
        }
        return v4 + v6
    }
}

private func setNoSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Blocking TCP connection with explicit timeouts. Used only from the sink's control queue.
final class TCPConnection {
    private(set) var fd: Int32
    let peer: SocketAddress
    let local: SocketAddress

    private init(fd: Int32, peer: SocketAddress, local: SocketAddress) {
        self.fd = fd
        self.peer = peer
        self.local = local
    }

    deinit { close() }

    /// Errors that say "not yet" rather than "no": macOS's Local Network privacy check makes a
    /// BSD socket `connect` to a LAN address fail at once with EHOSTUNREACH while it decides
    /// (the first connections after launch), and a Wi-Fi rejoin briefly leaves no route.
    static let retryableConnectErrors: Set<Int32> = [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EADDRNOTAVAIL]

    /// Connects to the first address of `host` that answers. An immediate "no route" is retried
    /// (re-resolving) every 250 ms until `timeout` has passed in all.
    static func connect(host: String, port: UInt16, timeout: TimeInterval,
                        onRetry: ((Int, RAOPSocketError) -> Void)? = nil) throws -> TCPConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while true {
            attempt += 1
            let addresses = try SocketAddress.resolve(host: host, port: port)
            var lastError: Error = RAOPSocketError(message: "no address for \(host)")
            for address in addresses {
                let left = max(0.5, deadline.timeIntervalSinceNow)
                do {
                    return try connect(to: address, timeout: left)
                } catch {
                    lastError = error
                }
            }
            guard let e = lastError as? RAOPSocketError, retryableConnectErrors.contains(e.code),
                  deadline.timeIntervalSinceNow > 0.25 else { throw lastError }
            onRetry?(attempt, e)
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    static func connect(to address: SocketAddress, timeout: TimeInterval) throws -> TCPConnection {
        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw RAOPSocketError("socket") }
        setNoSigPipe(fd)
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = address.withSockAddr { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            let err = errno
            guard err == EINPROGRESS else {
                Darwin.close(fd)
                throw RAOPSocketError("connect to \(address)", code: err)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(timeout * 1000))
            if n == 0 {
                Darwin.close(fd)
                throw RAOPSocketError(message: "connect to \(address): timed out after \(timeout) s")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if n < 0 || soError != 0 {
                let code = n < 0 ? errno : soError
                Darwin.close(fd)
                throw RAOPSocketError("connect to \(address)", code: code)
            }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        var peerStorage = sockaddr_storage()
        var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var localStorage = sockaddr_storage()
        var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let peer: SocketAddress = withUnsafeMutablePointer(to: &peerStorage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &peerLen) == 0 ? SocketAddress(sa, length: peerLen) : address
            }
        }
        let local: SocketAddress = withUnsafeMutablePointer(to: &localStorage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &localLen) == 0 ? SocketAddress(sa, length: localLen) : SocketAddress()
            }
        }
        return TCPConnection(fd: fd, peer: peer, local: local)
    }

    var isOpen: Bool { fd >= 0 }

    func write(_ data: Data, timeout: TimeInterval) throws {
        guard fd >= 0 else { throw RAOPSocketError(message: "connection closed") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Int32(timeout * 1000))
                if ready == 0 { throw RAOPSocketError(message: "write timed out") }
                if ready < 0 { if errno == EINTR { continue }; throw RAOPSocketError("poll") }
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw RAOPSocketError("send")
                }
                offset += n
            }
        }
    }

    /// Reads whatever is available (waiting up to `timeout`) and appends it. Returns 0 on EOF.
    func read(appendingTo buffer: inout Data, timeout: TimeInterval) throws -> Int {
        guard fd >= 0 else { throw RAOPSocketError(message: "connection closed") }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready == 0 { throw RAOPSocketError(message: "read timed out after \(timeout) s") }
            if ready < 0 { if errno == EINTR { continue }; throw RAOPSocketError("poll") }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw RAOPSocketError("recv")
            }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            return n
        }
    }

    /// Non-blocking check whether the peer closed the connection (EOF or error). Unread data is left in place.
    func peerHasClosed() -> Bool {
        guard fd >= 0 else { return true }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        if pfd.revents & Int16(POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 { return true }
        if n < 0 { return errno != EAGAIN && errno != EINTR }
        return false
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// Unconnected UDP socket bound to an ephemeral port on all interfaces.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let localPort: UInt16
    private var closed = false

    init(family: Int32) throws {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RAOPSocketError("udp socket") }
        setNoSigPipe(fd)
        var bufSize: Int32 = 512 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        var any = SocketAddress()
        if family == AF_INET6 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_addr = in6addr_any
            withUnsafeMutableBytes(of: &any.storage) { $0.storeBytes(of: sin6, as: sockaddr_in6.self) }
            any.length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr.s_addr = INADDR_ANY
            withUnsafeMutableBytes(of: &any.storage) { $0.storeBytes(of: sin, as: sockaddr_in.self) }
            any.length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let rc = any.withSockAddr { bind(fd, $0, $1) }
        guard rc == 0 else {
            let err = errno
            Darwin.close(fd)
            throw RAOPSocketError("udp bind", code: err)
        }
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let bound: SocketAddress = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(fd, sa, &len)
                return SocketAddress(sa, length: len)
            }
        }
        self.fd = fd
        self.localPort = bound.port
    }

    deinit { close() }

    @discardableResult
    func send(_ bytes: UnsafeRawBufferPointer, to address: SocketAddress) -> Bool {
        guard !closed, let base = bytes.baseAddress else { return false }
        let n = address.withSockAddr { sendto(fd, base, bytes.count, 0, $0, $1) }
        return n == bytes.count
    }

    @discardableResult
    func send(_ data: Data, to address: SocketAddress) -> Bool {
        data.withUnsafeBytes { send($0, to: address) }
    }

    @discardableResult
    func send(_ bytes: [UInt8], to address: SocketAddress) -> Bool {
        bytes.withUnsafeBytes { send($0, to: address) }
    }

    /// Non-blocking receive (call after poll said readable).
    func receive(into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, from: SocketAddress)? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n: Int = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, buffer.baseAddress, buffer.count, MSG_DONTWAIT, sa, &len)
            }
        }
        guard n >= 0 else { return nil }
        let from: SocketAddress = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress($0, length: len) }
        }
        return (n, from)
    }

    func close() {
        if !closed {
            closed = true
            Darwin.close(fd)
        }
    }
}
