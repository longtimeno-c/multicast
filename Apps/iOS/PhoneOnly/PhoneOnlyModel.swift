import Foundation
import MulticastHubModel
import MulticastKit
import Observation
import SwiftUI

/// What the iPhone Only screen needs from the outside: the speakers on the network, the
/// settings shared with the broadcast extension, and the extension's status. The live one
/// browses with `SpeakerDirectory` and reads the App Group; review scenes use the mock.
@MainActor
protocol PhoneOnlyService: AnyObject {
    /// False when broadcasts are started with a plain button (review scenes), not the system's picker.
    var usesSystemPicker: Bool { get }
    /// False when this build cannot share settings with the extension (no App Group).
    var canBroadcast: Bool { get }
    /// How long an empty list still counts as "looking" before it says none were found.
    var searchPatience: Duration { get }
    func speakers() -> AsyncStream<[SpeakerDescriptor]>
    func statuses() -> AsyncStream<PhoneBroadcastStatus>
    func loadConfiguration() -> PhoneBroadcastConfiguration
    func save(_ configuration: PhoneBroadcastConfiguration)
    func refresh()
    func stop()
    /// Review scenes only: start or stop the pretend broadcast.
    func toggleMockBroadcast()
}

/// State of the iPhone Only screen. Views read it and call its intents.
@Observable
@MainActor
final class PhoneOnlyModel {
    enum Capture: Equatable {
        /// Nothing is being broadcast.
        case idle
        /// A broadcast began; no audio has arrived yet.
        case starting
        /// Audio buffers are arriving. `hearing` is false while they hold only silence.
        case capturing(hearing: Bool)
        /// The last broadcast ended by itself, for this reason.
        case ended(reason: String)
    }

    private(set) var discovered: [SpeakerDescriptor] = []
    private(set) var configuration: PhoneBroadcastConfiguration
    private(set) var status: PhoneBroadcastStatus = .idle
    private(set) var hasSearched = false
    /// Re-read every second so a broadcast that died without a word stops looking alive.
    private(set) var now = Date()
    var reduceMotion = false

    let usesSystemPicker: Bool
    let canBroadcast: Bool

    @ObservationIgnored private let service: PhoneOnlyService
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// The level a speaker starts at the first time it is turned on: quiet rather than startling.
    static let firstVolume: Float = 0.3

