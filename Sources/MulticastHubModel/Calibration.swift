import Foundation

/// Sync calibration: the hub plays a short test sound on a speaker, a microphone listens for
/// it (the Mac's, or a paired phone's held next to the speaker), and the speaker's sync trim is
/// set so it is heard in step with the others. Speakers are tuned one at a time, whenever the
/// person is ready; each measurement is kept on the hub, so speakers tuned on different days
/// still line up. This is what a UI shows of a tuning, while it runs and after.
///
/// Wire: `HubState.calibration` is absent while there is nothing to show, so builds that
/// predate it read and write every state unchanged.
public struct SyncCalibrationStatus: Equatable, Hashable, Sendable, Codable {
    /// What is listening.
    public enum Microphone: Equatable, Hashable, Sendable, Codable {
        /// The hub's own microphone.
        case hub
        /// A paired phone's, held by the person at the speaker.
        case phone(name: String)
    }

    /// Still measuring. False once it finished: the results stay until dismissed
    /// (`HubCommand.cancelSyncCalibration`) or the next run.
    public var isRunning: Bool
    public var microphone: Microphone
    /// The speakers being tuned, in order: one when the person picked one, every speaker that
    /// is on for "all in turn".
    public var speakers: [Speaker]
    /// Why it could not run or finish, in plain words ("Multicast isn't allowed to use the
    /// microphone."). nil when it ran.
    public var problem: String?

    // How it listens, for drawing it.
    /// Seconds from one test sweep to the next.
    public var sweepPeriod: TimeInterval
    /// Sweeps listened to per speaker.
    public var sweepsPerSpeaker: Int
    /// Each sweep is looked for from `earliestMs` before the moment it is due to `latestMs` after.
    public var earliestMs: Double
    public var latestMs: Double

    public init(isRunning: Bool, microphone: Microphone = .hub, speakers: [Speaker] = [], problem: String? = nil,
                sweepPeriod: TimeInterval = 1, sweepsPerSpeaker: Int = 5, earliestMs: Double = 150, latestMs: Double = 600) {
        self.isRunning = isRunning
        self.microphone = microphone
        self.speakers = speakers
        self.problem = problem
        self.sweepPeriod = sweepPeriod
        self.sweepsPerSpeaker = sweepsPerSpeaker
        self.earliestMs = earliestMs
        self.latestMs = latestMs
    }

    public struct Speaker: Identifiable, Equatable, Hashable, Sendable, Codable {
        public let id: SpeakerID
        public var outcome: Outcome
        /// The sync trim it had when the tuning began.
        public var previousTrimMs: Int
        /// When the first sweep it is listened to on is due at the loudspeaker (the hub's wall
        /// clock); sweep `n` is due `n × sweepPeriod` later. nil until its turn.
        public var sweepsBeganAt: Date?
        /// What the microphone made of each sweep so far, in order.
        public var sweeps: [Sweep]

        public init(id: SpeakerID, outcome: Outcome = .waiting, previousTrimMs: Int = 0, sweepsBeganAt: Date? = nil,
                    sweeps: [Sweep] = []) {
            self.id = id
            self.outcome = outcome
            self.previousTrimMs = previousTrimMs
            self.sweepsBeganAt = sweepsBeganAt
            self.sweeps = sweeps
        }
    }

    /// One sweep as the microphone found it.
    public struct Sweep: Equatable, Hashable, Sendable, Codable {
        /// How long after it was due the sweep arrived, in milliseconds (through the microphone,
        /// so only differences between speakers mean something). nil: not clearly heard.
        public var latenessMs: Double?
        /// How far the best candidate stood above the noise; about 6.5 and up is believed.
        public var strength: Double
        /// A picture of the search across the listening window, one byte per step from
        /// `earliestMs` before due to `latestMs` after: a heard sweep is one spike over a low
        /// floor, noise is grass of even height.
        public var trace: Data

        public init(latenessMs: Double?, strength: Double, trace: Data) {
            self.latenessMs = latenessMs
            self.strength = strength
            self.trace = trace
        }
    }

