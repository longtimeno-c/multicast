#if os(macOS)
import Carbon
import Foundation
import MulticastSources
import os

/// Spotify's now playing and transport as raw Apple Events, built from the four-character codes
/// in Spotify's scripting dictionary (Spotify.sdef). Nothing is compiled: an app compiling an
/// AppleScript has it security-scanned first, which held the first status read of a fresh
/// Multicast process for tens of seconds and every distinct script after it again, so now
/// playing never arrived while Spotify played. Each event waits at most `timeout` for Spotify.
///
/// Needs the Automation permission for Spotify like any Apple Event; errors come back as
/// `MediaAppController.MediaControlError` so callers map them as before.
public struct SpotifyEvents: Sendable {
    public static let bundleID = MediaApp.spotify.bundleID
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) { self.timeout = timeout }

    // Codes from Spotify.sdef.
    enum Code {
        static let suite: FourCharCode = fourCC("spfy")
        static let play: FourCharCode = fourCC("Play")
        static let pause: FourCharCode = fourCC("Paus")
        static let next: FourCharCode = fourCC("Next")
        static let previous: FourCharCode = fourCC("Prev")
        static let playerState: FourCharCode = fourCC("pPlS")
        static let playerPosition: FourCharCode = fourCC("pPos")
        static let currentTrack: FourCharCode = fourCC("pTrk")
        static let name: FourCharCode = fourCC("pnam")
        static let artist: FourCharCode = fourCC("pArt")
        static let album: FourCharCode = fourCC("pAlb")
        static let duration: FourCharCode = fourCC("pDur")
        static let id: FourCharCode = fourCC("ID  ")
        static let artworkURL: FourCharCode = fourCC("aUrl")
    }

    static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    // MARK: Transport

    public func play() throws { try command(Code.play) }
    public func pause() throws { try command(Code.pause) }
    public func next() throws { try command(Code.next) }
    public func previous() throws { try command(Code.previous) }

    private func command(_ id: FourCharCode) throws {
        _ = try send(eventClass: Code.suite, eventID: id, directObject: nil)
    }

    // MARK: Now playing

    /// What Spotify is playing now, or nil when it is not running. One event per field
    /// (Spotify answers `properties` with error -10000), each a few milliseconds.
    public func nowPlaying() throws -> NowPlaying? {
        guard isRunning else { return nil }
        let sampled = Date()
        let state = try get(Self.property(Code.playerState))
        let position = try? get(Self.property(Code.playerPosition))
        let current = Self.property(Code.currentTrack)
        let track = NSAppleEventDescriptor.record()
        var any = false
        for code in [Code.name, Code.artist, Code.album, Code.duration, Code.id, Code.artworkURL] {
            if let v = try? get(Self.property(code, of: current)), v.descriptorType != typeNull {
                track.setDescriptor(v, forKeyword: code)
                any = true
            }
        }
        return Self.nowPlaying(state: state, position: position, track: any ? track : nil, sampledAt: sampled)
    }

    /// Builds the hub's value from the three replies (pure; tested with made-up descriptors).
    static func nowPlaying(state: NSAppleEventDescriptor, position: NSAppleEventDescriptor?,
                           track: NSAppleEventDescriptor?, sampledAt: Date) -> NowPlaying {
        var np = NowPlaying(app: .spotify, state: playerState(state), sampledAt: sampledAt)
        if let position, let p = number(position), p >= 0 { np.position = p }
        if let track {
            func text(_ key: FourCharCode) -> String? {
                guard let s = track.forKeyword(key)?.stringValue, !s.isEmpty else { return nil }
                return s
            }
            np.title = text(Code.name)
            np.artist = text(Code.artist)
            np.album = text(Code.album)
            np.trackID = text(Code.id)
            np.artworkURL = text(Code.artworkURL).flatMap(URL.init(string:))
            // Spotify reports milliseconds.
            if let d = track.forKeyword(Code.duration).flatMap(number), d > 0 { np.duration = d / 1000 }
        }
        return np
    }

    static func playerState(_ d: NSAppleEventDescriptor) -> MediaPlayerState {
        switch d.enumCodeValue {
        case fourCC("kPSP"): return .playing
        case fourCC("kPSp"): return .paused
        case fourCC("kPSS"): return .stopped
        default: return .unknown
        }
    }

    static func number(_ d: NSAppleEventDescriptor) -> Double? {
        if let c = d.coerce(toDescriptorType: typeIEEE64BitFloatingPoint) { return c.doubleValue }
        if let c = d.coerce(toDescriptorType: typeSInt32) { return Double(c.int32Value) }
        return nil
    }

    // MARK: Events

    var isRunning: Bool { MediaAppController.isRunning(.spotify) }

    /// `property code of container` (the application when `container` is nil).
    static func property(_ code: FourCharCode, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: FourCharCode(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    private func get(_ spec: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), directObject: spec)
    }

    private func send(eventClass: AEEventClass, eventID: AEEventID, directObject: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard isRunning else { throw MediaAppController.MediaControlError.notRunning }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: Self.bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let directObject { event.setParam(directObject, forKeyword: keyDirectObject) }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let e as NSError {
            throw Self.mapError(e.code)
        }
        if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 {
            throw Self.mapError(Int(code))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    static func mapError(_ code: Int) -> MediaAppController.MediaControlError {
        switch code {
        case -1743: return .automationDenied
        case -1744: return .automationConsentRequired
        case -600, -609, -10810: return .notRunning
        default: return .scriptError(code: code, message: "Apple Event error \(code)")
        }
    }
}

/// Polls `SpotifyEvents.nowPlaying()` (and reads at once on Spotify's playback notification),
/// yielding the first value and then every significant change.
final class SpotifyEventsObserver: @unchecked Sendable {
    private let events: SpotifyEvents
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "Multicast.SpotifyEvents.observer")
    private var timer: DispatchSourceTimer?
    private var token: NSObjectProtocol?
    private var last: NowPlaying??
    private var cancelled = false
    private let continuation: AsyncStream<NowPlaying?>.Continuation
    static let log = Logger(subsystem: "io.github.longtimeno-c.multicast", category: "media-app")

    init(events: SpotifyEvents, interval: TimeInterval, continuation: AsyncStream<NowPlaying?>.Continuation) {
        self.events = events
        self.interval = max(0.25, interval)
        self.continuation = continuation
    }

    static func stream(_ events: SpotifyEvents, interval: TimeInterval) -> AsyncStream<NowPlaying?> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let o = SpotifyEventsObserver(events: events, interval: interval, continuation: continuation)
            o.start()
            continuation.onTermination = { _ in o.cancel() }
        }
    }

    private func start() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(MediaApp.spotify.playbackNotificationName), object: nil, queue: nil
        ) { [weak self] _ in self?.queue.async { self?.tick() } }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func cancel() {
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
        do { current = try events.nowPlaying() } catch {
            Self.log.debug("Spotify status failed: \(String(describing: error), privacy: .public)")
            return
        }
        let changed: Bool
        switch last {
        case .none: changed = true
        case .some(let previous):
            switch (previous, current) {
            case (nil, nil): changed = false
            case (nil, _), (_, nil): changed = true
            case (.some(let p), .some(let c)): changed = c.isSignificantChange(from: p)
            }
        }
        if changed {
            last = .some(current)
            continuation.yield(current)
        }
    }
}
#endif
