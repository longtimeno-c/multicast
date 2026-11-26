#if os(macOS)
import AppKit
import Carbon
import Foundation
import os

/// Queries and controls Spotify / Music through Apple Events (NSAppleScript).
///
/// Never launches an app: every query first checks `NSRunningApplication`, and every script is
/// additionally guarded by `if application id "…" is running`. When the app is not running,
/// queries return nil / `.notRunning` without sending any Apple Event.
///
/// Requires the Automation permission for the target app (the host app needs
/// `NSAppleEventsUsageDescription`, and, if sandboxed, the apple-events entitlement). Denial is
/// surfaced as `MediaControlError.automationDenied`.
public final class MediaAppController: @unchecked Sendable {
    public enum MediaControlError: Error, Equatable {
        case notRunning
        /// The user (or policy) denied Automation of this app (errAEEventNotPermitted, -1743).
        case automationDenied
        /// Automation consent has not been given yet and asking was not allowed (-1744).
        case automationConsentRequired
        case scriptCompileFailed(String)
        case scriptError(code: Int, message: String)
        case unexpectedResult(String)
    }

    public enum AutomationPermission: Sendable, Equatable {
        case granted
        case denied
        case notDetermined
        case appNotRunning
        case unknown(OSStatus)
    }

    public let app: MediaApp
    private let queue: DispatchQueue
    private var compiled: [String: NSAppleScript] = [:]
    private var artworkCache: (trackID: String, data: Data?)?

    public init(app: MediaApp) {
        self.app = app
        self.queue = DispatchQueue(label: "Multicast.MediaAppController.\(app.displayName)")
    }

    /// Controllers for whichever supported apps are running right now.
    public static func runningControllers() -> [MediaAppController] {
        MediaApp.allCases.filter(isRunning).map(MediaAppController.init(app:))
    }

