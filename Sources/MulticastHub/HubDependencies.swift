import Foundation
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import MulticastKit
import MulticastSources

// Everything `LocalHub` touches outside itself, behind small protocols so the tests can drive it
// with fakes. The real implementations live in LiveDependencies.swift (macOS).

// MARK: - Session (MulticastKit)

/// Now-playing text and cover pushed to a network speaker's display.
public struct SpeakerMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artworkJPEG: Data?

    public init(title: String?, artist: String?, album: String?, artworkJPEG: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkJPEG = artworkJPEG
    }
}

/// The part of `MulticastSession` the hub drives. `KitSession` adapts the real one.
public protocol HubSessionControlling: AnyObject, Sendable {
    /// Current merged state (speakers, selection, engine). Cheap, always up to date.
    var state: SessionState { get }
    func stateUpdates() -> AsyncStream<SessionState>
    func meterUpdates() -> AsyncStream<MeterReading>
    func eventUpdates() -> AsyncStream<EngineEvent>
    /// The last DNS-SD error of discovery (-65570 = local network access denied), if any.
    var discoveryErrorCode: Int32? { get }
    /// Group latency: how long after delivery audio is heard.
    var latencySeconds: TimeInterval { get }
    /// The source set last (unwrapped from its fader).
    var currentSource: AudioSource? { get }

    func start()
    func shutdown() async

    func select(_ speaker: SpeakerDescriptor, volume: Float, offsetMillis: Int) async throws
    func deselect(speakerID: String) async
    func retry(speakerID: String) async
    /// Asks a speaker whether it lets this hub in, without selecting it or sending audio.
    func checkAccess(_ speaker: SpeakerDescriptor) async -> SpeakerAccessCheck
    /// Browse for speakers again and retry failed ones (default: nothing).
    func refreshSpeakers()

    func setSource(_ source: AudioSource) async throws
    func play() async throws
    /// Flushes the speakers; a finite source resumes where it was heard.
    func pause() async
    /// Stops the clock and the source and releases the speakers' sessions.
    func stop() async
    /// Seeks the current file source (flush + re-anchor while playing).
    func seek(toSeconds seconds: TimeInterval) async throws

    /// A speaker that brings its own sink (a paired iPhone); see `MulticastSession`. Defaults:
    /// nothing.
    func addExternalSpeaker(_ speaker: SpeakerDescriptor, sink: any AudioSink) async
    func removeExternalSpeaker(id: String) async

    func setMasterVolume(_ volume: Float)
    func setVolume(_ volume: Float, forSpeaker id: String)
    func setOffset(millis: Int, forSpeaker id: String)

    /// Pushes metadata to a selected network speaker. Returns false for speakers that take none
    /// (local outputs, or not selected).
    func sendNowPlaying(_ metadata: SpeakerMetadata, toSpeaker id: String) async -> Bool
    func sendProgress(elapsed: TimeInterval, duration: TimeInterval, toSpeaker id: String) async -> Bool
}

// MARK: - Device volumes

/// Speakers whose volume is a real device volume: the slider moves the device's own volume
/// (for a Mac output, the one the volume keys and the menu bar move) instead of scaling the
/// audio inside Multicast. The hub holds such a speaker's gain at full, so only the master
/// volume attenuates it, shows the device's volume as the speaker's, and never writes a
/// remembered value to the device on its own.
public protocol SpeakerDeviceVolumeProviding: Sendable {
    /// The device's volume now, 0…1, whether or not the speaker is on. nil: this speaker has
    /// no device volume (or none that can be set) and keeps its volume inside Multicast.
    /// Called often (every published state): answer from memory.
    func deviceVolume(of speaker: SpeakerDescriptor) -> Double?
    /// Sets the device's volume. `deviceVolume(of:)` answers the new value from then on, even
    /// if the device takes a moment to follow.
    func setDeviceVolume(_ volume: Double, of speaker: SpeakerDescriptor)
    /// Fires (no payload) when a volume was changed somewhere else (volume keys, Control
    /// Centre) or a device gained or lost its volume control. Coalesced by the provider.
    func deviceVolumeChanges() -> AsyncStream<Void>
}

/// No speaker has a device volume (tests, other platforms).
public struct NoDeviceVolumes: SpeakerDeviceVolumeProviding {
    public init() {}
    public func deviceVolume(of speaker: SpeakerDescriptor) -> Double? { nil }
    public func setDeviceVolume(_ volume: Double, of speaker: SpeakerDescriptor) {}
    public func deviceVolumeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

// MARK: - Sources

/// A finite, seekable file source (`FileSource` conforms).
public protocol HubFileSource: AudioSource {
    var duration: TimeInterval { get }
    func seek(to seconds: TimeInterval)
}

/// What the capture tap says about the System Audio Recording permission.
public enum CapturePermissionEvidence: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

/// A live app-audio capture (`AppAudioTapSource` via `TapCaptureSource`).
public protocol HubCaptureSource: AudioSource {
    func permissionEvidence() -> AsyncStream<CapturePermissionEvidence>
}

public protocol HubSourceMaking: Sendable {
    func openFile(_ url: URL) async throws -> any HubFileSource
    /// A tap on `bundleID`'s audio, muted on the Mac while tapped.
    func makeCapture(bundleID: String, name: String) throws -> any HubCaptureSource
    /// Reads tags, duration, cover and format. nil = not a playable, DRM-free audio file.
    func inspect(_ url: URL) async -> InspectedFile?

