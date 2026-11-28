import AVFoundation
import Foundation
import MulticastAudio
import MulticastCalibration

/// This iPhone's microphone, lent to the Mac while it tunes a speaker's sync: an input tap into
/// a `RecordingRing`, each buffer stamped with the host time iOS gives for its first sample,
/// less the input latency the audio session reports.
///
/// The Mac never gets audio. It asks "did you hear the sweep between these two moments?" and
/// the answer is worked out here (`RecordingRing.heard`): when it arrived and how clearly.
/// Only the last six seconds are held, in memory.
///
/// Audio session: play-and-record in measurement mode (no voice processing, no automatic
/// gain), Bluetooth output kept on A2DP, the phone's own microphone preferred over a headset's.
/// A headset's microphone is never used: opening it would switch the headset to its call mode
/// and change the very delay being measured. What the session was before is put back on stop.
final class PhoneMicrophone: CalibrationMicrophone, @unchecked Sendable {
    struct Unavailable: Error {}

    private struct Running {
        var engine: AVAudioEngine
        var ring: RecordingRing
        var previous: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)
    }

    private let lock = NSLock()
    private var running: Running?
    /// When the Mac last asked this microphone for something. If it then goes quiet (the link
    /// dropped, the Mac app quit) the microphone turns itself off: it never stays open waiting
    /// for a stop that can't arrive.
    private var lastAsked: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    static let idleSeconds: Double = 30

    private func touch() { lock.withLock { lastAsked = HostClock.nowNanos() } }

    private func startWatchdog() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let idle = self.lock.withLock { self.running == nil ? nil : Optional(HostClock.nowNanos() &- self.lastAsked) }
                guard let idle else { return }
                if Double(idle) / 1e9 > Self.idleSeconds { await self.stop(); return }
            }
        }
        lock.withLock { watchdog?.cancel(); watchdog = task }
    }

    func access(ask: Bool) async -> MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default:
            guard ask else { return .notDetermined }
            return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }
    }

    func start() async throws {
        touch()
        guard lock.withLock({ running == nil }) else { return }
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            if let own = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(own)
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate >= 8000, format.channelCount > 0 else { throw Unavailable() }
            let ring = RecordingRing(sampleRate: format.sampleRate, seconds: 6)
            let latency = UInt64(max(0, session.inputLatency) * 1e9)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
                guard when.isHostTimeValid, let channels = buffer.floatChannelData else { return }
                let heard = HostClock.nanos(fromHostTicks: when.hostTime)
                ring.append(channels[0], frames: Int(buffer.frameLength), hostNanos: heard > latency ? heard - latency : 0)
            }
            try engine.start()
            lock.withLock { running = Running(engine: engine, ring: ring, previous: previous) }
            startWatchdog()
        } catch {
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
            throw error
        }
    }

    func stop() async {
        guard let r = lock.withLock({ () -> Running? in defer { running = nil; watchdog?.cancel(); watchdog = nil }; return running }) else { return }
        r.engine.inputNode.removeTap(onBus: 0)
        r.engine.stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(r.previous.category, mode: r.previous.mode, options: r.previous.options)
        // A phone that is also playing as a speaker keeps its session; otherwise give other
        // apps their audio back.
        if r.previous.category != .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep? {
        touch()
        guard let ring = lock.withLock({ running?.ring }) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ring.heard(signal, fromHostNanos: fromHostNanos, seconds: seconds)
        }.value
    }

    /// The last 40 ms heard, as about a hundred points, newest last; empty while not listening.
    func waveform() -> [Float] {
        guard let ring = lock.withLock({ running?.ring }) else { return [] }
        let points = 96
        return ring.latest(points, step: max(1, Int(ring.sampleRate * 0.04) / points))
    }
}
