import Foundation

/// Turns measured delays into sync trims that line the speakers up.
///
/// Every delay here was measured through the same microphone, so whatever that microphone adds
/// (its own input latency) is in all of them alike and drops out: only the differences between
/// speakers are used. One speaker is the reference and keeps its trim; the others are moved to
/// arrive with it.
///
/// The reference is the preferred speaker when one was measured (the Mac's own speakers, whose
/// delay the system reports truthfully), otherwise the earliest one: a speaker that under-reports
/// its delay plays late, so the earliest is the one most likely to be on time, and speakers that
/// could not be measured (another room) stay in step with it.
public enum TrimPlanner {
    public struct Input: Equatable, Sendable {
        public var id: String
        /// How late the speaker was heard, in milliseconds, with `currentTrimMs` in effect.
        /// On any common scale: only differences between speakers matter.
        public var delayMs: Double
        public var currentTrimMs: Int
        public var isPreferredReference: Bool

        public init(id: String, delayMs: Double, currentTrimMs: Int, isPreferredReference: Bool = false) {
            self.id = id
            self.delayMs = delayMs
            self.currentTrimMs = currentTrimMs
            self.isPreferredReference = isPreferredReference
        }
    }

    public struct Output: Equatable, Sendable {
        public var id: String
        /// The trim to set, within the allowed range.
        public var trimMs: Int
        /// How late this speaker plays behind the reference with no trims at all (negative: ahead).
        public var lagMs: Double
        /// The trim that would line it up lies outside the range; it was set as far as it goes.
        public var isOutOfRange: Bool
        /// This is the speaker the others were lined up to.
        public var isReference: Bool

        public init(id: String, trimMs: Int, lagMs: Double, isOutOfRange: Bool, isReference: Bool = false) {
            self.id = id
            self.trimMs = trimMs
            self.lagMs = lagMs
            self.isOutOfRange = isOutOfRange
            self.isReference = isReference
        }
    }

    public static func plan(_ inputs: [Input], range: ClosedRange<Int>) -> [Output] {
        guard !inputs.isEmpty else { return [] }
        // Lateness with no trim: a positive trim plays later, so it is taken back out.
        let natural = inputs.map { $0.delayMs - Double($0.currentTrimMs) }
        let referenceIndex = inputs.firstIndex(where: \.isPreferredReference)
            ?? natural.indices.min(by: { natural[$0] < natural[$1] })!
        let target = natural[referenceIndex] + Double(inputs[referenceIndex].currentTrimMs)
        var trims = natural.map { Int((target - $0).rounded()) }

        // All of them can move together without changing how they line up: do that when it
        // brings every trim into range (which then costs nothing but the reference's own trim).
        let low = trims.min()!, high = trims.max()!
        if high - low <= range.upperBound - range.lowerBound {
            let shift = low < range.lowerBound ? range.lowerBound - low : (high > range.upperBound ? range.upperBound - high : 0)
            trims = trims.map { $0 + shift }
        }
        return inputs.indices.map { i in
            let clamped = min(range.upperBound, max(range.lowerBound, trims[i]))
            return Output(id: inputs[i].id, trimMs: clamped, lagMs: natural[i] - natural[referenceIndex],
                          isOutOfRange: clamped != trims[i], isReference: i == referenceIndex)
        }
    }
}
