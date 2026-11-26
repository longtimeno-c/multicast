import Foundation
import MulticastAudio

/// One resolved Bonjour service instance, as the browser sees it. Pure value; the merge logic
/// below turns a set of these into `SpeakerDescriptor`s, so it can be tested without a network.
public struct ResolvedService: Hashable, Sendable {
    public var type: AirPlayServiceType
    /// Unescaped instance name ("542A1B001122@Hall Sonos" / "Hall Sonos").
    public var instanceName: String
    public var domain: String
    /// Resolved SRV target without the trailing dot ("Sonos-542A1B001122.local").
    public var host: String
    public var port: UInt16
    public var txt: [String: String]
    /// Interface the record was resolved on (0 if unknown).
    public var interfaceIndex: UInt32
    /// The service was seen on the loopback interface, i.e. it is registered by this machine.
    public var seenOnLoopback: Bool

    public init(type: AirPlayServiceType, instanceName: String, domain: String = "local.", host: String, port: UInt16,
                txt: [String: String], interfaceIndex: UInt32 = 0, seenOnLoopback: Bool = false) {
        self.type = type
        self.instanceName = instanceName
        self.domain = domain
        self.host = HostName.clean(host)
        self.port = port
        self.txt = txt
        self.interfaceIndex = interfaceIndex
        self.seenOnLoopback = seenOnLoopback
    }

    /// The device id this record belongs to: the RAOP name prefix, or the AirPlay `deviceid`.
    /// Falls back to a name-derived key so a malformed record still yields one stable entry.
    public var deviceKey: String {
        switch type {
        case .raop:
            let parsed = RAOPInstanceName(instanceName)
            if let id = parsed.deviceID { return id }
            if let id = txt.txtValue("deviceid").flatMap(DeviceID.normalize) { return id }
            return "name:" + parsed.name.lowercased()
        case .airplay:
            if let id = txt.txtValue("deviceid").flatMap(DeviceID.normalize) { return id }
            return "name:" + instanceName.lowercased()
        }
    }

    /// Display name contributed by this record.
    public var displayName: String {
        switch type {
        case .raop: return RAOPInstanceName(instanceName).name
        case .airplay: return instanceName
        }
    }
}

/// Merge rules and classification. All functions are pure.
public enum SpeakerCatalog {
    /// Merge resolved services into one descriptor per device, sorted by name (then id).
    ///
    /// - The `_raop` and `_airplay` records of one device share a key: RAOP "<MACHEX>@…" prefix
    ///   == AirPlay `deviceid` without separators. `id` is that lowercase hex string.
    /// - `name` is the RAOP name (after "@"); the AirPlay instance name is used only for devices
    ///   with no RAOP record.
    /// - `host`/`port` come from the RAOP record (what the sender connects to); a device with only
    ///   an AirPlay record uses the AirPlay host/port.
    /// - When several records of the same type exist for one device (multiple interfaces, or a
    ///   stale + fresh pair), the input order decides: the LAST one wins, so callers pass records
    ///   oldest-first.
    /// - `localMachine` (if given) drops descriptors it matches when `hideThisMachine` is true.
    public static func merge(_ services: [ResolvedService],
                             hideThisMachine: Bool = false,
                             localMachine: LocalMachineIdentity? = nil) -> [SpeakerDescriptor] {
        var raopByKey: [String: ResolvedService] = [:]
        var airplayByKey: [String: ResolvedService] = [:]
        var loopbackKeys = Set<String>()
        for service in services {
            let key = service.deviceKey
            if service.seenOnLoopback { loopbackKeys.insert(key) }
            switch service.type {
            case .raop: raopByKey[key] = service
            case .airplay: airplayByKey[key] = service
            }
        }

        var result: [SpeakerDescriptor] = []
        for key in Set(raopByKey.keys).union(airplayByKey.keys) {
            let raop = raopByKey[key]
            let airplay = airplayByKey[key]
            guard let primary = raop ?? airplay else { continue }
            let raopTXT = raop?.txt ?? [:]
            let airplayTXT = airplay?.txt ?? [:]
            var descriptor = SpeakerDescriptor(
                id: key,
                name: primary.displayName,
                transport: classify(raopTXT: raopTXT, airplayTXT: airplayTXT, hasAirPlayRecord: airplay != nil),
                host: primary.host,
                port: primary.port,
                raopTXT: raopTXT,
                airplayTXT: airplayTXT
            )
            descriptor.model = descriptor.advertisedModel
            descriptor.requiresPassword = descriptor.advertisesPasswordRequired
            if hideThisMachine {
                if loopbackKeys.contains(key) { continue }
                if let localMachine, localMachine.matches(descriptor) { continue }
            }
            result.append(descriptor)
        }
        return sorted(result)
    }

    /// Stable display order: case/diacritic-insensitive name, then id.
    public static func sorted(_ speakers: [SpeakerDescriptor]) -> [SpeakerDescriptor] {
        speakers.sorted { a, b in
            switch a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// `.airplay2` when the device advertises AirPlay 2 capability:
    /// - any AirPlay 2 marker feature bit (38 buffered audio, 40 PTP, 48 transient pairing) in
    ///   RAOP `ft` or AirPlay `features`, or
    /// - an `_airplay._tcp` record together with RAOP `vn=65537` (AirPlay 2 era RAOP version) when
    ///   no feature mask is advertised at all.
    /// Everything else (including AirPlay 1 devices that also advertise `_airplay._tcp` for video,
    /// like old Apple TVs) is `.airplay1`.
    public static func classify(raopTXT: [String: String], airplayTXT: [String: String],
                                hasAirPlayRecord: Bool? = nil) -> SpeakerDescriptor.Transport {
        var features = AirPlayFeatures()
        var sawMask = false
        if let ft = raopTXT.txtValue("ft"), let f = AirPlayFeatures(txtValue: ft) { features.formUnion(f); sawMask = true }
        if let ft = airplayTXT.txtValue("features"), let f = AirPlayFeatures(txtValue: ft) { features.formUnion(f); sawMask = true }
        if !features.isDisjoint(with: .airPlay2Markers) { return .airplay2 }
        let hasAirPlay = hasAirPlayRecord ?? !airplayTXT.isEmpty
        if !sawMask, hasAirPlay, raopTXT.txtValue("vn") == "65537" { return .airplay2 }
        return .airplay1
    }
}
