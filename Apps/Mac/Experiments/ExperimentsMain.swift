import AppKit
import CoreAudio
import Foundation
import MulticastAppleMusic
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
/// Launch with `open` so the app (not the terminal) is the process TCC asks about. The log goes
/// to `--experiment-log` (stdout is lost under `open`) and to stdout.
@_cdecl("MulticastExperimentsMain")
func multicastExperimentsMain() {
    let args = CommandLine.arguments
    let kind: ExperimentKind
    if args.contains("--music-experiment") {
        kind = .musicKit(preferCatalog: args.contains("--catalog"), prompt: !args.contains("--no-prompt"))
    } else if args.contains("--music-app-experiment") {
        kind = .musicApp(prompt: !args.contains("--no-prompt"))
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

    var description: String {
        switch self {
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
