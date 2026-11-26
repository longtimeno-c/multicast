import Foundation
import MulticastAudio

// MARK: - Feature bits

/// The 64-bit AirPlay feature mask advertised as `ft=` (RAOP) / `features=` (AirPlay),
/// either "0xLO" or "0xLO,0xHI" (high 32 bits after the comma).
///
/// Bit meanings follow the publicly reverse-engineered tables (openairplay / pyatv / shairport-sync);
/// only bits whose meaning is well established get a name. `rawValue` keeps every bit.
public struct AirPlayFeatures: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let video = AirPlayFeatures(bit: 0)
    public static let photo = AirPlayFeatures(bit: 1)
    public static let screen = AirPlayFeatures(bit: 7)
    public static let audio = AirPlayFeatures(bit: 9)
    public static let audioRedundant = AirPlayFeatures(bit: 11)
    public static let audioFormatsDeclared = AirPlayFeatures(bit: 19)
    public static let supportsLegacyPairing = AirPlayFeatures(bit: 27)
    public static let unifiedAdvertiserInfo = AirPlayFeatures(bit: 30)
    /// Bit 38: buffered audio (AirPlay 2 "type 103" streams).
    public static let supportsBufferedAudio = AirPlayFeatures(bit: 38)
    /// Bit 40: PTP clock synchronisation (AirPlay 2).
    public static let supportsPTP = AirPlayFeatures(bit: 40)
    public static let screenMultiCodec = AirPlayFeatures(bit: 41)
    public static let systemPairing = AirPlayFeatures(bit: 42)
    /// Bit 46: HomeKit pairing and access control.
    public static let homeKitPairing = AirPlayFeatures(bit: 46)
    /// Bit 48: CoreUtils pairing and encryption (transient / "pair-setup with PIN 3939").
    public static let transientPairing = AirPlayFeatures(bit: 48)
    public static let unifiedPairSetupAndMFi = AirPlayFeatures(bit: 51)
    public static let audioStreamConnectionSetup = AirPlayFeatures(bit: 59)

    /// Bits that only AirPlay 2 receivers advertise.
    public static let airPlay2Markers: AirPlayFeatures = [.supportsBufferedAudio, .supportsPTP, .transientPairing]

    init(bit: Int) { rawValue = 1 << UInt64(bit) }

    public func contains(bit: Int) -> Bool {
        guard (0 ..< 64).contains(bit) else { return false }
        return rawValue & (1 << UInt64(bit)) != 0
    }

    /// Indices of all set bits, ascending.
    public var setBits: [Int] { (0 ..< 64).filter { contains(bit: $0) } }

    /// Parse "0x445F8A00,0x801C340" (lo,hi), "0x5A7FFFF7" (lo only) or a decimal value.
    /// Returns `nil` for anything malformed.
    public init?(txtValue: String) {
        let parts = txtValue.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1 ... 2).contains(parts.count), let lo = Self.parseWord(parts[0]) else { return nil }
        var value = UInt64(lo)
        if parts.count == 2 {
            guard let hi = Self.parseWord(parts[1]) else { return nil }
            value |= UInt64(hi) << 32
        }
        rawValue = value
    }

    private static func parseWord(_ s: String) -> UInt32? {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let digits = s.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            return UInt32(digits, radix: 16)
        }
        return UInt32(s, radix: 10)
    }

    /// Canonical "0xLO,0xHI" text.
    public var description: String {
        String(format: "0x%X,0x%X", UInt32(truncatingIfNeeded: rawValue), UInt32(truncatingIfNeeded: rawValue >> 32))
    }
}

// MARK: - Status flags

/// `sf=` (RAOP) / `flags=` (AirPlay) status flags.
public struct AirPlayStatusFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let problemDetected = AirPlayStatusFlags(rawValue: 1 << 0)
    public static let notConfigured = AirPlayStatusFlags(rawValue: 1 << 1)
    public static let audioCableAttached = AirPlayStatusFlags(rawValue: 1 << 2)
    public static let pinRequired = AirPlayStatusFlags(rawValue: 1 << 3)
    public static let supportsAirPlayFromCloud = AirPlayStatusFlags(rawValue: 1 << 6)
    public static let passwordRequired = AirPlayStatusFlags(rawValue: 1 << 7)
    public static let oneTimePairingRequired = AirPlayStatusFlags(rawValue: 1 << 9)
    public static let deviceSetupForHKAccessControl = AirPlayStatusFlags(rawValue: 1 << 10)
    public static let relayable = AirPlayStatusFlags(rawValue: 1 << 11)
    public static let silentPrimary = AirPlayStatusFlags(rawValue: 1 << 12)
    public static let tightSyncIsGroupLeader = AirPlayStatusFlags(rawValue: 1 << 13)
    public static let tightSyncBuddyNotReachable = AirPlayStatusFlags(rawValue: 1 << 14)
    public static let receiverSessionIsActive = AirPlayStatusFlags(rawValue: 1 << 17)

    /// Parse "0x404" or a decimal value.
    public init?(txtValue: String) {
        let s = txtValue.trimmingCharacters(in: .whitespaces)
        let parsed: UInt32?
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            parsed = UInt32(s.dropFirst(2), radix: 16)
        } else {
            parsed = UInt32(s, radix: 10)
        }
        guard let parsed else { return nil }
        rawValue = parsed
    }
}

