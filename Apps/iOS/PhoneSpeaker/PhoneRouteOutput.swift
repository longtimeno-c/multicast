import AVFoundation
import Foundation
import MulticastAudio
import MulticastLocalOutput
import MulticastRemote
import UIKit

/// What the "This iPhone" control needs from the audio output besides playing: whether
/// something else has taken the audio session, and a way to take it back.
protocol PhoneSpeakerOutput: PhoneAudioOutput {
    /// Called (on any thread) when an interruption begins or ends. `interrupted` true: a call or
    /// another app took the audio session and playback has stopped.
    var onInterruption: (@Sendable (_ interrupted: Bool) -> Void)? { get set }
    /// Called when the output stopped by itself and should be started again.
    var onStopped: (@Sendable () -> Void)? { get set }
    /// The person asked to play again after an interruption that didn't end by itself.
    func resume()
}

/// The stream through this device's current audio route (its speaker, AirPods, a Bluetooth
/// speaker): `CurrentRouteSink` from MulticastLocalOutput, told how the hub's clock relates to
/// this device's, with the audio session manners of a music app.
///
/// - Category `.playback`, not mixed: it plays with the screen locked and with the ring switch
///   on silent, and it interrupts other apps' audio like any player, and is interrupted by them.
/// - A call or another app interrupts it: playback stops and is not taken back unless iOS says
///   the interruption ended and playback should resume, or the person taps Try Again.
final class PhoneRouteOutput: PhoneSpeakerOutput, @unchecked Sendable {
    private let sink = CurrentRouteSink()
    private let lock = NSLock()
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private var stoppedHandler: (@Sendable () -> Void)?

    var onInterruption: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { interruptionHandler } }
        set { lock.withLock { interruptionHandler = newValue } }
    }

    var onStopped: (@Sendable () -> Void)? {
        get { lock.withLock { stoppedHandler } }
        set { lock.withLock { stoppedHandler = newValue } }
    }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // The sink has closed itself; remember not to reopen it on our own.
                self.lock.withLock { self.interrupted = true }
                self.onStopped?()
                self.onInterruption?(true)
            case .ended:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume) else { return }
                self.lock.withLock { self.interrupted = false }
                self.onInterruption?(false)
            @unknown default:
                break
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.onStopped?()
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    var mayStart: Bool { lock.withLock { !interrupted } }

    func resume() {
        lock.withLock { interrupted = false }
        onInterruption?(false)
    }

    func start(timeline: StreamTimeline) -> Bool {
        do {
            try sink.start(timeline: timeline)
            return true
        } catch {
            return false
        }
    }

    func setClockOffset(nanos: Int64) { sink.setClockOffset(nanos: nanos) }
    func write(_ packet: AudioPacket) { sink.enqueue(packet) }
    func flush() { sink.flushNow() }
    func setVolume(_ volume: Float) { sink.setVolumeNow(volume) }
    func setOffset(millis: Int) { sink.setOffsetNow(millis: millis) }
    func stop() { sink.stopNow(deactivateSession: true) }

    /// What the output itself measures (sync error, rate correction, underruns, route latency).
    var syncStats: LocalOutputSyncStats { sink.syncStats }
    var outputLatencyMillis: Double { Double(sink.reportedLatency.totalNanos) / 1e6 }
}

// MARK: - The current route

/// Tells the control what this device would play through, and when that changes.
protocol PhoneRouteMonitoring: AnyObject, Sendable {
    var current: PhoneRoute { get }
    /// Every change of output. `lostOutput`: the output that was playing went away (a Bluetooth
    /// speaker switched off, headphones unplugged), so audio would fall back to another one.
    func changes() -> AsyncStream<(route: PhoneRoute, lostOutput: Bool)>
}

final class AudioSessionRouteMonitor: PhoneRouteMonitoring, @unchecked Sendable {
    var current: PhoneRoute { Self.route(AVAudioSession.sharedInstance().currentRoute) }

    func changes() -> AsyncStream<(route: PhoneRoute, lostOutput: Bool)> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                continuation.yield((Self.route(AVAudioSession.sharedInstance().currentRoute), reason == .oldDeviceUnavailable))
            }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
        }
    }

    static func route(_ description: AVAudioSessionRouteDescription) -> PhoneRoute {
        guard let port = description.outputs.first else { return PhoneRoute(name: "Speaker", kind: .builtIn) }
        return route(portType: port.portType, name: port.portName)
    }

    /// Pure: how an output port is described to the hub and the person.
    static func route(portType: AVAudioSession.Port, name: String) -> PhoneRoute {
        switch portType {
        case .builtInSpeaker, .builtInReceiver:
            return PhoneRoute(name: "Speaker", kind: .builtIn)
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            let n = name.lowercased()
            let worn = ["airpods", "headphone", "buds", "beats", "headset"].contains { n.contains($0) }
            return PhoneRoute(name: name, kind: worn ? .headphones : .bluetooth)
        case .headphones: return PhoneRoute(name: name, kind: .headphones)
        case .airPlay: return PhoneRoute(name: name, kind: .airPlay)
        case .carAudio: return PhoneRoute(name: name, kind: .car)
        case .usbAudio: return PhoneRoute(name: name, kind: .usb)
        default: return PhoneRoute(name: name, kind: .other)
        }
    }
}
