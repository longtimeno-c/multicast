#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox

/// The output volume of this Mac's Core Audio devices: the one the volume keys and the menu
/// bar's Sound slider move, read, set and followed by device UID.
///
/// - A device has a volume here only if Core Audio lets it be set: its virtual main volume
///   (what the system's own slider uses), else the volume of its main element, else of its
///   preferred stereo channels. HDMI outputs, many DACs and most aggregates have none; for
///   those `volume(forDeviceUID:)` is nil and the caller keeps scaling the audio itself.
/// - A muted device reads as 0. Setting a volume above 0 unmutes it, as the volume keys do.
/// - Values are cached and kept current by HAL listeners, so reading is cheap. `changes` fires
///   when anything it has reported moved (volume keys, Control Centre, a device coming or
///   going), at most once per `coalesceSeconds`: a held volume key is a handful of events.
/// - Setting returns at once: the new value is what is reported from then on, and the device
///   is written on a private queue (newest value only, so a fast drag never queues up).
///
/// All Core Audio calls happen on that private queue; none is made from an IO thread.
public final class OutputDeviceVolumes: @unchecked Sendable {
    /// How a device's volume is reached.
    enum Control: Equatable {
        /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, output scope.
        case virtualMain
        /// `kAudioDevicePropertyVolumeScalar` on these output elements (the main element, or
        /// the preferred stereo pair, which are all set to the same value).
        case elements([AudioObjectPropertyElement])
    }

    private struct Entry {
        var device: AudioObjectID
        /// nil: connected, but its volume can't be set.
        var control: Control?
        var hasMute = false
        var volume: Float = 0
        var muted = false
        var listeners: [AudioObjectPropertyAddress] = []
    }

    public static let coalesceSeconds: TimeInterval = 0.08

    private let queue = DispatchQueue(label: "multicast.localoutput.volumes")
    private let lock = NSLock()
    // Guarded by `lock`. Devices are looked up and read on `queue`; `setVolume` only records
    // the value it wants written.
    private var entries: [String: Entry] = [:]
    private var pending: [String: Float] = [:]
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var invalidated = false
    // Only touched on `queue`.
    private var refreshScheduled = false
    /// The listener blocks reach this object through a relay, so they can be made before it is
    /// fully initialised and removed while it is being torn down.
    private final class Relay: @unchecked Sendable { weak var owner: OutputDeviceVolumes? }
    private let relay = Relay()
    private let volumeListener: AudioObjectPropertyListenerBlock
    private let deviceListener: AudioObjectPropertyListenerBlock

