import Foundation
import MulticastAudio
import MulticastEngine
import MulticastSources
import notify
import os

// "iPhone only" mode: the iPhone app chooses speakers, a ReplayKit broadcast extension captures
// the phone's audio and plays it to them. The two are separate processes; everything they share
// lives here so both sides (and the tests) use the same types:
//
//   app  ── PhoneBroadcastConfiguration ──►  extension     (speakers, volumes, trims)
//   app  ◄──── PhoneBroadcastStatus ──────   extension     (capturing, per-speaker state, level)
//
// Both are small JSON files in the App Group container, with a Darwin notification on change.

public enum PhoneBroadcast {
    /// The App Group shared by the iPhone app and its broadcast extension.
    public static let appGroup = "group.io.github.longtimeno-c.multicast"
    /// The broadcast extension's bundle id (what the system's broadcast picker is pointed at).
    public static let extensionBundleID = "io.github.longtimeno-c.multicast.remote.broadcast"
}

// MARK: - What the app tells the extension

public struct PhoneBroadcastConfiguration: Codable, Equatable, Sendable {
    public struct Speaker: Codable, Equatable, Sendable, Identifiable {
        /// As discovery last saw it; the extension connects to this host and port.
        public var descriptor: SpeakerDescriptor
        public var isOn: Bool
        /// 0…1.
        public var volume: Float
        /// Sync trim; positive plays later.
        public var offsetMillis: Int

        public var id: String { descriptor.id }

        public init(descriptor: SpeakerDescriptor, isOn: Bool, volume: Float, offsetMillis: Int = 0) {
            self.descriptor = descriptor
            self.isOn = isOn
            self.volume = volume
            self.offsetMillis = offsetMillis
        }
    }

    /// Every speaker the user has set anything on; the ones that are on get the audio.
    public var speakers: [Speaker]
    public var masterVolume: Float

    public init(speakers: [Speaker] = [], masterVolume: Float = 1) {
        self.speakers = speakers
        self.masterVolume = masterVolume
    }

    public var chosen: [Speaker] { speakers.filter(\.isOn) }
}

// MARK: - What the extension tells the app

public struct PhoneBroadcastStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No broadcast has run, or the last one was cleaned up.
        case idle
        /// The broadcast began; speakers are being connected.
        case starting
        /// Running: audio buffers are arriving from the system.
        case capturing
        /// The broadcast stopped (see `endedReason` when it was not the user).
        case ended
    }

    public struct Speaker: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var state: EngineSnapshot.SinkStatus
        public var error: String?

        public init(id: String, name: String, state: EngineSnapshot.SinkStatus, error: String? = nil) {
            self.id = id
            self.name = name
            self.state = state
            self.error = error
        }
    }

    public var phase: Phase
    /// When the extension last wrote this; a running broadcast writes at least once a second.
    public var updated: Date
    public var speakers: [Speaker]
    /// Source level over the last interval, linear 0…1.
    public var peakLeft: Float
    public var peakRight: Float
    /// Audio buffers have arrived at all.
    public var hasReceivedAudio: Bool
    /// The last couple of seconds held something other than digital silence.
    public var isHearingAudio: Bool
    /// Sample rate of what the system delivers, 0 until known.
    public var inputSampleRate: Double
    public var underruns: Int
    /// Why the broadcast ended, when it ended by itself.
    public var endedReason: String?

    public init(phase: Phase = .idle, updated: Date = Date(), speakers: [Speaker] = [], peakLeft: Float = 0, peakRight: Float = 0,
                hasReceivedAudio: Bool = false, isHearingAudio: Bool = false, inputSampleRate: Double = 0, underruns: Int = 0,
                endedReason: String? = nil) {
        self.phase = phase
        self.updated = updated
        self.speakers = speakers
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.hasReceivedAudio = hasReceivedAudio
        self.isHearingAudio = isHearingAudio
        self.inputSampleRate = inputSampleRate
        self.underruns = underruns
        self.endedReason = endedReason
    }

    public static let idle = PhoneBroadcastStatus()

    /// How long a running broadcast may go without writing before it is taken for dead (the
    /// system can kill the extension without a word).
    public static let staleAfter: TimeInterval = 4

    /// Whether a broadcast is running as far as anyone can tell at `now`.
    public func isRunning(at now: Date = Date()) -> Bool {
        (phase == .starting || phase == .capturing) && now.timeIntervalSince(updated) < Self.staleAfter
    }
}

// MARK: - The shared store

/// The two files and their change notifications. Safe from any thread and either process.
public final class PhoneBroadcastStore: Sendable {
    public let directory: URL
    private let notificationPrefix: String

    /// - Parameter notificationPrefix: distinguishes stores in tests; the apps use the default.
    public init(directory: URL, notificationPrefix: String = PhoneBroadcast.appGroup) {
        self.directory = directory
        self.notificationPrefix = notificationPrefix
    }

