import Foundation

// MARK: - Speakers

/// Stable identity of a speaker across launches: the hub's speaker id (a RAOP device id such
/// as "542a1b001122", or "local:<Core Audio UID>"). Encodes as a bare string.
public struct SpeakerID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// How audio reaches a speaker. Drives grouping and the default glyph.
public enum SpeakerTransport: String, Sendable, Codable, CaseIterable {
    case airPlay1, airPlay2, builtIn, bluetooth, usb
    /// A paired iPhone playing the stream through its own output (its speaker, or the Bluetooth
    /// speaker or headphones connected to it). Remote protocol version 4 and later.
    case phone

    public var isNetwork: Bool { self == .airPlay1 || self == .airPlay2 }

    public var label: String {
        switch self {
        case .airPlay1: "AirPlay 1"
        case .airPlay2: "AirPlay 2"
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .phone: "iPhone"
        }
    }
}

/// The glyph a speaker row shows. Backends pick one from what they know about the device.
public enum SpeakerGlyph: String, Sendable, Codable, CaseIterable {
    case speaker, smartSpeaker, receiver, airportExpress, laptop, display, portable, headphones, usb
    /// Remote protocol version 4 and later.
    case phone

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .speaker: "hifispeaker.fill"
        case .smartSpeaker: "hifispeaker.fill"
        case .receiver: "hifireceiver.fill"
        case .airportExpress: "hifispeaker.fill"
        // Outline-only symbols; rows draw them a weight heavier.
        case .laptop: "laptopcomputer"
        case .display: "display"
        case .portable: "hifispeaker.fill"
        case .headphones: "headphones"
        case .usb: "cable.connector"
        case .phone: "iphone"
        }
    }
}

/// Live state of one speaker as the hub sees it.
///
/// Wire form (synthesized): `{"off":{}}`, `{"connecting":{}}`, `{"ready":{}}`, `{"playing":{}}`,
/// `{"failed":{"reason":"Not responding"}}`.
public enum SpeakerState: Equatable, Hashable, Sendable, Codable {
    /// Not selected.
    case off
    /// Selected; the hub is opening a session (AirPlay handshake, Core Audio device start).
    case connecting
    /// Selected and connected, but nothing is playing.
    case ready
    /// Selected and receiving the stream.
    case playing
    /// Selected but unusable. `reason` is short, human and sentence case.
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .off: false
        default: true
        }
    }
}

