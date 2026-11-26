import SwiftUI
import MulticastHubModel

/// Entry point. `Multicast --snapshot <dir>` renders the review PNGs and exits; anything else
/// launches the app, on the real hub unless `--mock` is given (see `LaunchOptions`).
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let path = args.indices.contains(i + 1) ? args[i + 1] : FileManager.default.currentDirectoryPath + "/snapshots"
            MainActor.assumeIsolated {
                Snapshotter.run(into: URL(fileURLWithPath: path, isDirectory: true))
            }
            exit(0)
        }
        MulticastApp.main()
    }
}

struct MulticastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let runtime = HubRuntime.shared
    private var model: HubModel { runtime.model }
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Multicast", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: RootView.minWidth, minHeight: 600)
                .task { runtime.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            PlaybackCommands(model: model)
        }

        MenuBarExtra("Multicast", systemImage: "hifispeaker.2.fill", isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(model)
                .task { runtime.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(runtime)
                .task { runtime.refreshPairedRemotes() }
        }
    }
}

/// Starts the hub at launch (even with no window open), adds files opened with Multicast to
/// Files, and tears everything down before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { HubRuntime.shared.start() }
        // `kill <pid>` quits like Quit does, through the same teardown.
        signal(SIGTERM, SIG_IGN)
        // Not on the main queue: terminating from inside a main-queue block would keep the
        // queue (and with it the teardown) from running until the block returned.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        source.resume()
        termSource = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let runtime = HubRuntime.shared
            runtime.start()
            runtime.model.addFiles(urls.filter(\.isFileURL))
            runtime.model.browsingSource = .files
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Bounded: a speaker (or an app) that never answers must not keep the app from quitting.
        let reply = ReplyOnce { sender.reply(toApplicationShouldTerminate: true) }
        Task { @MainActor in
            await HubRuntime.shared.shutdown()
            reply.fire()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply.fire() }
        return .terminateLater
    }
}

/// Runs its action the first time `fire()` is called, never again.
final class ReplyOnce {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func fire() {
        let a = action
        action = nil
        a?()
    }
}

/// The Controls menu. Play/Pause owns the space bar, as in Music, and shows it. While a text
/// field is being edited the space goes to the field instead.
struct PlaybackCommands: Commands {
    let model: HubModel

    var body: some Commands {
        CommandMenu("Controls") {
            Button(model.transport.isPlaying ? "Pause" : "Play") {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                    editor.insertText(" ", replacementRange: editor.selectedRange())
                } else {
                    model.togglePlayPause()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.canPlay)
            Button("Next") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!model.transport.canSkip || !model.canPlay)
            Button("Previous") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!model.transport.canSkip || !model.canPlay)
            Divider()
            Button("Increase Volume") { model.nudgeMasterVolume(0.05) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { model.nudgeMasterVolume(-0.05) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}
