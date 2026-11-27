#if os(iOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import MulticastAudio

/// `SpeakerDescriptor.id` of the iOS "current route" output (stable across route changes).
public let currentRouteSpeakerID = "local:current-route"

enum CurrentRouteInfo {
    static func descriptor(_ session: AVAudioSession = .sharedInstance()) -> SpeakerDescriptor {
        let port = session.currentRoute.outputs.first
        let kind = port.map { LocalKindMapping.kind(forRoutePortType: $0.portType.rawValue) } ?? .builtIn
        return SpeakerDescriptor(
            id: currentRouteSpeakerID,
            name: port?.portName ?? "This device",
            transport: .local,
            model: port?.portType.rawValue,
            localDeviceUID: port?.uid,
            localKind: kind
        )
    }

    static func latency(_ session: AVAudioSession = .sharedInstance()) -> LocalOutputLatency {
        LocalOutputLatency(
            deviceSampleRate: session.sampleRate,
            bufferFrames: UInt32(max(0, (session.ioBufferDuration * session.sampleRate).rounded())),
            // Output latency only, as on macOS: the render timestamp already refers to the
            // buffer being filled, so adding ioBufferDuration would play one IO buffer EARLY.
            // (Unverified on a device: iOS has only been compiled, never run.)
            platformLatencySeconds: session.outputLatency
        )
    }
}

/// iOS: reports the current audio route as the single local output and updates on route changes.
/// Same surface as the macOS directory so app code is shared.
public final class LocalOutputDirectory: @unchecked Sendable {
    private let devicesBroadcaster: ReplayingBroadcaster<[SpeakerDescriptor]>
    private let defaultBroadcaster: ReplayingBroadcaster<String?>
    private var observer: NSObjectProtocol?
    private let lock = NSLock()

    public init() {
        devicesBroadcaster = ReplayingBroadcaster([CurrentRouteInfo.descriptor()])
        defaultBroadcaster = ReplayingBroadcaster(currentRouteSpeakerID)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { invalidate() }

    public var devices: [SpeakerDescriptor] { devicesBroadcaster.current }
    public var updates: AsyncStream<[SpeakerDescriptor]> { devicesBroadcaster.makeStream() }
    public var defaultOutputID: String? { defaultBroadcaster.current }
    public var defaultOutput: SpeakerDescriptor? { devices.first }
    public var defaultOutputUpdates: AsyncStream<String?> { defaultBroadcaster.makeStream() }

    public func refresh() {
        devicesBroadcaster.sendIfChanged([CurrentRouteInfo.descriptor()])
    }

    public func reportedLatency(forDeviceUID uid: String) -> LocalOutputLatency? {
        CurrentRouteInfo.latency()
    }

    public func invalidate() {
        lock.lock()
        let o = observer
        observer = nil
        lock.unlock()
        if let o { NotificationCenter.default.removeObserver(o) }
        devicesBroadcaster.finishAll()
        defaultBroadcaster.finishAll()
    }
}

/// iOS: one sink for whatever the current route is (built-in speaker, Bluetooth, AirPlay…),
/// built on AVAudioEngine + AVAudioSourceNode and aligned to the stream timeline using
/// `AVAudioSession.outputLatency + ioBufferDuration`.
public final class CurrentRouteSink: AudioSink, @unchecked Sendable {
    public let id: String
    public let displayName: String

    private let core = RenderCore()
    private let control = NSLock()
    private let accepting = AtomicU64(0)
    private let stateBroadcaster = ReplayingBroadcaster<SinkState>(.idle)

    // Guarded by `control`.
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private var volume: Float = 1
    private var offset = 0
    private var latency = LocalOutputLatency.zero
    private var currentTimeline: StreamTimeline?

    public init(descriptor: SpeakerDescriptor? = nil) {
        id = descriptor?.id ?? currentRouteSpeakerID
        displayName = descriptor?.name ?? "This device"
        _ = HostClock.nanos(fromHostTicks: 1)
    }

    deinit {
        engine?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        stateBroadcaster.finishAll()
    }

    public var reportedLatency: LocalOutputLatency { control.withLock { latency } }
    public var syncStats: LocalOutputSyncStats { core.snapshotStats() }
    public var currentState: SinkState { stateBroadcaster.current }
    public var stateUpdates: AsyncStream<SinkState> { stateBroadcaster.makeStream() }

    public func prepare(timeline: StreamTimeline) async throws {
        try prepareSync(timeline: timeline)
    }

    // MARK: A stream timed by another machine (this device as a hub's speaker)

    /// `prepare`, callable from a queue.
    public func start(timeline: StreamTimeline) throws { try prepareSync(timeline: timeline) }