    init(service: PhoneOnlyService) {
        self.service = service
        usesSystemPicker = service.usesSystemPicker
        canBroadcast = service.canBroadcast
        configuration = service.loadConfiguration()
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        let service = service
        tasks.append(Task { [weak self] in
            for await list in service.speakers() { self?.receive(speakers: list) }
        })
        tasks.append(Task { [weak self] in
            for await status in service.statuses() { self?.receive(status: status) }
        })
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: service.searchPatience)
            guard let self, !Task.isCancelled else { return }
            withAnimation(MC.Motion.state(self.reduceMotion)) { self.hasSearched = true }
        })
    }

    func stop() {
        for t in tasks { t.cancel() }
        tasks = []
        pendingSave?.cancel()
        service.save(configuration)
        service.stop()
    }

    private func receive(speakers list: [SpeakerDescriptor]) {
        let network = list.filter { $0.transport != .local }
        guard network != discovered else { return }
        withAnimation(MC.Motion.state(reduceMotion)) { discovered = network }
        // A remembered speaker that moved (a bridge restarted on another port): the broadcast
        // must connect where it is now.
        var changed = false
        for descriptor in network {
            if let i = configuration.speakers.firstIndex(where: { $0.id == descriptor.id }),
               configuration.speakers[i].descriptor != descriptor {
                configuration.speakers[i].descriptor = descriptor
                changed = true
            }
        }
        if changed { service.save(configuration) }
    }

    private func receive(status new: PhoneBroadcastStatus) {
        now = Date()
        guard new != status else { return }
        if new.phase != status.phase || new.speakers != status.speakers || new.isHearingAudio != status.isHearingAudio {
            withAnimation(MC.Motion.state(reduceMotion)) { status = new }
        } else {
            status = new
        }
    }

    // MARK: What to show

    var isRunning: Bool { status.isRunning(at: now) }

    var capture: Capture {
        if isRunning {
            return status.phase == .capturing ? .capturing(hearing: status.isHearingAudio) : .starting
        }
        if status.phase == .ended, let reason = status.endedReason { return .ended(reason: reason) }
        return .idle
    }

    var levels: StereoLevels {
        guard isRunning else { return .silent }
        return StereoLevels(left: status.peakLeft, right: status.peakRight)
    }

    var chosenCount: Int { configuration.chosen.count }
    var playingCount: Int { isRunning ? status.speakers.filter { $0.state == .playing }.count : 0 }
    /// True until the first search has had time to answer.
    var isSearching: Bool { !hasSearched && discovered.isEmpty }

    /// The speakers on the network, plus any turned-on speaker that is not answering now.
    var speakers: [SpeakerItem] {
        var items = discovered.map { item(for: $0, isSeen: true) }
        let seen = Set(discovered.map(\.id))
        for remembered in configuration.speakers where remembered.isOn && !seen.contains(remembered.id) {
            items.append(item(for: remembered.descriptor, isSeen: false))
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func speaker(_ id: SpeakerID) -> SpeakerItem? { speakers.first { $0.id == id } }

    private func item(for descriptor: SpeakerDescriptor, isSeen: Bool) -> SpeakerItem {
        let setting = configuration.speakers.first { $0.id == descriptor.id }
        let isOn = setting?.isOn ?? false
        // A bridge's "model" is the bridge software and Apple's are identifiers ("AudioAccessory5,1"):
        // neither helps anyone pick a speaker.
        let advertised = descriptor.model ?? descriptor.advertisedModel
        let model = descriptor.isAirConnectBridge || advertised?.contains(",") == true ? nil : advertised
        return SpeakerItem(
            id: SpeakerID(descriptor.id),
            name: descriptor.name,
            transport: descriptor.transport == .airplay2 ? .airPlay2 : .airPlay1,
            glyph: Self.glyph(for: descriptor, model: model),
            model: model,
            address: descriptor.host,
            isEnabled: isOn,
            volume: Double(setting?.volume ?? Self.firstVolume),
            state: state(for: descriptor.id, isOn: isOn),
            syncTrimMs: setting?.offsetMillis ?? 0,
            notSeenSince: isSeen ? nil : now
        )
    }

    private func state(for id: String, isOn: Bool) -> SpeakerState {
        guard isOn else { return .off }
        guard isRunning else { return .ready }
        guard let live = status.speakers.first(where: { $0.id == id }) else { return .connecting }
        switch live.state {
        case .playing: return .playing
        case .failed: return .failed(reason: Self.plain(live.error))
        case .idle, .connecting, .disabled: return .connecting
        }
    }

    /// The engine's reasons are for logs; the row says something a person can act on.
    private static func plain(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return "Not responding" }
        let lower = error.lowercased()
        if lower.contains("password") { return "Needs a password" }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("unreachable")
            || lower.contains("refused") || lower.contains("not responding") {
            return "Not responding"
        }
        return "Couldn\u{2019}t connect"
    }

    private static func glyph(for descriptor: SpeakerDescriptor, model: String?) -> SpeakerGlyph {
        let words = [model, descriptor.advertisedModel, descriptor.manufacturer, descriptor.name].compactMap { $0?.lowercased() }.joined(separator: " ")
        if ["avr", "receiver", "denon", "marantz", "yamaha", "onkyo"].contains(where: words.contains) { return .receiver }
        if words.contains("airport") { return .airportExpress }
        if words.contains("audioaccessory") || words.contains("homepod") || words.contains("sonos") { return .smartSpeaker }
        return .speaker
    }

    // MARK: Intents

    func setOn(_ on: Bool, for id: SpeakerID) {
        mutate(id) { $0.isOn = on }
        saveNow()
    }

    func setVolume(_ volume: Double, for id: SpeakerID) {
        mutate(id) { $0.volume = Float(min(1, max(0, volume))) }
        saveSoon()
    }

    func commitVolume(for id: SpeakerID) { saveNow() }

    func setSyncTrim(_ millis: Int, for id: SpeakerID) {
        let range = SpeakerItem.syncTrimRange
        mutate(id) { $0.offsetMillis = min(range.upperBound, max(range.lowerBound, millis)) }
        saveSoon()
    }

    func commitSyncTrim(for id: SpeakerID) { saveNow() }

    func refresh() { service.refresh() }

    func toggleMockBroadcast() { service.toggleMockBroadcast() }

    private func mutate(_ id: SpeakerID, _ body: (inout PhoneBroadcastConfiguration.Speaker) -> Void) {
        if let i = configuration.speakers.firstIndex(where: { $0.id == id.rawValue }) {
            body(&configuration.speakers[i])
        } else if let descriptor = discovered.first(where: { $0.id == id.rawValue }) {
            var speaker = PhoneBroadcastConfiguration.Speaker(descriptor: descriptor, isOn: false, volume: Self.firstVolume)
            body(&speaker)
            configuration.speakers.append(speaker)
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        service.save(configuration)
    }

    /// While a slider moves: at most ten saves a second, each of which the broadcast follows.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            self.service.save(self.configuration)
        }
    }
}