    public init() {
        let relay = relay
        volumeListener = { _, _ in relay.owner?.scheduleRefresh() }
        deviceListener = { _, _ in relay.owner?.deviceListChanged() }
        relay.owner = self
        var a = CoreAudioHAL.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, deviceListener)
    }

    deinit { invalidate() }

    /// 0…1, or nil when the device isn't connected or its volume can't be set.
    public func volume(forDeviceUID uid: String) -> Float? {
        if let known = lock.withLock({ entries[uid] }) { return Self.reported(known) }
        return queue.sync { Self.reported(probe(uid)) }
    }

    /// Sets the device's volume (clamped to 0…1) and unmutes it when above 0. Nothing happens
    /// for a device without a settable volume.
    public func setVolume(_ volume: Float, forDeviceUID uid: String) {
        guard self.volume(forDeviceUID: uid) != nil else { return }
        let v = volume.isFinite ? min(1, max(0, volume)) : 0
        lock.withLock {
            // No entry: the device list changed since the line above. The value waits all the
            // same, and `drain` looks the device up again.
            if let known = entries[uid], known.control == nil { return }
            entries[uid]?.volume = v
            if v > 0 { entries[uid]?.muted = false }
            pending[uid] = v
        }
        queue.async { [weak self] in self?.drain() }
    }

    /// Fires (no payload) when a reported volume changed or may have: read again.
    public var changes: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        let finished: Bool = lock.withLock {
            if invalidated { return true }
            continuations[key] = continuation
            return false
        }
        if finished { continuation.finish() }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.continuations.removeValue(forKey: key) }
        }
        return stream
    }

    /// Removes the HAL listeners and finishes all streams.
    public func invalidate() {
        let (old, streams): ([Entry], [AsyncStream<Void>.Continuation]) = lock.withLock {
            if invalidated { return ([], []) }
            invalidated = true
            let e = Array(entries.values)
            let s = Array(continuations.values)
            entries.removeAll()
            pending.removeAll()
            continuations.removeAll()
            return (e, s)
        }
        for e in old { removeListeners(e) }
        var a = CoreAudioHAL.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, deviceListener)
        for c in streams { c.finish() }
    }

    // MARK: Private (on `queue`)

    private static func reported(_ e: Entry?) -> Float? {
        guard let e, e.control != nil else { return nil }
        return e.muted ? 0 : e.volume
    }

    /// Looks the device up, reads it and starts listening to it. A device that isn't connected
    /// is remembered as having no volume until the device list next changes.
    private func probe(_ uid: String) -> Entry? {
        if let known = lock.withLock({ entries[uid] }) { return known }
        guard !lock.withLock({ invalidated }) else { return nil }
        guard let device = CoreAudioHAL.deviceID(forUID: uid) else {
            let absent = Entry(device: AudioObjectID(kAudioObjectUnknown), control: nil)
            lock.withLock { entries[uid] = absent }
            return absent
        }
        var entry = Entry(device: device, control: Self.control(of: device))
        if entry.control != nil {
            entry.hasMute = Self.isSettable(device, Self.muteAddress)
            for addr in Self.watched(device) {
                var a = addr
                if AudioObjectAddPropertyListenerBlock(device, &a, queue, volumeListener) == noErr { entry.listeners.append(addr) }
            }
            Self.read(&entry)
        }
        lock.withLock {
            // A value still waiting to be written (the device list changed under it) is the
            // one to report, not what the device had before.
            if entry.control != nil, let waiting = pending[uid] {
                entry.volume = waiting
                if waiting > 0 { entry.muted = false }
            }
            entries[uid] = entry
        }
        return entry
    }

    private func deviceListChanged() {
        forgetDevices()
        // A freshly connected (e.g. Bluetooth) device may publish its volume control a moment
        // after it appears; look again shortly.
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.forgetDevices() }
    }

    /// The device list changed: object ids and controls may be different now. Everything is
    /// looked up afresh the next time it is asked for. Values still waiting to be written stay
    /// (Multicast's own capture devices coming and going change the list too, and a volume set
    /// at that moment must not be lost): they are written to the devices as found now.
    private func forgetDevices() {
        let (old, waiting): ([Entry], Bool) = lock.withLock {
            let e = Array(entries.values)
            entries.removeAll()
            return (e, !pending.isEmpty)
        }
        for e in old { removeListeners(e) }
        if waiting { drain() }
        if !old.isEmpty { notify() }
    }

    private func removeListeners(_ e: Entry) {
        for addr in e.listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(e.device, &a, queue, volumeListener)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + Self.coalesceSeconds) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Reads every followed device again and says so if anything moved. A device with a write
    /// still waiting is left alone: its newest value is the one being reported.
    private func refresh() {
        let (snapshot, waiting) = lock.withLock { (entries, Set(pending.keys)) }
        var changed = false
        for (uid, old) in snapshot where old.control != nil && !waiting.contains(uid) {
            var e = old
            Self.read(&e)
            guard abs(e.volume - old.volume) > 0.0005 || e.muted != old.muted else { continue }
            let applied: Bool = lock.withLock {
                guard entries[uid]?.device == old.device, pending[uid] == nil else { return false }
                entries[uid]?.volume = e.volume
                entries[uid]?.muted = e.muted
                return true
            }
            changed = changed || applied
        }
        if changed { notify() }
    }

    /// Writes the newest value waiting for each device.
    private func drain() {
        let waiting = lock.withLock { pending }
        // A device forgotten since the value was set is looked up again (it takes the waiting
        // value as its own); one that has gone, or lost its control, drops it.
        let work: [(Entry, Float)] = waiting.compactMap { uid, v in probe(uid).map { ($0, v) } }
        lock.withLock {
            // A newer value set meanwhile stays for the drain that follows it.
            for (uid, v) in waiting where pending[uid] == v { pending[uid] = nil }
        }
        for (e, v) in work {
            guard let control = e.control else { continue }
            Self.write(v, to: e.device, control)
            if v > 0, e.hasMute, (CoreAudioHAL.uint32(e.device, Self.muteAddress) ?? 0) != 0 {
                Self.set(e.device, Self.muteAddress, UInt32(0))
            }
        }
        // The device rounds to its own steps: report what it settled on.
        if !work.isEmpty { scheduleRefresh() }
    }

    private func notify() {
        let targets = lock.withLock { Array(continuations.values) }
        for c in targets { c.yield(()) }
    }

    // MARK: Core Audio

    private static let output = kAudioObjectPropertyScopeOutput
    private static let virtualMainAddress = CoreAudioHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output)
    private static let muteAddress = CoreAudioHAL.address(kAudioDevicePropertyMute, output)

    private static func scalarAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        CoreAudioHAL.address(kAudioDevicePropertyVolumeScalar, output, element)
    }

    private static func isSettable(_ device: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        guard AudioObjectHasProperty(device, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static func control(of device: AudioObjectID) -> Control? {
        if isSettable(device, virtualMainAddress) { return .virtualMain }
        if isSettable(device, scalarAddress(kAudioObjectPropertyElementMain)) { return .elements([kAudioObjectPropertyElementMain]) }
        let stereo = CoreAudioHAL.array(device, CoreAudioHAL.address(kAudioDevicePropertyPreferredChannelsForStereo, output),
                                        of: UInt32.self)
        let channels = (stereo.isEmpty ? [1, 2] : stereo).filter { isSettable(device, scalarAddress($0)) }
        return channels.isEmpty ? nil : .elements(channels)
    }

    /// Everything whose change can move the reported value: the virtual main volume, the
    /// channel volumes under it, and mute.
    private static func watched(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let stereo = CoreAudioHAL.array(device, CoreAudioHAL.address(kAudioDevicePropertyPreferredChannelsForStereo, output),
                                        of: UInt32.self)
        let elements = [kAudioObjectPropertyElementMain] + (stereo.isEmpty ? [1, 2] : stereo)
        let candidates = [virtualMainAddress, muteAddress] + elements.map(scalarAddress)
        return candidates.filter { var a = $0; return AudioObjectHasProperty(device, &a) }
    }

    private static func read(_ e: inout Entry) {
        switch e.control {
        case .virtualMain?:
            if let v = CoreAudioHAL.scalar(e.device, virtualMainAddress, as: Float32.self) { e.volume = clamp(v) }
        case .elements(let elements)?:
            let values = elements.compactMap { CoreAudioHAL.scalar(e.device, scalarAddress($0), as: Float32.self) }
            if !values.isEmpty { e.volume = clamp(values.reduce(0, +) / Float(values.count)) }
        case nil:
            return
        }
        e.muted = e.hasMute && (CoreAudioHAL.uint32(e.device, muteAddress) ?? 0) != 0
    }

    private static func write(_ volume: Float, to device: AudioObjectID, _ control: Control) {
        switch control {
        case .virtualMain: set(device, virtualMainAddress, Float32(volume))
        case .elements(let elements): for el in elements { set(device, scalarAddress(el), Float32(volume)) }
        }
    }

    private static func set<T>(_ device: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) {
        var a = addr
        _ = withUnsafePointer(to: value) { AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    private static func clamp(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
}
#endif
