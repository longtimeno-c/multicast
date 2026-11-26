import Foundation
import MulticastHubModel

/// A stand-in for the network connector: one made-up Mac that appears after a moment, a
/// pairing step that accepts any six digits except 000000, and silent reconnects once paired.
/// It never touches the network.
actor MockHubConnector: HubConnector {
    struct Options: Sendable {
        /// The hub this phone already holds pairing for, so it reconnects without a code.
        var isPaired = false
        /// False: the Mac is never found (the "can't find your Mac" state).
        var discovers = true
        var discoveryDelay: Duration = .milliseconds(700)
        /// The link to start from, for fixed review scenes; nil starts by browsing.
        var initialLink: InitialLink?
        /// After the first connection, drop the link this long later with a reason.
        var dropAfter: Duration?
    }

    enum InitialLink: Sendable { case pairing(PairingPrompt), connected, lost(reason: String) }

    static let studio = DiscoveredHub(id: "hub.studio-mac", name: "Studio Mac")
    /// The one code the mock refuses, so the error path can be tried by hand.
    static let refusedCode = "000000"

    private let backend: any HubBackend
    private var options: Options
    private var found: [DiscoveredHub] = []
    private var link: HubLink = .searching
    private var paired: Set<String> = []
    private var hubSubs: [UUID: AsyncStream<[DiscoveredHub]>.Continuation] = [:]
    private var linkSubs: [UUID: AsyncStream<HubLink>.Continuation] = [:]
    private var work: Task<Void, Never>?
    private var droppedOnce = false

    init(backend: any HubBackend, options: Options = Options()) {
        self.backend = backend
        self.options = options
        if options.isPaired { paired.insert(Self.studio.id) }
        switch options.initialLink {
        case .pairing(let prompt)?:
            found = [Self.studio]
            link = .pairing(Self.studio, prompt)
        case .connected?:
            found = [Self.studio]
            paired.insert(Self.studio.id)
            link = .connected(Self.studio, backend)
            if options.dropAfter != nil { Task { await self.scheduleDrop(Self.studio) } }
        case .lost(let reason)?:
            found = [Self.studio]
            paired.insert(Self.studio.id)
            droppedOnce = true
            link = .lost(Self.studio, reason: reason)
        case nil:
            break
        }
    }

    // MARK: Streams

    func hubs() -> AsyncStream<[DiscoveredHub]> {
        let (stream, c) = AsyncStream.makeStream(of: [DiscoveredHub].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        hubSubs[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.dropHubSub(id) } }
        c.yield(found)
        startIfNeeded()
        return stream
    }

    func links() -> AsyncStream<HubLink> {
        let (stream, c) = AsyncStream.makeStream(of: HubLink.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        linkSubs[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.dropLinkSub(id) } }
        c.yield(link)
        startIfNeeded()
        return stream
    }

    private func dropHubSub(_ id: UUID) { hubSubs[id] = nil }
    private func dropLinkSub(_ id: UUID) { linkSubs[id] = nil }

    private func setLink(_ new: HubLink) {
        link = new
        for c in linkSubs.values { c.yield(new) }
    }

    private func setFound(_ new: [DiscoveredHub]) {
        found = new
        for c in hubSubs.values { c.yield(new) }
    }

    // MARK: Discovery

    private var started = false

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        guard options.initialLink == nil else { return }
        browse()
    }

    private func browse() {
        work?.cancel()
        guard options.discovers else { return }
        let delay = options.discoveryDelay
        work = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.discovered()
        }
    }

    private func discovered() async {
        setFound([Self.studio])
        // Pairing already held: reconnect without asking.
        if paired.contains(Self.studio.id), case .searching = link {
            await connect(to: Self.studio)
        }
    }

    // MARK: Commands

    func connect(to hub: DiscoveredHub) async {
        work?.cancel()
        setLink(.connecting(hub))
        let isPaired = paired.contains(hub.id)
        work = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.finishConnecting(hub, isPaired: isPaired)
        }
    }

    private func finishConnecting(_ hub: DiscoveredHub, isPaired: Bool) {
        if isPaired { connected(hub) } else { setLink(.pairing(hub, PairingPrompt())) }
    }

    private func connected(_ hub: DiscoveredHub) {
        setLink(.connected(hub, backend))
        scheduleDrop(hub)
    }

    private func scheduleDrop(_ hub: DiscoveredHub) {
        guard let after = options.dropAfter, !droppedOnce else { return }
        droppedOnce = true
        work = Task { [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            await self?.drop(hub)
        }
    }

    private func drop(_ hub: DiscoveredHub) {
        setLink(.lost(hub, reason: "\(hub.name) stopped answering."))
    }

    func submit(code: String) async {
        guard case .pairing(let hub, let prompt) = link else { return }
        try? await Task.sleep(for: .milliseconds(350))
        // The link may have moved on (cancelled) while the code was in flight.
        guard case .pairing(let current, _) = link, current == hub else { return }
        let digits = code.filter(\.isNumber)
        if digits.count == prompt.codeLength, digits != Self.refusedCode {
            paired.insert(hub.id)
            connected(hub)
        } else {
            setLink(.pairing(hub, PairingPrompt(
                codeLength: prompt.codeLength,
                failure: "That code doesn\u{2019}t match. Check the code on \(hub.name) and try again.",
                attempt: prompt.attempt + 1)))
        }
    }

    func cancel() async {
        work?.cancel()
        setLink(.searching)
        if found.isEmpty { browse() }
    }

    func forget() async {
        if let hub = link.hub { paired.remove(hub.id) }
        work?.cancel()
        setLink(.searching)
        if found.isEmpty { browse() }
    }
}
