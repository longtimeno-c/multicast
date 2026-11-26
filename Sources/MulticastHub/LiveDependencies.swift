#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import ImageIO
import IOKit.ps
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import MulticastKit
import MulticastRAOP
import MulticastSources
import UniformTypeIdentifiers

// The real implementations of the protocols in HubDependencies.swift, on macOS.

// MARK: - LocalHub factory

public extension LocalHub {
    /// A hub over a real `MulticastSession` (Bonjour discovery, Core Audio outputs, process taps,
    /// Apple Events to Spotify). Call `start()` to begin discovery.
    static func live(settings: HubSettingsStore = UserDefaultsSettingsStore(),
                     sessionConfiguration: MulticastSession.Configuration = LocalHub.defaultSessionConfiguration(),
                     configuration: Configuration = Configuration()) -> LocalHub {
        let session = MulticastSession(configuration: sessionConfiguration)
        let deps = HubDependencies(
            session: KitSession(session),
            sources: LiveSourceMaker(),
            apps: WorkspaceAppPresence(),
            capturableApps: ProcessTapApps(),
            spotify: SpotifyAppleEvents(),
            system: LiveSystemServices(),
            settings: settings
        )
        return LocalHub(dependencies: deps, configuration: configuration)
    }

    /// Meters at the 20 Hz the hub publishes; everything else MulticastKit's defaults.
    static func defaultSessionConfiguration() -> MulticastSession.Configuration {
        var c = MulticastSession.Configuration()
        c.engine.meterRateHz = 20
        return c
    }
}

// MARK: - Session

/// `HubSessionControlling` over the real `MulticastSession`.
public final class KitSession: HubSessionControlling, @unchecked Sendable {
    public let session: MulticastSession

    public init(_ session: MulticastSession) { self.session = session }

    public var state: SessionState { session.state }
    public func stateUpdates() -> AsyncStream<SessionState> { session.updates }
    public func meterUpdates() -> AsyncStream<MeterReading> { session.meters }
    public func eventUpdates() -> AsyncStream<EngineEvent> { session.events }
    public var discoveryErrorCode: Int32? { session.directory.discoveryError }
    public var latencySeconds: TimeInterval { Double(session.engine.snapshot.latencyMillis) / 1000 }
    public var currentSource: AudioSource? { session.currentSource }

    public func start() { session.start() }
    public func shutdown() async { await session.shutdown() }

    public func select(_ speaker: SpeakerDescriptor, volume: Float, offsetMillis: Int) async throws {
        try await session.select(speaker, volume: volume, offsetMillis: offsetMillis)
    }
    public func deselect(speakerID: String) async { await session.deselect(speakerID: speakerID) }
    public func retry(speakerID: String) async { await session.retry(speakerID: speakerID) }
    public func refreshSpeakers() { session.refreshSpeakers() }

    public func setSource(_ source: AudioSource) async throws { try await session.setSource(.custom(source)) }
    public func play() async throws { try await session.play() }
    public func pause() async { await session.pause() }
    public func stop() async { await session.stop() }
    public func seek(toSeconds seconds: TimeInterval) async throws { try await session.seek(toSeconds: seconds) }

    public func setMasterVolume(_ volume: Float) { session.setMasterVolume(volume) }
    public func setVolume(_ volume: Float, forSpeaker id: String) { session.setVolume(volume, forSpeaker: id) }
    public func setOffset(millis: Int, forSpeaker id: String) { session.setOffset(millis: millis, forSpeaker: id) }

    public func sendNowPlaying(_ m: SpeakerMetadata, toSpeaker id: String) async -> Bool {
        guard let raop = session.sink(forSpeaker: id) as? RAOPSink else { return false }
        await raop.setNowPlaying(title: m.title, artist: m.artist, album: m.album, artworkJPEG: m.artworkJPEG)
        return true
    }

    public func sendProgress(elapsed: TimeInterval, duration: TimeInterval, toSpeaker id: String) async -> Bool {
        guard let raop = session.sink(forSpeaker: id) as? RAOPSink else { return false }
        await raop.setProgress(elapsedSeconds: elapsed, durationSeconds: duration)
        return true
    }
}

