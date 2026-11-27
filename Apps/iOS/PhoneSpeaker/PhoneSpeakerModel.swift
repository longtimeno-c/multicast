import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastRemote
import Observation
import SwiftUI

/// The part of the link to the Mac that makes this device a speaker. `RemoteHubBackend` is the
/// real one; `MockPhoneSpeakerBackend` stands in for it in the review scenes.
protocol PhoneSpeakerBackend: AnyObject, Sendable {
    func startPhoneSpeaker(route: PhoneRoute, output: any PhoneAudioOutput)
    func stopPhoneSpeaker()
    func phoneSpeakerPhases() -> AsyncStream<PhoneSpeakerPhase>
    var phoneSpeakerStats: PhoneSpeakerStats? { get }
    func phoneSpeakerOutputStopped()
    /// The Mac leaves this speaker's volume to the device (false for an older Mac, which
    /// applies it to the audio itself).
    var phoneSpeakerVolumeIsSystemVolume: Bool { get }
}

extension RemoteHubBackend: PhoneSpeakerBackend {}

/// "Play on this iPhone": the one switch, what it would play through, and how it is going.
///
/// Turning it on offers this device to the Mac as a speaker; the Mac lists it, turns it on and
/// sends it the stream. Its sync trim is the hub's, like any speaker's, kept per output. It is
/// off at every launch: an app that starts playing by itself is a surprise.
///
/// Its volume is this iPhone's own volume. The row's slider sets the system volume at once and
/// tells the Mac; the side buttons and Control Centre move the slider and tell the Mac; and a
/// change made on the Mac (its slider for this row) is written to the system volume here.
/// `DeviceVolumeReconciler` decides which way a difference goes, so the two never fight. When
/// the speaker is turned on, and when the output changes (iOS keeps a volume per output), the
/// phone's volume is the one kept. With an older Mac the volume stays the hub's, as it was.
@Observable
@MainActor
final class PhoneSpeakerModel {
    /// What the person asked for.
    private(set) var isOn = false
    private(set) var phase: PhoneSpeakerPhase = .off
    private(set) var route: PhoneRoute
    /// A call or another app has the audio session; playback waits.
    private(set) var isInterrupted = false
    /// Why it turned itself off, until the next change ("Garden Speaker disconnected").
    private(set) var notice: String?
    /// Clock, buffer and loss figures while on, refreshed every second.
    private(set) var stats: PhoneSpeakerStats?
    private(set) var outputDiagnostics: PhoneOutputDiagnostics?
    /// False on a hub link that can't carry audio (the mock connector without a backend).
    private(set) var isAvailable = false
    /// This device's system volume, as iOS last reported it.
    private(set) var deviceVolume: Double
    /// Where the row's slider is while it is being dragged.
    private var dragVolume: Double?

    /// The hub's speakers as the hub last published them: what this device's volume is
    /// compared with. Not the app model's speakers, which show a volume sent from here before
    /// the hub has taken it; the reconciler must only see what the hub itself says.
    @ObservationIgnored var hubSpeakers: (() -> [SpeakerItem])?
    /// Sends a speaker volume to the hub the way a slider does (shown at once, sent at a
    /// measured pace), and ends that the way a slider's release does.
    @ObservationIgnored var sendVolume: ((SpeakerID, Double) -> Void)?
    @ObservationIgnored var commitSentVolume: ((SpeakerID) -> Void)?

    @ObservationIgnored private let routes: any PhoneRouteMonitoring
    @ObservationIgnored private let output: any PhoneSpeakerOutput
    @ObservationIgnored private let systemVolume: any PhoneSystemVolume
    @ObservationIgnored private var reconciler = DeviceVolumeReconciler()
    @ObservationIgnored private var backend: (any PhoneSpeakerBackend)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var phaseTask: Task<Void, Never>?
    /// The hub showed this device's row as on since the last offer: a later "off" is the Mac's doing.
    @ObservationIgnored private var seenOnAtHub = false

