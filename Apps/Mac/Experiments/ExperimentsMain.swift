import AppKit
import CoreAudio
import Foundation
import MulticastAppleMusic
import MulticastHub
import MulticastHubModel
import MulticastKit
import MulticastSources

/// Debug experiments that must run inside the signed app bundle (MusicKit's developer token and
/// the TCC grants belong to the app, not to a command-line tool). Called from a C constructor
/// before `main` (ExperimentsHook.c); returns immediately unless a flag below is present.
///
///   open -W -n Multicast.app --args --music-experiment [--catalog] [--no-prompt] --experiment-log <file>
///       MusicKit: authorize, play one song with ApplicationMusicPlayer, list the processes
///       running output, tap them, report whether samples arrive. `--no-prompt` only reads
///       the authorization status (never shows the prompt).
///   open -W -n Multicast.app --args --music-app-experiment [--no-prompt] --experiment-log <file>
///       Music app: authorize Automation, play one library track in Music at volume ≤ 12,
///       tap Music through `MusicAppPlayer.makeAudioSource()`, report whether samples arrive.
///
///   open -W -n Multicast.app --args --spotify-experiment --experiment-log <file>
///       Spotify (already playing, quietly): list the processes running output with their
///       output devices, then tap each Spotify process, the app as the hub taps it (muted and
///       unmuted) and the whole system minus Multicast, and report peak/RMS for each.
///
///   open -W -n Multicast.app --args --applescript-experiment <file.applescript> --experiment-log <file>
///       Runs one AppleScript with the app's own Automation grants (Music, Spotify) and logs the
///       result. For reading an app's scripting model, e.g. how Music reports playlist folders.
///
///   open -W -n Multicast.app --args --catalog-experiment "<search term>" [--no-play] --experiment-log <file>
///       Apple Music catalog, end to end through a real hub with the Music app as the backend
///       (never prompts): search the catalog, say whether the first result is in the library,
///       then play it through the hub's queue on this Mac's built-in speakers only (device
///       volume capped at 0.10, about 6 s), logging now playing, the speaker and the capture
///       counters each second. Tears everything down and restores the volume. `--no-play`
///       stops after the search; `--to-end` seeks to 4 s before the end after the first second,
///       to watch the queue start the next result.
///
/// Launch with `open` so the app (not the terminal) is the process TCC asks about. The log goes
/// to `--experiment-log` (stdout is lost under `open`) and to stdout.
@_cdecl("MulticastExperimentsMain")
func multicastExperimentsMain() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--applescript-experiment"), args.indices.contains(i + 1) {
        let logPath = args.firstIndex(of: "--experiment-log").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let log = ExperimentLog(path: logPath)
        guard let source = try? String(contentsOfFile: args[i + 1], encoding: .utf8),
              let script = NSAppleScript(source: source) else {
            log.write("could not read the script")
            exit(1)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { log.write("error: \(error)") } else { log.write("result: \(result)") }
        log.write("experiment finished")
        exit(0)
    }
    let kind: ExperimentKind
    if args.contains("--music-experiment") {
        kind = .musicKit(preferCatalog: args.contains("--catalog"), prompt: !args.contains("--no-prompt"))
    } else if args.contains("--music-app-experiment") {
        kind = .musicApp(prompt: !args.contains("--no-prompt"))
    } else if let i = args.firstIndex(of: "--catalog-experiment"), args.indices.contains(i + 1) {
        kind = .catalog(term: args[i + 1], play: !args.contains("--no-play"), toEnd: args.contains("--to-end"))
    } else if args.contains("--spotify-experiment") {
        kind = .spotify
    } else {
        return
    }
    let logPath = args.firstIndex(of: "--experiment-log").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    let log = ExperimentLog(path: logPath)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task.detached {
        log.write("experiment \(kind) pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        await kind.run(log: log.write)
        log.write("experiment finished")
        exit(0)
    }
    app.run()
    exit(0)
}

private enum ExperimentKind: CustomStringConvertible {
    case musicKit(preferCatalog: Bool, prompt: Bool)
    case musicApp(prompt: Bool)
    case spotify
    case catalog(term: String, play: Bool, toEnd: Bool)