    public static func isRunning(_ app: MediaApp) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
    }

    public var isRunning: Bool { Self.isRunning(app) }

    // MARK: Permission

    /// Checks (optionally asking the user, which blocks until they answer) whether we may send
    /// Apple Events to the app. Does not launch it.
    public func automationPermission(askIfNeeded: Bool = false) async -> AutomationPermission {
        guard isRunning else { return .appNotRunning }
        let bundleID = app.bundleID
        return await withCheckedContinuation { c in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askIfNeeded)
                c.resume(returning: Self.mapPermission(status))
            }
        }
    }

    static func mapPermission(_ status: OSStatus) -> AutomationPermission {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .appNotRunning
        default: return .unknown(status)
        }
    }

    // MARK: Queries

    /// What is playing, or nil if the app is not running. Music artwork bytes are included
    /// (cached per track); Spotify provides `artworkURL` instead.
    public func nowPlaying(includeArtwork: Bool = true) async throws -> NowPlaying? {
        try await onQueue { try self.nowPlayingSync(includeArtwork: includeArtwork) }
    }

    public func playerState() async throws -> MediaPlayerState {
        try await nowPlaying(includeArtwork: false)?.state ?? .stopped
    }

    // MARK: Commands (never launch)

    public func play() async throws { try await command("play") }
    public func pause() async throws { try await command("pause") }
    public func playPause() async throws { try await command("playpause") }
    public func nextTrack() async throws { try await command("next track") }
    public func previousTrack() async throws { try await command("previous track") }

    public func setPosition(_ seconds: TimeInterval) async throws {
        let s = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        try await command("set player position to \(s)")
    }

    // MARK: Change stream

    /// Emits the current state, then whenever it changes significantly (track, state, tags,
    /// seek). Driven by the app's distributed notification (delivered when the main run loop
    /// runs, i.e. in an app) plus polling every `pollInterval` seconds as a fallback.
    /// Emits nil while the app is not running (no Apple Events are sent then).
    public func changes(pollInterval: TimeInterval = 2) -> AsyncStream<NowPlaying?> {
        AsyncStream { continuation in
            let observer = ChangeObserver(controller: self, continuation: continuation, pollInterval: pollInterval)
            observer.start()
            continuation.onTermination = { _ in observer.cancel() }
        }
    }

    // MARK: Scripts

    /// How long one script waits for the app to answer. An app that has stopped handling its
    /// scripting (Spotify does at times while it looks fine) would otherwise hold this
    /// controller's queue for AppleScript's default two minutes per call.
    static let appleEventTimeout: TimeInterval = 5

    static func stateScript(for app: MediaApp) -> String {
        let id = app.bundleID
        let artworkExpr = app == .spotify ? "artwork url of t" : "\"\""
        let idExpr = app == .spotify ? "id of t" : "persistent ID of t"
        return """
        on txt(v)
            if v is missing value then return ""
            try
                return v as string
            on error
                return ""
            end try
        end txt
        set US to character id 31
        with timeout of \(Int(appleEventTimeout)) seconds
        if application id "\(id)" is running then
            tell application id "\(id)"
                set st to ""
                try
                    set st to my txt(player state)
                end try
                set out to "OK" & US & st
                try
                    set t to current track
                    set f1 to ""
                    set f2 to ""
                    set f3 to ""
                    set f4 to ""
                    set f5 to ""
                    set f6 to ""
                    set f7 to ""
                    try
                        set f1 to my txt(name of t)
                    end try
                    try
                        set f2 to my txt(artist of t)
                    end try
                    try
                        set f3 to my txt(album of t)
                    end try
                    try
                        set f4 to my txt(duration of t)
                    end try
                    try
                        set f5 to my txt(player position)
                    end try
                    try
                        set f6 to my txt(\(artworkExpr))
                    end try
                    try
                        set f7 to my txt(\(idExpr))
                    end try
                    set out to out & US & f1 & US & f2 & US & f3 & US & f4 & US & f5 & US & f6 & US & f7
                end try
                return out
            end tell
        else
            return "\(AppleScriptNowPlayingParser.notRunningMarker)"
        end if
        end timeout
        """
    }

    static func musicArtworkScript() -> String {
        """
        if application id "\(MediaApp.music.bundleID)" is running then
            tell application id "\(MediaApp.music.bundleID)"
                try
                    return raw data of artwork 1 of current track
                end try
            end tell
        end if
        return ""
        """
    }

    static func commandScript(for app: MediaApp, command: String) -> String {
        """
        with timeout of \(Int(appleEventTimeout)) seconds
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)" to \(command)
            return "\(AppleScriptNowPlayingParser.okMarker)"
        else
            return "\(AppleScriptNowPlayingParser.notRunningMarker)"
        end if
        end timeout
        """
    }

    /// Maps an NSAppleScript error dictionary to a typed error.
    static func mapScriptError(_ info: NSDictionary?) -> MediaControlError {
        let code = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (info?[NSAppleScript.errorMessage] as? String)
            ?? (info?[NSAppleScript.errorBriefMessage] as? String) ?? "unknown AppleScript error"
        switch code {
        case -1743: return .automationDenied
        case -1744: return .automationConsentRequired
        case -600, -609, -10810: return .notRunning
        default: return .scriptError(code: code, message: message)
        }
    }

    // MARK: Private (script queue)

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try body() }) }
        }
    }

    static let log = Logger(subsystem: "io.github.longtimeno-c.multicast", category: "media-app")

    private func script(_ source: String) throws -> NSAppleScript {
        if let s = compiled[source] { return s }
        guard let s = NSAppleScript(source: source) else { throw MediaControlError.scriptCompileFailed("init") }
        var err: NSDictionary?
        let started = Date()
        // Compiling can take tens of seconds the first time in an app process (the system scans
        // the script before compiling it), and the script's own timeout does not cover it.
        let ok = s.compileAndReturnError(&err)
        Self.log.debug("compile \(self.app.displayName, privacy: .public) ok=\(ok) \(Int(Date().timeIntervalSince(started) * 1000))ms")
        if !ok {
            let code = (err?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            Self.log.error("compile \(self.app.displayName, privacy: .public) failed: \(code)")
            throw MediaControlError.scriptCompileFailed(Self.mapScriptError(err).localizedDescription)
        }
        compiled[source] = s
        return s
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        let s = try script(source)
        var err: NSDictionary?
        let result = s.executeAndReturnError(&err)
        if let err { throw Self.mapScriptError(err) }
        return result
    }

    func nowPlayingSync(includeArtwork: Bool) throws -> NowPlaying? {
        guard isRunning else { return nil }
        let sampled = Date()
        let desc = try run(Self.stateScript(for: app))
        guard let text = desc.stringValue else { throw MediaControlError.unexpectedResult("non-text result") }
        guard var np = try AppleScriptNowPlayingParser.parse(text, app: app, sampledAt: sampled) else { return nil }
        if includeArtwork, app == .music, np.hasTrack {
            let key = np.trackID ?? "\(np.title ?? "")|\(np.artist ?? "")|\(np.album ?? "")"
            if let cache = artworkCache, cache.trackID == key {
                np.artworkData = cache.data
            } else {
                let data = try? musicArtworkSync()
                artworkCache = (key, data)
                np.artworkData = data
            }
        }
        return np
    }

    private func musicArtworkSync() throws -> Data? {
        guard isRunning else { return nil }
        let desc = try run(Self.musicArtworkScript())
        if desc.descriptorType == typeUnicodeText || desc.descriptorType == typeUTF8Text || desc.descriptorType == typeNull {
            return nil
        }
        let d = desc.data
        return d.isEmpty ? nil : d
    }

    private func command(_ cmd: String) async throws {
        guard isRunning else { throw MediaControlError.notRunning }
        let source = Self.commandScript(for: app, command: cmd)
        let out: String = try await onQueue { try self.run(source).stringValue ?? "" }
        if out == AppleScriptNowPlayingParser.notRunningMarker { throw MediaControlError.notRunning }
        guard out == AppleScriptNowPlayingParser.okMarker else { throw MediaControlError.unexpectedResult(out) }
    }
}

