import Foundation
import MulticastAudio
import MulticastCalibration

/// How the server hands a phone that asked to tune a speaker to whatever runs calibrations (the
/// Mac app wires this to `LocalHub.tuneSpeaker`). Like `RemoteSpeakerHost`: the server itself
/// only knows `HubBackend`, which takes no microphone.
public struct RemoteMicrophoneHost: Sendable {
    /// Start tuning `speakerID`, listening with `microphone`. `microphoneID` identifies the
    /// phone across sessions ("phone:" + its remote id), `name` is what to show for it. Throws
    /// what a command would (unknown speaker, another tuning running).
    public var tune: @Sendable (_ speakerID: String, _ microphone: any CalibrationMicrophone, _ microphoneID: String, _ name: String) async throws -> Void

    public init(tune: @escaping @Sendable (String, any CalibrationMicrophone, String, String) async throws -> Void) {
        self.tune = tune
    }
}

/// A paired phone's microphone, as the hub sees it: every call is a question over the link,
/// answered by the phone (`RemoteHubBackend.setCalibrationMicrophone`). The phone records and
/// looks for the sweep itself; what comes back is when it arrived, never audio.
///
/// The phone has its own clock. Before listening, and again before every question, the hub
/// makes NTP-style exchanges with it (`MicrophoneRequest.clock`) and keeps the best: the two
/// clocks are then known to within about half the link's round trip, typically well under a
/// millisecond on a home network. That error is in every sweep of one tuning alike.
final class RemoteMicrophone: CalibrationMicrophone, @unchecked Sendable {
    typealias Ask = @Sendable (_ request: MicrophoneRequest, _ timeout: TimeInterval) async -> MicrophoneAnswer?

    private let ask: Ask
    private let now: @Sendable () -> UInt64
    /// Phone clock minus hub clock, estimated.
    private let clock = Locked(ClockEstimator())

    init(ask: @escaping Ask, now: @escaping @Sendable () -> UInt64 = { HostClock.nowNanos() }) {
        self.ask = ask
        self.now = now
    }

    func access(ask shouldAsk: Bool) async -> MicrophoneAccess {
        // Asking waits for a person at the phone.
        if case .access(let status)? = await ask(.access(ask: shouldAsk), shouldAsk ? 120 : 5) { return status }
        return .denied
    }

    struct Unreachable: Error {}
    struct Refused: Error { var message: String }

    func start() async throws {
        guard case .started(let error)? = await ask(.start, 8) else { throw Unreachable() }
        if let error { throw Refused(message: error) }
        clock.withLock { $0.reset() }
        for _ in 0..<8 { await exchangeClocks() }
        guard clock.value.sampleCount > 0 else { throw Unreachable() }
    }

    func stop() async { _ = await ask(.stop, 2) }

    private func exchangeClocks() async {
        let sent = now()
        guard case .clock(let received, let answered)? = await ask(.clock, 2) else { return }
        let back = now()
        clock.withLock { _ = $0.add(t1: sent, t2: received, t3: answered, t4: back) }
    }

    /// Phone clock minus hub clock at hub time `hubNanos`.
    var offsetNanos: Int64? { clock.value.offsetNanos(at: now()) }

    func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep? {
        await exchangeClocks()
        guard let offset = offsetNanos else { return nil }
        let fromPhone = UInt64(bitPattern: Int64(bitPattern: fromHostNanos) &+ offset)
        guard case .heard(var heard?)? = await ask(.listen(signal: signal, fromNanos: fromPhone, seconds: seconds), 5) else { return nil }
        heard.arrivalHostNanos = heard.arrivalHostNanos.map { UInt64(bitPattern: Int64(bitPattern: $0) &- offset) }
        return heard
    }
}

/// The phone's side: answers the hub's questions with the phone's own microphone.
struct MicrophoneResponder: Sendable {
    var microphone: (any CalibrationMicrophone)?

    /// `received`: the phone's clock when the question arrived.
    func answer(_ request: MicrophoneRequest, received: UInt64) async -> MicrophoneAnswer {
        switch request {
        case .clock:
            return .clock(receivedNanos: received, sentNanos: HostClock.nowNanos())
        case .access(let ask):
            return .access(await microphone?.access(ask: ask) ?? .denied)
        case .start:
            guard let microphone else { return .started(error: "This device has no microphone to listen with.") }
            do {
                try await microphone.start()
                return .started(error: nil)
            } catch {
                return .started(error: "The microphone couldn\u{2019}t be used.")
            }
        case .stop:
            await microphone?.stop()
            return .stopped
        case .listen(let signal, let fromNanos, let seconds):
            // What the hub asks is bounded: a short sweep, a window of a second or two.
            guard seconds > 0, seconds <= 5, signal.sweepSeconds > 0, signal.sweepSeconds <= 2 else { return .heard(nil) }
            return .heard(await microphone?.listen(for: signal, fromHostNanos: fromNanos, seconds: seconds))
        }
    }
}
