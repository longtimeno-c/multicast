import Foundation

/// The two Bonjour service types an AirPlay speaker can advertise.
public enum AirPlayServiceType: String, Sendable, CaseIterable, Hashable {
    /// `_raop._tcp`: the RTSP audio endpoint, instance name "<MACHEX>@<Name>".
    case raop = "_raop._tcp"
    /// `_airplay._tcp`: the AirPlay (2) control endpoint, instance name "<Name>", TXT `deviceid=AA:BB:…`.
    case airplay = "_airplay._tcp"
}

/// A RAOP instance name split into its device id and display name.
public struct RAOPInstanceName: Hashable, Sendable {
    /// Normalised device id (lowercase hex, no separators), or `nil` if the prefix is not hex.
    public var deviceID: String?
    /// The human name (the part after the first "@", or the whole name when there is no "@").
    public var name: String

    /// Split "<MACHEX>@<Name>". Only the FIRST "@" separates: names may contain "@" themselves.
    public init(_ instanceName: String) {
        if let at = instanceName.firstIndex(of: "@") {
            let prefix = String(instanceName[..<at])
            let rest = String(instanceName[instanceName.index(after: at)...])
            if let id = DeviceID.normalize(prefix) {
                deviceID = id
                name = rest
                return
            }
        }
        deviceID = nil
        name = instanceName
    }
}

/// Device identifier normalisation shared by RAOP names and `_airplay` `deviceid=` values.
public enum DeviceID {
    /// "54:2A:1B:00:11:22", "542A1B001122", "54-2a-1b-00-11-22" -> "542a1b001122".
    /// Returns `nil` unless the result is a non-empty even-length hex string.
    public static func normalize(_ raw: String) -> String? {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if ch == ":" || ch == "-" || ch == "." { continue }
            guard ch.isASCII, ch.isHexDigit else { return nil }
            out.append(ch)
        }
        guard !out.isEmpty, out.count % 2 == 0 else { return nil }
        return out.lowercased()
    }
}

/// Host names as returned by DNS-SD resolve end with the root dot ("pi.local."). Strip it so the
/// value can be passed straight to `NWEndpoint.Host` / `getaddrinfo`, and compare case-insensitively.
enum HostName {
    static func clean(_ raw: String) -> String {
        var s = raw
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func equal(_ a: String, _ b: String) -> Bool {
        clean(a).caseInsensitiveCompare(clean(b)) == .orderedSame
    }
}
