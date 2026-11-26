import Foundation

// UI-facing value types. The app owns these; backends translate into them.
// Nothing here depends on AppKit, UIKit or MulticastKit, so the iOS remote can share them.

// MARK: - Speakers

struct SpeakerID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

/// How audio reaches a speaker. Drives grouping and the default glyph.
enum SpeakerTransport: String, Sendable, Codable, CaseIterable {
    case airPlay1, airPlay2, builtIn, bluetooth, usb

    var isNetwork: Bool { self == .airPlay1 || self == .airPlay2 }

    var label: String {
        switch self {
        case .airPlay1: "AirPlay 1"
        case .airPlay2: "AirPlay 2"
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        }
    }
}

/// The glyph a speaker row shows. Backends pick one from what they know about the device.
enum SpeakerGlyph: String, Sendable, Codable {
    case speaker, smartSpeaker, receiver, airportExpress, laptop, display, portable, headphones, usb

    var symbolName: String {
        switch self {
        case .speaker: "hifispeaker.fill"
        case .smartSpeaker: "hifispeaker.fill"
        case .receiver: "hifireceiver.fill"
        case .airportExpress: "hifispeaker.fill"
        // Outline-only symbols; rows draw them a weight heavier (`SpeakerGlyph.weight`).
        case .laptop: "laptopcomputer"
        case .display: "display"
        case .portable: "hifispeaker.fill"
        case .headphones: "headphones"
        case .usb: "cable.connector"
        }
    }
}

/// Live state of one speaker as the hub sees it.
enum SpeakerState: Equatable, Sendable {
    /// Not selected.
    case off
    /// Selected; the hub is opening a session (AirPlay handshake, Core Audio device start).
    case connecting
    /// Selected and connected, but nothing is playing.
    case ready
    /// Selected and receiving the stream.
    case playing
    /// Selected but unusable. `reason` is short, human and sentence case.
    case failed(reason: String)

    var isActive: Bool {
        switch self {
        case .off: false
        default: true
        }
    }
}

struct SpeakerItem: Identifiable, Equatable, Sendable {
    let id: SpeakerID
    var name: String
    var transport: SpeakerTransport
    var glyph: SpeakerGlyph
    /// Optional model name ("Sonos One"); shown after the transport when it adds something.
    var model: String?
    /// Network address or Core Audio device UID, for the detail popover.
    var address: String?
    /// The user's checkbox.
    var isEnabled: Bool
    /// 0…1, before the master volume is applied.
    var volume: Double
    var state: SpeakerState
    /// Per-speaker playout offset in milliseconds. Negative plays earlier.
    var syncTrimMs: Int

    static let syncTrimRange: ClosedRange<Int> = -500...500

    /// What the speaker actually plays at: its own level scaled by the master.
    func effectiveVolume(master: Double) -> Double { volume * master }

    var kindDescription: String {
        if let model { return "\(transport.label) · \(model)" }
        return transport.label
    }
}

// MARK: - Sources

enum SourceKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case appleMusic, spotify, app, files
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .app: "Other app"
        case .files: "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .appleMusic: "music.note"
        case .spotify: "music.note.list"
        case .app: "macwindow"
        case .files: "folder.fill"
        }
    }

    /// Whether the source exposes a playback position the hub can show and seek.
    var hasPosition: Bool { self != .app }
    /// Whether next / previous make sense.
    var canSkip: Bool { self != .app }
}

/// A running app that the hub could capture.
struct CapturableApp: Identifiable, Equatable, Sendable {
    /// Bundle identifier.
    let id: String
    var name: String
    var isMakingSound: Bool
}

/// What the Spotify source knows about the Spotify app.
enum SpotifyStatus: Equatable, Sendable {
    case notInstalled, notRunning, running
}

// MARK: - Library (Apple Music and files)

/// Artwork travels by reference so state stays small enough to send to the iOS remote on
/// every change; the bytes come from `HubBackend.artwork(id:)` once and are cached.
typealias ArtworkID = String

