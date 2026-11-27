import Foundation
import MulticastAudio
import MulticastDiscovery
import MulticastEngine
import MulticastLocalOutput
import MulticastRAOP
import MulticastSources
import os

/// Everything a UI needs to draw the app, in one Codable value.
public struct SessionState: Codable, Sendable, Equatable {
    /// Every speaker that can be picked (local outputs first, then network speakers).
    public var speakers: [SpeakerDescriptor]
    /// Ids of the speakers in the current group, in the order they were added.
    public var selectedSpeakerIDs: [String]
    /// The engine: transport, source, master volume and per-speaker state/volume/offset.
    public var engine: EngineSnapshot
    /// Increases with every published change of ANY part of this state (speaker list, selection
    /// or engine), so a remote receiving states out of order can drop stale ones.
    public var revision: UInt64
    /// Network speakers still listed that stopped answering discovery, with when they went
    /// (see `SpeakerRoster`). Empty for speakers that are answering.
    public var notSeenSince: [String: Date]

    public init(speakers: [SpeakerDescriptor], selectedSpeakerIDs: [String], engine: EngineSnapshot, revision: UInt64 = 0,
                notSeenSince: [String: Date] = [:]) {
        self.speakers = speakers
        self.selectedSpeakerIDs = selectedSpeakerIDs
        self.engine = engine
        self.revision = revision
        self.notSeenSince = notSeenSince
    }

    private enum CodingKeys: String, CodingKey { case speakers, selectedSpeakerIDs, engine, revision, notSeenSince }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speakers = try c.decode([SpeakerDescriptor].self, forKey: .speakers)
        selectedSpeakerIDs = try c.decode([String].self, forKey: .selectedSpeakerIDs)
        engine = try c.decode(EngineSnapshot.self, forKey: .engine)
        revision = try c.decode(UInt64.self, forKey: .revision)
        notSeenSince = try c.decodeIfPresent([String: Date].self, forKey: .notSeenSince) ?? [:]
    }
}

/// Live counters for one selected speaker (for a status line or a debug panel).
public struct SinkDiagnostics: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: SinkFactory.Kind
    // Network (RAOP) sinks
    public var packetsSent: Int?
    public var sendErrors: Int?
    public var resendRequests: Int?
    public var packetsResent: Int?
    public var resendMisses: Int?
    public var timingRequestsAnswered: Int?
    public var syncPacketsSent: Int?
    /// The receiver's own Audio-Latency header, if it sent one (frames).
    public var receiverAudioLatencyFrames: Int?
    // Local sinks
    public var renderCallbacks: UInt64?
    /// Smoothed difference between where the output is and where the timeline says it should be.
    public var syncErrorMillis: Double?
    public var rateCorrectionPPM: Double?
    public var underrunFrames: UInt64?
    public var outputLatencyMillis: Double?
}