/// Drives `MediaAppController.changes`.
private final class ChangeObserver: @unchecked Sendable {
    private let controller: MediaAppController
    private let app: MediaApp
    private let continuation: AsyncStream<NowPlaying?>.Continuation
    private let pollInterval: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var token: NSObjectProtocol?
    private var last: NowPlaying??
    private var cancelled = false

    init(controller: MediaAppController, continuation: AsyncStream<NowPlaying?>.Continuation, pollInterval: TimeInterval) {
        self.controller = controller
        self.app = controller.app
        self.continuation = continuation
        self.pollInterval = max(0.25, pollInterval)
        self.queue = DispatchQueue(label: "Multicast.MediaAppController.changes")
    }

    func start() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(app.playbackNotificationName), object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.tick() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            timer?.cancel()
            timer = nil
            if let token { DistributedNotificationCenter.default().removeObserver(token) }
            token = nil
        }
    }

    private func tick() {
        guard !cancelled else { return }
        let current: NowPlaying?
        do {
            // Runs on this observer's queue; the controller's NSAppleScript use stays serial
            // because the controller dispatches synchronously onto its own queue.
            current = try controller.syncNowPlayingForObserver()
        } catch {
            // Permission errors etc.: keep last value; callers can query directly for the error.
            MediaAppController.log.debug("\(self.app.displayName, privacy: .public) status failed: \(String(describing: error), privacy: .public)")
            return
        }
        switch last {
        case .none:
            last = .some(current)
            continuation.yield(current)
        case .some(let previous):
            let changed: Bool
            switch (previous, current) {
            case (nil, nil): changed = false
            case (nil, _), (_, nil): changed = true
            case (.some(let p), .some(let c)): changed = c.isSignificantChange(from: p)
            }
            if changed {
                last = .some(current)
                continuation.yield(current)
            }
        }
    }
}

extension MediaAppController {
    fileprivate func syncNowPlayingForObserver() throws -> NowPlaying? {
        try queue.sync { try nowPlayingSync(includeArtwork: true) }
    }
}
#endif
