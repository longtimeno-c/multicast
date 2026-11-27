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
import MulticastLocalOutput
import MulticastRAOP
import MulticastSources
import os
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
            settings: settings,
            deviceVolumes: MacOutputVolumes()
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

    private var diagnosticsTask: Task<Void, Never>?

    public init(_ session: MulticastSession) { self.session = session }

    deinit { diagnosticsTask?.cancel() }

    public var state: SessionState { session.state }
    public func stateUpdates() -> AsyncStream<SessionState> { session.updates }
    public func meterUpdates() -> AsyncStream<MeterReading> { session.meters }
    public func eventUpdates() -> AsyncStream<EngineEvent> { session.events }
    public var discoveryErrorCode: Int32? { session.directory.discoveryError }
    public var latencySeconds: TimeInterval { Double(session.engine.snapshot.latencyMillis) / 1000 }
    public var currentSource: AudioSource? { session.currentSource }

    public func start() {
        session.start()
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.logDiagnostics()
            }
        }
    }

    public func shutdown() async {
        diagnosticsTask?.cancel()
        await session.shutdown()
    }

    private static let diagnosticsLog = Logger(subsystem: "io.github.longtimeno-c.multicast", category: "diagnostics")

    /// While the engine plays, every 5 s: each sink's counters and the capture's (debug level, so
    /// it costs nothing unless someone streams the log). Counters are cumulative since the sink
    /// or capture started; names are never logged.
    private func logDiagnostics() {
        guard session.state.engine.transport == .playing else { return }
        let log = Self.diagnosticsLog
        for (i, d) in session.diagnostics().enumerated() {
            switch d.kind {
            case .raop:
                log.debug("sink\(i) raop sent=\(d.packetsSent ?? 0) sendErrors=\(d.sendErrors ?? 0) resendRequests=\(d.resendRequests ?? 0) resent=\(d.packetsResent ?? 0) resendMisses=\(d.resendMisses ?? 0) timing=\(d.timingRequestsAnswered ?? 0) sync=\(d.syncPacketsSent ?? 0) receiverLatency=\(d.receiverAudioLatencyFrames ?? -1)")
            default:
                log.debug("sink\(i) local callbacks=\(d.renderCallbacks ?? 0) syncErrorMs=\(String(format: "%.2f", d.syncErrorMillis ?? 0), privacy: .public) ratePPM=\(String(format: "%.1f", d.rateCorrectionPPM ?? 0), privacy: .public) underrunFrames=\(d.underrunFrames ?? 0) outputLatencyMs=\(String(format: "%.1f", d.outputLatencyMillis ?? 0), privacy: .public)")
            }
        }
        if #available(macOS 14.2, *), let tap = session.currentSource as? AppAudioTapSource {
            let s = tap.statistics
            log.debug("capture cycles=\(s.ioCycles) frames=\(s.capturedFrames) nonSilent=\(s.nonSilentCycles) inOverflow=\(s.inputOverflowFrames) outOverflow=\(s.outputOverflowFrames) underruns=\(s.underruns) driftDrops=\(s.driftDrops) driftDups=\(s.driftDuplicates) resyncs=\(s.resyncs) rebuilds=\(s.rebuilds)")
        }
    }

    public func select(_ speaker: SpeakerDescriptor, volume: Float, offsetMillis: Int) async throws {
        try await session.select(speaker, volume: volume, offsetMillis: offsetMillis)
    }
    public func deselect(speakerID: String) async { await session.deselect(speakerID: speakerID) }
    public func retry(speakerID: String) async { await session.retry(speakerID: speakerID) }
    public func checkAccess(_ speaker: SpeakerDescriptor) async -> SpeakerAccessCheck { await session.checkAccess(speaker) }
    public func refreshSpeakers() { session.refreshSpeakers() }
    public func addExternalSpeaker(_ speaker: SpeakerDescriptor, sink: any AudioSink) async {
        await session.addExternalSpeaker(speaker, sink: sink)
    }
    public func removeExternalSpeaker(id: String) async { await session.removeExternalSpeaker(id: id) }

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

// MARK: - Device volumes

/// This Mac's outputs: a local speaker's slider is the output device's own volume, where the
/// device has one that can be set. Network speakers have none here.
public final class MacOutputVolumes: SpeakerDeviceVolumeProviding, @unchecked Sendable {
    private let volumes = OutputDeviceVolumes()

    public init() {}

    public func deviceVolume(of speaker: SpeakerDescriptor) -> Double? {
        guard speaker.transport == .local, let uid = speaker.localDeviceUID else { return nil }
        return volumes.volume(forDeviceUID: uid).map(Double.init)
    }

    public func setDeviceVolume(_ volume: Double, of speaker: SpeakerDescriptor) {
        guard speaker.transport == .local, let uid = speaker.localDeviceUID else { return }
        volumes.setVolume(Float(volume), forDeviceUID: uid)
    }

    public func deviceVolumeChanges() -> AsyncStream<Void> { volumes.changes }
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

