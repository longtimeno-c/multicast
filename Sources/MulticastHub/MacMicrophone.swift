#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import MulticastAudio
import MulticastCalibration
import MulticastHubModel
import os

/// The Mac's microphone, for sync calibration: an IOProc on an input device, one channel into a
/// `RecordingRing`, each buffer stamped with the host time the device gives for its first
/// sample, less the input latency the device reports (so times are when the sound was in the
/// air, as nearly as the device knows).
///
/// The built-in microphone is used when there is one, whatever the default input is; otherwise
/// the default input. A Bluetooth microphone is never opened: doing so switches a headset to
/// its call mode, which changes the very output delay being measured.
///
/// Permission: Microphone access (`NSMicrophoneUsageDescription`). Nothing is kept beyond the
/// ring's few seconds, and nothing leaves this process.
public final class MacMicrophone: CalibrationMicrophone, @unchecked Sendable {
    public enum MicrophoneError: Error, Equatable {
        case noMicrophone
        case unsupportedFormat
        case startFailed(OSStatus)
    }

    private struct Running {
        var device: AudioObjectID
        var procID: AudioDeviceIOProcID
        var ring: RecordingRing
    }

    private let running = OSAllocatedUnfairLock<Running?>(uncheckedState: nil)

    public init() {}

    deinit { stopNow() }

    public func access(ask: Bool) async -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined:
            guard ask else { return .notDetermined }
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        default: return .denied
        }
    }

    public func start() async throws {
        guard running.withLockUnchecked({ $0 == nil }) else { return }
        guard let device = Self.chooseDevice() else { throw MicrophoneError.noMicrophone }
        let rate: Double = Self.value(device, kAudioDevicePropertyNominalSampleRate) ?? 0
        guard rate >= 8000, Self.inputIsFloat32(device) else { throw MicrophoneError.unsupportedFormat }
        let latencyNanos = UInt64(Double(Self.inputLatencyFrames(device)) / rate * 1e9)
        let ring = RecordingRing(sampleRate: rate, seconds: 6)

        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
            guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count > 0, let data = list[0].mData else { return }
            let channels = max(1, Int(list[0].mNumberChannels))
            let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let heard = HostClock.nanos(fromHostTicks: inputTime.pointee.mHostTime)
            ring.append(data.assumingMemoryBound(to: Float.self), frames: frames, stride: channels,
                        hostNanos: heard > latencyNanos ? heard - latencyNanos : 0)
        }
        guard created == noErr, let procID else { throw MicrophoneError.startFailed(created) }
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            throw MicrophoneError.startFailed(started)
        }
        running.withLockUnchecked { $0 = Running(device: device, procID: procID, ring: ring) }
    }

    public func stop() async { stopNow() }

    private func stopNow() {
        guard let r = running.withLockUnchecked({ r -> Running? in defer { r = nil }; return r }) else { return }
        AudioDeviceStop(r.device, r.procID)
        AudioDeviceDestroyIOProcID(r.device, r.procID)
    }

    public func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep? {
        guard let ring = running.withLockUnchecked({ $0?.ring }) else { return nil }
        // The correlation is a few tens of milliseconds of arithmetic: off the caller's actor.
        return await Task.detached(priority: .userInitiated) {
            ring.heard(signal, fromHostNanos: fromHostNanos, seconds: seconds)
        }.value
    }

    /// The last `seconds` heard, thinned to about `points` values (a live waveform); empty
    /// while not listening.
    public func waveform(seconds: Double = 0.05, points: Int = 120) -> [Float] {
        guard let ring = running.withLockUnchecked({ $0?.ring }) else { return [] }
        let count = Int(seconds * ring.sampleRate)
        return ring.latest(points, step: max(1, count / max(1, points)))
    }

    // MARK: Core Audio

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return pointer.pointee
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputStreams(_ device: AudioObjectID) -> [AudioObjectID] {
        objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    }

    /// The built-in microphone if there is one; else the default input, unless that is a
    /// Bluetooth or virtual device.
    static func chooseDevice() -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let inputs = objects(system, kAudioHardwarePropertyDevices).filter { !inputStreams($0).isEmpty }
        func transport(_ d: AudioObjectID) -> UInt32 { value(d, kAudioDevicePropertyTransportType) ?? 0 }
        if let builtIn = inputs.first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn }) { return builtIn }
        guard let preferred: AudioObjectID = value(system, kAudioHardwarePropertyDefaultInputDevice),
              inputs.contains(preferred) else { return nil }
        let unusable = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                        kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate]
        return unusable.contains(transport(preferred)) ? nil : preferred
    }

    private static func inputIsFloat32(_ device: AudioObjectID) -> Bool {
        guard let stream = inputStreams(device).first,
              let format: AudioStreamBasicDescription = value(stream, kAudioStreamPropertyVirtualFormat) else { return false }
        return format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    /// Device latency + safety offset + the stream's own, on the input side, in frames.
    private static func inputLatencyFrames(_ device: AudioObjectID) -> UInt32 {
        let input = kAudioObjectPropertyScopeInput
        let deviceLatency: UInt32 = value(device, kAudioDevicePropertyLatency, scope: input) ?? 0
        let safety: UInt32 = value(device, kAudioDevicePropertySafetyOffset, scope: input) ?? 0
        let stream: UInt32 = inputStreams(device).first.flatMap { value($0, kAudioStreamPropertyLatency) } ?? 0
        return deviceLatency + safety + stream
    }
}
#endif
