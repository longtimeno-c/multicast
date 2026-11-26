import Foundation

/// Minimal DMAP (Digital Media Access Protocol) encoder for RAOP now-playing metadata
/// (`SET_PARAMETER` with `Content-Type: application/x-dmap-tagged`).
public enum DMAP {
    /// One tagged item: 4-byte code, 4-byte big-endian length, payload.
    public static func item(_ code: String, _ payload: Data) -> Data {
        precondition(code.utf8.count == 4, "DMAP codes are 4 ASCII characters")
        var d = Data(code.utf8)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    public static func string(_ code: String, _ value: String) -> Data { item(code, Data(value.utf8)) }

    /// `mlit` listing item with title (`minm`), artist (`asar`) and album (`asal`).
    public static func nowPlaying(title: String?, artist: String?, album: String?) -> Data {
        var inner = Data()
        if let title { inner.append(string("minm", title)) }
        if let artist { inner.append(string("asar", artist)) }
        if let album { inner.append(string("asal", album)) }
        return item("mlit", inner)
    }

    /// `text/parameters` progress body: `progress: start/current/end` in RTP time units.
    public static func progressBody(start: UInt32, current: UInt32, end: UInt32) -> String {
        "progress: \(start)/\(current)/\(end)\r\n"
    }
}
