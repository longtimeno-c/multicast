import AppKit
import SwiftUI
import MulticastHubModel

/// Renders the review PNGs off-screen at 2x, without Screen Recording permission: each view is
/// hosted in an NSHostingView inside a window parked off-screen, laid out at size, and drawn
/// with `cacheDisplay`. Window chrome and materials aren't part of a view, so they're absent.
@MainActor
enum Snapshotter {
    static let windowSize = CGSize(width: 1180, height: 780)
    /// The smallest window the app allows, to prove nothing truncates or squeezes there.
    static let minimumSize = CGSize(width: RootView.minWidth, height: 600)
    /// Tall enough that the speakers list ends on screen, "Not available to you" included.
    static let fullListSize = CGSize(width: 1180, height: 1240)

    static func run(into directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Active, so the rendered windows are key and controls draw in their active style
        // (accent checkboxes and slider fills), as people see them.
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: name)!
            app.appearance = appearance

            for scene in MockScene.allCases {
                let model = model(for: scene)
                let file = "main-\(fileName(scene))-\(suffix).png"
                render(RootView().environment(model), size: windowSize, appearance: appearance,
                       to: directory.appendingPathComponent(file))
                written.append(file)
            }

            let minimum = "main-minimum-size-\(suffix).png"
            render(RootView().environment(model(for: .appleMusic)), size: minimumSize, appearance: appearance,
                   to: directory.appendingPathComponent(minimum))
            written.append(minimum)

            // Every speaker, down to the group of those that admit only their owner.
            let fullList = "main-speakers-full-list-\(suffix).png"
            render(RootView().environment(model(for: .appleMusic)), size: fullListSize, appearance: appearance,
                   to: directory.appendingPathComponent(fullList))
            written.append(fullList)

            // Tuning a speaker's sync, at each moment worth looking at.
            for moment in MockTuning.Moment.allCases {
                let file = "tuning-\(moment.rawValue)-\(suffix).png"
                // The Sync section by itself, as wide as it is in the window (the whole panel is
                // taller than a screen, and this renderer can't draw past one).
                render(SyncCalibrationSection()
                        .environment(model(for: .appleMusic, tuning: moment))
                        .environment(\.mcTuningFrozenTime, 2.45)
                        .frame(width: 520)
                        .padding(MC.Space.xxl)
                        .background(MC.Surface.canvas),
                       size: nil, appearance: appearance, to: directory.appendingPathComponent(file))
                written.append(file)
            }

            let popoverModel = model(for: .spotify)
            let popover = "popover-speaker-detail-\(suffix).png"
            render(SpeakerDetailView(speakerID: MockData.jbl)
                    .environment(popoverModel)
                    .background(MC.Surface.raised),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(popover))
            written.append(popover)

            let restricted = "popover-speaker-restricted-\(suffix).png"
            render(SpeakerDetailView(speakerID: MockData.neighbourHomePod)
                    .environment(model(for: .appleMusic))
                    .background(MC.Surface.raised),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(restricted))
            written.append(restricted)

            let menuModel = model(for: .appleMusic)
            let menu = "menubar-panel-\(suffix).png"
            render(MenuBarPanel(solidBackground: true).environment(menuModel),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(menu))
            written.append(menu)