    public var macOutputIsInstalled: Bool { OutputDeviceSource.isInstalled }
    public var macOutputIsDefault: Bool { OutputDeviceSource.isDefaultOutput }
    public func makeMacOutputCapture() throws -> any AudioSource { OutputDeviceSource(displayName: "Mac output") }
    public func reportMacOutputLatency(seconds: TimeInterval) { OutputDeviceSource.reportLatency(seconds: seconds) }
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

    public func open(_ bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw HubCommandError(.unavailable, "Not installed")
        }
        // Activation is cooperative (macOS 14+): the active app (this one, where the person
        // clicked) must yield to the other app, or the request is silently ignored.
        await MainActor.run { NSApp?.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        // Already running and hidden or behind other windows: bring it forward as well.
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
                .activate(from: .current, options: [])
        }
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
    private let lock = NSLock()
    private var statusCheck: Task<PermissionStatus?, Never>?
    /// How long `automationStatus(ask: false)` waits before answering "unknown" (the check runs
    /// on and is reused by the next caller). The system asks Spotify itself; a Spotify that
    /// stopped handling its scripting makes that take most of a minute.
    public let statusWait: TimeInterval

    public init(statusWait: TimeInterval = 2) { self.statusWait = statusWait }

    /// Now playing and transport go out as raw Apple Events (`SpotifyEvents`): no AppleScript is
    /// compiled, so none waits on the system's script scan.
    private let events = SpotifyEvents()
    private let eventQueue = DispatchQueue(label: "Multicast.SpotifyEvents")

    public func changes() -> AsyncStream<NowPlaying?> { SpotifyEventsObserver.stream(events, interval: 2) }

    public func play() async throws { try await map { try await self.send { try $0.play() } } }
    public func pause() async throws { try await map { try await self.send { try $0.pause() } } }
    public func next() async throws { try await map { try await self.send { try $0.next() } } }
    public func previous() async throws { try await map { try await self.send { try $0.previous() } } }

    private func send(_ body: @escaping @Sendable (SpotifyEvents) throws -> Void) async throws {
        let events = events
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            eventQueue.async { c.resume(with: Result { try body(events) }) }
        }
    }

    public func seek(to seconds: TimeInterval) async throws {
        try await map { try await self.controller.seek(to: seconds) }
    }

    public func play(uri: String, shuffled: Bool?) async throws {
        try await map { try await self.controller.play(uri: uri, shuffled: shuffled) }
    }

    public func automationStatus(ask: Bool) async -> PermissionStatus? {
        // Asking waits on a person; only the silent check is shared and bounded.
        if ask { return await Self.map(controller.automationPermission(askIfNeeded: true)) }
        let check: Task<PermissionStatus?, Never> = lock.withLock {
            if let running = statusCheck { return running }
            let controller = controller
            let t = Task<PermissionStatus?, Never> { [weak self] in
                let status = Self.map(await controller.automationPermission(askIfNeeded: false))
                self?.lock.withLock { self?.statusCheck = nil }
                return status
            }
            statusCheck = t
            return t
        }
        // Whichever comes first (a task group would wait for the check anyway).
        let wait = statusWait
        let once = OnceFlag()
        return await withCheckedContinuation { (c: CheckedContinuation<PermissionStatus?, Never>) in
            Task {
                let status = await check.value
                if once.claim() { c.resume(returning: status) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                if once.claim() { c.resume(returning: nil) }
            }
        }
    }

    private static func map(_ permission: MediaAppController.AutomationPermission) -> PermissionStatus? {
        switch permission {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .appNotRunning, .unknown: return nil
        }
    }

    /// How long one transport command may take before the hub reports Spotify as not
    /// responding. The script itself times out after 5 s, but compiling it (which loads
    /// Spotify's terminology, from Spotify) is not covered by that and has been seen to hang.
    public static let commandWait: TimeInterval = 6

    private func map(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let once = OnceFlag()
        let wait = Self.commandWait
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Task {
                do {
                    try await Self.mapErrors(body)
                    if once.claim() { c.resume() }
                } catch {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                if once.claim() {
                    c.resume(throwing: HubCommandError(.failed, "Spotify isn\u{2019}t responding. Quit and reopen Spotify, then try again."))
                }
            }
        }
    }

    private static func mapErrors(_ body: () async throws -> Void) async throws {
        do { try await body() } catch let e as MediaAppController.MediaControlError {
            switch e {
            case .automationDenied, .automationConsentRequired:
                throw HubCommandError(.permissionMissing,
                                      "Allow Multicast to control Spotify in System Settings \u{203A} Privacy & Security \u{203A} Automation.")
            case .notRunning:
                throw HubCommandError(.unavailable, "Spotify isn\u{2019}t open.")
            case .scriptError(code: -1712, _):
                throw HubCommandError(.failed, "Spotify isn\u{2019}t responding. Quit and reopen Spotify, then try again.")
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

    /// A network call to Spotify with the pasted link, only when someone pastes one.
    public func spotifyEmbed(for page: URL) async -> SpotifyEmbedInfo? {
        guard page.host == "open.spotify.com",
              var c = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        c.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty else { return nil }
        let thumb = (object["thumbnail_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return SpotifyEmbedInfo(title: String(title.prefix(300)), thumbnailURL: thumb)
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
