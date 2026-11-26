import AppKit
import Foundation
import MulticastAppleMusic

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

    var description: String {
        switch self {
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
