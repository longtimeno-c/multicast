import Foundation

/// Media players `MediaAppController` can drive (macOS).
public enum MediaApp: String, Codable, Sendable, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    public var bundleID: String { rawValue }

    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    /// Distributed notification the app posts when playback changes.
    public var playbackNotificationName: String {
        switch self {
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        case .music: return "com.apple.Music.playerInfo"
        }
    }
}

public enum MediaPlayerState: String, Codable, Sendable {
    case playing, paused, stopped, fastForwarding, rewinding, unknown

    /// Parses AppleScript `player state as string` / notification "Player State" values.
    public init(scriptValue: String) {
        let raw = scriptValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Raw four-char enum codes (case-sensitive), as returned when terminology is unavailable.
        switch raw {
        case "kPSP", "«constant ****kPSP»": self = .playing; return
        case "kPSp", "«constant ****kPSp»": self = .paused; return
        case "kPSS", "«constant ****kPSS»": self = .stopped; return
        case "kPSF", "«constant ****kPSF»": self = .fastForwarding; return
        case "kPSR", "«constant ****kPSR»": self = .rewinding; return
        default: break
        }
        switch raw.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        case "fast forwarding", "fastforwarding": self = .fastForwarding
        case "rewinding": self = .rewinding
        default: self = .unknown
        }
    }
}

/// What a media app is playing. Shared by Spotify and Music.
public struct NowPlaying: Codable, Sendable, Equatable {
    public var app: MediaApp
    public var state: MediaPlayerState
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: TimeInterval?
    /// Seconds into the track when sampled.
    public var position: TimeInterval?
    /// Spotify URI ("spotify:track:…") or Music persistent ID.
    public var trackID: String?
    /// Spotify exposes a cover URL.
    public var artworkURL: URL?
    /// Music exposes the cover bytes.
    public var artworkData: Data?
    public var sampledAt: Date

    public init(app: MediaApp, state: MediaPlayerState, title: String? = nil, artist: String? = nil,
                album: String? = nil, duration: TimeInterval? = nil, position: TimeInterval? = nil,
                trackID: String? = nil, artworkURL: URL? = nil, artworkData: Data? = nil, sampledAt: Date = Date()) {
        self.app = app
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.trackID = trackID
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.sampledAt = sampledAt
    }

    public var hasTrack: Bool { title != nil || trackID != nil }

    /// Position extrapolated to `date` (advances only while playing), clamped to the duration.
    public func estimatedPosition(at date: Date = Date()) -> TimeInterval? {
        guard let position else { return nil }
        var p = position
        if state == .playing { p += max(0, date.timeIntervalSince(sampledAt)) }
        if let duration { p = min(p, duration) }
        return p
    }

    /// True when `self` differs from `previous` in a way a UI should react to: different
    /// app / state / track / tags, or a position jump (seek) of more than `seekTolerance`
    /// relative to where `previous` would have been by now. Normal play progress is not a change.
    public func isSignificantChange(from previous: NowPlaying?, seekTolerance: TimeInterval = 2) -> Bool {
        guard let previous else { return true }
        if app != previous.app || state != previous.state || trackID != previous.trackID
            || title != previous.title || artist != previous.artist || album != previous.album
            || duration != previous.duration || artworkURL != previous.artworkURL {
            return true
        }
        if (artworkData == nil) != (previous.artworkData == nil) { return true }
        switch (position, previous.estimatedPosition(at: sampledAt)) {
        case (nil, nil): return false
        case (.some(let now), .some(let expected)): return abs(now - expected) > seekTolerance
        default: return true
        }
    }

    /// Same content ignoring sample time (for tests / de-duplication).
    public func sameContent(as other: NowPlaying) -> Bool {
        var a = self, b = other
        a.sampledAt = .distantPast
        b.sampledAt = .distantPast
        return a == b
    }
}

/// Parses the delimited text the controller's AppleScripts return. Pure; tested.
public enum AppleScriptNowPlayingParser {
    /// ASCII unit separator, used between fields (never appears in track tags).
    public static let separator: Character = "\u{1F}"
    public static let notRunningMarker = "NOT_RUNNING"
    public static let okMarker = "OK"

    public enum ParseError: Error, Equatable {
        case unexpectedOutput(String)
    }

    /// Output: "NOT_RUNNING" | "OK␟state" | "OK␟state␟title␟artist␟album␟duration␟position␟artwork␟id".
    /// Spotify reports duration in milliseconds, Music in seconds.
    /// Returns nil when the app is not running.
    public static func parse(_ output: String, app: MediaApp, sampledAt: Date = Date()) throws -> NowPlaying? {
        let trimmed = output.trimmingCharacters(in: .newlines)
        if trimmed == notRunningMarker { return nil }
        let fields = trimmed.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, fields[0] == okMarker else {
            throw ParseError.unexpectedOutput(String(trimmed.prefix(200)))
        }
        var np = NowPlaying(app: app, state: MediaPlayerState(scriptValue: fields[1]), sampledAt: sampledAt)
        guard fields.count >= 9 else { return np }
        np.title = nonEmpty(fields[2])
        np.artist = nonEmpty(fields[3])
        np.album = nonEmpty(fields[4])
        if let d = number(fields[5]) {
            np.duration = app == .spotify ? d / 1000 : d
        }
        np.position = number(fields[6])
        if let s = nonEmpty(fields[7]), let url = URL(string: s), url.scheme != nil {
            np.artworkURL = url
        }
        np.trackID = nonEmpty(fields[8])
        if np.duration == 0 { np.duration = nil }
        return np
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "missing value" { return nil }
        return t
    }

    /// Accepts "123", "12.5", "12,5" (locale decimal comma), "1.234,5"/"1,234.5" thousands.
    static func number(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "missing value" { return nil }
        let lastDot = t.lastIndex(of: ".")
        let lastComma = t.lastIndex(of: ",")
        switch (lastDot, lastComma) {
        case (.some(let d), .some(let c)):
            if d > c { t.removeAll { $0 == "," } } else {
                t.removeAll { $0 == "." }
                t = t.replacingOccurrences(of: ",", with: ".")
            }
        case (nil, .some):
            t = t.replacingOccurrences(of: ",", with: ".")
        default:
            break
        }
        t = t.replacingOccurrences(of: "E", with: "e")
        return Double(t)
    }
}
