import Foundation
import MulticastCalibration
import MulticastHubModel
import MulticastRemote
import Observation

/// What tuning needs of the link to the Mac. `RemoteHubBackend` is the real one;
/// `MockTuningBackend` stands in for it in the review scenes.
protocol SpeakerTuningBackend: AnyObject, Sendable {
    /// The Mac can tune speakers with this device's microphone (false for an older Mac).
    var canTuneSpeakers: Bool { get }
    func setCalibrationMicrophone(_ microphone: (any CalibrationMicrophone)?)
    /// Returns once the tuning has begun; its progress is `HubState.calibration`.
    func tuneSpeaker(_ speakerID: SpeakerID) async throws
}

extension RemoteHubBackend: SpeakerTuningBackend {}

/// Tuning speaker sync from this iPhone: the person stands next to a speaker, the Mac plays
/// its test sound there, and this iPhone's microphone listens for it.
@Observable
@MainActor
final class TuningModel {
    /// Why the last attempt to start didn't (the Mac refused, the link is down).
    var failure: String?
    /// Asked, and the Mac hasn't answered yet.
    private(set) var isStarting = false
    private(set) var isAttached = false

    /// The live sound at this iPhone's microphone while it listens, for the stage.
    @ObservationIgnored let waveform: (() -> [Float])?
    @ObservationIgnored private let microphone: (any CalibrationMicrophone)?
    @ObservationIgnored private var backend: (any SpeakerTuningBackend)?

    init(microphone: (any CalibrationMicrophone)?, waveform: (() -> [Float])?) {
        self.microphone = microphone
        self.waveform = waveform
    }

    /// The real thing: this iPhone's microphone.
    static func live() -> TuningModel {
        let microphone = PhoneMicrophone()
        return TuningModel(microphone: microphone, waveform: { microphone.waveform() })
    }

    func attach(_ backend: (any SpeakerTuningBackend)?) {
        self.backend = backend
        isAttached = backend != nil
        backend?.setCalibrationMicrophone(microphone)
    }

    var isAvailable: Bool { backend?.canTuneSpeakers == true }

    func tune(_ id: SpeakerID) {
        guard let backend, !isStarting else { return }
        failure = nil
        isStarting = true
        Task {
            do {
                try await backend.tuneSpeaker(id)
            } catch {
                failure = (error as? HubCommandError)?.message ?? "Couldn\u{2019}t reach the Mac. Try again."
            }
            isStarting = false
        }
    }
}

/// The review scenes' Mac: plays a tuning out on the mock hub.
final class MockTuningBackend: SpeakerTuningBackend, @unchecked Sendable {
    private let hub: MockHubBackend
    init(hub: MockHubBackend) { self.hub = hub }

    var canTuneSpeakers: Bool { true }
    func setCalibrationMicrophone(_ microphone: (any CalibrationMicrophone)?) {}
    func tuneSpeaker(_ speakerID: SpeakerID) async throws { try await hub.tuneWithPhone(speakerID) }
}

enum MockMicrophone {
    /// A room's murmur for the review scenes: moves, but is the same every time.
    static func waveform() -> [Float] {
        let t = Date().timeIntervalSinceReferenceDate
        return (0..<96).map { i in
            let x = Double(i) / 96
            return Float(0.5 * sin(2 * .pi * (3 * x + t * 1.7)) * sin(2 * .pi * (0.5 * x + t * 0.31)) + 0.25 * sin(2 * .pi * (11 * x - t * 2.3)))
        }
    }
}
