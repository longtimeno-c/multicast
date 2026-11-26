import Foundation
import MulticastAudio
import MulticastDiscovery
import MulticastLocalOutput
import os

/// One live list of every speaker the user can pick: this machine's audio outputs
/// (MulticastLocalOutput) followed by the AirPlay 1 / AirPlay 2 speakers on the network
/// (MulticastDiscovery). This machine's own AirPlay receiver is hidden by default.
public final class SpeakerDirectory: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var includeNetwork: Bool = true
        public var includeLocal: Bool = true
        /// Hide this machine's own AirPlay receiver advertisement.
        public var hideThisMachine: Bool = true
        /// Local device kinds that are not offered. By default the macOS "AirPlay" system output
        /// is hidden (it would route audio through the OS's own AirPlay stack a second time).
        public var hiddenLocalKinds: Set<SpeakerDescriptor.LocalKind> = [.airplaySystem]
        /// How long a network speaker that stopped answering stays listed (see `SpeakerRoster`).
        public var roster = SpeakerRoster.Policy()
        /// How often held speakers are re-checked against `roster` (marking, dropping).
        public var rosterTick: TimeInterval = 5
        /// Re-browse the network this often (fresh queries; known speakers stay listed). nil = never.
        public var rescanInterval: TimeInterval? = 45
        public var log: (@Sendable (String) -> Void)?

        public init(includeNetwork: Bool = true, includeLocal: Bool = true, hideThisMachine: Bool = true,
                    log: (@Sendable (String) -> Void)? = nil) {
            self.includeNetwork = includeNetwork
            self.includeLocal = includeLocal
            self.hideThisMachine = hideThisMachine
            self.log = log
        }
    }

    public let configuration: Configuration

    private struct Inputs {
        var roster: SpeakerRoster
        var local: [SpeakerDescriptor] = []
        var defaultLocalID: String?
        var tasks: [Task<Void, Never>] = []
        var running = false
    }

    private let inputs: OSAllocatedUnfairLock<Inputs>
    private let broadcaster = Broadcaster<[SpeakerDescriptor]>([])
    private let listingBroadcaster = Broadcaster<SpeakerRoster.Listing>(SpeakerRoster.Listing())
    private let browser: SpeakerBrowser?
    private var localDirectory: LocalOutputDirectory?
    private let localLock = NSLock()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        inputs = OSAllocatedUnfairLock(initialState: Inputs(roster: SpeakerRoster(policy: configuration.roster)))
        if configuration.includeNetwork {
            var browse = SpeakerBrowser.Configuration(hideThisMachine: configuration.hideThisMachine,
                                                      log: configuration.log)
            browse.rescanInterval = configuration.rescanInterval
            browser = SpeakerBrowser(configuration: browse)
        } else {
            browser = nil
        }
    }

    deinit {
        browser?.stop()
        localDirectory?.invalidate()
        for t in inputs.withLock({ $0.tasks }) { t.cancel() }
        broadcaster.finish()
        listingBroadcaster.finish()
    }

    // MARK: Public API

    /// Start discovery and device monitoring. Idempotent.
    public func start() {
        let shouldStart: Bool = inputs.withLock {
            if $0.running { return false }
            $0.running = true
            return true
        }
        guard shouldStart else { return }
        var tasks: [Task<Void, Never>] = []
        if let browser {
            browser.start()
            let stream = browser.snapshots
            tasks.append(Task { [weak self] in
                for await list in stream {
                    guard let self else { return }
                    self.inputs.withLock { $0.roster.observe(list, at: Date()) }
                    self.republish()
                }
            })
            let tick = configuration.rosterTick
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(tick, 0.5) * 1e9))
                    guard let self else { return }
                    self.inputs.withLock { _ = $0.roster.prune(at: Date()) }
                    self.republish()
                }
            })
        }
        if configuration.includeLocal {
            let dir: LocalOutputDirectory = localLock.withLock {
                if let d = localDirectory { return d }
                let d = LocalOutputDirectory()
                localDirectory = d
                return d
            }
            let devices = dir.updates
            let defaults = dir.defaultOutputUpdates
            tasks.append(Task { [weak self] in
                for await list in devices {
                    guard let self else { return }
                    self.inputs.withLock { $0.local = list }
                    self.republish()
                }
            })
            tasks.append(Task { [weak self] in
                for await id in defaults {
                    guard let self else { return }
                    self.inputs.withLock { $0.defaultLocalID = id }
                    self.republish()
                }
            })
        }
        let started = tasks
        inputs.withLock { $0.tasks = started }
    }

    /// Stop discovery and device monitoring. The list becomes empty; `start()` resumes.
    public func stop() {
        let tasks: [Task<Void, Never>] = inputs.withLock {
            $0.running = false
            defer { $0.tasks = []; $0.roster.reset(); $0.local = [] }
            return $0.tasks
        }
        for t in tasks { t.cancel() }
        browser?.stop()
        republish()
    }

    /// The current merged list (local outputs first, default output first among them).
    public var speakers: [SpeakerDescriptor] { broadcaster.current }

    /// The merged list now, then on every change.
    public var updates: AsyncStream<[SpeakerDescriptor]> { broadcaster.makeStream() }

    /// The merged list with the network speakers that stopped answering (still listed, see
    /// `SpeakerRoster`), now and on every change of either.
    public var listing: SpeakerRoster.Listing { listingBroadcaster.current }
    public var listingUpdates: AsyncStream<SpeakerRoster.Listing> { listingBroadcaster.makeStream() }

    /// Browse the network again now (e.g. a Refresh button). Known speakers stay listed while
    /// the fresh answers come in.
    public func refresh() { browser?.refresh() }

    public func speaker(id: String) -> SpeakerDescriptor? { speakers.first { $0.id == id } }

    /// `SpeakerDescriptor.id` of the system default output, if known.
    public var defaultLocalOutputID: String? { inputs.withLock { $0.defaultLocalID } }

    /// The last DNS-SD error (e.g. -65570 = local network access denied), if any.
    public var discoveryError: Int32? { browser?.lastError }

    /// Waits until every query resolves to exactly one speaker (see `SpeakerMatching.resolve`)
    /// or `timeout` passes, and returns the final match for each query in order.
    public func waitForSpeakers(_ queries: [String], timeout: TimeInterval) async -> [SpeakerMatching.Match] {
        let deadline = Date().addingTimeInterval(timeout)
        func matches() -> [SpeakerMatching.Match] {
            let list = speakers
            return queries.map { SpeakerMatching.resolve($0, in: list) }
        }
        var current = matches()
        while Date() < deadline {
            if current.allSatisfy({ if case .found = $0 { return true } else { return false } }) { return current }
            try? await Task.sleep(nanoseconds: 100_000_000)
            current = matches()
        }
        return current
    }

    // MARK: Merge

    private func republish() {
        let now = Date()
        let (network, local, def) = inputs.withLock { ($0.roster.listing(at: now), $0.local, $0.defaultLocalID) }
        let merged = SpeakerDirectory.merge(network: network.speakers, local: local, defaultLocalID: def,
                                            hiddenLocalKinds: configuration.hiddenLocalKinds)
        if merged != broadcaster.current { broadcaster.send(merged) }
        let listing = SpeakerRoster.Listing(speakers: merged, notSeenSince: network.notSeenSince)
        if listing != listingBroadcaster.current { listingBroadcaster.send(listing) }
    }

    /// Pure merge: local outputs first (the default output first, then by name), then network
    /// speakers in the order discovery sorted them. Ids are unique; on a clash the first wins.
    public static func merge(network: [SpeakerDescriptor], local: [SpeakerDescriptor],
                             defaultLocalID: String? = nil,
                             hiddenLocalKinds: Set<SpeakerDescriptor.LocalKind> = [.airplaySystem]) -> [SpeakerDescriptor] {
        let visibleLocal = local.filter { d in
            guard let kind = d.localKind else { return true }
            return !hiddenLocalKinds.contains(kind)
        }
        let sortedLocal = visibleLocal.enumerated().sorted { a, b in
            let aDef = a.element.id == defaultLocalID, bDef = b.element.id == defaultLocalID
            if aDef != bDef { return aDef }
            return a.offset < b.offset
        }.map(\.element)
        var seen = Set<String>()
        var out: [SpeakerDescriptor] = []
        for d in sortedLocal + network where seen.insert(d.id).inserted { out.append(d) }
        return out
    }
}
