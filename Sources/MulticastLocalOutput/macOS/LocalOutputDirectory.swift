#if os(macOS)
import Foundation
import CoreAudio
import MulticastAudio

/// Enumerates this Mac's Core Audio OUTPUT devices as `SpeakerDescriptor`s and keeps the list
/// current via HAL property listeners (device add/remove, default output change).
///
/// - Devices with no output channels and hidden devices are excluded.
/// - Multicast's own private aggregate / tap devices (name or UID prefix "Multicast") are hidden.
/// - Aggregate, virtual and AirPlay-system devices are *included* and flagged through
///   `localKind` (`.aggregate`, `.virtual`, `.airplaySystem`) so the app can filter them.
public final class LocalOutputDirectory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "multicast.localoutput.directory")
    private let devicesBroadcaster: ReplayingBroadcaster<[SpeakerDescriptor]>
    private let defaultBroadcaster: ReplayingBroadcaster<String?>
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let lock = NSLock()
    private var invalidated = false

    public init() {
        devicesBroadcaster = ReplayingBroadcaster(LocalOutputDirectory.enumerate())
        defaultBroadcaster = ReplayingBroadcaster(LocalOutputDirectory.currentDefaultID())
        installListeners()
    }

    deinit {
        invalidate()
    }

    /// Current output devices, sorted built-in first, then by name.
    public var devices: [SpeakerDescriptor] { devicesBroadcaster.current }

    /// Updates whenever the device list changes. Replays the current list to each subscriber.
    public var updates: AsyncStream<[SpeakerDescriptor]> { devicesBroadcaster.makeStream() }

    /// `SpeakerDescriptor.id` of the system default output device, if any.
    public var defaultOutputID: String? { defaultBroadcaster.current }

    /// The default output device's descriptor, if it is in `devices`.
    public var defaultOutput: SpeakerDescriptor? {
        guard let id = defaultOutputID else { return nil }
        return devices.first { $0.id == id }
    }

    /// Updates when the system default output changes. Replays the current value.
    public var defaultOutputUpdates: AsyncStream<String?> { defaultBroadcaster.makeStream() }

    /// Re-enumerate now (normally not needed; listeners do this).
    public func refresh() {
        devicesBroadcaster.sendIfChanged(LocalOutputDirectory.enumerate())
        defaultBroadcaster.sendIfChanged(LocalOutputDirectory.currentDefaultID())
    }

    /// Reported output latency for a device UID (for UI), or nil if it is not connected.
    public func reportedLatency(forDeviceUID uid: String) -> LocalOutputLatency? {
        CoreAudioHAL.deviceID(forUID: uid).map { CoreAudioHAL.outputLatency($0) }
    }

    /// Remove the HAL listeners and finish all streams.
    public func invalidate() {
        lock.lock()
        if invalidated { lock.unlock(); return }
        invalidated = true
        let toRemove = listeners
        listeners.removeAll()
        lock.unlock()
        for (addr, block) in toRemove {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
        devicesBroadcaster.finishAll()
        defaultBroadcaster.finishAll()
    }

    // MARK: Private

    private func installListeners() {
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
        for sel in selectors {
            let addr = CoreAudioHAL.address(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.refresh()
                if sel == kAudioHardwarePropertyDevices {
                    // A freshly connected (e.g. Bluetooth) device may publish its output streams
                    // a moment after it appears; look again shortly.
                    self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
                }
            }
            var a = addr
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            if status == noErr {
                lock.lock()
                listeners.append((addr, block))
                lock.unlock()
            }
        }
    }

    static func enumerate() -> [SpeakerDescriptor] {
        CoreAudioHAL.allDeviceIDs()
            .compactMap { CoreAudioHAL.descriptor(for: $0) }
            .sorted(by: LocalOutputDirectory.order)
    }

    static func currentDefaultID() -> String? {
        CoreAudioHAL.defaultOutputDeviceID()
            .flatMap { CoreAudioHAL.deviceUID($0) }
            .map { LocalKindMapping.speakerID(forDeviceUID: $0) }
    }

    static func order(_ a: SpeakerDescriptor, _ b: SpeakerDescriptor) -> Bool {
        let ra = rank(a.localKind), rb = rank(b.localKind)
        if ra != rb { return ra < rb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    static func rank(_ k: SpeakerDescriptor.LocalKind?) -> Int {
        switch k {
        case .builtIn: return 0
        case .bluetooth: return 1
        case .usb: return 2
        case .hdmi, .displayPort: return 3
        case .other, .none: return 4
        case .airplaySystem: return 5
        case .aggregate: return 6
        case .virtual: return 7
        }
    }
}
#endif