    static let placeholderID: SpeakerID = "phone:this-device"

    init(routes: any PhoneRouteMonitoring, output: any PhoneSpeakerOutput, systemVolume: (any PhoneSystemVolume)? = nil) {
        let systemVolume = systemVolume ?? FixedSystemVolume()
        self.routes = routes
        self.output = output
        self.systemVolume = systemVolume
        deviceVolume = systemVolume.volume
        route = routes.current
        systemVolume.onChange = { [weak self] volume in self?.systemVolumeChanged(volume) }
        output.onInterruption = { [weak self] interrupted in
            Task { @MainActor in self?.isInterrupted = interrupted }
        }
        output.onStopped = { [weak self] in
            Task { @MainActor in self?.backend?.phoneSpeakerOutputStopped() }
        }
        let changes = routes.changes()
        tasks.append(Task { [weak self] in
            for await change in changes { self?.routeChanged(change.route, lostOutput: change.lostOutput) }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let fresh = self.isOn ? self.backend?.phoneSpeakerStats : nil
                if fresh != self.stats { self.stats = fresh }
                let measured = self.isOn ? self.output.diagnostics : nil
                if measured != self.outputDiagnostics { self.outputDiagnostics = measured }
                // A change iOS didn't announce, and anything the settle window put off.
                if self.isOn {
                    self.systemVolume.refresh()
                    self.syncVolume()
                }
            }
        })
    }

    /// The hub this device is the remote of (nil: none that can carry audio).
    func attach(_ backend: (any PhoneSpeakerBackend)?) {
        if let old = self.backend, old !== backend as AnyObject? { old.stopPhoneSpeaker() }
        phaseTask?.cancel()
        self.backend = backend
        isAvailable = backend != nil
        isOn = false
        phase = .off
        dragVolume = nil
        reconciler.deviceLeadsNow()
        systemVolume.setInUse(false)
        guard let backend else { return }
        let phases = backend.phoneSpeakerPhases()
        phaseTask = Task { [weak self] in
            for await phase in phases {
                self?.phase = phase
                self?.syncVolume()
            }
        }
    }

    // MARK: Intents

    func setOn(_ on: Bool) {
        notice = nil
        seenOnAtHub = false
        isOn = on
        dragVolume = nil
        reconciler.deviceLeadsNow()
        systemVolume.setInUse(on)
        if on {
            systemVolume.refresh()
            route = routes.current
            output.resume()
            backend?.startPhoneSpeaker(route: route, output: output)
        } else {
            backend?.stopPhoneSpeaker()
            isInterrupted = false
            stats = nil
        }
    }

    /// Play again after another app or a call took the sound.
    func resume() {
        guard isOn else { return setOn(true) }
        output.resume()
    }

    private func routeChanged(_ new: PhoneRoute, lostOutput: Bool) {
        let old = route
        guard new != old else { return }
        route = new
        // iOS keeps a volume per output: the new output's is the one to keep.
        reconciler.deviceLeadsNow()
        systemVolume.refresh()
        guard isOn else { return }
        if lostOutput {
            // What was playing went away. Like any player, stop rather than carry on from the
            // phone's own speaker at whatever volume that was left at.
            setOn(false)
            notice = "\(old.name) disconnected, so this iPhone stopped playing."
        } else {
            backend?.startPhoneSpeaker(route: new, output: output)
        }
    }

    /// The hub's speakers changed. This device's row turned off there (on the Mac, or by another
    /// remote) means the same as turning it off here.
    func hubSpeakersChanged(_ speakers: [SpeakerItem]) {
        guard isOn, let id = speakerID, let mine = speakers.first(where: { $0.id == id }) else { return }
        if mine.isEnabled {
            seenOnAtHub = true
        } else if seenOnAtHub {
            setOn(false)
        }
        syncVolume()
    }

    /// The hub published a state (called for every one, with or without a view on screen).
    func hubPublished() {
        guard isOn else { return }
        syncVolume()
    }

    // MARK: Volume

    /// The Mac leaves this speaker's volume to this device, and the speaker is on.
    private var usesSystemVolume: Bool {
        isOn && speakerID != nil && backend?.phoneSpeakerVolumeIsSystemVolume == true
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The row's slider moved.
    func setVolume(_ volume: Double) {
        guard let id = speakerID else { return }
        let v = min(1, max(0, volume))
        guard usesSystemVolume else {
            sendVolume?(id, v)
            return
        }
        dragVolume = v
        systemVolume.set(v)
        perform(reconciler.userSet(v, now: now))
    }

    /// The row's slider was let go.
    func commitVolume() {
        dragVolume = nil
        if let id = speakerID { commitSentVolume?(id) }
    }

    /// The side buttons, Control Centre, or iOS following a write made here.
    private func systemVolumeChanged(_ volume: Double) {
        deviceVolume = volume
        guard usesSystemVolume else { return }
        // The output changed and iOS moved to its volume before saying so.
        if routes.current != route { reconciler.deviceLeadsNow() }
        perform(reconciler.deviceChanged(to: volume, now: now))
        syncVolume()
    }

    /// Compares the hub's volume for this device's row with the system volume and does what the
    /// reconciler says. Until the hub lists this device with the output it is playing through
    /// now, there is nothing to compare with and the device's volume is the one to keep.
    private func syncVolume() {
        guard usesSystemVolume, let id = speakerID,
              let mine = (hubSpeakers?() ?? []).first(where: { $0.id == id }),
              mine.model == route.nameAtHub else {
            reconciler.deviceLeadsNow()
            return
        }
        perform(reconciler.hubReports(mine.volume, device: systemVolume.volume, now: now))
    }

    private func perform(_ action: DeviceVolumeReconciler.Action) {
        guard let id = speakerID else { return }
        switch action {
        case .none:
            break
        case .setDevice(let volume):
            systemVolume.set(volume)
        case .tellHub(let volume):
            sendVolume?(id, volume)
            if dragVolume == nil { commitSentVolume?(id) }
        }
    }

    // MARK: What to show

    /// This device's row in the hub's speakers, once the Mac lists it.
    var speakerID: SpeakerID? {
        if case .on(let id) = phase { return id }
        return nil
    }

    /// The row for the "This iPhone" section: the hub's own item for this device while it is
    /// listed, a stand-in before that, named after the output either way.
    func row(in speakers: [SpeakerItem]) -> SpeakerItem {
        var item = speakerID.flatMap { id in speakers.first { $0.id == id } }
            ?? SpeakerItem(id: Self.placeholderID, name: "", transport: .phone, glyph: .phone, isEnabled: isOn, volume: 0.5,
                           state: placeholderState)
        item.name = Self.outputName(route)
        // The slider is this iPhone's volume: shown as it is here, not as the hub last heard it.
        if usesSystemVolume { item.volume = dragVolume ?? deviceVolume }
        item.model = nil
        item.notSeenSince = nil
        switch route.kind {
        case .builtIn: (item.transport, item.glyph) = (.builtIn, .phone)
        case .bluetooth, .car: (item.transport, item.glyph) = (.bluetooth, .portable)
        case .headphones: (item.transport, item.glyph) = (.bluetooth, .headphones)
        case .usb: (item.transport, item.glyph) = (.usb, .usb)
        case .airPlay, .other: (item.transport, item.glyph) = (.builtIn, .speaker)
        }
        if isOn, isInterrupted { item.state = .failed(reason: "Paused: something else is playing") }
        return item
    }

    private var placeholderState: SpeakerState {
        guard isOn else { return .off }
        switch phase {
        case .off, .offering, .waitingForHub, .on: return .connecting
        case .unsupported(let message), .failed(let message): return .failed(reason: message)
        }
    }

    static func outputName(_ route: PhoneRoute) -> String {
        route.kind == .builtIn ? "iPhone Speaker" : route.name
    }

    /// The line under the row: what turning it on does, or what to know about this output.
    func footnote(hubName: String) -> String {
        if let notice { return notice }
        switch route.kind {
        case .bluetooth, .headphones, .car:
            if isOn {
                return "Bluetooth adds a delay nothing reports. If \(route.name) sounds late next to the other speakers, open its details and move Sync trim earlier, once, by ear."
            }
            return "Plays \(hubName)\u{2019}s music through \(route.name), in time with the other speakers. Bluetooth adds a delay, so its Sync trim may need setting once by ear."
        default:
            return isOn ? "Keeps playing with the screen locked." : "Plays \(hubName)\u{2019}s music through this iPhone, in time with the other speakers."
        }
    }
}

