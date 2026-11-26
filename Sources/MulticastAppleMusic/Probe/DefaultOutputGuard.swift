#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// Safety rails for live experiments: identifies the system default output device and lets an
/// experiment cap its volume before any audio starts, then put it back.
///
/// Used only by probes and live tests (`MusicKitRenderProbe`, the gated live tests). Production
/// playback never changes the system volume.
public struct DefaultOutputDevice: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let name: String
    public let uid: String
    public let isBuiltIn: Bool

    /// The current default output device, or nil if Core Audio reports none.
    public static func current() -> DefaultOutputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        let name = string(dev, kAudioObjectPropertyName) ?? "?"
        let uid = string(dev, kAudioDevicePropertyDeviceUID) ?? "?"
        var transport: UInt32 = 0
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(dev, &tAddr, 0, nil, &size, &transport)
        return DefaultOutputDevice(objectID: dev, name: name, uid: uid, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// Scalar output volume 0…1, or nil when the device has no settable volume.
    public var volume: Float32? {
        var addr = Self.volumeAddress
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(objectID, &addr),
              AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Sets the scalar output volume. Returns false when the device refuses.
    @discardableResult
    public func setVolume(_ value: Float32) -> Bool {
        var addr = Self.volumeAddress
        var v = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(objectID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
#endif