// MARK: - Live

/// Bonjour on the phone and the App Group shared with the broadcast extension.
@MainActor
final class LivePhoneOnlyService: PhoneOnlyService {
    let usesSystemPicker = true
    let canBroadcast: Bool
    /// Long enough for Bonjour's first answers.
    let searchPatience: Duration = .seconds(4)
    private let store: PhoneBroadcastStore
    private let directory: SpeakerDirectory

    init() {
        if let shared = PhoneBroadcastStore.shared() {
            store = shared
            canBroadcast = true
        } else {
            // Not signed with the App Group: the screen still works, a broadcast could not see it.
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = PhoneBroadcastStore(directory: fallback.appendingPathComponent("Broadcast", isDirectory: true))
            canBroadcast = false
        }
        directory = SpeakerDirectory(configuration: .init(includeNetwork: true, includeLocal: false))
    }

    func speakers() -> AsyncStream<[SpeakerDescriptor]> {
        directory.start()
        return directory.updates
    }

    func statuses() -> AsyncStream<PhoneBroadcastStatus> {
        let store = store
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(store.loadStatus())
            let changes = Task {
                for await _ in store.statusChanges { continuation.yield(store.loadStatus()) }
            }
            // A broadcast the system killed writes nothing more; the tick lets it go stale.
            let tick = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(store.loadStatus())
                }
            }
            continuation.onTermination = { _ in
                changes.cancel()
                tick.cancel()
            }
        }
    }

    func loadConfiguration() -> PhoneBroadcastConfiguration { store.loadConfiguration() }
    func save(_ configuration: PhoneBroadcastConfiguration) { store.save(configuration) }
    func refresh() { directory.refresh() }
    func stop() { directory.stop() }
    func toggleMockBroadcast() {}
}

// MARK: - Mock

/// Made-up speakers and a pretend broadcast, for review scenes. Touches neither the network
/// nor the App Group.
@MainActor
final class MockPhoneOnlyService: PhoneOnlyService {
    enum Start { case searching, noSpeakers, idle, capturing, silent, unreachable, ended }

    let usesSystemPicker = false
    let canBroadcast = true
    var searchPatience: Duration { start == .searching ? .seconds(600) : .zero }
    private var configuration: PhoneBroadcastConfiguration
    private let found: [SpeakerDescriptor]
    private var status: PhoneBroadcastStatus
    private var statusSubs: [UUID: AsyncStream<PhoneBroadcastStatus>.Continuation] = [:]
    private var meter: Task<Void, Never>?
    private let start: Start

    static let kitchen = descriptor("a1b2c3000001", "Kitchen", model: "Sonos One", transport: .airplay2)
    static let livingRoom = descriptor("a1b2c3000002", "Living Room", model: "Denon AVR-X2800H", transport: .airplay2)
    static let bedroom = descriptor("a1b2c3000003", "Bedroom", model: "AirPort Express", transport: .airplay1)
    static let study = descriptor("a1b2c3000004", "Study", model: "HomePod mini", transport: .airplay2)