// MARK: - Stand-ins for the review scenes

final class FixedRouteMonitor: PhoneRouteMonitoring, @unchecked Sendable {
    let current: PhoneRoute
    init(_ route: PhoneRoute) { current = route }
    func changes() -> AsyncStream<(route: PhoneRoute, lostOutput: Bool)> { AsyncStream { _ in } }
}

/// Plays nothing.
final class SilentPhoneOutput: PhoneSpeakerOutput, @unchecked Sendable {
    var onInterruption: (@Sendable (Bool) -> Void)?
    var onStopped: (@Sendable () -> Void)?
    let mayStart = true
    var diagnostics: PhoneOutputDiagnostics? {
        PhoneOutputDiagnostics(outputLatencyMillis: 172, syncErrorMillis: 0.2, rateCorrectionPPM: -11, underrunFrames: 0, jumps: 0)
    }
    func resume() {}
    func start(timeline: StreamTimeline) -> Bool { true }
    func setClockOffset(nanos: Int64) {}
    func write(_ packet: AudioPacket) {}
    func flush() {}
    func setVolume(_ volume: Float) {}
    func setOffset(millis: Int) {}
    func stop() {}
}

/// A hub that takes the offer at once and lists this device among the mock speakers.
final class MockPhoneSpeakerBackend: PhoneSpeakerBackend, @unchecked Sendable {
    static let speakerID: SpeakerID = "phone:mock-remote"
    private let hub: MockHubBackend
    private let (stream, continuation) = AsyncStream.makeStream(of: PhoneSpeakerPhase.self, bufferingPolicy: .bufferingNewest(4))
    private let deviceName: String