/// The façade the macOS and iOS apps drive: one engine, one speaker directory, one sink factory.
///
/// - Speakers are selected and deselected by id; their sinks are created and added to (or removed
///   from) the engine live, mid-playback included.
/// - Selecting two advertisements of the same physical device (an AirConnect bridge and the
///   native AirPlay 2 receiver it bridges to) is refused.
/// - Sources are wrapped in a `FadingSource`, so `stop(fadeOut:)` fades instead of clicking.
/// - `state`/`updates` merge the directory's speaker list with the engine snapshot.
///
/// UI-framework free; an `@Observable` view model can simply iterate `updates` and copy `state`.
public final class MulticastSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var engine: MulticastEngine.Configuration = .init()
        public var directory: SpeakerDirectory.Configuration = .init()
        /// Volume a newly selected speaker starts at, unless `select` is given one.
        public var defaultSpeakerVolume: Float = 0.5
        /// Fade applied to every source at its start and on `stop(fadeOut: true)`.
        public var fadeSeconds: TimeInterval = 0.5
        /// Allow selecting two advertisements of one physical device (normally refused).
        public var allowSamePhysicalDevice: Bool = false
        /// Backoff for retrying a failed network speaker while playing; nil turns it off.
        public var reconnectDelays: [TimeInterval]? = [2, 5, 10, 20, 30]

        public init() {}
    }

    public enum Source: Sendable {
        /// A sine tone. `duration` nil plays until stopped.
        case tone(frequency: Double = 440, amplitude: Double = 0.125, duration: TimeInterval? = nil)
        /// An audio file AVFoundation can read (decoded and resampled to the pipeline format).
        case file(URL)
        #if os(macOS)
        /// Capture of other apps' audio through a Core Audio process tap (macOS 14.2+).
        case capture(CaptureTarget)
        #endif
        /// Any other `AudioSource`.
        case custom(AudioSource)
    }

    #if os(macOS)
    public enum CaptureTarget: Sendable, Equatable {
        /// One app by bundle id (its helper processes included).
        case app(bundleID: String)
        /// Everything this Mac plays except this process.
        case system
    }
    #endif

    public enum SessionError: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownSpeaker(String)
        case samePhysicalDevice(String, String)
        case sinkCreationFailed(String, String)
        case unsupportedSource(String)
        /// `shutdown()` was called; this session cannot be used again (make a new one).
        case shutDown

        public var description: String {
            switch self {
            case .shutDown: return "The session was shut down"
            case .unknownSpeaker(let s): return "No speaker with id \(s)"
            case .samePhysicalDevice(let a, let b): return "\"\(a)\" and \"\(b)\" are the same physical device; play to only one of them"
            case .sinkCreationFailed(let s, let why): return "Cannot open \(s): \(why)"
            case .unsupportedSource(let why): return why
            }
        }
    }

    public let configuration: Configuration
    public let engine: MulticastEngine
    public let directory: SpeakerDirectory
    public let factory: SinkProviding

    private struct Selection {
        var order: [String] = []
        var descriptors: [String: SpeakerDescriptor] = [:]
        var sinks: [String: AudioSink] = [:]
        var source: FadingSource?
        var tasks: [Task<Void, Never>] = []
        var started = false
    }

    private let selection = OSAllocatedUnfairLock(initialState: Selection())
    /// Speakers that come with their own sink (a paired iPhone), in the order they were added.
    private let externals = OSAllocatedUnfairLock(uncheckedState: [(descriptor: SpeakerDescriptor, sink: any AudioSink)]())
    private let broadcaster: Broadcaster<SessionState>
    /// select/deselect run one at a time, so a deselect can never overtake the engine add of an
    /// in-flight select of the same speaker (which would leave it playing but untracked).
    private let membership = AsyncFIFO()
    private let isShutDown = OSAllocatedUnfairLock(initialState: false)
    private let reconnects = OSAllocatedUnfairLock(initialState: ReconnectSchedule())

    public init(configuration: Configuration = Configuration(),
                directory: SpeakerDirectory? = nil,
                factory: SinkProviding = SinkFactory()) {
        self.configuration = configuration
        self.engine = MulticastEngine(configuration: configuration.engine)
        self.directory = directory ?? SpeakerDirectory(configuration: configuration.directory)
        self.factory = factory
        broadcaster = Broadcaster(SessionState(speakers: [], selectedSpeakerIDs: [], engine: engine.snapshot))
    }

    deinit {
        for t in selection.withLock({ $0.tasks }) { t.cancel() }
        broadcaster.finish()
    }

    // MARK: Lifecycle

    /// Starts speaker discovery and state publishing. Idempotent. Does nothing after `shutdown()`.
    public func start() {
        if isShutDown.withLock({ $0 }) { return }
        let go: Bool = selection.withLock {
            if $0.started { return false }
            $0.started = true
            return true
        }
        guard go else { return }
        directory.start()
        let listings = directory.listingUpdates
        let snapshots = engine.snapshots
        if let delays = configuration.reconnectDelays { reconnects.withLock { $0 = ReconnectSchedule(delays: delays) } }
        let t1 = Task { [weak self] in
            var previouslyNotSeen = Set<String>()
            for await listing in listings {
                guard let self else { return }
                self.publish {
                    $0.speakers = listing.speakers + self.externalDescriptors
                    $0.notSeenSince = listing.notSeenSince
                }
                // A speaker answering again after a gap: retry it now rather than on its backoff.
                let back = previouslyNotSeen.subtracting(listing.notSeenSince.keys)
                previouslyNotSeen = Set(listing.notSeenSince.keys)
                if !back.isEmpty { self.reconnects.withLock { r in for id in back { r.retrySoon(id, at: Date()) } } }
                await self.followEndpointChanges(listing.speakers)
            }
        }
        let t2 = Task { [weak self] in
            for await snap in snapshots {
                guard let self else { return }
                self.publish { $0.engine = snap }
            }
        }
        var started = [t1, t2]
        if configuration.reconnectDelays != nil {
            started.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self else { return }
                    await self.reconnectDue()
                }
            })
        }
        let all = started
        selection.withLock { $0.tasks += all }
    }

    /// Retries the selected network speakers that failed during playback, on their backoff.
    private func reconnectDue() async {
        let snapshot = engine.snapshot
        var failing: [String: String?] = [:]
        if snapshot.transport == .playing {
            let network: Set<String> = selection.withLock { sel in
                Set(sel.descriptors.values.filter { $0.transport != .local }.map(\.id))
            }
            for e in snapshot.sinks where e.state == .failed && network.contains(e.id) { failing[e.id] = e.error }
        }
        let failingNow = failing
        let due = reconnects.withLock { $0.due(failing: failingNow, at: Date()) }
        for id in due {
            configuration.directory.log?("reconnecting \(id)")
            await engine.retrySink(id: id)
        }
    }

    /// Browses the network again now, and retries every failed network speaker at once.
    public func refreshSpeakers() {
        directory.refresh()
        let ids = selection.withLock { Array($0.order) }
        reconnects.withLock { r in for id in ids { r.retrySoon(id, at: Date()) } }
    }

    /// Stops playback, tears every speaker down, closes the source and stops discovery.
    ///
    /// TERMINAL: the engine's state, event and meter streams are finished, so the session cannot
    /// be restarted. Afterwards `start()` does nothing and `select`, `setSource`, `play` and
    /// `seek` throw `SessionError.shutDown`. To stop playback but keep the session, use `stop()`.
    public func shutdown() async {
        isShutDown.withLock { $0 = true }
        await engine.shutdown()
        let (source, tasks): (FadingSource?, [Task<Void, Never>]) = selection.withLock {
            defer { $0 = Selection() }
            return ($0.source, $0.tasks)
        }
        if let source { await Self.close(source) }
        directory.stop()
        for t in tasks { t.cancel() }
        publish { $0.selectedSpeakerIDs = [] }
    }

    public var hasShutDown: Bool { isShutDown.withLock { $0 } }

    private func ensureUsable() throws {
        if isShutDown.withLock({ $0 }) { throw SessionError.shutDown }
    }

    /// Every published change goes through here so `revision` always increases.
    private func publish(_ body: (inout SessionState) -> Void) {
        broadcaster.update {
            body(&$0)
            $0.revision &+= 1
        }
    }

    // MARK: State

    public var state: SessionState {
        var s = broadcaster.current  // keeps the published revision
        s.engine = engine.snapshot
        let listing = directory.listing
        s.speakers = listing.speakers + externalDescriptors
        s.notSeenSince = listing.notSeenSince
        s.selectedSpeakerIDs = selection.withLock { $0.order }
        return s
    }

    /// The state now, then on every change.
    public var updates: AsyncStream<SessionState> { broadcaster.makeStream() }

    public var events: AsyncStream<EngineEvent> { engine.events }
    public var meters: AsyncStream<MeterReading> { engine.meters }

    public var selectedSpeakerIDs: [String] { selection.withLock { $0.order } }

    /// The sink built for a selected speaker (for transport-specific extras such as metadata).
    public func sink(forSpeaker id: String) -> AudioSink? { selection.withLock { $0.sinks[id] } }

    /// The source currently set (unwrapped from its fader).
    public var currentSource: AudioSource? { selection.withLock { $0.source?.underlying } }

    // MARK: Speakers

    /// Adds a speaker (by `SpeakerDescriptor.id`) to the group. While playing it joins the
    /// current timeline. Its volume is pushed before any audio reaches it.
    public func select(speakerID id: String, volume: Float? = nil, offsetMillis: Int = 0) async throws {
        guard let descriptor = directory.speaker(id: id) else { throw SessionError.unknownSpeaker(id) }
        try await select(descriptor, volume: volume, offsetMillis: offsetMillis)
    }

    /// Adds a speaker from a descriptor (e.g. one remembered from a previous launch). If discovery
    /// currently knows the same id, its fresh descriptor (current host/port) is used instead.
    public func select(_ descriptor: SpeakerDescriptor, volume: Float? = nil, offsetMillis: Int = 0) async throws {
        try ensureUsable()
        let current = directory.speaker(id: descriptor.id) ?? external(id: descriptor.id)?.descriptor ?? descriptor
        try await membership.runThrowing { [self] in
            try await selectNow(current, volume: volume, offsetMillis: offsetMillis)
        }
    }

    private func selectNow(_ descriptor: SpeakerDescriptor, volume: Float?, offsetMillis: Int) async throws {
        try ensureUsable()
        enum Outcome { case already, conflict(SpeakerDescriptor), reserved }
        let allowDup = configuration.allowSamePhysicalDevice
        let outcome: Outcome = selection.withLock {
            if $0.descriptors[descriptor.id] != nil { return .already }
            if !allowDup, let other = SpeakerMatching.physicalConflict(for: descriptor, among: Array($0.descriptors.values)) {
                return .conflict(other)
            }
            $0.descriptors[descriptor.id] = descriptor
            $0.order.append(descriptor.id)
            return .reserved
        }
        switch outcome {
        case .already: return
        case .conflict(let other): throw SessionError.samePhysicalDevice(descriptor.name, other.name)
        case .reserved: break
        }
        let sink: AudioSink
        do {
            if let own = external(id: descriptor.id)?.sink {
                sink = own
            } else if descriptor.transport == .remote {
                // Its sink is the link to the device, which no factory can make.
                throw SinkFactoryError.deviceNotConnected(speaker: descriptor.name)
            } else {
                sink = try factory.makeSink(for: descriptor)
            }
        } catch {
            unreserve(descriptor.id)
            throw SessionError.sinkCreationFailed(descriptor.name, String(describing: error))
        }
        selection.withLock { $0.sinks[descriptor.id] = sink }
        await engine.addSink(sink, volume: volume ?? configuration.defaultSpeakerVolume, offsetMillis: offsetMillis)
        publish { $0.selectedSpeakerIDs = self.selectedSpeakerIDs }
    }

    /// Removes a speaker from the group, mid-playback included (its connection is torn down).
    /// Waits for an in-flight `select` of the same speaker to finish first.
    public func deselect(speakerID id: String) async {
        await membership.run { [self] in
            let known = selection.withLock { $0.descriptors[id] != nil }
            guard known else { return }
            await engine.removeSink(id: id)
            unreserve(id)
        }
    }

    // MARK: Speakers that bring their own sink

    private var externalDescriptors: [SpeakerDescriptor] { externals.withLockUnchecked { $0.map(\.descriptor) } }

    private func external(id: String) -> (descriptor: SpeakerDescriptor, sink: any AudioSink)? {
        externals.withLockUnchecked { list in list.first { $0.descriptor.id == id } }
    }

    /// Lists a speaker that isn't found by discovery and can't be built by the factory: a paired
    /// iPhone, whose sink is the link to it. It appears among `state.speakers` and is selected
    /// like any other. Adding the same id again updates its descriptor (the phone's output
    /// changed); with a different sink, the old one is taken out of the group first.
    public func addExternalSpeaker(_ descriptor: SpeakerDescriptor, sink: any AudioSink) async {
        if isShutDown.withLock({ $0 }) { return }
        if let old = external(id: descriptor.id), old.sink !== sink { await deselect(speakerID: descriptor.id) }
        externals.withLockUnchecked { list in
            if let i = list.firstIndex(where: { $0.descriptor.id == descriptor.id }) {
                list[i] = (descriptor, sink)
            } else {
                list.append((descriptor, sink))
            }
        }
        selection.withLock { if $0.descriptors[descriptor.id] != nil { $0.descriptors[descriptor.id] = descriptor } }
        publish { $0.speakers = self.directory.listing.speakers + self.externalDescriptors }
    }

    /// The device left: its speaker is taken out of the group and off the list.
    public func removeExternalSpeaker(id: String) async {
        guard external(id: id) != nil else { return }
        await deselect(speakerID: id)
        externals.withLockUnchecked { $0.removeAll { $0.descriptor.id == id } }
        publish { $0.speakers = self.directory.listing.speakers + self.externalDescriptors }
    }

    /// Discovery re-resolved a selected network speaker on another host/port (an AirConnect
    /// bridge restarted): point its sink there, and if it had failed meanwhile, retry it.
    private func followEndpointChanges(_ list: [SpeakerDescriptor]) async {
        let moved: [String] = selection.withLock { sel in
            var moved: [String] = []
            for d in list {
                guard let old = sel.descriptors[d.id], d.transport != .local,
                      d.host != nil, d.port != nil, old.host != d.host || old.port != d.port,
                      let raop = sel.sinks[d.id] as? RAOPSink else { continue }
                raop.updateEndpoint(host: d.host, port: d.port)
                sel.descriptors[d.id] = d
                moved.append(d.id)
            }
            return moved
        }
        let snapshot = engine.snapshot
        for id in moved where snapshot.sinks.first(where: { $0.id == id })?.state == .failed {
            await engine.retrySink(id: id)
        }
    }

    private func unreserve(_ id: String) {
        selection.withLock {
            $0.descriptors[id] = nil
            $0.sinks[id] = nil
            $0.order.removeAll { $0 == id }
        }
        publish { $0.selectedSpeakerIDs = self.selectedSpeakerIDs }
    }

    // MARK: Source & transport

    /// Builds and sets a source. While playing, the group re-anchors on the new source.
    /// Returns the underlying source (e.g. a `FileSource` for seeking or metadata).
    @discardableResult
    public func setSource(_ source: Source) async throws -> AudioSource {
        try ensureUsable()
        let made = try await Self.make(source)
        let fading = FadingSource(made, fadeIn: configuration.fadeSeconds, fadeOut: configuration.fadeSeconds)
        let old: FadingSource? = selection.withLock {
            defer { $0.source = fading }
            return $0.source
        }
        do {
            try await engine.setSource(fading)
        } catch {
            selection.withLock { if $0.source === fading { $0.source = nil } }
            await Self.close(fading)
            throw error
        }
        if let old { await Self.close(old) }
        return made
    }

    private static func make(_ source: Source) async throws -> AudioSource {
        switch source {
        case .tone(let frequency, let amplitude, let duration):
            guard frequency > 0, frequency < Double(PCM.sampleRate) / 2 else {
                throw SessionError.unsupportedSource("Tone frequency must be between 0 and \(PCM.sampleRate / 2) Hz")
            }
            return ToneSource(frequency: frequency, amplitude: amplitude, duration: duration,
                              fadeIn: 0.05, fadeOut: 0.05)
        case .file(let url):
            return try await FileSource.open(url: url)
        #if os(macOS)
        case .capture(let target):
            guard #available(macOS 14.2, *) else {
                throw SessionError.unsupportedSource("App audio capture needs macOS 14.2 or later")
            }
            switch target {
            case .app(let bundleID): return AppAudioTapSource(target: .apps(bundleIDs: [bundleID]))
            case .system: return AppAudioTapSource(target: .systemExcludingSelf(alsoExcludingApps: []))
            }
        #endif
        case .custom(let s):
            return s
        }
    }

    private static func close(_ source: FadingSource) async {
        await source.stop()
        if let file = source.underlying as? FileSource { file.close() }
    }

    /// Starts or resumes. After a faded stop or `requestFadeOut()` the source is re-armed, so it
    /// plays again (with a fade-in) instead of ending at once.
    public func play() async throws {
        try ensureUsable()
        if engine.snapshot.transport != .playing, let src = selection.withLock({ $0.source }), src.isFadeOutRequested {
            src.rearm()
        }
        try await engine.play()
    }

    /// Pauses at once, without a fade: every speaker is flushed (network speakers cut where they
    /// are; local outputs apply a 64-frame declick). The audio that had been sent but not yet heard
    /// is kept, so resume continues from what was last heard (no content is skipped).
    public func pause() async { await engine.pause() }

    /// Seeks the current file source. While playing, the speakers are flushed (without keeping the
    /// pre-seek audio) and re-anchored, so the new position is heard after one group latency
    /// instead of after the ~latency of old audio already buffered. Seeking a `FileSource`
    /// directly bypasses this and is heard about one latency late.
    /// The first ~ms after the re-anchor may be silence while the file decodes at the target.
    public func seek(toSeconds seconds: TimeInterval) async throws {
        try ensureUsable()
        guard let file = currentSource as? FileSource else {
            throw SessionError.unsupportedSource("The current source cannot seek")
        }
        let wasPlaying = engine.snapshot.transport == .playing
        if wasPlaying { await engine.pause(retainUnplayedAudio: false) }
        file.seek(to: max(0, seconds))
        if wasPlaying { try await engine.play() }
    }

    /// Starts fading the current source out without waiting; the engine then reports
    /// `.endOfStream` (with the time the faded tail is audible until) and the state becomes `.ended`.
    public func requestFadeOut() {
        selection.withLock { $0.source }?.requestFadeOut()
    }

    /// Stops playback. With `fadeOut`, the source fades out first and this returns once the
    /// faded tail has been heard (about latency + fade time); otherwise it stops at once.
    public func stop(fadeOut: Bool = false) async {
        if fadeOut, engine.snapshot.transport == .playing, let src = selection.withLock({ $0.source }) {
            let events = engine.events
            src.requestFadeOut()
            let limit = HostClock.nowNanos() + engine.configuration.latencyNanos + 3_000_000_000
            await Self.waitForAudibleEnd(events: events, deadlineNanos: limit)
        }
        await engine.stop()
    }

    /// Waits for the next `.endOfStream` event and then until its tail is audible (bounded).
    public static func waitForAudibleEnd(events: AsyncStream<EngineEvent>, deadlineNanos: UInt64) async {
        let waiter = Task {
            for await e in events {
                if case .endOfStream(_, let until) = e { return until }
            }
            return UInt64(0)
        }
        let timeout = Task {
            let now = HostClock.nowNanos()
            if deadlineNanos > now { try? await Task.sleep(nanoseconds: deadlineNanos - now) }
            waiter.cancel()
        }
        let until = await waiter.value
        timeout.cancel()
        let now = HostClock.nowNanos()
        if until > now, until <= deadlineNanos { try? await Task.sleep(nanoseconds: until - now + 100_000_000) }
    }

    // MARK: Volume & sync trim

    public func setMasterVolume(_ volume: Float) { engine.setMasterVolume(volume) }
    public func setVolume(_ volume: Float, forSpeaker id: String) { engine.setVolume(volume, forSink: id) }
    public func setMuted(_ muted: Bool, forSpeaker id: String) { engine.setMuted(muted, forSink: id) }
    /// Per-speaker sync trim in ms (positive = later), e.g. for a bridge's extra delay.
    public func setOffset(millis: Int, forSpeaker id: String) { engine.setOffset(millis: millis, forSink: id) }
    public func retry(speakerID id: String) async { await engine.retrySink(id: id) }

    /// Whether a speaker lets this sender in, asked without joining the group, so no audio
    /// reaches it whatever is playing: a network speaker gets one `OPTIONS` on a connection of
    /// its own (with its password, if one is set); a local output is always admitted. The
    /// speaker's current advertisement is used when discovery has a newer one.
    public func checkAccess(_ descriptor: SpeakerDescriptor) async -> SpeakerAccessCheck {
        guard descriptor.transport != .local, descriptor.transport != .remote else { return .admitted }
        let current = directory.speaker(id: descriptor.id) ?? descriptor
        let sink: AudioSink
        do { sink = try factory.makeSink(for: current) } catch { return .inconclusive(String(describing: error)) }
        guard let raop = sink as? RAOPSink else { return .admitted }
        switch await raop.checkAccess() {
        case .admitted: return .admitted
        case .refused: return .refused
        case .inconclusive(let why): return .inconclusive(why)
        }
    }

    // MARK: Diagnostics

    public func diagnostics() -> [SinkDiagnostics] {
        let (order, sinks) = selection.withLock { ($0.order, $0.sinks) }
        return order.compactMap { id in sinks[id].map(Self.diagnostics(for:)) }
    }

    public static func diagnostics(for sink: AudioSink) -> SinkDiagnostics {
        var d = SinkDiagnostics(id: sink.id, name: sink.displayName, kind: .local)
        if let r = sink as? RAOPSink {
            let s = r.statistics
            d.kind = .raop
            d.packetsSent = s.packetsSent
            d.sendErrors = s.sendErrors
            d.resendRequests = s.resendRequests
            d.packetsResent = s.packetsResent
            d.resendMisses = s.resendMisses
            d.timingRequestsAnswered = s.timingRequestsAnswered
            d.syncPacketsSent = s.syncPacketsSent
            d.receiverAudioLatencyFrames = r.reportedAudioLatencyFrames
        } else if let l = sink as? LocalOutputSink {
            let s = l.syncStats
            d.renderCallbacks = s.callbacks
            d.syncErrorMillis = s.filteredErrorMillis
            d.rateCorrectionPPM = s.ratioPPM
            d.underrunFrames = s.underrunFrames
            d.outputLatencyMillis = l.reportedLatency.totalMillis
        }
        return d
    }
}

/// What asking a speaker whether it admits this sender found (`MulticastSession.checkAccess`).
public enum SpeakerAccessCheck: Equatable, Sendable {
    case admitted
    /// Its AirPlay access setting turns this sender away (403 Forbidden).
    case refused
    /// No trustworthy answer (unreachable, timed out): `reason` says why.
    case inconclusive(String)
}
