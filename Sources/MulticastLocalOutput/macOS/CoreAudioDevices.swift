#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import MulticastAudio

/// Thin, synchronous Core Audio HAL queries (never called from an IO thread).
enum CoreAudioHAL {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, as: T.Type) -> T? {
        var a = addr
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, p)
        guard status == noErr else { return nil }
        return p.load(as: T.self)
    }

    static func uint32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        scalar(object, addr, as: UInt32.self)
    }

    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, p) == noErr else { return [] }
        let typed = p.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice))
        return (id ?? 0) == 0 ? nil : id
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        string(id, address(kAudioDevicePropertyDeviceUID))
    }

    static func deviceName(_ id: AudioObjectID) -> String? {
        string(id, address(kAudioObjectPropertyName))
    }

    static func transportType(_ id: AudioObjectID) -> UInt32 {
        uint32(id, address(kAudioDevicePropertyTransportType)) ?? 0
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        (uint32(id, address(kAudioDevicePropertyDeviceIsAlive)) ?? 0) != 0
    }

    static func isHidden(_ id: AudioObjectID) -> Bool {
        (uint32(id, address(kAudioDevicePropertyIsHidden)) ?? 0) != 0
    }

    /// Number of output channels (sum over the output stream configuration's buffers).
    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        // kAudioHardwarePropertyTranslateUIDToDevice: qualifier = CFString UID.
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &a,
                UInt32(MemoryLayout<CFString>.size), q, &size, &device)
        }
        if status == noErr, device != kAudioObjectUnknown { return device }
        // Fallback: linear search (some HAL versions return unknown for transient devices).
        return allDeviceIDs().first { deviceUID($0) == uid }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        scalar(id, address(kAudioDevicePropertyNominalSampleRate), as: Float64.self) ?? Double(PCM.sampleRate)
    }

    /// Reported output latency components of `id`.
    static func outputLatency(_ id: AudioObjectID) -> LocalOutputLatency {
        let out = kAudioObjectPropertyScopeOutput
        let dev = uint32(id, address(kAudioDevicePropertyLatency, out)) ?? 0
        let safety = uint32(id, address(kAudioDevicePropertySafetyOffset, out)) ?? 0
        let buffer = uint32(id, address(kAudioDevicePropertyBufferFrameSize, out)) ?? 0
        let streams = array(id, address(kAudioDevicePropertyStreams, out), of: AudioStreamID.self)
        let stream = streams.first.flatMap { uint32($0, address(kAudioStreamPropertyLatency)) } ?? 0
        return LocalOutputLatency(
            deviceSampleRate: nominalSampleRate(id),
            deviceFrames: dev,
            streamFrames: stream,
            safetyOffsetFrames: safety,
            bufferFrames: buffer
        )
    }

    /// Build the descriptor for one device, or nil if it has no outputs / is hidden / is ours.
    static func descriptor(for id: AudioObjectID) -> SpeakerDescriptor? {
        guard let uid = deviceUID(id) else { return nil }
        let name = deviceName(id) ?? uid
        if LocalKindMapping.isMulticastPrivateDevice(name: name, uid: uid) { return nil }
        if isHidden(id) { return nil }
        guard outputChannelCount(id) > 0 else { return nil }
        let kind = LocalKindMapping.kind(forTransportType: transportType(id))
        let model = string(id, address(kAudioObjectPropertyModelName))
        return SpeakerDescriptor(
            id: LocalKindMapping.speakerID(forDeviceUID: uid),
            name: name,
            transport: .local,
            model: model,
            localDeviceUID: uid,
            localKind: kind
        )
    }
}
#endif
