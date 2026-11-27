import AppKit
import SwiftUI
import MulticastAppleMusic
import MulticastHub
import MulticastHubModel
import MulticastRemote
import os

/// What the app runs on, chosen once at launch from its arguments.
///
/// - (default) the real hub: `LocalHub` over MulticastKit, with the Apple Music player
///   connected, served to paired iPhone remotes by a `HubServer`.
/// - `--mock`: the mock hub (no audio, no network), as the snapshots use.
/// - `--pairing-code-log <file>`: also writes each pairing code the Mac shows to `<file>`
///   (mode 0600), so a scripted test can pair without reading the screen. Off by default.
struct LaunchOptions {
    var useMock = false
    var pairingCodeLog: URL?

    init(arguments: [String]) {
        useMock = arguments.contains("--mock")
        if let i = arguments.firstIndex(of: "--pairing-code-log"), arguments.indices.contains(i + 1) {
            pairingCodeLog = URL(fileURLWithPath: arguments[i + 1])
        }
    }
}

/// Owns the hub for the app's lifetime: the backend the windows and the menu-bar extra share,
/// the server remotes reach it through, the pairing prompt, and an orderly teardown at quit.
@MainActor
@Observable
final class HubRuntime {
    static let shared = HubRuntime(options: LaunchOptions(arguments: CommandLine.arguments))

    let model: HubModel
    let isMock: Bool
    /// The pairing code on show, while a remote is pairing.
    private(set) var pairingPrompt: PairingPrompt?
    private(set) var pairedRemotes: [PairedRemote] = []
    /// Why remotes can't reach this Mac, when the server could not start.
    private(set) var remoteProblem: String?
    /// The remote server was refused by Local Network privacy (macOS answers NoAuth). The hub
    /// keeps trying, so turning access on in System Settings takes effect without a relaunch.
    private(set) var localNetworkBlocked = false
    let hubName: String

    @ObservationIgnored private let hub: LocalHub?
    @ObservationIgnored private let musicPlayer: AppleMusicHubPlayer?
    @ObservationIgnored private var server: HubServer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pairingPanel: NSPanel?
    @ObservationIgnored private let codeLog: URL?
    @ObservationIgnored private var serverRetry: Task<Void, Never>?
    /// Failed starts in a row; the wait before the next one doubles with each (see `serverFailed`).
    @ObservationIgnored private var serverFailures = 0
    @ObservationIgnored private var servingSince: Date?
    @ObservationIgnored private var lastServerAttempt = Date.distantPast
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    @ObservationIgnored private let log = Logger(subsystem: "io.github.longtimeno-c.multicast", category: "hub")

    static let hubKeychainService = "io.github.longtimeno-c.multicast.hub-pairings"

