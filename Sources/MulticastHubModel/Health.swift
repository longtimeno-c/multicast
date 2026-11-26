import Foundation

// MARK: - Permissions and health

/// The system permissions the hub depends on. All of them are granted (or not) on the Mac.
public enum HubPermission: String, Sendable, Codable, CaseIterable {
    /// Finding AirPlay speakers (Bonjour on the local network); also needed by the iOS remote.
    case localNetwork
    /// Core Audio process taps (System Audio Recording): capturing Spotify and other apps.
    case audioCapture
    /// Whatever gates the hub's Apple Music player: MusicKit's Media & Apple Music permission,
    /// or Automation of the Music app when the hub drives Music. Reported per player.
    case appleMusic
    /// Apple Events to Spotify and Music: now playing and play/pause/skip.
    case automation

    public var title: String {
        switch self {
        case .localNetwork: "Local Network"
        case .audioCapture: "System Audio Recording"
        case .appleMusic: "Media & Apple Music"
        case .automation: "Automation"
        }
    }
}

public enum PermissionStatus: String, Equatable, Sendable, Codable, CaseIterable {
    /// Never asked: `HubCommand.requestPermission` will show the system prompt.
    case notDetermined
    case granted
    /// Refused (or restricted): only System Settings can change it.
    case denied
}

/// One status per permission, with stable field names on the wire.
public struct PermissionSet: Equatable, Hashable, Sendable, Codable {
    public var localNetwork: PermissionStatus
    public var audioCapture: PermissionStatus
    public var appleMusic: PermissionStatus
    public var automation: PermissionStatus

    public init(localNetwork: PermissionStatus = .notDetermined, audioCapture: PermissionStatus = .notDetermined,
                appleMusic: PermissionStatus = .notDetermined, automation: PermissionStatus = .notDetermined) {
        self.localNetwork = localNetwork
        self.audioCapture = audioCapture
        self.appleMusic = appleMusic
        self.automation = automation
    }

    public static let allGranted = PermissionSet(localNetwork: .granted, audioCapture: .granted,
                                                 appleMusic: .granted, automation: .granted)

    public subscript(_ permission: HubPermission) -> PermissionStatus {
        get {
            switch permission {
            case .localNetwork: localNetwork
            case .audioCapture: audioCapture
            case .appleMusic: appleMusic
            case .automation: automation
            }
        }
        set {
            switch permission {
            case .localNetwork: localNetwork = newValue
            case .audioCapture: audioCapture = newValue
            case .appleMusic: appleMusic = newValue
            case .automation: automation = newValue
            }
        }
    }
}

/// Something that explains an empty or non-working screen. Typed, so each surface can say the
/// right thing and offer the right action.
///
/// Wire form (synthesized), e.g. `{"permissionMissing":{"permission":"audioCapture","status":"denied"}}`,
/// `{"sourceAppNotRunning":{"source":"spotify","bundleID":"com.spotify.client","name":"Spotify"}}`.
public enum HubIssue: Equatable, Hashable, Sendable, Codable {
    /// A permission the hub needs is not granted (`status` is `.notDetermined` or `.denied`).
    case permissionMissing(permission: HubPermission, status: PermissionStatus)
    /// The app a source plays from is installed but not running (Spotify closed; captured app quit).
    case sourceAppNotRunning(source: SourceKind, bundleID: String, name: String)
    /// The app a source plays from is not installed.
    case sourceAppNotInstalled(source: SourceKind, bundleID: String, name: String)

    /// Whether this issue stops `source` from working. A missing Local Network permission blocks
    /// no source (it hides AirPlay speakers instead).
    public func blocks(_ source: SourceKind) -> Bool {
        switch self {
        case .permissionMissing(let p, _):
            switch p {
            case .appleMusic: source == .appleMusic
            // Apple Music is captured from whichever process renders it, so it needs the tap too.
            case .audioCapture: source == .spotify || source == .app || source == .appleMusic
            case .automation: source == .spotify
            case .localNetwork: false
            }
        case .sourceAppNotRunning(let s, _, _), .sourceAppNotInstalled(let s, _, _):
            s == source
        }
    }
}

/// Permissions plus whatever currently stands in the way.
public struct HubHealth: Equatable, Hashable, Sendable, Codable {
    public var permissions: PermissionSet
    /// Current issues, most important first. Backends keep this in step with `permissions`
    /// (see `HubHealth.permissionIssues(for:)`) plus whatever they know about source apps.
    public var issues: [HubIssue]

    public init(permissions: PermissionSet = PermissionSet(), issues: [HubIssue] = []) {
        self.permissions = permissions
        self.issues = issues
    }

    /// Health built from permissions alone: one `.permissionMissing` per permission not granted.
    public init(permissions: PermissionSet, extraIssues: [HubIssue]) {
        self.permissions = permissions
        self.issues = Self.permissionIssues(for: permissions) + extraIssues
    }

    public static func permissionIssues(for permissions: PermissionSet) -> [HubIssue] {
        HubPermission.allCases.compactMap { p in
            let s = permissions[p]
            return s == .granted ? nil : .permissionMissing(permission: p, status: s)
        }
    }

    public func permission(_ p: HubPermission) -> PermissionStatus { permissions[p] }

    public func issues(for source: SourceKind) -> [HubIssue] { issues.filter { $0.blocks(source) } }

    /// The issues worth putting in front of someone for `source`. System Audio Recording has
    /// no preflight on macOS: it reads `.notDetermined` until a capture has run, even when it
    /// was allowed long ago, so only its refusal is shown.
    public func shownIssues(for source: SourceKind) -> [HubIssue] {
        issues(for: source).filter { $0 != .permissionMissing(permission: .audioCapture, status: .notDetermined) }
    }
}

/// Whether a UI can reach the hub at all. Always `.connected` in-process on the Mac; the iOS
/// remote moves through the others as it finds and loses the Mac. Not part of `HubState`: it
/// describes the link, not the hub.
public enum HubAvailability: Equatable, Hashable, Sendable, Codable {
    case connecting
    case connected
    case unreachable(reason: String)
}