    /// The store in the App Group container; nil when the process has no access to the group
    /// (not signed with the App Groups entitlement).
    public static func shared() -> PhoneBroadcastStore? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PhoneBroadcast.appGroup) else {
            return nil
        }
        return PhoneBroadcastStore(directory: url.appendingPathComponent("Broadcast", isDirectory: true))
    }

    private var configurationURL: URL { directory.appendingPathComponent("configuration.json") }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }
    private var configurationName: String { notificationPrefix + ".broadcast.configuration" }
    private var statusName: String { notificationPrefix + ".broadcast.status" }

    public func loadConfiguration() -> PhoneBroadcastConfiguration {
        read(PhoneBroadcastConfiguration.self, from: configurationURL) ?? PhoneBroadcastConfiguration()
    }

    public func save(_ configuration: PhoneBroadcastConfiguration) {
        write(configuration, to: configurationURL)
        notify_post(configurationName)
    }

    public func loadStatus() -> PhoneBroadcastStatus {
        read(PhoneBroadcastStatus.self, from: statusURL) ?? .idle
    }

    public func save(_ status: PhoneBroadcastStatus) {
        write(status, to: statusURL)
        notify_post(statusName)
    }

    /// Yields each time the other side saves a configuration.
    public var configurationChanges: AsyncStream<Void> { Self.notifications(named: configurationName) }
    /// Yields each time the other side saves a status.
    public var statusChanges: AsyncStream<Void> { Self.notifications(named: statusName) }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func notifications(named name: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}

// MARK: - Running a broadcast

public enum PhoneBroadcastError: Error, Equatable, Sendable, LocalizedError {
    /// The broadcast was started with no speaker turned on.
    case noSpeakers
    /// Every chosen speaker has been failing for too long.
    case noSpeakerReachable
    case alreadyRunning
    case couldNotStart(String)

    /// Plain wording: the system shows this to the user when a broadcast ends by itself.
    public var errorDescription: String? {
        switch self {
        case .noSpeakers:
            "No speakers are turned on. Open Multicast, turn on the speakers to play on, then start again."
        case .noSpeakerReachable:
            "Multicast couldn\u{2019}t reach any of your speakers. Check they\u{2019}re on, that this iPhone is on the same Wi\u{2011}Fi, and that Local Network is allowed for Multicast in Settings."
        case .alreadyRunning:
            "Multicast is already playing this iPhone\u{2019}s sound."
        case .couldNotStart(let why):
            "Multicast couldn\u{2019}t start playing: \(why)"
        }
    }
}

