import Foundation
import MulticastHubModel
import MulticastRemote
import UIKit

/// The real `HubConnector`: finds Macs with `HubBrowser`, talks to the chosen one through a
/// `RemoteHubBackend`, and turns the backend's link states into the `HubLink`s the screens
/// show.
///
/// - A Mac this phone holds a pairing key for is connected to as soon as it is seen (the last
///   one used first), with no pairing step.
/// - The key is deleted only by the person (Forget) or by the Mac inside the authenticated
///   session (Settings > Remotes > Remove sends a sealed revocation); the phone then goes back
///   to the list. A Mac that merely fails to prove the pairing, or says it doesn't know this
///   phone, may be any device using the Mac's public id: the phone keeps its key, shows the
///   link as lost and keeps retrying. Choosing that Mac again offers to pair.
/// - Choosing a Mac asks it for a code at once; a refused code asks for a fresh one (the Mac
///   draws a new code per attempt) and shows why the last one failed.
/// - A pairing the Mac cancelled or let expire shows as `.lost` with the Mac's reason; "Try
///   Again" asks for a new code.
actor NetworkHubConnector: HubConnector {
    static let keychainService = "io.github.longtimeno-c.multicast.remote-pairings"
    private static let lastHubKey = "MulticastRemote.lastHubID"
    private static let remoteIDKey = "MulticastRemote.remoteID"

    private let keyStore: PairingKeyStore
    private let remoteID: String
    private let remoteName: String

    private var found: [MulticastRemote.DiscoveredHub] = []
    private var link: HubLink = .searching
    private var hubSubs: [UUID: AsyncStream<[DiscoveredHub]>.Continuation] = [:]
    private var linkSubs: [UUID: AsyncStream<HubLink>.Continuation] = [:]
    private var browseTask: Task<Void, Never>?

    // The current attempt.
    private var backend: RemoteHubBackend?
    private var backendTask: Task<Void, Never>?
    private var hub: DiscoveredHub?
    private var chosenByPerson = false
    private var askedForCode = false
    private var lastWasVerifying = false
    private var attempt = 0
    private var failure: String?
    /// Macs not to reconnect to on their own until chosen again (cancelled, or pairing lost).
    private var noAutoConnect: Set<String> = []

    init(keyStore: PairingKeyStore = KeychainPairingKeyStore(service: NetworkHubConnector.keychainService),
         remoteName: String) {
        self.keyStore = keyStore
        self.remoteName = remoteName
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.remoteIDKey), !id.isEmpty {
            remoteID = id
        } else {
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Self.remoteIDKey)
            remoteID = id
        }
    }

    // MARK: Streams

    func hubs() -> AsyncStream<[DiscoveredHub]> {
        startBrowsing()
        let (stream, c) = AsyncStream.makeStream(of: [DiscoveredHub].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        hubSubs[id] = c
        c.yield(appHubs)
        c.onTermination = { [weak self] _ in Task { await self?.dropHubSub(id) } }
        return stream
    }

    func links() -> AsyncStream<HubLink> {
        startBrowsing()
        let (stream, c) = AsyncStream.makeStream(of: HubLink.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        linkSubs[id] = c
        c.yield(link)
        c.onTermination = { [weak self] _ in Task { await self?.dropLinkSub(id) } }
        return stream
    }

    private func dropHubSub(_ id: UUID) { hubSubs[id] = nil }
    private func dropLinkSub(_ id: UUID) { linkSubs[id] = nil }

    private var appHubs: [DiscoveredHub] { found.map { DiscoveredHub(id: $0.id, name: $0.name) } }

    private func set(_ new: HubLink) {
        link = new
        for c in linkSubs.values { c.yield(new) }
    }

    // MARK: Browsing

    private func startBrowsing() {
        guard browseTask == nil else { return }
        let stream = HubBrowser().hubs()
        browseTask = Task { [weak self] in
            for await list in stream { await self?.receive(list) }
        }
    }

    private func receive(_ list: [MulticastRemote.DiscoveredHub]) {
        found = list.filter(\.isCompatible)
        // For testing against one hub among several (`-MCOnlyHub "Test Hub"`): the others are
        // not seen, so a Mac this device is paired with isn't connected to by itself.
        if let only = UserDefaults.standard.string(forKey: "MCOnlyHub"), !only.isEmpty {
            found = found.filter { $0.name == only }
        }
        let hubs = appHubs
        for c in hubSubs.values { c.yield(hubs) }
        autoConnectIfPaired()
    }

    /// Reconnects by itself to a Mac this phone is paired with, preferring the last one used.
    private func autoConnectIfPaired() {
        guard backend == nil, case .searching = link else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastHubKey)
        let candidates = found.filter { !noAutoConnect.contains($0.id) && ((try? keyStore.record(for: $0.id)) ?? nil) != nil }
        guard let pick = candidates.first(where: { $0.id == last }) ?? candidates.first else { return }
        open(DiscoveredHub(id: pick.id, name: pick.name), chosenByPerson: false)
    }

    // MARK: Intents

    func connect(to hub: DiscoveredHub) {
        noAutoConnect.remove(hub.id)
        open(hub, chosenByPerson: true)
    }

    func submit(code: String) {
        backend?.submitPairingCode(code)
    }

    func cancel() async {
        if let id = hub?.id { noAutoConnect.insert(id) }
        await close()
        set(.searching)
    }

    func forget() async {
        if let id = hub?.id {
            try? keyStore.remove(peerID: id)
            if UserDefaults.standard.string(forKey: Self.lastHubKey) == id {
                UserDefaults.standard.removeObject(forKey: Self.lastHubKey)
            }
            noAutoConnect.insert(id)
        }
        await close()
        set(.searching)
    }

    private func open(_ hub: DiscoveredHub, chosenByPerson: Bool) {
        let previous = backend
        backendTask?.cancel()
        backend = nil
        if let previous { Task { await previous.stop() } }

        self.hub = hub
        self.chosenByPerson = chosenByPerson
        askedForCode = false
        lastWasVerifying = false
        attempt = 0
        failure = nil
        let config = RemoteHubBackend.Configuration(remoteID: remoteID, remoteName: remoteName, target: .hub(id: hub.id))
        let backend = RemoteHubBackend(configuration: config, keyStore: keyStore)
        self.backend = backend
        set(.connecting(hub))
        let states = backend.connectionStates()
        backend.start()
        backendTask = Task { [weak self] in
            for await s in states {
                guard !Task.isCancelled else { return }
                await self?.receive(s, from: backend)
            }
        }
    }

    private func close() async {
        backendTask?.cancel()
        backendTask = nil
        let b = backend
        backend = nil
        hub = nil
        await b?.stop()
    }

    // MARK: Backend link → HubLink

    private func receive(_ state: RemoteConnectionState, from source: RemoteHubBackend) async {
        guard source === backend, let hub else { return }
        let wasVerifying = lastWasVerifying
        lastWasVerifying = false
        switch state {
        case .idle:
            return
        case .searching, .connecting:
            if case .pairing = link { return }       // re-pairing after a refused code: stay put
            if case .connected = link { set(.lost(hub, reason: "Reconnecting\u{2026}")); return }
            if case .lost = link { return }           // the banner stays until it is back
            set(.connecting(hub))
        case .notRecognised(_, let message, _):
            if chosenByPerson && !askedForCode {
                // The person chose this Mac: offer the code at once (the key is replaced only
                // once the code shown on the real Mac has been entered).
                askedForCode = true
                failure = nil
                source.startPairing()
                set(.pairing(hub, PairingPrompt(failure: nil, attempt: attempt)))
            } else if case .pairing = link {
                return
            } else {
                set(.lost(hub, reason: message))
            }
        case .pairingNeeded(_, let message):
            if !chosenByPerson {
                // The Mac removed this phone, inside the authenticated session (the backend has
                // already dropped the key). Nothing is deleted here on an unauthenticated answer.
                noAutoConnect.insert(hub.id)
                await close()
                set(.searching)
                return
            }
            if !askedForCode || wasVerifying {
                if askedForCode, let message {
                    attempt += 1
                    failure = message
                }
                askedForCode = true
                source.startPairing()
                set(.pairing(hub, PairingPrompt(failure: failure, attempt: attempt)))
            } else {
                // The Mac cancelled the pairing, or the code expired, before one was entered.
                await close()
                set(.lost(hub, reason: message ?? "The Mac ended pairing."))
                self.hub = hub
            }
        case .pairing(_, let step):
            switch step {
            case .contactingHub:
                if case .pairing = link { return }
                set(.connecting(hub))
            case .enterCode(let message):
                if let message {
                    attempt += 1
                    failure = message
                }
                set(.pairing(hub, PairingPrompt(failure: failure, attempt: attempt)))
            case .verifying:
                lastWasVerifying = true
            }
        case .connected(let info):
            UserDefaults.standard.set(info.id, forKey: Self.lastHubKey)
            let named = DiscoveredHub(id: info.id, name: info.name)
            self.hub = named
            set(.connected(named, source))
        case .lost(let reason, _):
            set(.lost(hub, reason: reason))
        case .incompatible(let message):
            set(.lost(hub, reason: message))
        }
    }
}

extension NetworkHubConnector {
    /// The name this phone pairs under, as the Mac lists it.
    @MainActor static func deviceName() -> String {
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
    }
}