    var description: String {
        switch self {
        case .catalog(_, let play, let toEnd): return "catalog(play: \(play), toEnd: \(toEnd))"
        case .spotify: return "spotify"
        case .musicKit(let catalog, let prompt): return "musicKit(preferCatalog: \(catalog), prompt: \(prompt))"
        case .musicApp(let prompt): return "musicApp(prompt: \(prompt))"
        }
    }

    func run(log: @escaping @Sendable (String) -> Void) async {
        guard #available(macOS 14.2, *) else {
            log("needs macOS 14.2 for process taps")
            return
        }
        switch self {
        case .musicKit(let preferCatalog, let prompt):
            var options = MusicKitRenderProbe.Options()
            options.preferCatalog = preferCatalog
            options.requestAuthorization = prompt
            let outcome = await MusicKitRenderProbe.run(options, log: log)
            log("OUTCOME\n\(outcome)")
        case .musicApp(let prompt):
            let outcome = await MusicAppCaptureProbe.run(promptForPermission: prompt, log: log)
            log("OUTCOME\n\(outcome)")
        case .spotify:
            await SpotifyCaptureExperiment.run(log: log)
        case .catalog(let term, let play, let toEnd):
            await CatalogPlaybackExperiment.run(term: term, play: play, toEnd: toEnd, log: log)
        }
    }
}

private final class ExperimentLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        } else {
            handle = nil
        }
    }

    func write(_ line: String) {
        let stamped = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(line)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(stamped.utf8))
        handle?.write(Data(stamped.utf8))
    }
}

@available(macOS 14.2, *)
private enum SpotifyCaptureExperiment {
    static let bundleID = "com.spotify.client"

    static func run(log: @escaping @Sendable (String) -> Void) async {
        let defaultOut = CAProbe.defaultOutputUID() ?? "-"
        log("default output uid=\(defaultOut)")
        let all = AudioProcessDirectory.snapshot()
        for p in all where p.isRunningOutput || p.belongs(toApp: bundleID) {
            log(TapProbe.describe(p) + " output=\(p.isRunningOutput) devices=\(CAProbe.deviceUIDs(of: p.objectID).joined(separator: ","))")
        }
        let spotify = all.filter { $0.belongs(toApp: bundleID) && !$0.isCurrentProcess }
        for p in spotify {
            let m = await TapProbe.measure(.processObjects([p.objectID]), seconds: 3)
            log("single pid=\(p.pid) bundle=\(p.bundleID ?? "-"): \(m)")
        }
        for mute in [AppAudioTapSource.MuteBehavior.mutedWhenTapped, .unmuted] {
            let m = await TapProbe.measure(.apps(bundleIDs: [bundleID]), seconds: 3, muteBehavior: mute)
            log("hub target (\(mute)): \(m)")
        }
        let g = await TapProbe.measure(.systemExcludingSelf(alsoExcludingApps: []), seconds: 3, muteBehavior: .unmuted)
        log("system minus Multicast (unmuted): \(g)")
    }
}

/// Small Core Audio property reads for the experiment.
private enum CAProbe {
    static func defaultOutputUID() -> String? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return uid(of: id)
    }

    static func uid(of device: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// The devices a process is playing to (`kAudioProcessPropertyDevices`, output scope).
    static func deviceUIDs(of process: AudioObjectID) -> [String] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                           mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(uid(of:))
    }
}

/// A catalog song through the product's own path: `LocalHub` with the Music app backend
/// (`CatalogRoutingProvider`), the hub's queue, the tap on both renderers, the local speaker.
@available(macOS 14.2, *)
private enum CatalogPlaybackExperiment {
    static let volumeCap: Float32 = 0.10
    static let playSeconds = 6