    private static func descriptor(_ id: String, _ name: String, model: String, transport: SpeakerDescriptor.Transport) -> SpeakerDescriptor {
        SpeakerDescriptor(id: id, name: name, transport: transport, host: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).local",
                          port: 7000, model: model)
    }

    init(start: Start) {
        self.start = start
        found = start == .searching || start == .noSpeakers ? [] : [Self.kitchen, Self.livingRoom, Self.bedroom, Self.study]
        let on = start != .searching && start != .noSpeakers
        configuration = PhoneBroadcastConfiguration(speakers: on ? [
            .init(descriptor: Self.kitchen, isOn: true, volume: 0.35),
            .init(descriptor: Self.livingRoom, isOn: true, volume: 0.5, offsetMillis: -40),
            .init(descriptor: Self.bedroom, isOn: start == .capturing, volume: 0.25),
        ] : [])
        switch start {
        case .capturing: status = Self.running(configuration, hearing: true)
        case .silent: status = Self.running(configuration, hearing: false)
        case .unreachable:
            var s = Self.running(configuration, hearing: true)
            s.speakers = s.speakers.map { .init(id: $0.id, name: $0.name, state: .failed, error: "connection timed out") }
            status = s
        case .ended:
            status = PhoneBroadcastStatus(phase: .ended, endedReason: PhoneBroadcastError.noSpeakerReachable.errorDescription)
        default: status = .idle
        }
    }

    private static func running(_ configuration: PhoneBroadcastConfiguration, hearing: Bool) -> PhoneBroadcastStatus {
        PhoneBroadcastStatus(
            phase: .capturing,
            updated: .distantFuture,
            speakers: configuration.chosen.enumerated().map { index, speaker in
                // The third speaker is still joining, so the scene shows that state too.
                .init(id: speaker.id, name: speaker.descriptor.name, state: index == 2 ? .connecting : .playing)
            },
            peakLeft: hearing ? 0.42 : 0, peakRight: hearing ? 0.36 : 0,
            hasReceivedAudio: true, isHearingAudio: hearing, inputSampleRate: 44_100)
    }

    func speakers() -> AsyncStream<[SpeakerDescriptor]> {
        let found = found
        return AsyncStream { $0.yield(found) }
    }

    func statuses() -> AsyncStream<PhoneBroadcastStatus> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            statusSubs[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.statusSubs[id] = nil } }
        }
    }

    private func publish(_ new: PhoneBroadcastStatus) {
        status = new
        for c in statusSubs.values { c.yield(new) }
    }

    func loadConfiguration() -> PhoneBroadcastConfiguration { configuration }

    func save(_ new: PhoneBroadcastConfiguration) {
        configuration = new
        if status.phase == .capturing || status.phase == .starting {
            var s = status
            s.speakers = new.chosen.map { .init(id: $0.id, name: $0.descriptor.name, state: .playing) }
            publish(s)
        }
    }

    func refresh() {}
    func stop() { meter?.cancel() }

    func toggleMockBroadcast() {
        meter?.cancel()
        if status.phase == .capturing || status.phase == .starting {
            publish(PhoneBroadcastStatus(phase: .ended))
            return
        }
        var s = Self.running(configuration, hearing: true)
        s.phase = .starting
        s.hasReceivedAudio = false
        s.isHearingAudio = false
        s.speakers = s.speakers.map { .init(id: $0.id, name: $0.name, state: .connecting) }
        publish(s)
        meter = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            var step = 0.0
            while !Task.isCancelled, let self {
                var s = Self.running(self.configuration, hearing: true)
                s.speakers = s.speakers.map { .init(id: $0.id, name: $0.name, state: .playing) }
                s.peakLeft = Float(0.35 + 0.2 * sin(step))
                s.peakRight = Float(0.33 + 0.2 * sin(step + 0.7))
                self.publish(s)
                step += 0.6
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}