// MARK: - Sources

extension FileSource: HubFileSource {}

@available(macOS 14.2, *)
extension AppAudioTapSource: HubCaptureSource {
    public func permissionEvidence() -> AsyncStream<CapturePermissionEvidence> {
        let statuses = statusUpdates
        return AsyncStream { continuation in
            let task = Task {
                var last: CapturePermissionEvidence?
                for await s in statuses {
                    let e: CapturePermissionEvidence
                    switch s.permission {
                    case .granted: e = .granted
                    case .likelySilencedByTCC, .denied: e = .denied
                    case .unknown: e = .unknown
                    }
                    if e != last { continuation.yield(e); last = e }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct LiveSourceMaker: HubSourceMaking {
    public init() {}

    public func openFile(_ url: URL) async throws -> any HubFileSource {
        try await FileSource.open(url: url)
    }

    public func makeCapture(bundleID: String, name: String) throws -> any HubCaptureSource {
        guard #available(macOS 14.2, *) else {
            throw MulticastSession.SessionError.unsupportedSource("App audio capture needs macOS 14.2 or later")
        }
        return AppAudioTapSource(target: .apps(bundleIDs: [bundleID]), muteBehavior: .mutedWhenTapped, displayName: name)
    }

    public func inspect(_ url: URL) async -> InspectedFile? {
        await FileInspector.inspect(url)
    }
}

/// Reads what the Files list shows about a file. DRM-protected files are refused.
enum FileInspector {
    static func inspect(_ url: URL) async -> InspectedFile? {
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.hasProtectedContent)) == true { return nil }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.fileFormat
        let duration = Double(file.length) / format.sampleRate
        var info = InspectedFile(duration: duration, format: formatNote(format.streamDescription.pointee))
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle?:
                    if info.title == nil { info.title = clean(try? await item.load(.stringValue)) }
                case .commonKeyArtist?:
                    if info.artist == nil { info.artist = clean(try? await item.load(.stringValue)) }
                case .commonKeyAlbumName?:
                    if info.album == nil { info.album = clean(try? await item.load(.stringValue)) }
                case .commonKeyArtwork?:
                    if info.artwork == nil, let d = try? await item.load(.dataValue), !d.isEmpty { info.artwork = d }
                default: break
                }
            }
        }
        return info
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// "FLAC · 24-bit", "ALAC · 16-bit", "WAV · 24-bit", "AAC", "MP3".
    static func formatNote(_ asbd: AudioStreamBasicDescription) -> String? {
        func losslessDepth(_ flags: AudioFormatFlags) -> Int? {
            switch flags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return nil
            }
        }
        let rate = asbd.mSampleRate
        let rateNote = rate > 0 && rate != 44_100 && rate != 48_000 ? String(format: " · %g kHz", rate / 1000) : ""
        switch asbd.mFormatID {
        case kAudioFormatFLAC: return "FLAC" + (losslessDepth(asbd.mFormatFlags).map { " · \($0)-bit" } ?? "") + rateNote
        case kAudioFormatAppleLossless:
            return "ALAC" + (losslessDepth(asbd.mFormatFlags).map { " · \($0)-bit" } ?? "") + rateNote
        case kAudioFormatLinearPCM:
            return "PCM" + (asbd.mBitsPerChannel > 0 ? " · \(asbd.mBitsPerChannel)-bit" : "") + rateNote
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatOpus: return "Opus"
        default: return nil
        }
    }
}

// MARK: - Apps

/// App launch state from NSWorkspace (notifications, plus the hub's own polling).
public final class WorkspaceAppPresence: AppPresenceMonitoring, @unchecked Sendable {
    public init() {}

    public func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let names: [Notification.Name] = [NSWorkspace.didLaunchApplicationNotification,
                                              NSWorkspace.didTerminateApplicationNotification]
            let tokens = names.map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in continuation.yield(()) } }
            let box = TokenBox(tokens)
            continuation.onTermination = { _ in box.tokens.forEach { center.removeObserver($0) } }
        }
    }

    private final class TokenBox: @unchecked Sendable {
        let tokens: [NSObjectProtocol]
        init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    }

    public func launch(_ bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw HubCommandError(.unavailable, "Not installed")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    public func iconPNG(bundleID: String, maxPixel: Int) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let side = maxPixel > 0 ? min(maxPixel, 1024) : 512
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return ArtworkImaging.encode(cg, as: .png)
    }
}