    static func run(term: String, play: Bool, toEnd: Bool = false, log: @escaping @Sendable (String) -> Void) async {
        let provider = AppleMusicProviderFactory.make(.musicApp)
        let catalog: Page<TrackItem>
        do {
            catalog = try await provider.searchCatalog(term, PageRequest(limit: 5))
        } catch {
            log("catalog search failed: \(error)")
            return
        }
        log("catalog search ok: \(catalog.items.count) song(s)")
        guard let song = catalog.items.first else { return }
        log("first result: \(song.title) / \(song.artist) id=\(song.id) duration=\(Int(song.duration))s")
        // Is it in the library? (MusicKit's library search: no Apple Events.)
        let mine = (try? await MusicKitPlayer().search(song.title, PageRequest(limit: 50)))?.items ?? []
        let owned = mine.contains { $0.title.caseInsensitiveCompare(song.title) == .orderedSame && $0.artist.caseInsensitiveCompare(song.artist) == .orderedSame }
        log("in the library: \(owned) (\(mine.count) library song(s) match the title text)")
        guard play else { return }

        guard let device = DefaultOutputDevice.current(), device.isBuiltIn else {
            log("default output is not the built-in device; refusing to play")
            return
        }
        let savedVolume = device.volume
        if let savedVolume, savedVolume > volumeCap, !device.setVolume(volumeCap) {
            log("could not cap the output volume; refusing to play")
            return
        }
        log("output builtIn=\(device.isBuiltIn) volume \(savedVolume.map { String($0) } ?? "n/a") -> \(device.volume.map { String($0) } ?? "n/a")")

        // A hub of its own, with settings in memory so nothing of the installed app's changes.
        let session = MulticastSession(configuration: LocalHub.defaultSessionConfiguration())
        let deps = HubDependencies(session: KitSession(session), sources: LiveSourceMaker(), apps: WorkspaceAppPresence(),
                                   capturableApps: ProcessTapApps(), spotify: SpotifyAppleEvents(), system: LiveSystemServices(),
                                   settings: InMemorySettingsStore(HubSettings(masterVolume: 1)))
        let hub = LocalHub(dependencies: deps)
        let player = AppleMusicHubPlayer(provider: provider)
        await hub.start()
        await hub.setMusicPlayer(player)
        _ = await player.refreshAuthorization()
        defer { if let savedVolume, savedVolume > volumeCap { _ = device.setVolume(savedVolume) } }

        var speaker: SpeakerItem?
        for _ in 0..<30 where speaker == nil {
            speaker = hub.currentState.speakers.first { $0.transport == .builtIn }
            if speaker == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let speaker else {
            log("no built-in speaker in the hub's list; stopping")
            await hub.shutdown()
            return
        }
        do {
            try await hub.perform(.setSpeakerVolume(id: speaker.id, volume: 1))
            try await hub.perform(.setSpeakerEnabled(id: speaker.id, enabled: true))
            _ = try await hub.searchCatalog(term, PageRequest(limit: 5))
            try await hub.perform(.playTrack(id: song.id, context: .catalog(query: term)))
            log("playTrack accepted")
        } catch {
            log("could not start: \(error)")
        }
        let levels = Task { () -> Float in
            var peak: Float = 0
            for await l in await hub.levels() { peak = max(peak, l.left, l.right) }
            return peak
        }
        for second in 1...playSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = hub.currentState
            let sp = s.speakers.first { $0.id == speaker.id }
            var line = "t=\(second)s source=\(s.activeSource.map { "\($0)" } ?? "none") playing=\(s.transport.isPlaying) trackID=\(s.nowPlaying?.trackID ?? "-") "
                + "queueCurrent=\(s.queue.currentID ?? "-") upNext=\(s.queue.upcomingCount) speaker=\(sp.map { "\($0.state)" } ?? "-")"
            if let tap = session.currentSource as? AppAudioTapSource {
                let st = tap.statistics
                line += " capture[\(tap.target.description)] state=\(tap.status.state) cycles=\(st.ioCycles) frames=\(st.capturedFrames) nonSilent=\(st.nonSilentCycles) rebuilds=\(st.rebuilds)"
            } else {
                line += " capture=none"
            }
            log(line)
            if toEnd, second == 1, song.duration > 10 {
                do {
                    try await hub.perform(.seek(position: song.duration - 4))
                    log("seeked to 4 s before the end")
                } catch { log("seek failed: \(error)") }
            }
        }
        try? await hub.perform(.pause)
        try? await hub.perform(.setSpeakerEnabled(id: speaker.id, enabled: false))
        try? await provider.pause()
        await hub.shutdown()
        levels.cancel()
        log("outgoing mix peak level=\(await levels.value)")
        log("stopped; output volume restored to \(savedVolume.map { String($0) } ?? "n/a")")
    }
}
