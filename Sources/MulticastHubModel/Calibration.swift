import Foundation

/// Sync calibration: the hub plays a short test sound on each speaker that is on, one at a
/// time, listens for it with a microphone, and sets every speaker's sync trim so they are heard
/// together. This is what a UI shows of it, while it runs and after.
///
/// Wire: `HubState.calibration` is absent while there is nothing to show, so builds that
/// predate it read and write every state unchanged.
public struct SyncCalibrationStatus: Equatable, Hashable, Sendable, Codable {
    /// Still measuring. False once it finished: the results stay until dismissed
    /// (`HubCommand.cancelSyncCalibration`) or the next run.
    public var isRunning: Bool
    /// One entry per speaker that was on when it started, in the order they are measured.
    public var speakers: [Speaker]
    /// Why it could not run or finish, in plain words ("Multicast isn't allowed to use the
    /// microphone."). nil when it ran.
    public var problem: String?

    public init(isRunning: Bool, speakers: [Speaker] = [], problem: String? = nil) {
        self.isRunning = isRunning
        self.speakers = speakers
        self.problem = problem
    }

    public struct Speaker: Identifiable, Equatable, Hashable, Sendable, Codable {
        public let id: SpeakerID
        public var outcome: Outcome

        public init(id: SpeakerID, outcome: Outcome = .waiting) {
            self.id = id
            self.outcome = outcome
        }
    }

    /// Wire form (synthesized): `{"waiting":{}}`, `{"measuring":{}}`,
    /// `{"aligned":{"lagMs":172.4,"trimMs":-172,"reachedLimit":false}}`, `{"notHeard":{}}`,
    /// `{"unclear":{}}`, `{"skipped":{}}`.
    public enum Outcome: Equatable, Hashable, Sendable, Codable {
        /// Its turn hasn't come.
        case waiting
        /// The test sound is playing on it now.
        case measuring
        /// Heard. `lagMs`: how far it played behind the reference speaker with no trim at all
        /// (negative: ahead). `trimMs`: the sync trim now set. `reachedLimit`: lining it up
        /// needs more than the trim allows, so it was set as far as it goes.
        case aligned(lagMs: Double, trimMs: Int, reachedLimit: Bool)
        /// The microphone didn't pick it up (another room, too quiet). Its trim is unchanged.
        case notHeard
        /// It was heard, but the readings disagree. Its trim is unchanged.
        case unclear
        /// It went off or stopped responding before its turn. Its trim is unchanged.
        case skipped
    }

    public func speaker(_ id: SpeakerID) -> Speaker? { speakers.first { $0.id == id } }

    /// "3 of 4 lined up"-style summary once finished; nil while running or when nothing ran.
    public var summary: String? {
        guard !isRunning else { return nil }
        if let problem { return problem }
        guard !speakers.isEmpty else { return nil }
        let aligned = speakers.filter { if case .aligned = $0.outcome { true } else { false } }.count
        if aligned == speakers.count {
            return aligned == 1 ? "Measured 1 speaker. Turn on another to line them up." : "All \(aligned) speakers are lined up."
        }
        if aligned == 0 { return "Couldn\u{2019}t hear any speaker from here." }
        return "\(aligned) of \(speakers.count) speakers lined up."
    }
}

extension SyncCalibrationStatus.Outcome {
    /// The short line a speaker row shows.
    public var caption: String {
        switch self {
        case .waiting: return "Waiting to be measured"
        case .measuring: return "Measuring\u{2026}"
        case .aligned(let lagMs, let trimMs, let reachedLimit):
            let lag = Int(lagMs.rounded())
            let found = lag == 0 ? "In step" : (lag > 0 ? "Was \(lag) ms late" : "Was \(-lag) ms early")
            let trim = trimMs == 0 ? "no trim" : "trim \(trimMs > 0 ? "+" : "\u{2212}")\(abs(trimMs)) ms"
            return reachedLimit ? "\(found) \u{00B7} \(trim), the most it allows" : "\(found) \u{00B7} \(trim)"
        case .notHeard: return "Couldn\u{2019}t hear this speaker"
        case .unclear: return "Readings didn\u{2019}t agree \u{00B7} try again somewhere quieter"
        case .skipped: return "Not measured"
        }
    }
}
