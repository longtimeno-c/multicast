#if os(macOS)
import CoreAudio
import Foundation
import MulticastSources
import MusicKit

/// The experiment that decides the MusicKit design: which process renders
/// `ApplicationMusicPlayer` audio on macOS, and can a process tap read it?
///
/// Must run inside the signed Multicast.app (MusicKit mints its developer token from the app's
/// bundle id and team). Started from the app with `--music-experiment` (see
/// Apps/Mac/Experiments). Steps:
///  1. MusicKit authorization (prompts once; waits up to `authorizationTimeout`).
///  2. Subscription status; one catalog search (proves the developer token).
///  3. Safety: refuses unless the default output is the built-in device, then caps its volume.
///  4. Plays one song with ApplicationMusicPlayer and lists the processes running output.
///  5. Taps each candidate process (muted while tapped) and measures the samples.
///  6. Stops playback, restores the volume.
@available(macOS 14.2, *)
public enum MusicKitRenderProbe {
    public struct Options: Sendable {
        public var authorizationTimeout: TimeInterval = 60
        /// Output volume cap applied to the built-in device before any audio starts.
        public var volumeCap: Float32 = 0.08
        /// Seconds of playback before the process list is taken.
        public var settleSeconds: Double = 1.5
        /// Seconds each tap is measured.
        public var tapSeconds: Double = 2.5
        /// Skip the library and play a catalog song.
        public var preferCatalog = false
        /// When false the probe never shows the authorization prompt: it only reads the status.
        public var requestAuthorization = true
        public init() {}
    }

    public struct Outcome: Sendable, CustomStringConvertible {
        public var authorization = "unknown"
        public var catalogSearchWorked = false
        public var played = false
        public var newOutputProcesses: [String] = []
        public var thisProcessRunsOutput = false
        public var measurements: [TapMeasurement] = []
        public var error: String?

        public var description: String {
            var lines = ["authorization=\(authorization)", "catalogSearchWorked=\(catalogSearchWorked)", "played=\(played)",
                         "thisProcessRunsOutput=\(thisProcessRunsOutput)"]
            lines += newOutputProcesses.map { "newOutputProcess: \($0)" }
            lines += measurements.map { "measurement: \($0)" }
            if let error { lines.append("error: \(error)") }
            return lines.joined(separator: "\n")
        }
    }

