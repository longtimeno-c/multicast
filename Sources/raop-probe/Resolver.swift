import Foundation
import dnssd

/// A resolved `_raop._tcp` service.
struct ResolvedService {
    var instanceName: String
    var host: String
    var port: UInt16
    var txt: [String: String]

    /// "BBBB58000010@Main Bedroom" -> "Main Bedroom".
    var displayName: String {
        let parts = instanceName.split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : instanceName
    }
}

/// Minimal synchronous DNS-SD (Bonjour) browse + resolve using the dns_sd C API.
enum DNSSD {
    private final class BrowseContext {
        var names: [String] = []
    }

    private final class ResolveContext {
        var host: String?
        var port: UInt16 = 0
        var txt: [String: String] = [:]
        var done = false
    }

    /// Process results of `ref` until `deadline` or `stop()` returns true.
    private static func pump(_ ref: DNSServiceRef, until deadline: Date, stop: () -> Bool) {
        let fd = DNSServiceRefSockFD(ref)
        while !stop() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, Int32(max(1, remaining * 1000)))
            if n > 0 {
                if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { return }
            } else if n == 0 {
                return
            }
        }
    }

    /// Instance names of all services of `type` seen within `seconds`.
    static func browse(type: String, seconds: TimeInterval) -> [String] {
        let context = BrowseContext()
        var ref: DNSServiceRef?
        let callback: DNSServiceBrowseReply = { _, flags, _, error, name, _, _, ctx in
            guard error == kDNSServiceErr_NoError, let name, let ctx else { return }
            let context = Unmanaged<BrowseContext>.fromOpaque(ctx).takeUnretainedValue()
            let instance = String(cString: name)
            if flags & kDNSServiceFlagsAdd != 0 {
                if !context.names.contains(instance) { context.names.append(instance) }
            } else {
                context.names.removeAll { $0 == instance }
            }
        }
        let err = DNSServiceBrowse(&ref, 0, 0, type, "local.", callback, Unmanaged.passUnretained(context).toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }
        pump(ref, until: Date().addingTimeInterval(seconds)) { false }
        return context.names
    }

    static func resolve(instance: String, type: String, timeout: TimeInterval) -> ResolvedService? {
        let context = ResolveContext()
        var ref: DNSServiceRef?
        let callback: DNSServiceResolveReply = { _, _, _, error, _, hosttarget, port, txtLen, txtRecord, ctx in
            guard let ctx else { return }
            let context = Unmanaged<ResolveContext>.fromOpaque(ctx).takeUnretainedValue()
            context.done = true
            guard error == kDNSServiceErr_NoError, let hosttarget else { return }
            context.host = String(cString: hosttarget)
            context.port = UInt16(bigEndian: port)
            if let txtRecord { context.txt = DNSSD.parseTXT(UnsafeRawBufferPointer(start: txtRecord, count: Int(txtLen))) }
        }
        let err = DNSServiceResolve(&ref, 0, 0, instance, type, "local.", callback, Unmanaged.passUnretained(context).toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        pump(ref, until: Date().addingTimeInterval(timeout)) { context.done }
        guard let host = context.host else { return nil }
        return ResolvedService(instanceName: instance, host: host, port: context.port, txt: context.txt)
    }

    /// TXT record: length-prefixed "key=value" strings.
    static func parseTXT(_ bytes: UnsafeRawBufferPointer) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            i += 1
            guard i + len <= bytes.count else { break }
            let entry = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[i..<(i + len)]), as: UTF8.self)
            i += len
            if let eq = entry.firstIndex(of: "=") {
                result[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            } else if !entry.isEmpty {
                result[entry] = ""
            }
        }
        return result
    }
}
