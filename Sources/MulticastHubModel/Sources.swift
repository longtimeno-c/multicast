import Foundation

// MARK: - Sources

public enum SourceKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// The hub's own Apple Music player: library, playlists, search, queue.
    case appleMusic
    /// The Spotify Mac app's audio, captured; transport goes to Spotify over Apple Events.
    case spotify
    /// Any other running app's audio, captured.
    case app
    /// DRM-free files played directly.
    case files
    /// Whatever the Mac plays to the "Multicast" output device (Drivers/MulticastDevice): any app
    /// or System Settings › Sound can choose "Multicast" as its output.
    case macOutput

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .app: "Other app"
        case .files: "Files"
        case .macOutput: "Mac output"
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .appleMusic: "music.note"
        case .spotify: "music.note.list"
        case .app: "macwindow"
        case .files: "folder.fill"
        case .macOutput: "hifispeaker.fill"
        }
    }

    /// Whether the source exposes a playback position the hub can show and seek.
    public var hasPosition: Bool { !isLiveCapture }
    /// Whether next / previous make sense.
    public var canSkip: Bool { !isLiveCapture }
    /// A live capture the hub can't pause, skip or seek at the source (an app, the Mac output).
    public var isLiveCapture: Bool { self == .app || self == .macOutput }
}

/// A running app that the hub could capture.
public struct CapturableApp: Identifiable, Equatable, Hashable, Sendable, Codable {
    /// Bundle identifier.
    public let id: String
    public var name: String
    public var isMakingSound: Bool
    /// Artwork id of the app's icon, fetched with `HubBackend.artwork(id:maxPixel:)`.
    public var iconArtworkID: ArtworkID?

    public init(id: String, name: String, isMakingSound: Bool, iconArtworkID: ArtworkID? = nil) {
        self.id = id
        self.name = name
        self.isMakingSound = isMakingSound
        self.iconArtworkID = iconArtworkID
    }
}

/// What the Spotify source knows about the Spotify app.
public enum SpotifyStatus: String, Equatable, Sendable, Codable, CaseIterable {
    case notInstalled, notRunning, running
}

/// Everything about app-audio capture that the UI shows. Small: running apps only.
public struct CaptureStatus: Equatable, Hashable, Sendable, Codable {
    /// Running apps that could be captured, the ones making sound first.
    public var apps: [CapturableApp]
    /// Bundle id of the app being captured when `HubState.activeSource == .app`.
    public var capturedAppID: String?

    public init(apps: [CapturableApp] = [], capturedAppID: String? = nil) {
        self.apps = apps
        self.capturedAppID = capturedAppID
    }
}