            let pairing = "pairing-code-\(suffix).png"
            render(PairingCodeView(remoteName: "Test iPhone", code: "482915", expiresAt: Date().addingTimeInterval(118),
                                   onCancel: {}),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(pairing))
            written.append(pairing)
        }
        for file in written { print(directory.appendingPathComponent(file).path) }
    }

    private static let artwork = MockData.artwork

    private static func model(for scene: MockScene, tuning: MockTuning.Moment? = nil) -> HubModel {
        var state = scene.state
        if let tuning {
            // A phone tunes the Bluetooth speaker; the Mac's own microphone heard the others earlier.
            let mic: SyncCalibrationStatus.Microphone = tuning == .refused ? .hub : .phone(name: "Sample iPhone")
            state.calibration = MockTuning.status(tuning, speaker: MockData.jbl, microphone: mic)
            for i in state.speakers.indices where state.speakers[i].isEnabled && !state.speakers[i].isRestricted {
                state.speakers[i].tunedAt = Date().addingTimeInterval(-86_400 * Double(i % 3))
                if i > 0 { state.speakers[i].syncTrimMs = -12 * i }
            }
            if let i = state.speakers.firstIndex(where: { $0.id == MockData.jbl }) {
                state.speakers[i].syncTrimMs = tuning == .inSync ? -172 : 0
                state.speakers[i].tunedAt = tuning == .inSync || tuning == .reference ? Date() : nil
            }
        }
        let content = scene.content
        var preload = content.preload
        if scene == .search {
            let q = MockScene.searchQuery
            func matches(_ t: TrackItem) -> Bool { t.title.localizedCaseInsensitiveContains(q) || t.artist.localizedCaseInsensitiveContains(q) }
            preload.search = (q, content.songs.filter(matches), MockData.catalogSongs.filter(matches))
        }
        return HubModel(backend: MockHubBackend(state: state, content: content, artwork: artwork), state: state,
                        preload: preload, artwork: artwork, levels: scene.levels, browsing: scene.browsing,
                        openPlaylist: scene == .playlist ? openPlaylist : nil,
                        playlistTracks: scene == .playlist ? content.playlistTracks[openPlaylist.id] ?? [] : [],
                        showsUpNext: scene == .upNext,
                        openFolderID: scene == .folder ? "f1" : nil)
    }

    /// The playlist the playlist scene opens.
    private static var openPlaylist: PlaylistItem {
        MockData.playlists.first { $0.id == "p4" } ?? MockData.playlists[0]
    }

    private static func fileName(_ scene: MockScene) -> String {
        switch scene {
        case .idle: "idle-no-speakers"
        case .appleMusic: "apple-music-playing"
        case .phoneSpeaker: "iphone-as-speaker"
        case .folder: "folder-open"
        case .playlist: "playlist-open"
        case .upNext: "up-next"
        case .search: "search-with-catalog"
        case .spotify: "spotify-capture"
        case .appPicker: "other-app-picker"
        case .firstRun: "first-run-looking-for-speakers"
        case .localNetworkDenied: "local-network-denied"
        }
    }

    /// Lays `view` out at `size` (or its fitting size) and writes a 2x PNG.
    static func render<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance, to url: URL) {
        if let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"], !url.lastPathComponent.contains(only) { return }
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let initial = size ?? hosting.fittingSize
        // The main window gets a real titled window so its toolbar and sidebar are the
        // system's; fitted panels (popover, menu-bar panel) get a bare one.
        let style: NSWindow.StyleMask = size == nil ? [.borderless]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = KeyableWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: initial),
                              styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(initial)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Let SwiftUI settle: lists populate and layout passes finish on later run-loop turns.
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // The app's window has a hidden title bar (`.windowStyle(.hiddenTitleBar)`), which a bare
        // hosting window doesn't apply: drop the toolbar it grew, as the app's window has none.
        if size != nil { window.toolbar = nil }
        let finalSize = size ?? hosting.fittingSize
        if finalSize != hosting.bounds.size {
            window.setContentSize(finalSize)
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }

        let data = captureOwnWindow(window) ?? cacheDisplay(hosting, appearance: appearance)
        try? data?.write(to: url)
        window.orderOut(nil)
        window.close()
    }

    /// The window server's composited image of our own window. SwiftUI draws through layers
    /// that `cacheDisplay` can't see, so this is the faithful path. A process may always read
    /// its own windows, so no Screen Recording permission is involved. The function is
    /// unavailable in the current SDK headers but still exported, hence the lookup.
    private static func captureOwnWindow(_ window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = createImage(.null, optionIncludingWindow, UInt32(window.windowNumber),
                                      boundsIgnoreFraming | bestResolution)?.takeRetainedValue(),
              image.width > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A borderless window can't become key by default; these must, to draw active controls.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Fallback: AppKit's own drawing. Misses most SwiftUI layer content, but never fails.
    private static func cacheDisplay(_ view: NSView, appearance: NSAppearance) -> Data? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: rep) }
        return rep.representation(using: .png, properties: [:])
    }
}
