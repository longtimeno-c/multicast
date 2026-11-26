import SwiftUI
import MulticastKit // Linked for the real backend to come; nothing calls into it yet.

/// Entry point. `Multicast --snapshot <dir>` renders the review PNGs and exits; anything else
/// launches the app.
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
    @State private var model = HubModel(backend: MockHubBackend.live())
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Multicast", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: RootView.minWidth, minHeight: 600)
                .task { model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            PlaybackCommands(model: model)
        }

        MenuBarExtra("Multicast", systemImage: "hifispeaker.2.fill", isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
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