    /// The timeline's clock minus this device's, when the timeline came from another machine.
    public func setClockOffset(nanos: Int64) { core.setClockOffset(nanos: nanos) }

    public func setVolumeNow(_ volume: Float) {
        control.withLock {
            self.volume = max(0, min(1, volume))
            core.setGainTarget(VolumeCurve.amplitude(forVolume: self.volume))
        }
    }

    public func setOffsetNow(millis: Int) {
        control.withLock {
            offset = millis
            core.setOffset(millis: millis)
        }
    }

    public func flushNow() { core.ring.requestReset() }

    /// `stop`, callable from a queue. Also gives the audio session back, so whatever this
    /// interrupted (another app's music) can resume.
    public func stopNow(deactivateSession: Bool) {
        control.withLock { teardownLocked() }
        stateBroadcaster.sendIfChanged(.idle)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func prepareSync(timeline: StreamTimeline) throws {
        control.lock()
        defer { control.unlock() }
        do {
            try core.checkCapacity(for: timeline)
        } catch {
            stateBroadcaster.send(.failed((error as? LocalOutputError)?.description ?? "\(error)"))
            throw error
        }
        if let engine, engine.isRunning {
            if currentTimeline != timeline { core.ring.requestReset() }
            currentTimeline = timeline
            core.setTimeline(timeline)
            accepting.store(1)
            stateBroadcaster.sendIfChanged(.playing)
            return
        }
        teardownLocked()
        stateBroadcaster.sendIfChanged(.connecting)
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback && session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)

            core.resetForStart()
            core.ring.requestReset()
            core.setTimeline(timeline)
            core.setOffset(millis: offset)
            core.setGainTarget(VolumeCurve.amplitude(forVolume: volume))
            currentTimeline = timeline

            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(PCM.sampleRate), channels: AVAudioChannelCount(PCM.channels)) else {
                throw LocalOutputError.coreAudio(operation: "AVAudioFormat", status: -1)
            }
            let core = self.core
            let node = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, abl in
                let ts = timestamp.pointee
                let host: UInt64? = ts.mFlags.contains(.hostTimeValid) ? HostClock.nanos(fromHostTicks: ts.mHostTime) : nil
                let silent = core.render(hostNanos: host, frames: Int(frameCount), abl: UnsafeMutableAudioBufferListPointer(abl))
                isSilence.pointee = ObjCBool(silent)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            self.engine = engine
            self.sourceNode = node
            refreshLatencyLocked()
            installObserversLocked()
            core.setActive(true)
            accepting.store(1)
            try engine.start()
            stateBroadcaster.send(.playing)
        } catch {
            teardownLocked()
            stateBroadcaster.send(.failed(String(describing: error)))
            throw error
        }
    }

    public func enqueue(_ packet: AudioPacket) {
        guard accepting.load(acquire: false) == 1 else { return }
        core.write(packet: packet)
    }

    public func setVolume(_ volume: Float) async {
        control.withLock {
            self.volume = max(0, min(1, volume))
            core.setGainTarget(VolumeCurve.amplitude(forVolume: self.volume))
        }
    }

    public func setOffset(millis: Int) async {
        control.withLock {
            offset = millis
            core.setOffset(millis: millis)
        }
    }

    public func flush() async { core.ring.requestReset() }

    public func stop() async {
        control.withLock { teardownLocked() }
        stateBroadcaster.sendIfChanged(.idle)
    }

    private func teardownLocked() {
        accepting.store(0)
        core.setActive(false)
        engine?.stop()
        if let node = sourceNode { engine?.detach(node) }
        engine = nil
        sourceNode = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        core.ring.requestReset()
        currentTimeline = nil
    }

    private func refreshLatencyLocked() {
        latency = CurrentRouteInfo.latency()
        core.setOutputLatency(nanos: latency.totalNanos)
    }

    private func installObserversLocked() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.control.withLock { self.refreshLatencyLocked() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // The engine stopped itself (route / format change): restart it on the new route.
            guard let self else { return }
            self.control.lock()
            guard let engine = self.engine else { self.control.unlock(); return }
            self.refreshLatencyLocked()
            do {
                engine.prepare()
                try engine.start()
                self.control.unlock()
            } catch {
                self.teardownLocked()
                self.control.unlock()
                self.stateBroadcaster.send(.failed("Audio engine could not restart: \(error)"))
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.control.withLock { self.teardownLocked() }
            self.stateBroadcaster.send(.failed("Audio session interrupted"))
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.control.withLock { self.teardownLocked() }
            self.stateBroadcaster.send(.failed("Media services were reset"))
        })
    }
}

/// On iOS the only local sink is the current-route sink.
public typealias LocalOutputSink = CurrentRouteSink
#endif
