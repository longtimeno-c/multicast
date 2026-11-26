import Foundation
import MulticastAudio
import MulticastDiscovery

/// Keeps the network speaker list steady while discovery comes and goes.
///
/// Bonjour drops a speaker the moment a browse reports it gone (a Wi-Fi blip, a re-browse, a
/// bridge restarting) and adds it back seconds later. The roster holds every speaker it has seen:
/// one that left the latest snapshot stays listed, counts as *not seen* once it has been gone
/// `missingAfter`, and is dropped only after `dropAfter`. A speaker that answers again is
/// current at once, with its fresh descriptor (new host or port included). Pure; unit-tested.
public struct SpeakerRoster: Sendable, Equatable {
    public struct Policy: Sendable, Equatable {
        /// Gone this long: listed as not seen.
        public var missingAfter: TimeInterval
        /// Gone this long: removed from the list.
        public var dropAfter: TimeInterval

        public init(missingAfter: TimeInterval = 20, dropAfter: TimeInterval = 180) {
            self.missingAfter = missingAfter
            self.dropAfter = max(dropAfter, missingAfter)
        }
    }

    public struct Listing: Sendable, Equatable {
        /// Every speaker still held, sorted like discovery sorts them.
        public var speakers: [SpeakerDescriptor]
        /// Speakers listed but not seen for at least `missingAfter`, with when they went.
        public var notSeenSince: [String: Date]

        public init(speakers: [SpeakerDescriptor] = [], notSeenSince: [String: Date] = [:]) {
            self.speakers = speakers
            self.notSeenSince = notSeenSince
        }
    }

    private struct Entry: Sendable, Equatable {
        var descriptor: SpeakerDescriptor
        /// nil while the latest snapshot has it; otherwise when it left.
        var goneSince: Date?
    }

    public var policy: Policy
    private var entries: [String: Entry] = [:]

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// Takes the latest discovery snapshot.
    public mutating func observe(_ snapshot: [SpeakerDescriptor], at now: Date) {
        var seen = Set<String>()
        for d in snapshot where seen.insert(d.id).inserted {
            entries[d.id] = Entry(descriptor: d, goneSince: nil)
        }
        for (id, e) in entries where !seen.contains(id) && e.goneSince == nil {
            entries[id]?.goneSince = now
        }
        prune(at: now)
    }

    /// Drops speakers gone for `dropAfter` or longer. Returns whether any were dropped.
    @discardableResult
    public mutating func prune(at now: Date) -> Bool {
        let expired = entries.filter { _, e in
            guard let gone = e.goneSince else { return false }
            return now.timeIntervalSince(gone) >= policy.dropAfter
        }.keys
        for id in expired { entries[id] = nil }
        return !expired.isEmpty
    }

    /// Forgets everything (discovery stopped).
    public mutating func reset() { entries.removeAll() }

    public func listing(at now: Date) -> Listing {
        var notSeen: [String: Date] = [:]
        for (id, e) in entries {
            if let gone = e.goneSince, now.timeIntervalSince(gone) >= policy.missingAfter { notSeen[id] = gone }
        }
        return Listing(speakers: SpeakerCatalog.sorted(entries.values.map(\.descriptor)), notSeenSince: notSeen)
    }
}
