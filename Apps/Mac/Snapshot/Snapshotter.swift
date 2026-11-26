import AppKit
import SwiftUI

/// Renders the review PNGs off-screen at 2x, without Screen Recording permission: each view is
/// hosted in an NSHostingView inside a window parked off-screen, laid out at size, and drawn
/// with `cacheDisplay`. Window chrome and materials aren't part of a view, so they're absent.
@MainActor
enum Snapshotter {
    static let windowSize = CGSize(width: 1180, height: 780)
    /// The smallest window the app allows, to prove nothing truncates or squeezes there.
    static let minimumSize = CGSize(width: RootView.minWidth, height: 600)

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

            let popoverModel = model(for: .spotify)
            let popover = "popover-speaker-detail-\(suffix).png"
            render(SpeakerDetailView(speakerID: MockData.jbl)
                    .environment(popoverModel)
                    .background(MC.Surface.raised),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(popover))
            written.append(popover)

            let menuModel = model(for: .appleMusic)
            let menu = "menubar-panel-\(suffix).png"
            render(MenuBarPanel(solidBackground: true).environment(menuModel),
                   size: nil, appearance: appearance, to: directory.appendingPathComponent(menu))
            written.append(menu)
        }
        for file in written { print(directory.appendingPathComponent(file).path) }
    }

    private static let artwork = MockData.artwork

    private static func model(for scene: MockScene) -> HubModel {
        let state = scene.state
        return HubModel(backend: MockHubBackend(state: state, artwork: artwork), state: state, artwork: artwork,
                        levels: scene.levels, browsing: scene.browsing)
    }

    private static func fileName(_ scene: MockScene) -> String {
        switch scene {
        case .idle: "idle-no-speakers"
        case .appleMusic: "apple-music-playing"
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
        let style: NSWindow.StyleMask = size == nil ? [.borderless] : [.titled, .fullSizeContentView]
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