struct TrackItem: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artwork: ArtworkID?
    /// Files only: a short format note such as "FLAC · 24-bit".
    var format: String?
}

struct PlaylistItem: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var trackCount: Int
    var artwork: ArtworkID?
}

struct LibrarySnapshot: Equatable, Sendable {
    var songs: [TrackItem] = []
    var playlists: [PlaylistItem] = []
    var upNext: [TrackItem] = []
}

// MARK: - Now playing and transport

struct NowPlayingInfo: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    var artwork: ArtworkID?
    /// The artwork is an app icon (a captured app), shown unclipped.
    var artworkIsIcon = false
    /// Nil when the source has no notion of length (a captured app).
    var duration: TimeInterval?
    /// Library track id when the item came from the hub's own library, so lists can mark it.
    var trackID: String?
}

struct TransportState: Equatable, Sendable {
    var isPlaying: Bool = false
    /// Position at `positionAsOf`. Views extrapolate while playing instead of the backend
    /// publishing every tick.
    var position: TimeInterval = 0
    var positionAsOf: Date = .distantPast
    var canSkip: Bool = true
    var canSeek: Bool = true

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return position + max(0, date.timeIntervalSince(positionAsOf))
    }
}

/// Peak levels of the outgoing mix, 0…1 (linear, post-master).
struct StereoLevels: Equatable, Sendable {
    var left: Float
    var right: Float
    static let silent = StereoLevels(left: 0, right: 0)
}

// MARK: - Hub status and permissions

/// Whether the UI can reach the hub at all. Always `.connected` in-process on the Mac; the iOS
/// remote moves through the others as it finds and loses the Mac.
enum HubAvailability: Equatable, Sendable {
    case connecting
    case connected
    case unreachable(reason: String)
}

/// The system permissions the hub depends on.
enum HubPermission: String, Sendable, CaseIterable {
    /// Finding AirPlay speakers (Bonjour on the local network).
    case localNetwork
    /// MusicKit: the user's Apple Music library and catalog.
    case appleMusic
    /// Core Audio process taps: capturing Spotify and other apps.
    case audioCapture
}

enum PermissionStatus: Equatable, Sendable {
    case notDetermined, granted, denied
}

// MARK: - Published state, in slices

/// Speakers and the master. Changes at drag rate, so it carries nothing heavy.
struct SpeakersState: Equatable, Sendable {
    var speakers: [SpeakerItem] = []
    var masterVolume: Double = 0.6
    /// Discovery is still browsing and may add speakers.
    var isDiscovering = false
}

/// What is playing and from where.
struct PlaybackState: Equatable, Sendable {
    /// The source audio currently comes from, if any.
    var activeSource: SourceKind?
    var nowPlaying: NowPlayingInfo?
    var transport = TransportState()
    /// Bundle id of the app being captured when `activeSource == .app`.
    var capturedAppID: String?
}

/// What each source can offer. Large and rarely changing.
struct SourcesState: Equatable, Sendable {
    var library = LibrarySnapshot()
    var files: [TrackItem] = []
    var capturableApps: [CapturableApp] = []
    var spotify: SpotifyStatus = .notRunning
    /// Tracks seen from Spotify this session, newest first.
    var spotifyHistory: [TrackItem] = []
}

/// Reachability and permissions: what explains an empty screen.
struct HubStatus: Equatable, Sendable {
    var availability: HubAvailability = .connected
    var permissions: [HubPermission: PermissionStatus] = [:]

    func permission(_ p: HubPermission) -> PermissionStatus { permissions[p] ?? .notDetermined }
}

/// All four slices together: a backend's own bookkeeping, and fixed scenes for snapshots.
struct HubState: Equatable, Sendable {
    var speakers = SpeakersState()
    var playback = PlaybackState()
    var sources = SourcesState()
    var status = HubStatus()
}