/// Plays a `PushedAudioSource` to the speakers in the store's configuration and keeps the
/// store's status current. This is the whole broadcast extension apart from ReplayKit itself,
/// kept here so it runs (and is tested) on the Mac with stand-in speakers.
public actor PhoneBroadcastRunner {
    public struct Options: Sendable {
        /// The session to run; discovery of local outputs is always off (the phone's own
        /// speaker would play what it is capturing).
        public var session = MulticastSession.Configuration()
        /// How often the status is refreshed while running.
        public var statusInterval: TimeInterval = 0.25
        /// The broadcast gives up when every chosen speaker has been failing this long.
        public var unreachableGrace: TimeInterval = 20
        /// Sound within this long counts as "hearing audio".
        public var audibleWindow: TimeInterval = 2

        public init() {
            session.directory.includeLocal = false
            // No fade: a broadcast starts and stops with the system's own controls.
            session.fadeSeconds = 0.05
        }
    }

    private let store: PhoneBroadcastStore
    private let source: PushedAudioSource
    private let factory: SinkProviding
    private let options: Options
    private let onFailure: @Sendable (PhoneBroadcastError) -> Void

    private var session: MulticastSession?
    private var applied = PhoneBroadcastConfiguration()
    private var tasks: [Task<Void, Never>] = []
    private var allFailedSince: Date?
    private var hasFailed = false
    private let peaks = OSAllocatedUnfairLock(initialState: (left: Float(0), right: Float(0)))

    /// - Parameter onFailure: called once if the broadcast cannot go on; the caller ends it
    ///   (`finishBroadcastWithError`) and then calls `stop`.
    public init(store: PhoneBroadcastStore, source: PushedAudioSource, factory: SinkProviding = SinkFactory(),
                options: Options = Options(), onFailure: @escaping @Sendable (PhoneBroadcastError) -> Void) {
        self.store = store
        self.source = source
        self.factory = factory
        var options = options
        options.session.directory.includeLocal = false
        self.options = options
        self.onFailure = onFailure
    }

    /// Connects the chosen speakers and starts playing whatever is pushed into the source.
    public func start() async throws {
        guard session == nil else { throw PhoneBroadcastError.alreadyRunning }
        let configuration = store.loadConfiguration()
        guard !configuration.chosen.isEmpty else {
            store.save(PhoneBroadcastStatus(phase: .ended, endedReason: PhoneBroadcastError.noSpeakers.errorDescription))
            throw PhoneBroadcastError.noSpeakers
        }
        let session = MulticastSession(configuration: options.session, factory: factory)
        self.session = session
        store.save(PhoneBroadcastStatus(phase: .starting, speakers: configuration.chosen.map {
            .init(id: $0.id, name: $0.descriptor.name, state: .connecting)
        }))
        session.start()
        session.setMasterVolume(configuration.masterVolume)
        do {
            try await session.setSource(.custom(source))
            await apply(configuration)
            try await session.play()
        } catch {
            await session.shutdown()
            self.session = nil
            let failure = PhoneBroadcastError.couldNotStart(String(describing: error))
            store.save(PhoneBroadcastStatus(phase: .ended, endedReason: failure.errorDescription))
            throw failure
        }

        let meters = session.meters
        let peaks = peaks
        tasks.append(Task {
            for await reading in meters {
                peaks.withLock {
                    $0.left = max($0.left, reading.peakLeft)
                    $0.right = max($0.right, reading.peakRight)
                }
            }
        })
        let changes = store.configurationChanges
        tasks.append(Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.reload()
            }
        })
        let interval = UInt64(options.statusInterval * 1_000_000_000)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.report()
                try? await Task.sleep(nanoseconds: interval)
            }
        })
    }

    /// Tears every speaker down and records that the broadcast ended. Safe to call twice.
    public func stop(reason: String? = nil) async {
        for task in tasks { task.cancel() }
        tasks = []
        guard let session else { return }
        self.session = nil
        await session.shutdown()
        var status = store.loadStatus()
        status.phase = .ended
        status.updated = Date()
        status.speakers = []
        status.peakLeft = 0
        status.peakRight = 0
        status.isHearingAudio = false
        status.endedReason = reason ?? status.endedReason
        store.save(status)
    }

    // MARK: Following the app

    private func reload() async {
        guard session != nil else { return }
        await apply(store.loadConfiguration())
    }

    /// Makes the session match `configuration`: speakers turned off leave, new ones join, and
    /// volumes and trims that changed are pushed.
    private func apply(_ configuration: PhoneBroadcastConfiguration) async {
        guard let session else { return }
        let before = Dictionary(applied.chosen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(configuration.chosen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in before.keys where after[id] == nil {
            await session.deselect(speakerID: id)
        }
        for speaker in configuration.chosen {
            if let old = before[speaker.id], session.selectedSpeakerIDs.contains(speaker.id) {
                if old.volume != speaker.volume { session.setVolume(speaker.volume, forSpeaker: speaker.id) }
                if old.offsetMillis != speaker.offsetMillis { session.setOffset(millis: speaker.offsetMillis, forSpeaker: speaker.id) }
            } else {
                // A speaker that cannot even be set up (the same device chosen twice, say) is
                // left out; the others play.
                try? await session.select(speaker.descriptor, volume: speaker.volume, offsetMillis: speaker.offsetMillis)
            }
        }
        if applied.masterVolume != configuration.masterVolume { session.setMasterVolume(configuration.masterVolume) }
        applied = configuration
    }

    // MARK: Reporting

    private func report() async {
        guard let session else { return }
        let now = Date()
        let engine = session.state.engine
        let stats = source.statistics
        let peak = peaks.withLock { p in
            defer { p = (0, 0) }
            return p
        }
        let audibleNanos = UInt64(options.audibleWindow * 1_000_000_000)
        let hearing = stats.lastAudibleHostNanos > 0 && HostClock.nowNanos() &- stats.lastAudibleHostNanos < audibleNanos
        store.save(PhoneBroadcastStatus(
            phase: stats.buffersPushed > 0 ? .capturing : .starting,
            updated: now,
            speakers: engine.sinks.map { .init(id: $0.id, name: $0.name, state: $0.state, error: $0.error) },
            peakLeft: peak.left,
            peakRight: peak.right,
            hasReceivedAudio: stats.buffersPushed > 0,
            isHearingAudio: hearing,
            inputSampleRate: stats.inputSampleRate,
            underruns: Int(stats.underruns)
        ))

        // Give up when nothing can be reached: a broadcast that plays nowhere only keeps the
        // red indicator on.
        let chosen = engine.sinks.filter(\.enabled)
        if !chosen.isEmpty, chosen.allSatisfy({ $0.state == .failed }) {
            let since = allFailedSince ?? now
            allFailedSince = since
            if now.timeIntervalSince(since) >= options.unreachableGrace, !hasFailed {
                hasFailed = true
                onFailure(.noSpeakerReachable)
            }
        } else {
            allFailedSince = nil
        }
    }
}
