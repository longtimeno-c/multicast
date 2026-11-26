import Foundation
import MulticastAudio
import MulticastDiscovery

/// Pure helpers for turning what a user typed into speakers, and for the
/// "same physical device" rule. No I/O; unit-tested.
public enum SpeakerMatching {
    public enum Match: Equatable, Sendable {
        case found(SpeakerDescriptor)
        case notFound
        case ambiguous([SpeakerDescriptor])
    }

    /// Case- and diacritic-insensitive comparison key ("Taylor’s" == "taylor's").
    public static func key(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Resolves a user query against a speaker list, in this order:
    /// 1. exact id (`542a1b001122`, `local:BuiltInSpeakerDevice`),
    /// 2. exact name, or a raw RAOP instance name (`542A1B001122@Hall Sonos`),
    /// 3. a unique name prefix.
    /// A name that two speakers share exactly is reported as ambiguous (use the id).
    public static func resolve(_ query: String, in speakers: [SpeakerDescriptor]) -> Match {
        let q = key(query)
        guard !q.isEmpty else { return .notFound }
        if let byID = speakers.first(where: { key($0.id) == q }) { return .found(byID) }

        var nameQuery = q
        if let at = q.firstIndex(of: "@"), let raw = RAOPInstanceName(query).deviceID {
            if let byID = speakers.first(where: { $0.id == raw }) { return .found(byID) }
            nameQuery = String(q[q.index(after: at)...])
        }
        let exact = speakers.filter { key($0.name) == nameQuery }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        let prefixed = speakers.filter { key($0.name).hasPrefix(nameQuery) }
        if prefixed.count == 1 { return .found(prefixed[0]) }
        if prefixed.count > 1 { return .ambiguous(prefixed) }
        return .notFound
    }

    /// The first already-selected speaker that is the same physical box as `candidate`
    /// (e.g. an AirConnect bridge and the native AirPlay 2 advertisement of one receiver).
    /// Playing to both would double the audio with two different delays.
    public static func physicalConflict(for candidate: SpeakerDescriptor,
                                        among selected: [SpeakerDescriptor]) -> SpeakerDescriptor? {
        guard candidate.transport != .local else { return nil }
        return selected.first { other in
            other.transport != .local && other.id != candidate.id && candidate.isLikelySamePhysicalDevice(as: other)
        }
    }
}