public struct SpeakerItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: SpeakerID
    public var name: String
    public var transport: SpeakerTransport
    public var glyph: SpeakerGlyph
    /// Optional model name ("Sonos One"); shown after the transport when it adds something.
    public var model: String?
    /// Network address or Core Audio device UID, for the detail popover.
    public var address: String?
    /// The user's checkbox.
    public var isEnabled: Bool
    /// 0…1, before the master volume is applied. Adjustable while the speaker is off: it is
    /// then the preset applied on connect. For a speaker with a volume of its own that the hub
    /// can set (an output of the Mac), this is that device's volume, on or off, and it also
    /// moves when the volume is changed outside Multicast.
    public var volume: Double
    public var state: SpeakerState
    /// Per-speaker playout offset in milliseconds. Negative plays earlier.
    public var syncTrimMs: Int
    /// Set while a network speaker has stopped answering on the network (it stays listed for a
    /// while in case it comes back): when it was last heard. nil = answering, or a local output.
    public var notSeenSince: Date?
    /// The speaker turned this hub away: its AirPlay access setting admits only its owner (or
    /// only people in its Home). Not a failure: the hub keeps it off, never turns it on by
    /// itself, and asks it again only on `retrySpeaker` (shown as "Check Again"), with
    /// `isCheckingAccess` set while it asks. Cleared once the speaker lets the hub in.
    ///
    /// Wire: the key `isRestricted` is present only when true, so builds that predate it read
    /// and write every other speaker unchanged, and read its absence as false.
    public var isRestricted: Bool
    /// A restricted speaker is being asked again ("Check Again") right now. Its `state` stays
    /// `.off` meanwhile, so a build that predates this key never shows or counts it as a speaker
    /// that is connecting.
    ///
    /// Wire: the key `isCheckingAccess` is present only when true; absent reads as false.
    public var isCheckingAccess: Bool
    /// When this speaker's sync was last measured by a calibration (the hub keeps the
    /// measurement with the speaker's other settings). nil: never, its trim is 0 or set by hand.
    ///
    /// Wire: the key `tunedAt` is present only when set.
    public var tunedAt: Date?

    public static let syncTrimRange: ClosedRange<Int> = -500...500

    public init(id: SpeakerID, name: String, transport: SpeakerTransport, glyph: SpeakerGlyph,
                model: String? = nil, address: String? = nil, isEnabled: Bool = false,
                volume: Double, state: SpeakerState = .off, syncTrimMs: Int = 0, notSeenSince: Date? = nil,
                isRestricted: Bool = false, isCheckingAccess: Bool = false, tunedAt: Date? = nil) {
        self.tunedAt = tunedAt
        self.id = id
        self.name = name
        self.transport = transport
        self.glyph = glyph
        self.model = model
        self.address = address
        self.isEnabled = isEnabled
        self.volume = volume
        self.state = state
        self.syncTrimMs = syncTrimMs
        self.notSeenSince = notSeenSince
        self.isRestricted = isRestricted
        self.isCheckingAccess = isCheckingAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transport, glyph, model, address, isEnabled, volume, state, syncTrimMs, notSeenSince, isRestricted, isCheckingAccess, tunedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SpeakerID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decode(SpeakerTransport.self, forKey: .transport)
        glyph = try c.decode(SpeakerGlyph.self, forKey: .glyph)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        volume = try c.decode(Double.self, forKey: .volume)
        state = try c.decode(SpeakerState.self, forKey: .state)
        syncTrimMs = try c.decode(Int.self, forKey: .syncTrimMs)
        notSeenSince = try c.decodeIfPresent(Date.self, forKey: .notSeenSince)
        isRestricted = try c.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
        isCheckingAccess = try c.decodeIfPresent(Bool.self, forKey: .isCheckingAccess) ?? false
        tunedAt = try c.decodeIfPresent(Date.self, forKey: .tunedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encode(glyph, forKey: .glyph)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(volume, forKey: .volume)
        try c.encode(state, forKey: .state)
        try c.encode(syncTrimMs, forKey: .syncTrimMs)
        try c.encodeIfPresent(notSeenSince, forKey: .notSeenSince)
        if isRestricted { try c.encode(true, forKey: .isRestricted) }
        if isCheckingAccess { try c.encode(true, forKey: .isCheckingAccess) }
        try c.encodeIfPresent(tunedAt, forKey: .tunedAt)
    }

    /// What the speaker actually plays at: its own level scaled by the master.
    public func effectiveVolume(master: Double) -> Double { volume * master }

    public var kindDescription: String {
        if let model { return "\(transport.label) · \(model)" }
        return transport.label
    }
}

/// How many speakers are in each live state, for the summary line over a speakers list.
/// Speakers that turned the hub away (`isRestricted`) are left out: they aren't failing, they
/// aren't this person's to use. Pure; unit-tested.
public struct SpeakerCounts: Equatable, Sendable {
    public var playing = 0, ready = 0, connecting = 0, failed = 0

    public init() {}

    public init(_ speakers: [SpeakerItem]) {
        for s in speakers where !s.isRestricted {
            switch s.state {
            case .playing: playing += 1
            case .ready: ready += 1
            case .connecting: connecting += 1
            case .failed: failed += 1
            case .off: break
            }
        }
    }

    /// Speakers that are on, whatever their state.
    public var on: Int { playing + ready + connecting + failed }
    public var isEmpty: Bool { on == 0 }

    /// "4 playing · 1 connecting · 1 not responding"; nil while none is on.
    public var summary: String? {
        var parts: [String] = []
        if playing > 0 { parts.append("\(playing) playing") }
        if ready > 0 { parts.append("\(ready) ready") }
        if connecting > 0 { parts.append("\(connecting) connecting") }
        if failed > 0 { parts.append("\(failed) not responding") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
