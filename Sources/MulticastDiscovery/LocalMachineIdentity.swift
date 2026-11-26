import Foundation
import MulticastAudio
#if os(macOS)
import SystemConfiguration
#endif

/// How to recognise this machine's own AirPlay receiver among discovered speakers.
///
/// macOS advertises its AirPlay receiver with a *randomised* device id (it is not the en0 MAC),
/// so the id alone cannot be derived locally. Three signals are used instead:
/// 1. the resolved SRV host equals this machine's Bonjour host name ("Taylors-MacBook-Air.local");
/// 2. the browser saw the service on the loopback interface (mDNSResponder delivers locally
///    registered services there) — those ids are recorded at runtime via `noteLocalDeviceID`;
/// 3. any extra ids the app configures.
public struct LocalMachineIdentity: Hashable, Sendable {
    /// Lowercased host names without trailing dot.
    public var hostNames: Set<String>
    /// Normalised device ids (lowercase hex).
    public var deviceIDs: Set<String>

    public init(hostNames: Set<String> = [], deviceIDs: Set<String> = []) {
        self.hostNames = Set(hostNames.map { HostName.clean($0).lowercased() })
        self.deviceIDs = Set(deviceIDs.compactMap(DeviceID.normalize))
    }

    public func matches(_ speaker: SpeakerDescriptor) -> Bool {
        guard speaker.transport != .local else { return false }
        if deviceIDs.contains(speaker.id) { return true }
        if let apID = speaker.airplayDeviceID, deviceIDs.contains(apID) { return true }
        if let host = speaker.host, hostNames.contains(HostName.clean(host).lowercased()) { return true }
        return false
    }

    // MARK: Process-wide current identity

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var hostNames: Set<String>?
        var observedDeviceIDs = Set<String>()
    }
    private static let registry = Registry()

    /// This machine's identity: system host names (cached; see `refreshHostNames`) plus every
    /// device id a `SpeakerBrowser` observed on the loopback interface in this process.
    public static var current: LocalMachineIdentity {
        let r = registry
        r.lock.lock()
        if r.hostNames == nil { r.hostNames = systemHostNames() }
        let identity = LocalMachineIdentity(hostNames: r.hostNames ?? [], deviceIDs: r.observedDeviceIDs)
        r.lock.unlock()
        return identity
    }

    /// Re-read the system host names (they change when the user renames the computer).
    public static func refreshHostNames() {
        let names = systemHostNames()
        registry.lock.lock()
        registry.hostNames = names
        registry.lock.unlock()
    }

    /// Record a device id known to be this machine's (called by the browser on loopback sightings).
    public static func noteLocalDeviceID(_ id: String) {
        guard let id = DeviceID.normalize(id) ?? (id.isEmpty ? nil : id) else { return }
        registry.lock.lock()
        registry.observedDeviceIDs.insert(id)
        registry.lock.unlock()
    }

    /// Bonjour host names of this machine, lowercased, without trailing dot.
    public static func systemHostNames() -> Set<String> {
        var names = Set<String>()
        #if os(macOS)
        if let cf = SCDynamicStoreCopyLocalHostName(nil) {
            let local = cf as String
            if !local.isEmpty { names.insert((local + ".local").lowercased()) }
        }
        #endif
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = HostName.clean(String(cString: buffer)).lowercased()
            // Only a fully qualified mDNS name is unambiguous enough to compare against SRV targets.
            if name.hasSuffix(".local") { names.insert(name) }
        }
        return names
    }
}