    init(hub: MockHubBackend, deviceName: String = "Sample iPhone") {
        self.hub = hub
        self.deviceName = deviceName
        continuation.yield(.off)
    }

    func startPhoneSpeaker(route: PhoneRoute, output: any PhoneAudioOutput) {
        let item = SpeakerItem(id: Self.speakerID, name: deviceName, transport: .phone, glyph: .phone, model: route.name,
                               isEnabled: true, volume: 0.45, state: .playing, syncTrimMs: route.kind == .builtIn ? 0 : -160)
        Task {
            await hub.setExtraSpeaker(item)
            continuation.yield(.on(speakerID: Self.speakerID))
        }
    }

    func stopPhoneSpeaker() {
        Task {
            await hub.removeExtraSpeaker(Self.speakerID)
            continuation.yield(.off)
        }
    }

    func phoneSpeakerPhases() -> AsyncStream<PhoneSpeakerPhase> { stream }

    let phoneSpeakerVolumeIsSystemVolume = false

    var phoneSpeakerStats: PhoneSpeakerStats? {
        var s = PhoneSpeakerStats()
        s.isPlaying = true
        s.hubIsStreaming = true
        s.clockSamples = 240
        s.bestRoundTripNanos = 2_400_000
        s.lastRoundTripNanos = 3_100_000
        s.clockDriftPPM = 11.4
        s.packetsReceived = 18_240
        s.packetsRecovered = 3
        s.bufferedMillis = 1_930
        return s
    }

    func phoneSpeakerOutputStopped() {}
}
