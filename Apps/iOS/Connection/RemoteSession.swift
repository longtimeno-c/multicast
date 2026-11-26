import Foundation
import MulticastHubModel
import Observation
import SwiftUI

/// The remote's top-level state: which hubs are visible, how the link to the chosen one is
/// doing, and, once connected, the `HubModel` every screen reads. Views only read this and call
/// its intents; the connector does the work.
@Observable
@MainActor
final class RemoteSession {
    private(set) var hubs: [DiscoveredHub] = []
    private(set) var link: HubLink = .searching
    /// The hub model for the connected hub. Kept through a dropped link, so the screens hold
    /// their last state while the connector reconnects, and replaced only for a different backend.
    private(set) var model: HubModel?
    /// The hub `model` belongs to.
    private(set) var hub: DiscoveredHub?
    /// Browsing has found nothing for `searchTimeout`: time to say what to check.
    private(set) var searchTimedOut = false
    /// A code is on its way to the hub.
    private(set) var isSubmittingCode = false

    let navigation: RemoteNavigation
    var reduceMotion = false

    @ObservationIgnored private let connector: HubConnector
    @ObservationIgnored private let searchTimeout: Duration
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var backendID: ObjectIdentifier?
    @ObservationIgnored private let prepare: @MainActor (HubModel) -> Void

    /// `prepare` runs once on each new `HubModel` before it starts (review scenes use it).
    init(connector: HubConnector, navigation: RemoteNavigation? = nil,
         searchTimeout: Duration = .seconds(10), prepare: @escaping @MainActor (HubModel) -> Void = { _ in }) {
        self.connector = connector
        self.navigation = navigation ?? RemoteNavigation()
        self.searchTimeout = searchTimeout
        self.prepare = prepare
    }

    // MARK: What to show

    enum Screen: Equatable { case connect, main }

    /// The hub screens once a model exists, unless the link went back to browsing or pairing.
    /// A drop or a reconnect keeps them, with a banner.
    var screen: Screen {
        guard model != nil else { return .connect }
        switch link.phase {
        case .connected, .lost, .connecting: return .main
        case .searching, .pairing: return .connect
        }
    }

    /// Shown over the hub screens while the link isn't up.
    var linkProblem: String? {
        guard screen == .main else { return nil }
        if case .lost(_, let reason) = link { return reason }
        if case .connecting(let h) = link { return "Reconnecting to \(h.name)\u{2026}" }
        if case .unreachable(let reason) = model?.availability { return reason }
        return nil
    }

    var isReconnecting: Bool {
        if case .connecting = link, screen == .main { return true }
        return false
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        let connector = connector
        tasks.append(Task { [weak self] in
            for await list in await connector.hubs() { self?.receive(hubs: list) }
        })
        tasks.append(Task { [weak self] in
            for await link in await connector.links() { self?.receive(link: link) }
        })
        armSearchTimeout()
    }

    private func receive(hubs list: [DiscoveredHub]) {
        if hubs != list {
            withAnimation(MC.Motion.state(reduceMotion)) { hubs = list }
        }
        if !list.isEmpty {
            timeoutTask?.cancel()
            if searchTimedOut { withAnimation(MC.Motion.state(reduceMotion)) { searchTimedOut = false } }
        }
    }

    private func receive(link new: HubLink) {
        // A new backend gets its model before the screen changes, in the same update as the
        // link, so the hub screens never appear without a model.
        var adopted: HubModel?
        if case .connected(let h, let backend) = new, ObjectIdentifier(backend as AnyObject) != backendID {
            let m = HubModel(backend: backend)
            m.reduceMotion = reduceMotion
            prepare(m)
            adopted = m
            backendID = ObjectIdentifier(backend as AnyObject)
            hub = h
        }
        let apply = {
            if let adopted {
                self.model?.stop()
                self.model = adopted
            }
            switch new {
            case .pairing, .connected: self.isSubmittingCode = false
            default: break
            }
            self.link = new
        }
        if new.phase != link.phase {
            // A new phase (found, pairing, connected, dropped) moves the screen, caused by the link.
            withAnimation(MC.Motion.state(reduceMotion), apply)
        } else {
            apply()
        }
        adopted?.start()
        if case .searching = new, hubs.isEmpty { armSearchTimeout() }
    }

    private func armSearchTimeout() {
        timeoutTask?.cancel()
        let timeout = searchTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            if self.hubs.isEmpty, case .searching = self.link {
                withAnimation(MC.Motion.state(self.reduceMotion)) { self.searchTimedOut = true }
            }
        }
    }

    // MARK: Intents

    func connect(_ hub: DiscoveredHub) {
        let connector = connector
        Task { await connector.connect(to: hub) }
    }

    /// Reconnect to the hub the screens belong to, now.
    func reconnect() {
        guard let hub = link.hub ?? hub else { return }
        connect(hub)
    }

    func submit(code: String) {
        isSubmittingCode = true
        let connector = connector
        Task { await connector.submit(code: code) }
    }

    func cancelPairing() {
        let connector = connector
        Task { await connector.cancel() }
    }

    /// Look again after "can't find your Mac".
    func searchAgain() {
        withAnimation(MC.Motion.state(reduceMotion)) { searchTimedOut = false }
        armSearchTimeout()
        let connector = connector
        Task { await connector.cancel() }
    }

    /// Forget this Mac: drop its pairing and go back to choosing one.
    func forget() {
        model?.stop()
        model = nil
        backendID = nil
        hub = nil
        navigation.reset()
        let connector = connector
        Task { await connector.forget() }
    }
}

/// Where the remote is looking: the tab, the music stack, and the open sheets. Kept out of the
/// views so a review scene (and the now-playing sheet's speakers button) can set it.
@Observable
@MainActor
final class RemoteNavigation {
    enum Tab: Hashable { case speakers, music }
    enum MusicRoute: Hashable { case source(SourceKind), playlist(PlaylistItem) }

    var tab: Tab = .speakers
    var musicPath: [MusicRoute] = []
    var showsNowPlaying = false
    /// Up Next, as a sheet over the tabs (the full player opens its own).
    var showsUpNext = false
    /// The speaker whose detail sheet is open.
    var speakerDetail: SpeakerTarget?

    struct SpeakerTarget: Identifiable, Hashable {
        let id: SpeakerID
    }
    /// The library search text, so a scene can start with a search.
    var librarySearch = ""

    func reset() {
        tab = .speakers
        musicPath = []
        showsNowPlaying = false
        showsUpNext = false
        speakerDetail = nil
        librarySearch = ""
    }

    /// From the full player: close it and show the speakers.
    func showSpeakers() {
        showsNowPlaying = false
        tab = .speakers
    }
}
