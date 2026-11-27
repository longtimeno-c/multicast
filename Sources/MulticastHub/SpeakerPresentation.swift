import Foundation
import MulticastAudio
import MulticastDiscovery
import MulticastEngine
import MulticastHubModel

/// Pure mapping from what discovery and the engine know about a speaker to what a hub UI shows.
/// No I/O; unit-tested.
public enum SpeakerPresentation {
    // MARK: Transport and glyph

    public static func transport(for d: SpeakerDescriptor) -> SpeakerTransport {
        switch d.transport {
        case .airplay1: return .airPlay1
        case .airplay2: return .airPlay2
        case .remote: return .phone
        case .local:
            switch d.localKind {
            case .bluetooth: return .bluetooth
            case .usb: return .usb
            // HubModel has no wired-display transport; HDMI/DisplayPort/virtual outputs are
            // external wired outputs, the closest is USB (the model string names the real kind).
            case .hdmi, .displayPort, .virtual, .aggregate, .other: return .usb
            case .builtIn, .airplaySystem, .none: return .builtIn
            }
        }
    }

    /// - Parameter hostIsLaptop: whether this Mac is a laptop (its built-in output gets the
    ///   laptop glyph, otherwise a display or speaker).
    public static func glyph(for d: SpeakerDescriptor, hostIsLaptop: Bool) -> SpeakerGlyph {
        switch d.transport {
        case .remote: return .phone
        case .local:
            switch d.localKind {
            case .builtIn, .none:
                if hostIsLaptop { return .laptop }
                return d.name.localizedCaseInsensitiveContains("display") ? .display : .speaker
            case .bluetooth:
                let n = d.name.lowercased()
                let wornWords = ["airpods", "headphone", "buds", "beats", "headset", "wh-", "wf-", "qc"]
                return wornWords.contains(where: { n.contains($0) }) ? .headphones : .portable
            case .usb: return .usb
            case .hdmi, .displayPort: return .display
            case .airplaySystem, .virtual, .aggregate, .other: return .speaker
            }
        case .airplay1, .airplay2:
            let model = (d.advertisedModel ?? "").lowercased()
            let maker = (d.manufacturer ?? "").lowercased()
            if d.isAirConnectBridge { return bridgedGlyph(name: d.physicalDeviceName) }
            if model.hasPrefix("audioaccessory") { return .smartSpeaker }
            if model.hasPrefix("airport") { return .airportExpress }
            if model.hasPrefix("appletv") { return .display }
            if model.hasPrefix("mac") || model.hasPrefix("imac") { return .laptop }
            if maker.contains("sonos") || sonosModels.contains(model) {
                return ["roam", "move", "roam sl", "move 2"].contains(model) ? .portable : .smartSpeaker
            }
            if isReceiver(model: model, maker: maker) { return .receiver }
            if maker.contains("bose") || maker.contains("bang") { return .smartSpeaker }
            return .speaker
        }
    }

    private static let sonosModels: Set<String> = [
        "one", "one sl", "era 100", "era 300", "five", "play:1", "play:3", "play:5", "beam", "arc", "arc ultra",
        "ray", "amp", "port", "connect", "connect:amp", "playbar", "playbase", "symfonisk", "roam", "roam sl",
        "move", "move 2", "sub", "sub mini",
    ]

    private static func isReceiver(model: String, maker: String) -> Bool {
        let makers = ["denon", "marantz", "yamaha", "onkyo", "pioneer", "integra", "harman kardon", "nad", "cambridge"]
        if makers.contains(where: { maker.contains($0) }) { return true }
        let markers = ["avr", "avc-", "rx-v", "rx-a", "tx-nr", "vsx-", "sr5", "sr6", "sr7", "nr1", "receiver", "cinema"]
        return markers.contains(where: { model.contains($0) })
    }

    /// An AirConnect bridge says nothing about its target except the name.
    private static func bridgedGlyph(name: String) -> SpeakerGlyph {
        let n = name.lowercased()
        if ["denon", "marantz", "yamaha", "onkyo", "receiver", "avr"].contains(where: { n.contains($0) }) { return .receiver }
        if n.contains("sonos") { return .smartSpeaker }
        return .speaker
    }

    // MARK: Model and address

