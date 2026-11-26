import Foundation

/// Every mutating call a hub accepts. A network transport carries these as they are (they are
/// Codable with stable, labelled field names) and the hub hands them to `HubBackend.perform(_:)`.
///
/// Wire form (synthesized), e.g. `{"play":{}}`, `{"seek":{"position":42.5}}`,
/// `{"setSpeakerVolume":{"id":"542a1b001122","volume":0.4}}`.
public enum HubCommand: Equatable, Hashable, Sendable, Codable {
    // Transport
    case play
    case pause
    case next
    case previous
    /// Seconds into the current item.
    case seek(position: TimeInterval)

    // Sources
    /// Make `source` the active one, starting from its current item where it has one. Choosing
    /// `.app` alone changes nothing: `captureApp` picks the app.
    case selectSource(source: SourceKind)
    /// Play a library or file track; `context` says what follows it.
    case playTrack(id: String, context: TrackContext)
    /// Play a playlist from its first track.
    case playPlaylist(id: String)
    case captureApp(bundleID: String)
    /// Add files on the hub's own disk to the file queue. Meaningless from a remote, which cannot
    /// name the hub's files.
    case addFiles(urls: [URL])
    case removeFiles(ids: [String])
    /// Launch the Spotify app on the hub.
    case openSpotify
    /// Shows the system prompt on the hub, or leaves `.denied` in place so the UI can send people
    /// to System Settings.
    case requestPermission(permission: HubPermission)

    // Speakers
    case setSpeakerEnabled(id: SpeakerID, enabled: Bool)
    /// 0…1. Legal while the speaker is off: it is then the preset applied on connect.
    case setSpeakerVolume(id: SpeakerID, volume: Double)
    /// Milliseconds within `SpeakerItem.syncTrimRange`. Legal while off, like volume.
    case setSpeakerSyncTrim(id: SpeakerID, milliseconds: Int)
    case retrySpeaker(id: SpeakerID)
    /// 0…1.
    case setMasterVolume(volume: Double)

    public enum Category: String, Sendable, Codable {
        case transport, source, speaker
    }

    /// What kind of change this is: drives how a UI reports a refusal (speaker failures show in
    /// the row; transport and source failures as an alert).
    public var category: Category {
        switch self {
        case .play, .pause, .next, .previous, .seek: .transport
        case .selectSource, .playTrack, .playPlaylist, .captureApp, .addFiles, .removeFiles, .openSpotify,
             .requestPermission: .source
        case .setSpeakerEnabled, .setSpeakerVolume, .setSpeakerSyncTrim, .retrySpeaker, .setMasterVolume: .speaker
        }
    }

    /// Commands that arrive at drag rate; a transport may coalesce consecutive ones with the same
    /// key, keeping the last.
    public var coalescingKey: String? {
        switch self {
        case .setSpeakerVolume(let id, _): "volume.\(id)"
        case .setSpeakerSyncTrim(let id, _): "trim.\(id)"
        case .setMasterVolume: "master"
        case .seek: "seek"
        default: nil
        }
    }
}

/// A command a hub could not accept. Thrown by `HubBackend.perform(_:)`; Codable so a network
/// transport can return it to the remote as it is.
public struct HubCommandError: Error, Equatable, Hashable, Sendable, Codable, LocalizedError {
    public enum Code: String, Sendable, Codable {
        /// The id names nothing the hub knows (a speaker gone, a stale track id).
        case notFound
        /// Not possible in the current state (Spotify not running, nothing to play).
        case unavailable
        /// A permission the command needs is missing.
        case permissionMissing
        /// Not supported by this backend or from this client.
        case unsupported
        /// The hub could not be reached (network transports only).
        case unreachable
        case failed
    }

    public var code: Code
    /// Short, human, sentence case; shown as the alert message.
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
