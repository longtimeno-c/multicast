import Foundation
import MulticastHubModel

/// Made-up tunings for the review scenes and the mock hub: what a real one publishes, without
/// a speaker, a microphone or a sound.
enum MockTuning {
    enum Moment: String, CaseIterable {
        /// Asked for; the speaker is connecting.
        case starting
        /// Two sweeps heard, the third in the air.
        case listening
        /// Heard 172 ms late and trimmed.
        case inSync
        /// The first speaker tuned: nothing to line up with yet.
        case reference
        /// Five sweeps, none found.
        case notHeard
        /// Found, but in different places.
        case tooNoisy
        /// The microphone was refused.
        case refused
    }

    /// The picture of one search: a low, uneven floor, and a spike where the sweep was found.
    /// Deterministic, so screenshots don't change from run to run.
    static func trace(latenessMs: Double?, seed: Int, earliestMs: Double = 150, latestMs: Double = 600, loud: Bool = false) -> Data {
        var state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 12345)
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        let bins = 96
        let heard = latenessMs != nil
        var bytes = (0..<bins).map { _ -> UInt8 in
            // Noise alone fills the height; under a heard sweep it is a low floor.
            let level = heard ? 0.03 + 0.07 * next() : (loud ? 0.35 + 0.65 * next() : 0.45 + 0.5 * next())
            return UInt8(min(255, level * 255))
        }
        if let latenessMs {
            let at = Int(((latenessMs + earliestMs) / (earliestMs + latestMs) * Double(bins)).rounded(.down))
            if bytes.indices.contains(at) {
                bytes[at] = 255
                // The room answers a little later, lower.
                if bytes.indices.contains(at + 1) { bytes[at + 1] = max(bytes[at + 1], 70) }
                if bytes.indices.contains(at + 2) { bytes[at + 2] = max(bytes[at + 2], 34) }
            }
        } else if let top = bytes.indices.max(by: { bytes[$0] < bytes[$1] }) {
            bytes[top] = 255
        }
        return Data(bytes)
    }

    static func sweep(_ latenessMs: Double?, seed: Int, loud: Bool = false) -> SyncCalibrationStatus.Sweep {
        .init(latenessMs: latenessMs, strength: latenessMs == nil ? 4.4 : 31, trace: trace(latenessMs: latenessMs, seed: seed, loud: loud))
    }

    /// `began`: when the first sweep left the speaker.
    static func status(_ moment: Moment, speaker: SpeakerID, previousTrimMs: Int = 0,
                       microphone: SyncCalibrationStatus.Microphone = .phone(name: "Sample iPhone"),
                       began: Date = Date().addingTimeInterval(-2.45)) -> SyncCalibrationStatus {
        let heard = (0..<5).map { sweep(196 + Double($0 % 2) * 0.3, seed: $0) }
        var entry = SyncCalibrationStatus.Speaker(id: speaker, previousTrimMs: previousTrimMs, sweepsBeganAt: began)
        var status = SyncCalibrationStatus(isRunning: false, microphone: microphone)
        switch moment {
        case .starting:
            entry.outcome = .measuring
            entry.sweepsBeganAt = nil
            status.isRunning = true
        case .listening:
            entry.outcome = .measuring
            entry.sweeps = Array(heard.prefix(2))
            status.isRunning = true
        case .inSync:
            entry.outcome = .aligned(lagMs: 172, trimMs: previousTrimMs - 172, reachedLimit: false, isReference: false)
            entry.sweeps = heard
        case .reference:
            entry.outcome = .aligned(lagMs: 0, trimMs: previousTrimMs, reachedLimit: false, isReference: true)
            entry.sweeps = (0..<5).map { sweep(24 + Double($0 % 2) * 0.2, seed: $0) }
        case .notHeard:
            entry.outcome = .notHeard
            entry.sweeps = (0..<3).map { sweep(nil, seed: $0 + 20) }
        case .tooNoisy:
            entry.outcome = .unclear
            entry.sweeps = [sweep(88, seed: 1), sweep(nil, seed: 2, loud: true), sweep(402, seed: 3), sweep(215, seed: 4), sweep(nil, seed: 5, loud: true)]
        case .refused:
            entry.outcome = .skipped
            entry.sweepsBeganAt = nil
            status.problem = microphone == .hub
                ? "Multicast isn\u{2019}t allowed to use the microphone. Allow it in Privacy & Security, then try again."
                : "Multicast Remote isn\u{2019}t allowed to use the iPhone\u{2019}s microphone. Allow it in Settings on the iPhone, then try again."
        }
        status.speakers = [entry]
        return status
    }
}