    /// A short human model name, or nil when there is nothing better than the transport label.
    public static func modelName(for d: SpeakerDescriptor) -> String? {
        switch d.transport {
        // What the phone plays through ("Speaker", or the name of its Bluetooth speaker).
        case .remote: return d.model
        case .local:
            switch d.localKind {
            case .hdmi: return "HDMI"
            case .displayPort: return "DisplayPort"
            case .virtual: return "Virtual output"
            case .aggregate: return "Aggregate device"
            default: return nil
            }
        case .airplay1, .airplay2:
            if d.isAirConnectBridge { return "AirConnect bridge" }
            guard let raw = d.advertisedModel else { return nil }
            if let apple = appleModelName(raw) { return apple }
            if let maker = d.manufacturer, maker != "Apple", !raw.lowercased().hasPrefix(maker.lowercased()) {
                return "\(maker) \(raw)"
            }
            return raw
        }
    }

    static func appleModelName(_ identifier: String) -> String? {
        if identifier.hasPrefix("AudioAccessory5") { return "HomePod mini" }
        if identifier.hasPrefix("AudioAccessory6") { return "HomePod" }
        if identifier.hasPrefix("AudioAccessory") { return "HomePod" }
        if identifier.hasPrefix("AirPort") { return "AirPort Express" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        if identifier.hasPrefix("MacBook") || identifier.hasPrefix("Mac") && identifier.contains(",") { return "Mac" }
        return nil
    }

    /// Host and port for network speakers (a trailing DNS dot removed), the Core Audio UID for
    /// local ones.
    public static func address(for d: SpeakerDescriptor) -> String? {
        switch d.transport {
        case .remote:
            return nil
        case .local:
            return d.localDeviceUID
        case .airplay1, .airplay2:
            guard var host = d.host, !host.isEmpty else { return nil }
            if host.hasSuffix(".") { host.removeLast() }
            if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }  // IPv6 literal
            if let port = d.port { return "\(host):\(port)" }
            return host
        }
    }

    // MARK: State

    /// The UI state of a selected speaker from its engine entry. `nil` entry = selected but not
    /// yet known to the engine (the add is in flight).
    public static func state(for entry: EngineSnapshot.SinkEntry?) -> SpeakerState {
        guard let entry else { return .connecting }
        switch entry.state {
        case .idle: return .ready
        case .connecting: return .connecting
        case .playing: return .playing
        case .failed: return .failed(reason: FailureWording.plain(entry.error ?? ""))
        case .disabled: return .off
        }
    }
}

/// Turns the engine's and transports' technical failure strings into a few plain words for a
/// speaker row. Unit-tested against the messages MulticastEngine, MulticastRAOP,
/// MulticastLocalOutput and MulticastKit actually produce.
public enum FailureWording {
    /// The speaker's AirPlay access setting turned this sender away (`RAOPError.accessRefused`):
    /// not a fault to retry or show as one, but a speaker this person may not use.
    public static func isAccessRefusal(_ raw: String?) -> Bool {
        (raw ?? "").lowercased().contains("refused access")
    }

    public static func plain(_ raw: String) -> String {
        let s = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains(where: { s.contains($0) }) }
        if s.isEmpty { return "Couldn\u{2019}t connect" }
        if has("did not become ready", "timed out", "timeout", "not responding") { return "Not responding" }
        if has("refused access") { return "Blocked by its AirPlay access setting" }
        if has("rejected the password", "authentication") { return "Wrong AirPlay password" }
        if has("requires a password", "password") { return "Needs an AirPlay password" }
        if has(" 453", "busy", "in use", "not enough bandwidth") { return "In use by another device" }
        if has("rejected set_parameter volume") { return "Didn\u{2019}t accept the volume" }
        if has("no host/port", "no resolved host", "missingaddress") { return "Not found on the network" }
        if has("closed the rtsp connection", "connection closed", "connection reset", "broken pipe") {
            return "The speaker hung up"
        }
        if has("cannot connect", "connection refused", "unreachable", "no route", "network is down") {
            return "Can\u{2019}t reach it on the network"
        }
        if has("is not connected", "not available", "no output channels", "not a local output") {
            return "Output not available"
        }
        if has("osstatus") { return "Core Audio refused the output" }
        if has("same physical device") { return "Same receiver as another speaker" }
        return "Couldn\u{2019}t connect"
    }
}
