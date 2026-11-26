import Foundation
import CryptoKit

/// One RTSP header line, kept in insertion order.
public struct RTSPHeader: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// An RTSP request as sent by the RAOP client.
public struct RTSPRequest: Sendable, Equatable {
    public var method: String
    public var uri: String
    public var headers: [RTSPHeader]
    public var body: Data

    public init(method: String, uri: String, headers: [RTSPHeader] = [], body: Data = Data()) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public mutating func setHeader(_ name: String, _ value: String) {
        if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[index].value = value
        } else {
            headers.append(RTSPHeader(name, value))
        }
    }

    /// Wire format. `Content-Length` is added automatically when there is a body.
    public func serialized() -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\n"
        for header in headers where header.name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            text += "\(header.name): \(header.value)\r\n"
        }
        if !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

public enum RTSPParseError: Error, Equatable, CustomStringConvertible {
    case malformedStatusLine(String)
    case malformedHeader(String)
    case headerTooLarge

    public var description: String {
        switch self {
        case .malformedStatusLine(let line): return "malformed RTSP status line: \(line)"
        case .malformedHeader(let line): return "malformed RTSP header: \(line)"
        case .headerTooLarge: return "RTSP response header exceeds 64 KiB"
        }
    }
}

/// An RTSP (or HTTP-framed, as some receivers answer POST with) response.
public struct RTSPResponse: Sendable, Equatable {
    public var protocolVersion: String
    public var statusCode: Int
    public var reason: String
    /// Headers keyed by lower-cased name.
    public var headers: [String: String]
    public var body: Data

    public init(protocolVersion: String = "RTSP/1.0", statusCode: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.protocolVersion = protocolVersion
        self.statusCode = statusCode
        self.reason = reason
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var cseq: Int? { header("CSeq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Try to parse one complete response from the front of `buffer`.
    /// Returns `nil` when more bytes are needed, otherwise the response and the bytes consumed.
    public static func parse(_ buffer: Data) throws -> (response: RTSPResponse, consumed: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: terminator) else {
            if buffer.count > 65_536 { throw RTSPParseError.headerTooLarge }
            return nil
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        let text = String(decoding: headerData, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw RTSPParseError.malformedStatusLine("") }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0].hasPrefix("RTSP/") || parts[0].hasPrefix("HTTP/"),
              let code = Int(parts[1]) else {
            throw RTSPParseError.malformedStatusLine(statusLine)
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw RTSPParseError.malformedHeader(line) }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headerEnd.upperBound
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        var response = RTSPResponse(
            protocolVersion: String(parts[0]), statusCode: code,
            reason: parts.count > 2 ? String(parts[2]) : "", body: body)
        response.headers = headers
        return (response, bodyStart + length - buffer.startIndex)
    }
}

/// Helpers for RTSP header values used by RAOP.
public enum RTSPHeaderValue {
    /// Parses `RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002`
    /// into lower-cased keys (flags without `=` map to an empty string).
    public static func parseParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in value.split(separator: ";") {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if let eq = trimmed.firstIndex(of: "=") {
                result[trimmed[..<eq].lowercased()] = String(trimmed[trimmed.index(after: eq)...])
            } else if !trimmed.isEmpty {
                result[trimmed.lowercased()] = ""
            }
        }
        return result
    }

    /// The Transport header the client sends in SETUP.
    public static func setupTransport(controlPort: UInt16, timingPort: UInt16) -> String {
        "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(controlPort);timing_port=\(timingPort)"
    }

    /// `seq=…;rtptime=…` for RECORD and FLUSH.
    public static func rtpInfo(seq: UInt16, rtpTime: UInt32) -> String {
        "seq=\(seq);rtptime=\(rtpTime)"
    }
}

/// HTTP Digest (RFC 2617, no qop) as used by password-protected AirPlay receivers.
public struct RTSPDigestChallenge: Sendable, Equatable {
    public var realm: String
    public var nonce: String

    public init(realm: String, nonce: String) {
        self.realm = realm
        self.nonce = nonce
    }

    /// Parses `Digest realm="raop", nonce="…"`. Returns nil for non-digest schemes.
    public static func parse(_ header: String) -> RTSPDigestChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        var fields: [String: String] = [:]
        let rest = trimmed.dropFirst("digest".count)
        // Split on commas that are outside quotes.
        var current = ""
        var inQuotes = false
        var pieces: [String] = []
        for ch in rest {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "," && !inQuotes { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        pieces.append(current)
        for piece in pieces {
            let p = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = p.firstIndex(of: "=") else { continue }
            let key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let realm = fields["realm"], let nonce = fields["nonce"] else { return nil }
        return RTSPDigestChallenge(realm: realm, nonce: nonce)
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `Authorization` header value for `method uri`.
    public func authorization(method: String, uri: String, username: String, password: String) -> String {
        let ha1 = Self.md5Hex("\(username):\(realm):\(password)")
        let ha2 = Self.md5Hex("\(method):\(uri)")
        let response = Self.md5Hex("\(ha1):\(nonce):\(ha2)")
        return "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }
}

/// Session Description Protocol body for ANNOUNCE.
public enum RAOPSDP {
    /// ALAC parameters: frameLength 352, compatibleVersion 0, bitDepth 16, pb 40, mb 10, kb 14,
    /// channels 2, maxRun 255, maxFrameBytes 0, avgBitRate 0, sampleRate 44100.
    public static let alacFmtp = "352 0 16 40 10 14 2 255 0 0 44100"

    public static func announce(sessionID: UInt32, localIP: String, remoteIP: String, localIsIPv6: Bool = false, remoteIsIPv6: Bool = false) -> String {
        let localFamily = localIsIPv6 ? "IP6" : "IP4"
        let remoteFamily = remoteIsIPv6 ? "IP6" : "IP4"
        return [
            "v=0",
            "o=iTunes \(sessionID) 0 IN \(localFamily) \(localIP)",
            "s=iTunes",
            "c=IN \(remoteFamily) \(remoteIP)",
            "t=0 0",
            "m=audio 0 RTP/AVP 96",
            "a=rtpmap:96 AppleLossless",
            "a=fmtp:96 \(alacFmtp)",
        ].joined(separator: "\r\n") + "\r\n"
    }
}