/// Running apps that play audio through Core Audio, grouped by app (helpers folded into it).
public final class ProcessTapApps: CapturableAppsProviding, @unchecked Sendable {
    private let directory = AudioProcessDirectory()

    public init() {}

    public func updates() -> AsyncStream<[CapturableApp]> {
        let source = directory.updates
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var last: [CapturableApp]?
                for await list in source {
                    let apps = Self.apps(from: list)
                    if apps != last { continuation.yield(apps); last = apps }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func apps(from processes: [AudioProcessInfo]) -> [CapturableApp] {
        var byApp: [String: CapturableApp] = [:]
        for p in processes where !p.isCurrentProcess && p.appBundleURL != nil {
            guard let id = p.appBundleID ?? p.bundleID else { continue }
            var app = byApp[id] ?? CapturableApp(id: id, name: p.name, isMakingSound: false, iconArtworkID: "hub.icon:\(id)")
            app.isMakingSound = app.isMakingSound || p.isRunningOutput
            byApp[id] = app
        }
        return byApp.values.sorted {
            if $0.isMakingSound != $1.isMakingSound { return $0.isMakingSound }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Spotify

/// Spotify over Apple Events (`MediaAppController`), errors mapped to `HubCommandError`.
public final class SpotifyAppleEvents: MediaAppControlling, @unchecked Sendable {
    private let controller = MediaAppController(app: .spotify)

    public init() {}

    public func changes() -> AsyncStream<NowPlaying?> { controller.changes(pollInterval: 2) }

    public func play() async throws { try await map { try await self.controller.play() } }
    public func pause() async throws { try await map { try await self.controller.pause() } }
    public func next() async throws { try await map { try await self.controller.nextTrack() } }
    public func previous() async throws { try await map { try await self.controller.previousTrack() } }

    public func automationStatus(ask: Bool) async -> PermissionStatus? {
        switch await controller.automationPermission(askIfNeeded: ask) {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .appNotRunning, .unknown: return nil
        }
    }

    private func map(_ body: () async throws -> Void) async throws {
        do { try await body() } catch let e as MediaAppController.MediaControlError {
            switch e {
            case .automationDenied, .automationConsentRequired:
                throw HubCommandError(.permissionMissing,
                                      "Allow Multicast to control Spotify in System Settings \u{203A} Privacy & Security \u{203A} Automation.")
            case .notRunning:
                throw HubCommandError(.unavailable, "Spotify isn\u{2019}t open.")
            default:
                throw HubCommandError(.failed, "Spotify didn\u{2019}t respond.")
            }
        }
    }
}

// MARK: - System services

public final class LiveSystemServices: HubSystemServices, @unchecked Sendable {
    public let hostIsLaptop: Bool = LiveSystemServices.hasInternalBattery()

    public init() {}

    public func openPrivacySettings(for permission: HubPermission) {
        let anchor: String
        switch permission {
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        case .audioCapture: anchor = "Privacy_AudioCapture"
        case .appleMusic: anchor = "Privacy_Media"
        case .automation: anchor = "Privacy_Automation"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    public func requestAudioCapturePermission() async {
        guard #available(macOS 14.2, *) else { return }
        // Creating a process tap is what makes macOS ask. Nothing is captured for real: the tap
        // is torn down after a moment and its audio never leaves this function.
        let probe = AppAudioTapSource(target: .system, muteBehavior: .unmuted, displayName: "Multicast permission probe")
        try? await probe.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await probe.stop()
    }

    public func fetchImage(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        let limit = 8 << 20
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Streamed, so a body past the limit is abandoned instead of downloaded whole.
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength < Int64(limit) else { return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { return nil }
        return data
    }

    static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { ps in
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { return false }
            return (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }
}
#endif