    init(options: LaunchOptions) {
        codeLog = options.pairingCodeLog
        hubName = Host.current().localizedName ?? "Mac"
        if options.useMock {
            isMock = true
            hub = nil
            musicPlayer = nil
            model = HubModel(backend: MockHubBackend.live())
            return
        }
        isMock = false
        var session = LocalHub.defaultSessionConfiguration()
        let latencyMs = UserDefaults.standard.object(forKey: SettingsKey.groupLatency) as? Int ?? 2000
        session.engine.latencyNanos = UInt64(min(max(latencyMs, 500), 5000)) * 1_000_000
        let hub = LocalHub.live(sessionConfiguration: session)
        self.hub = hub
        if #available(macOS 14.2, *) {
            let kind = AppleMusicBackendKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appleMusicBackend) ?? "")
                ?? .musicApp
            musicPlayer = AppleMusicHubPlayer(provider: AppleMusicProviderFactory.make(kind))
        } else {
            musicPlayer = nil
        }
        model = HubModel(backend: hub)
    }

    /// Starts the model, and on the real backend the hub, the Apple Music player and the
    /// server for remotes. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        model.start()
        guard let hub else { return }
        let musicPlayer = musicPlayer
        tasks.append(Task {
            await hub.start()
            self.log.info("hub started")
            await self.startServer(backend: hub)
            // After the server: reading the player's permission can take a while.
            if let musicPlayer { await hub.setMusicPlayer(musicPlayer) }
        })
    }

    private func startServer(backend: LocalHub) async {
        let config = HubServer.Configuration(hubID: Self.stableHubID(), name: hubName)
        // Keychain reads can block on an access prompt (ad hoc builds): they happen once, on a
        // queue of their own, and handshakes are answered from memory.
        let keys = CachingPairingKeyStore(wrapping: KeychainPairingKeyStore(service: Self.hubKeychainService))
        // A paired iPhone that offers itself becomes a speaker of this hub.
        let phones = RemoteSpeakerHost(
            add: { [backend] descriptor, sink, onDevice in
                await backend.addExternalSpeaker(descriptor, sink: sink, volumeOnDevice: onDevice)
            },
            remove: { [backend] id in await backend.removeExternalSpeaker(id: id) })
        let server = HubServer(backend: backend, configuration: config, keyStore: keys, speakerHost: phones)
        self.server = server
        tasks.append(Task { [weak self] in
            await keys.load()
            self?.refreshPairedRemotes()
        })
        let events = server.events()
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        await startListening(server)
        refreshPairedRemotes()
    }

    private func startListening(_ server: HubServer) async {
        lastServerAttempt = Date()
        do {
            let port = try await server.start()
            log.info("serving remotes on port \(port, privacy: .public)")
            servingSince = Date()
            tasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.noteServing()
            })
        } catch {
            log.error("remote server failed: \(String(describing: error), privacy: .public)")
            serverFailed(String(describing: error))
        }
    }

    /// Says why remotes can't connect, and tries again shortly: a refusal by Local Network
    /// privacy clears as soon as access is turned on, and a network that was down comes back.
    ///
    /// The listener can report ready and be refused moments later (NoAuth arrives after the
    /// Bonjour registration), so a start counts as good only once it has served for 30 s. Until
    /// then each retry waits twice as long as the last: 10 s, 20 s, 40 s … up to 5 minutes, so a
    /// refused app doesn't re-register its service over and over. Coming back to the app (from
    /// System Settings, say) retries at once.
    private func serverFailed(_ reason: String) {
        if let since = servingSince, Date().timeIntervalSince(since) >= 30 { serverFailures = 0 }
        servingSince = nil
        serverFailures += 1
        let blocked = reason.contains("Local Network") || reason.contains("NoAuth")
        localNetworkBlocked = blocked
        remoteProblem = blocked
            ? "iPhones can\u{2019}t find this Mac: Local Network access is off for Multicast. Turn it on in Privacy & Security."
            : "iPhone remotes can\u{2019}t connect: \(reason)"
        let delay = min(300, 10 * pow(2, Double(min(serverFailures - 1, 5))))
        scheduleServerRetry(after: delay)
        watchForReturnToApp()
    }

    private func scheduleServerRetry(after seconds: TimeInterval) {
        guard let server else { return }
        serverRetry?.cancel()
        log.info("remote server retry in \(Int(seconds), privacy: .public) s (failure \(self.serverFailures, privacy: .public))")
        serverRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.serverRetry = nil
            self.log.info("restarting remote server")
            await self.startListening(server)
        }
    }

    /// While remotes can't connect, returning to the app retries at once (at most every 5 s).
    private func watchForReturnToApp() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.serverRetry != nil, Date().timeIntervalSince(self.lastServerAttempt) >= 5 else { return }
                self.scheduleServerRetry(after: 0)
            }
        }
    }

    /// Clears the warning once the server has stayed up, so a refusal that follows "ready"
    /// doesn't flash the warning away and back.
    private func noteServing() {
        guard let since = servingSince, Date().timeIntervalSince(since) >= 5 else { return }
        remoteProblem = nil
        localNetworkBlocked = false
    }

    /// A random id, made once and kept, so remotes recognise this Mac across launches and
    /// renames.
    private static func stableHubID() -> String {
        let key = "MulticastHub.hubID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Remotes

    private func handle(_ event: HubServerEvent) {
        switch event {
        case .pairingRequested(let prompt):
            pairingPrompt = prompt
            writeCodeLog(prompt.code)
            showPairingPanel()
        case .pairingEnded(let id, _, _):
            if pairingPrompt?.id == id {
                pairingPrompt = nil
                closePairingPanel()
            }
            refreshPairedRemotes()
        case .remoteConnected, .remoteDisconnected:
            refreshPairedRemotes()
        case .stopped(let reason):
            log.error("remote server stopped: \(reason, privacy: .public)")
            serverFailed(reason)
        }
    }

    func cancelPairing() {
        server?.cancelPairing()
    }

    func revoke(_ remote: PairedRemote) {
        do { try server?.revoke(remoteID: remote.id) } catch {
            model.alert = HubAlert(title: "Couldn\u{2019}t remove \(remote.name)", message: error.localizedDescription)
        }
        refreshPairedRemotes()
    }

    func refreshPairedRemotes() {
        guard let server else { return }
        pairedRemotes = (try? server.pairedRemotes()) ?? []
    }

    private func writeCodeLog(_ code: String) {
        guard let codeLog else { return }
        FileManager.default.createFile(atPath: codeLog.path, contents: Data((code + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// The code shows in a panel of its own, so it appears whether or not the main window is
    /// open (the app may be living in the menu bar).
    private func showPairingPanel() {
        if pairingPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                                styleMask: [.titled], backing: .buffered, defer: true)
            panel.title = "Pair iPhone"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: PairingPanelContent(runtime: self))
            pairingPanel = panel
        }
        guard let panel = pairingPanel else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 240))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePairingPanel() {
        pairingPanel?.orderOut(nil)
    }

    // MARK: Quit

    /// Stops serving remotes, then tears the hub down: speakers disconnected, capture taps and
    /// their aggregate devices destroyed, the engine stopped.
    func shutdown() async {
        closePairingPanel()
        serverRetry?.cancel()
        serverRetry = nil
        for t in tasks { t.cancel() }
        tasks.removeAll()
        model.stop()
        await server?.stop()
        await (server?.keyStore as? CachingPairingKeyStore)?.flush()
        server = nil
        await hub?.shutdown()
        musicPlayer?.close()
        log.info("hub shut down")
    }
}

