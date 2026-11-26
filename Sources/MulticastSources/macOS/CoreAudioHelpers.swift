#if os(macOS)
import CoreAudio
import Foundation

/// Thin, typed wrappers around `AudioObjectGetPropertyData` & friends. Not real-time safe
/// (they allocate); used only on control paths.
enum CAProp {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(object, &addr)
    }

    /// Fixed-size scalar / struct property.
    static func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          as _: T.Type = T.self) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        guard status == noErr, size == UInt32(MemoryLayout<T>.size) else { return nil }
        return ptr.load(as: T.self)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        scalar(object, selector, scope: scope, as: UInt32.self)
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func setScalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> OSStatus {
        var addr = address(selector)
        var v = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    // MARK: Convenience

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ object: AudioObjectID) -> String? {
        string(object, kAudioObjectPropertyName)
    }

    static func classID(_ object: AudioObjectID) -> AudioClassID? {
        scalar(object, kAudioObjectPropertyClass, as: AudioClassID.self)
    }

    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
        }
        return "\(status)"
    }
}

/// Owns a property listener block registration and removes it on `cancel()`/deinit.
final class CAListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = CAProp.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else { return nil }
        active = true
    }

    func cancel() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { cancel() }
}
#endif
