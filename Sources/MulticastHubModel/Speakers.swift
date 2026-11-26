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

    public var isNetwork: Bool { self == .airPlay1 || self == .airPlay2 }

    public var label: String {
        switch self {
        case .airPlay1: "AirPlay 1"
        case .airPlay2: "AirPlay 2"
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        }
    }
}

/// The glyph a speaker row shows. Backends pick one from what they know about the device.
public enum SpeakerGlyph: String, Sendable, Codable, CaseIterable {
    case speaker, smartSpeaker, receiver, airportExpress, laptop, display, portable, headphones, usb

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
    /// then the preset applied on connect.
    public var volume: Double
    public var state: SpeakerState
    /// Per-speaker playout offset in milliseconds. Negative plays earlier.
    public var syncTrimMs: Int
    /// Set while a network speaker has stopped answering on the network (it stays listed for a
    /// while in case it comes back): when it was last heard. nil = answering, or a local output.
    public var notSeenSince: Date?

    public static let syncTrimRange: ClosedRange<Int> = -500...500

    public init(id: SpeakerID, name: String, transport: SpeakerTransport, glyph: SpeakerGlyph,
                model: String? = nil, address: String? = nil, isEnabled: Bool = false,
                volume: Double, state: SpeakerState = .off, syncTrimMs: Int = 0, notSeenSince: Date? = nil) {
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
    }

    /// What the speaker actually plays at: its own level scaled by the master.
    public func effectiveVolume(master: Double) -> Double { volume * master }

    public var kindDescription: String {
        if let model { return "\(transport.label) · \(model)" }
        return transport.label
    }
}