/// The pairing panel: who is asking, and the code to type on that iPhone.
private struct PairingPanelContent: View {
    let runtime: HubRuntime

    var body: some View {
        Group {
            if let prompt = runtime.pairingPrompt {
                PairingCodeView(remoteName: prompt.remoteName, code: prompt.code, expiresAt: prompt.expiresAt,
                                onCancel: runtime.cancelPairing)
            } else {
                Color.clear.frame(width: 360, height: 1)
            }
        }
    }
}

/// Six digits, big and spaced in two groups of three, under one line saying where to type them.
struct PairingCodeView: View {
    var remoteName: String
    var code: String
    var expiresAt: Date
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: MC.Space.l) {
            VStack(spacing: MC.Space.xs) {
                // The name is whatever the device sent: say so rather than assert it.
                Text("An iPhone called \u{201C}\(remoteName)\u{201D} wants to pair")
                    .font(MC.Font.title)
                    .foregroundStyle(MC.Ink.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Enter this code only on your own iPhone.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(Self.grouped(code))
                .font(.system(size: 44, weight: .medium, design: .rounded).monospacedDigit())
                .tracking(4)
                .foregroundStyle(MC.Ink.primary)
                .textSelection(.enabled)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded()))
                    Text(left > 0 ? "Expires in \(MC.Format.time(TimeInterval(left)))" : "Expired")
                        .font(MC.Font.captionValue)
                        .foregroundStyle(MC.Ink.tertiary)
                }
                Spacer(minLength: MC.Space.m)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(MC.Space.xxl)
        .frame(width: 360)
        .background(MC.Surface.canvas)
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3))\u{2009}\(code.suffix(3))"
    }
}