    /// Wire form (synthesized): `{"waiting":{}}`, `{"measuring":{}}`,
    /// `{"aligned":{"isReference":false,"lagMs":172.4,"reachedLimit":false,"trimMs":-172}}`,
    /// `{"notHeard":{}}`, `{"unclear":{}}`, `{"skipped":{}}`.
    public enum Outcome: Equatable, Hashable, Sendable, Codable {
        /// Its turn hasn't come.
        case waiting
        /// It is connecting, or the test sound is playing on it now.
        case measuring
        /// Heard. `lagMs`: how far it played behind the reference speaker with no trim at all
        /// (negative: ahead). `trimMs`: the sync trim now set. `reachedLimit`: lining it up
        /// needs more than the trim allows, so it was set as far as it goes. `isReference`: it
        /// is the speaker the others are lined up to (the only one measured so far, the Mac's
        /// own, or the earliest), so its trim was left as it was.
        case aligned(lagMs: Double, trimMs: Int, reachedLimit: Bool, isReference: Bool)
        /// The microphone didn't pick it up (too far, too quiet). Its trim is unchanged.
        case notHeard
        /// It was heard, but the readings disagree. Its trim is unchanged.
        case unclear
        /// It went off or stopped responding before its turn. Its trim is unchanged.
        case skipped

        public var isFinished: Bool {
            switch self {
            case .waiting, .measuring: false
            default: true
            }
        }

        public var isAligned: Bool { if case .aligned = self { true } else { false } }
    }

    public func speaker(_ id: SpeakerID) -> Speaker? { speakers.first { $0.id == id } }

    /// The speaker whose turn it is, or the last one when finished.
    public var current: Speaker? {
        speakers.first { $0.outcome == .measuring } ?? speakers.last { $0.outcome.isFinished } ?? speakers.first
    }

    /// A summary line once finished; nil while running or when nothing ran.
    public var summary: String? {
        guard !isRunning else { return nil }
        if let problem { return problem }
        guard !speakers.isEmpty else { return nil }
        if speakers.count == 1 { return speakers[0].outcome.caption }
        let aligned = speakers.filter(\.outcome.isAligned).count
        if aligned == speakers.count { return "All \(aligned) speakers are in sync." }
        if aligned == 0 { return "Couldn\u{2019}t hear any speaker from here." }
        return "\(aligned) of \(speakers.count) speakers in sync."
    }
}

extension SyncCalibrationStatus.Outcome {
    /// The short line a list shows.
    public var caption: String {
        switch self {
        case .waiting: return "Waiting"
        case .measuring: return "Listening\u{2026}"
        case .aligned(let lagMs, let trimMs, let reachedLimit, let isReference):
            let lag = Int(lagMs.rounded())
            if isReference { return "The others line up to this one" }
            let found = lag == 0 ? "In step" : (lag > 0 ? "Was \(lag) ms late" : "Was \(-lag) ms early")
            let trim = trimMs == 0 ? "no trim" : "trim \(SyncCalibrationStatus.signed(trimMs)) ms"
            return reachedLimit ? "\(found) \u{00B7} \(trim), the most it allows" : "\(found) \u{00B7} \(trim)"
        case .notHeard: return "Couldn\u{2019}t hear it"
        case .unclear: return "Too noisy to be sure"
        case .skipped: return "Not measured"
        }
    }

    /// What to do about an outcome that isn't a measurement; nil when nothing needs doing.
    public func nextStep(microphone: SyncCalibrationStatus.Microphone) -> String? {
        switch self {
        case .notHeard:
            switch microphone {
            case .hub: return "Turn the speaker up, or tune it with your iPhone held next to it."
            case .phone: return "Move closer, turn the speaker up a little, and try again."
            }
        case .unclear: return "Wait for a quiet moment and try again."
        case .skipped: return "The speaker didn\u{2019}t connect. Check it\u{2019}s on, then try again."
        default: return nil
        }
    }
}

extension SyncCalibrationStatus {
    /// "+40", "−172", "0": a trim as people read it (a real minus sign).
    public static func signed(_ ms: Int) -> String {
        ms == 0 ? "0" : "\(ms > 0 ? "+" : "\u{2212}")\(abs(ms))"
    }
}