    public static func run(_ options: Options = Options(), log: @escaping @Sendable (String) -> Void) async -> Outcome {
        var out = Outcome()

        // 1. Authorization.
        var status = MusicAuthorization.currentStatus
        log("MusicAuthorization.currentStatus = \(status)")
        if status == .notDetermined, options.requestAuthorization {
            log("requesting MusicAuthorization (a human must answer the prompt; waiting up to \(Int(options.authorizationTimeout)) s)")
            status = await withTimeout(options.authorizationTimeout) { await MusicAuthorization.request() } ?? .notDetermined
            log("MusicAuthorization after request = \(status)")
        }
        out.authorization = "\(status)"
        guard status == .authorized else {
            out.error = "MusicKit not authorized (\(status)); stopping before playback"
            log(out.error!)
            return out
        }

        // 2. Subscription + developer token.
        do {
            let sub = try await MusicSubscription.current
            log("subscription canPlayCatalogContent=\(sub.canPlayCatalogContent) canBecomeSubscriber=\(sub.canBecomeSubscriber) hasCloudLibraryEnabled=\(sub.hasCloudLibraryEnabled)")
        } catch {
            log("MusicSubscription.current failed: \(error)")
        }
        var catalogSong: Song?
        do {
            var req = MusicCatalogSearchRequest(term: "piano", types: [Song.self])
            req.limit = 1
            let res = try await req.response()
            catalogSong = res.songs.first
            out.catalogSearchWorked = true
            log("catalog search ok: \(res.songs.count) song(s)")
        } catch {
            log("catalog search failed (developer token / provisioning?): \(error)")
        }
        var song: Song?
        if !options.preferCatalog {
            do {
                var lib = MusicLibraryRequest<Song>()
                lib.limit = 1
                let res = try await lib.response()
                song = res.items.first
                log("library request ok: \(res.items.count) song(s) in first page")
            } catch {
                log("library request failed: \(error)")
            }
        }
        if song == nil { song = catalogSong }
        guard let song else {
            out.error = "no playable song found (library and catalog both empty/failed)"
            log(out.error!)
            return out
        }

        // 3. Safety.
        guard let device = DefaultOutputDevice.current(), device.isBuiltIn else {
            out.error = "default output is not the built-in device; refusing to play (\(DefaultOutputDevice.current()?.name ?? "none"))"
            log(out.error!)
            return out
        }
        let savedVolume = device.volume
        if let savedVolume, savedVolume > options.volumeCap {
            guard device.setVolume(options.volumeCap) else {
                out.error = "could not cap the output volume; refusing to play"
                log(out.error!)
                return out
            }
        }
        log("output=\(device.name) builtIn=\(device.isBuiltIn) volume \(savedVolume.map { String($0) } ?? "n/a") -> \(device.volume.map { String($0) } ?? "n/a")")
        defer {
            if let savedVolume, savedVolume > options.volumeCap { device.setVolume(savedVolume) }
        }

        // 4. Play and look.
        let before = Set(AudioProcessDirectory.snapshot().filter(\.isRunningOutput).map(\.objectID))
        log("output processes before play: \(before.count)")
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        do {
            try await player.play()
            out.played = true
            log("ApplicationMusicPlayer.play() returned; status=\(player.state.playbackStatus)")
        } catch {
            out.error = "ApplicationMusicPlayer.play() failed: \(error)"
            log(out.error!)
            return out
        }
        try? await Task.sleep(nanoseconds: UInt64(options.settleSeconds * 1e9))
        log("playbackStatus=\(player.state.playbackStatus) playbackTime=\(String(format: "%.2f", player.playbackTime))")
        let after = AudioProcessDirectory.snapshot().filter(\.isRunningOutput)
        for p in after { log("running output: \(TapProbe.describe(p))\(before.contains(p.objectID) ? "" : " [NEW]")") }
        let selfObj = AudioProcessDirectory.currentProcessObject()
        out.thisProcessRunsOutput = after.contains { $0.isCurrentProcess }
        let fresh = after.filter { !before.contains($0.objectID) && !$0.isCurrentProcess }
        out.newOutputProcesses = fresh.map(TapProbe.describe)
        log("this process object=\(selfObj.map(String.init) ?? "none") runsOutput=\(out.thisProcessRunsOutput)")

        // 5. Measure taps.
        if out.thisProcessRunsOutput, let selfObj {
            let m = await TapProbe.measure(.processObjects([selfObj]), seconds: options.tapSeconds)
            log("self tap: \(m)")
            out.measurements.append(m)
        }
        for p in fresh.prefix(3) {
            let m = await TapProbe.measure(.processObjects([p.objectID]), seconds: options.tapSeconds)
            log("tap \(p.name): \(m)")
            out.measurements.append(m)
        }

        // 6. Tear down.
        player.stop()
        player.queue = []
        log("stopped; status=\(player.state.playbackStatus)")
        return out
    }

    /// Returns `body`'s result, or nil after `seconds` (the body keeps running detached: a
    /// permission prompt cannot be cancelled, only stopped waiting for).
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            once.set(c)
            Task { once.resume(await body()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                once.resume(nil)
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T??

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value = pending { lock.unlock(); c.resume(returning: value!); return }
        continuation = c
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            pending = .some(value)
            lock.unlock()
            c.resume(returning: value)
            return
        }
        if pending == nil { pending = .some(value) }
        lock.unlock()
    }
}
#endif