// MARK: - Enumerated capabilities

/// `et=` encryption types.
public enum AirPlayEncryption: Hashable, Sendable {
    case none            // 0
    case rsa             // 1  (AirPort Express AES key wrapped with RSA)
    case fairPlay        // 2
    case mfiSAP          // 3
    case fairPlaySAPv25  // 4
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .none
        case 1: self = .rsa
        case 2: self = .fairPlay
        case 3: self = .mfiSAP
        case 4: self = .fairPlaySAPv25
        default: self = .other(code)
        }
    }
}

/// `cn=` audio codecs.
public enum AirPlayCodec: Hashable, Sendable {
    case pcm     // 0
    case alac    // 1
    case aac     // 2
    case aacELD  // 3
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .pcm
        case 1: self = .alac
        case 2: self = .aac
        case 3: self = .aacELD
        default: self = .other(code)
        }
    }
}

/// `md=` metadata types the receiver accepts.
public enum AirPlayMetadata: Hashable, Sendable {
    case text      // 0
    case artwork   // 1
    case progress  // 2
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .text
        case 1: self = .artwork
        case 2: self = .progress
        default: self = .other(code)
        }
    }
}

enum TXTList {
    /// "0,1,2" -> [0, 1, 2]; unparseable members are skipped.
    static func integers(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func bool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "1", "yes", "": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

// MARK: - Typed accessors

extension SpeakerDescriptor {
    private func raop(_ key: String) -> String? { raopTXT.txtValue(key) }
    private func airplay(_ key: String) -> String? { airplayTXT.txtValue(key) }

    /// Union of the RAOP `ft` and AirPlay `features` masks (they are normally identical).
    public var features: AirPlayFeatures {
        var set = AirPlayFeatures()
        if let ft = raop("ft"), let f = AirPlayFeatures(txtValue: ft) { set.formUnion(f) }
        if let ft = airplay("features"), let f = AirPlayFeatures(txtValue: ft) { set.formUnion(f) }
        return set
    }

    /// Union of RAOP `sf` and AirPlay `flags`.
    public var statusFlags: AirPlayStatusFlags {
        var set = AirPlayStatusFlags()
        if let s = raop("sf"), let f = AirPlayStatusFlags(txtValue: s) { set.formUnion(f) }
        if let s = airplay("flags"), let f = AirPlayStatusFlags(txtValue: s) { set.formUnion(f) }
        return set
    }

    /// Raw `et` codes in advertised order.
    public var encryptionTypeCodes: [Int] { TXTList.integers(raop("et")) }
    public var encryptionTypes: [AirPlayEncryption] { encryptionTypeCodes.map(AirPlayEncryption.init(code:)) }

    /// Raw `cn` codes in advertised order.
    public var codecCodes: [Int] { TXTList.integers(raop("cn")) }
    public var codecs: [AirPlayCodec] { codecCodes.map(AirPlayCodec.init(code:)) }

    public var metadataTypes: [AirPlayMetadata] { TXTList.integers(raop("md")).map(AirPlayMetadata.init(code:)) }
    public var supportsTextMetadata: Bool { metadataTypes.contains(.text) }
    public var supportsArtwork: Bool { metadataTypes.contains(.artwork) }
    public var supportsProgress: Bool { metadataTypes.contains(.progress) }

    /// `pw=true` on either record, or the password-required status flag.
    public var advertisesPasswordRequired: Bool {
        if TXTList.bool(raop("pw")) == true || TXTList.bool(airplay("pw")) == true { return true }
        return statusFlags.contains(.passwordRequired)
    }

    /// The PIN-required status flag (an on-screen code must be entered, e.g. Apple TV).
    public var advertisesPINRequired: Bool { statusFlags.contains(.pinRequired) }

    /// `am` (RAOP) or `model` (AirPlay), e.g. "One", "AVR-X2800H", "airupnp", "Mac17,4".
    public var advertisedModel: String? {
        nonEmpty(airplay("model")) ?? nonEmpty(raop("am"))
    }

    /// `manufacturer=` when advertised; otherwise "Apple" for Apple model identifiers.
    public var manufacturer: String? {
        if let m = nonEmpty(airplay("manufacturer")) ?? nonEmpty(raop("manufacturer")) { return m }
        guard let model = advertisedModel else { return nil }
        let applePrefixes = ["AppleTV", "AudioAccessory", "AirPort", "Mac", "iMac", "MacBook", "iPhone", "iPad", "iPod"]
        if applePrefixes.contains(where: { model.hasPrefix($0) }), model.contains(",") { return "Apple" }
        return nil
    }

    /// RAOP protocol version `vn` (3 = classic AirPlay 1; 65537 = AirPlay 2 era).
    public var raopProtocolVersion: Int? { raop("vn").flatMap { Int($0) } }

    /// Software version `vs` (RAOP) or `srcvers` (AirPlay).
    public var sourceVersion: String? { nonEmpty(raop("vs")) ?? nonEmpty(airplay("srcvers")) }

    /// `deviceid=` from the AirPlay record, normalised.
    public var airplayDeviceID: String? { airplay("deviceid").flatMap(DeviceID.normalize) }

    /// AirConnect (`airupnp` UPnP/Sonos bridge, `aircast` Chromecast bridge) — a software bridge
    /// that receives AirPlay 1 and replays it to a non-AirPlay device.
    public var isAirConnectBridge: Bool {
        guard let am = raop("am")?.lowercased() else { return false }
        return am == "airupnp" || am == "aircast"
    }

    /// Whether the device advertises AirPlay 2 capability. See `SpeakerCatalog.classify`.
    public var advertisesAirPlay2: Bool {
        SpeakerCatalog.classify(raopTXT: raopTXT, airplayTXT: airplayTXT) == .airplay2
    }

    /// `true` when this descriptor is this machine's own AirPlay receiver (resolved host equals
    /// this machine's host name, or the browser saw it on the loopback interface, or its id is
    /// one of `LocalMachineIdentity.current.deviceIDs`).
    public var isThisMachine: Bool { LocalMachineIdentity.current.matches(self) }

    /// The display name with AirConnect's default "+" suffix removed, for matching a bridge
    /// against the native AirPlay advertisement of the same physical device.
    public var physicalDeviceName: String {
        var n = name.trimmingCharacters(in: .whitespaces)
        if isAirConnectBridge {
            while n.hasSuffix("+") { n.removeLast() }
            n = n.trimmingCharacters(in: .whitespaces)
        }
        return n
    }

    /// Heuristic: an AirConnect bridge and a native AirPlay advertisement that drive the same
    /// physical device (e.g. "Denon AVR-X2800H+" via airupnp and native "Denon AVR-X2800H").
    /// Playing to both at once would double the audio, so the UI must offer only one of them.
    ///
    /// True when exactly one of the two is a bridge and their `physicalDeviceName`s match
    /// case-insensitively. AirConnect derives bridge MACs as "BBBB" + 4 bytes of the target's
    /// MAC, which for multi-NIC devices differs in the last byte, so ids are only used as a
    /// secondary signal: bridge suffix within ±4 of the native id's low 4 bytes AND same name stem.
    public func isLikelySamePhysicalDevice(as other: SpeakerDescriptor) -> Bool {
        guard id != other.id, isAirConnectBridge != other.isAirConnectBridge else { return false }
        if physicalDeviceName.caseInsensitiveCompare(other.physicalDeviceName) == .orderedSame { return true }
        let bridge = isAirConnectBridge ? self : other
        let native = isAirConnectBridge ? other : self
        guard bridge.id.count == 12, native.id.count == 12, bridge.id.hasPrefix("bbbb"),
              let b = UInt32(bridge.id.suffix(8), radix: 16),
              let n = UInt32(native.id.suffix(8), radix: 16) else { return false }
        let close = (b > n ? b - n : n - b) <= 4
        let stemB = bridge.physicalDeviceName.lowercased()
        let stemN = native.physicalDeviceName.lowercased()
        return close && (stemB.hasPrefix(stemN) || stemN.hasPrefix(stemB))
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

extension Array where Element == SpeakerDescriptor {
    /// Groups of descriptors that `isLikelySamePhysicalDevice` links (each group has ≥ 2 members).
    public func physicalDeviceConflicts() -> [[SpeakerDescriptor]] {
        var groups: [[SpeakerDescriptor]] = []
        var used = Set<String>()
        for (i, a) in enumerated() where !used.contains(a.id) {
            var group = [a]
            for b in self[(i + 1)...] where !used.contains(b.id) && group.contains(where: { $0.isLikelySamePhysicalDevice(as: b) }) {
                group.append(b)
            }
            if group.count > 1 {
                group.forEach { used.insert($0.id) }
                groups.append(group)
            }
        }
        return groups
    }
}
