import Foundation

/// DNS-SD TXT record codec (RFC 6763 §6).
///
/// The wire format is a sequence of length-prefixed strings, each `key=value` or a bare `key`
/// (a boolean attribute that is present but has no value). Keys are case-insensitive on the wire;
/// we keep them exactly as advertised and do case-insensitive lookups in the typed helpers.
public enum TXTRecord {
    /// Decode raw TXT RDATA into a dictionary.
    ///
    /// - Bare keys map to `""`.
    /// - Empty strings (a single zero length byte, the canonical "empty TXT") are skipped.
    /// - Entries that start with `=` (no key) are ignored, as RFC 6763 §6.4 requires.
    /// - If the same key appears twice (case-insensitively), the first occurrence wins (§6.4).
    /// - A truncated trailing entry is ignored rather than crashing.
    /// - Values that are not valid UTF-8 are decoded as ISO Latin 1 so nothing is lost silently.
    public static func decode(_ bytes: UnsafeRawBufferPointer) -> [String: String] {
        var result: [String: String] = [:]
        var seenLowercased = Set<String>()
        var index = 0
        let count = bytes.count
        while index < count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0 else { continue }
            guard index + length <= count else { break }
            let entry = UnsafeRawBufferPointer(rebasing: bytes[index ..< index + length])
            index += length

            let equals = entry.firstIndex(of: UInt8(ascii: "="))
            let keyBytes = UnsafeRawBufferPointer(rebasing: entry[..<(equals ?? entry.endIndex)])
            guard !keyBytes.isEmpty else { continue }
            let key = decodeString(keyBytes)
            let lowered = key.lowercased()
            guard !seenLowercased.contains(lowered) else { continue }
            seenLowercased.insert(lowered)

            if let equals {
                let valueBytes = UnsafeRawBufferPointer(rebasing: entry[(equals + 1)...])
                result[key] = decodeString(valueBytes)
            } else {
                result[key] = ""
            }
        }
        return result
    }

    public static func decode(_ data: Data) -> [String: String] {
        data.withUnsafeBytes { decode($0) }
    }

    /// Encode a dictionary into TXT RDATA (entries sorted by key for determinism). Values longer
    /// than 255 bytes in total are truncated, as the wire format cannot hold them.
    public static func encode(_ entries: [String: String]) -> Data {
        var data = Data()
        for key in entries.keys.sorted() {
            var entry = Array(key.utf8)
            if let value = entries[key], !value.isEmpty {
                entry.append(UInt8(ascii: "="))
                entry.append(contentsOf: value.utf8)
            }
            let clipped = entry.prefix(255)
            data.append(UInt8(clipped.count))
            data.append(contentsOf: clipped)
        }
        if data.isEmpty { data.append(0) }
        return data
    }

    /// Parse the space-separated `key=value` form that `dns-sd -L` prints. Test/fixture helper.
    /// `dns-sd` escapes spaces inside values as "\ ".
    public static func parse(displayString: String) -> [String: String] {
        var tokens: [String] = []
        var current = ""
        var escaping = false
        for ch in displayString {
            if escaping { current.append(ch); escaping = false; continue }
            if ch == "\\" { escaping = true; continue }
            if ch == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }

        var result: [String: String] = [:]
        for token in tokens {
            if let eq = token.firstIndex(of: "=") {
                let key = String(token[..<eq])
                guard !key.isEmpty, result[key] == nil else { continue }
                result[key] = String(token[token.index(after: eq)...])
            } else {
                result[String(token)] = result[String(token)] ?? ""
            }
        }
        return result
    }

    private static func decodeString(_ bytes: UnsafeRawBufferPointer) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }
}

extension Dictionary where Key == String, Value == String {
    /// Case-insensitive TXT lookup (TXT keys are case-insensitive per RFC 6763).
    func txtValue(_ key: String) -> String? {
        if let exact = self[key] { return exact }
        let lowered = key.lowercased()
        return first(where: { $0.key.lowercased() == lowered })?.value
    }
}