    /// The "Multicast" output device (Drivers/MulticastDevice): whether it's installed, whether
    /// it's the Mac's output now, a source reading what's played to it, and the playout delay
    /// it reports to apps. Defaults: not installed.
    var macOutputIsInstalled: Bool { get }
    var macOutputIsDefault: Bool { get }
    func makeMacOutputCapture() throws -> any AudioSource
    func reportMacOutputLatency(seconds: TimeInterval)
}

public struct MacOutputUnavailable: Error {}

extension HubSourceMaking {
    public var macOutputIsInstalled: Bool { false }
    public var macOutputIsDefault: Bool { false }
    public func makeMacOutputCapture() throws -> any AudioSource { throw MacOutputUnavailable() }
    public func reportMacOutputLatency(seconds: TimeInterval) {}
}

// MARK: - Apps

/// Launch state of apps the hub cares about (Spotify, captured apps).
public protocol AppPresenceMonitoring: Sendable {
    func isInstalled(_ bundleID: String) -> Bool
    func isRunning(_ bundleID: String) -> Bool
    /// Fires (no payload) whenever an app launches or quits.
    func changes() -> AsyncStream<Void>
    /// Launches without bringing it to the front.
    func launch(_ bundleID: String) async throws
    /// Opens it in front (launching it if needed), as when the person asks to open it.
    func open(_ bundleID: String) async throws
    /// The app's icon as PNG, at most `maxPixel` on a side (0 = 512).
    func iconPNG(bundleID: String, maxPixel: Int) -> Data?
}

public extension AppPresenceMonitoring {
    func open(_ bundleID: String) async throws { try await launch(bundleID) }
}

/// Running apps that could be captured, live.
public protocol CapturableAppsProviding: Sendable {
    func updates() -> AsyncStream<[CapturableApp]>
}

// MARK: - Spotify control (Apple Events)

/// Spotify's now playing and transport. `SpotifyAppleEvents` adapts `MediaAppController`.
public protocol MediaAppControlling: Sendable {
    /// The current value, then every significant change; nil while the app is not running.
    func changes() -> AsyncStream<NowPlaying?>
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    /// Plays a Spotify URI (track, playlist); `shuffled` sets shuffle first when given.
    func play(uri: String, shuffled: Bool?) async throws
    /// Seconds into the current track.
    func seek(to seconds: TimeInterval) async throws
    /// Automation permission for the app. `ask: true` shows the system prompt (and waits for
    /// the answer). nil when it cannot be known now (app not running).
    func automationStatus(ask: Bool) async -> PermissionStatus?
}

public extension MediaAppControlling {
    /// Plays a Spotify URI (track, playlist, album); `shuffled` sets Spotify's shuffle first
    /// when given. The default can't.
    func play(uri: String, shuffled: Bool?) async throws {
        throw HubCommandError(.unsupported, "This player can\u{2019}t play a link.")
    }

    func seek(to seconds: TimeInterval) async throws {
        throw HubCommandError(.unsupported, "This player can\u{2019}t seek.")
    }
}

/// What Spotify's public oEmbed endpoint says about a share link.
public struct SpotifyEmbedInfo: Equatable, Sendable {
    public var title: String
    public var thumbnailURL: URL?
    public init(title: String, thumbnailURL: URL?) {
        self.title = title
        self.thumbnailURL = thumbnailURL
    }
}

public extension HubSystemServices {
    /// `https://open.spotify.com/oembed?url=…` (no key). nil on any failure; the default knows nothing.
    func spotifyEmbed(for page: URL) async -> SpotifyEmbedInfo? { nil }
}

// MARK: - Misc system services

public protocol HubSystemServices: Sendable {
    /// Opens System Settings at the privacy pane for `permission`.
    func openPrivacySettings(for permission: HubPermission)
    /// Makes the System Audio Recording prompt appear (by briefly creating a process tap).
    func requestAudioCapturePermission() async
    /// Downloads a cover image (Spotify gives a URL). nil on failure.
    func fetchImage(_ url: URL) async -> Data?
    /// Whether this Mac is a laptop (built-in output glyph).
    var hostIsLaptop: Bool { get }
    /// What Spotify's public oEmbed endpoint says about an `open.spotify.com` page.
    func spotifyEmbed(for page: URL) async -> SpotifyEmbedInfo?
}

/// Everything `LocalHub` is built from.
public struct HubDependencies: Sendable {
    public var session: HubSessionControlling
    public var sources: HubSourceMaking
    public var apps: AppPresenceMonitoring
    public var capturableApps: CapturableAppsProviding
    public var spotify: MediaAppControlling
    public var system: HubSystemServices
    public var settings: HubSettingsStore
    /// Which speakers' sliders are a real device volume, and that volume.
    public var deviceVolumes: SpeakerDeviceVolumeProviding
    /// The hub's clock (tests pin it).
    public var now: @Sendable () -> Date

    public init(session: HubSessionControlling, sources: HubSourceMaking, apps: AppPresenceMonitoring,
                capturableApps: CapturableAppsProviding, spotify: MediaAppControlling, system: HubSystemServices,
                settings: HubSettingsStore, deviceVolumes: SpeakerDeviceVolumeProviding = NoDeviceVolumes(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.deviceVolumes = deviceVolumes
        self.session = session
        self.sources = sources
        self.apps = apps
        self.capturableApps = capturableApps
        self.spotify = spotify
        self.system = system
        self.settings = settings
        self.now = now
    }
}

extension HubSessionControlling {
    public func addExternalSpeaker(_ speaker: SpeakerDescriptor, sink: any AudioSink) async {}
    public func removeExternalSpeaker(id: String) async {}
    public func refreshSpeakers() {}
}
