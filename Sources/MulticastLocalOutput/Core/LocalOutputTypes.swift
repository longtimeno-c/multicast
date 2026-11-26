import Foundation
import MulticastAudio

// MARK: - Device kind mapping

public enum LocalKindMapping {
    /// Core Audio `kAudioDevicePropertyTransportType` four-char codes (spelled out so the mapping
    /// is portable and testable without Core Audio).
    public enum TransportType {
        public static let unknown: UInt32 = 0
        public static let builtIn: UInt32 = fourCC("bltn")
        public static let aggregate: UInt32 = fourCC("grup")
        public static let virtual: UInt32 = fourCC("virt")
        public static let pci: UInt32 = fourCC("pci ")
        public static let usb: UInt32 = fourCC("usb ")
        public static let fireWire: UInt32 = fourCC("1394")
        public static let bluetooth: UInt32 = fourCC("blue")
        public static let bluetoothLE: UInt32 = fourCC("blea")
        public static let hdmi: UInt32 = fourCC("hdmi")
        public static let displayPort: UInt32 = fourCC("dprt")
        public static let airPlay: UInt32 = fourCC("airp")
        public static let avb: UInt32 = fourCC("eavb")
        public static let thunderbolt: UInt32 = fourCC("thun")
        public static let continuityCaptureWired: UInt32 = fourCC("ccwd")
        public static let continuityCaptureWireless: UInt32 = fourCC("ccwl")
    }

    public static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
        return v
    }

    /// Map a Core Audio transport type to the contract's `LocalKind`.
    public static func kind(forTransportType t: UInt32) -> SpeakerDescriptor.LocalKind {
        switch t {
        case TransportType.builtIn: return .builtIn
        case TransportType.bluetooth, TransportType.bluetoothLE: return .bluetooth
        case TransportType.usb: return .usb
        case TransportType.hdmi: return .hdmi
        case TransportType.displayPort: return .displayPort
        case TransportType.airPlay: return .airplaySystem
        case TransportType.virtual: return .virtual
        case TransportType.aggregate: return .aggregate
        default: return .other
        }
    }

    /// Map an `AVAudioSession.Port` raw value (iOS route output port type) to `LocalKind`.
    public static func kind(forRoutePortType portType: String) -> SpeakerDescriptor.LocalKind {
        switch portType {
        case "Speaker", "Receiver": return .builtIn
        case "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP": return .bluetooth
        case "USBAudio": return .usb
        case "HDMI": return .hdmi
        case "AirPlay": return .airplaySystem
        case "Virtual": return .virtual
        default: return .other // Headphones, LineOut, CarAudio…
        }
    }

    /// Multicast's own private aggregate / tap devices are never offered as speakers.
    public static func isMulticastPrivateDevice(name: String, uid: String) -> Bool {
        name.hasPrefix("Multicast") || uid.hasPrefix("Multicast")
    }

    static func speakerID(forDeviceUID uid: String) -> String { "local:" + uid }
}

// MARK: - Latency

/// The output latency a local sink compensates for, broken down for UI.
public struct LocalOutputLatency: Sendable, Equatable {
    /// Nominal device sample rate the frame counts below are expressed in.
    public var deviceSampleRate: Double
    /// `kAudioDevicePropertyLatency` (output scope), device frames.
    public var deviceFrames: UInt32
    /// `kAudioStreamPropertyLatency` of the first output stream, device frames.
    public var streamFrames: UInt32
    /// `kAudioDevicePropertySafetyOffset` (output scope), device frames.
    public var safetyOffsetFrames: UInt32
    /// IO buffer size in device frames (reported for information; not part of `totalNanos`
    /// because the callback timestamp already refers to the start of the buffer being filled).
    public var bufferFrames: UInt32
    /// Output unit / sample-rate-converter latency (`kAudioUnitProperty_Latency`), seconds.
    public var unitLatencySeconds: Double
    /// Extra latency reported by the platform in seconds (iOS: `AVAudioSession.outputLatency`, the
    /// IO buffer is not added, same rationale as macOS; macOS: 0).
    public var platformLatencySeconds: Double

    public init(
        deviceSampleRate: Double,
        deviceFrames: UInt32 = 0,
        streamFrames: UInt32 = 0,
        safetyOffsetFrames: UInt32 = 0,
        bufferFrames: UInt32 = 0,
        unitLatencySeconds: Double = 0,
        platformLatencySeconds: Double = 0
    ) {
        self.deviceSampleRate = deviceSampleRate
        self.deviceFrames = deviceFrames
        self.streamFrames = streamFrames
        self.safetyOffsetFrames = safetyOffsetFrames
        self.bufferFrames = bufferFrames
        self.unitLatencySeconds = unitLatencySeconds
        self.platformLatencySeconds = platformLatencySeconds
    }

    public static let zero = LocalOutputLatency(deviceSampleRate: Double(PCM.sampleRate))

    /// Total latency from callback timestamp to the loudspeaker, in nanoseconds.
    public var totalNanos: UInt64 {
        let frames = Double(deviceFrames) + Double(streamFrames) + Double(safetyOffsetFrames)
        let rate = deviceSampleRate > 0 ? deviceSampleRate : Double(PCM.sampleRate)
        let seconds = frames / rate + max(0, unitLatencySeconds) + max(0, platformLatencySeconds)
        return UInt64((seconds * 1e9).rounded())
    }

    public var totalMillis: Double { Double(totalNanos) / 1e6 }
}

// MARK: - Sync statistics

/// Live sync telemetry of a local sink (read by UI / tests; written by the IO thread).
public struct LocalOutputSyncStats: Sendable, Equatable {
    /// IO callbacks rendered since prepare.
    public var callbacks: UInt64
    /// Last measured read-cursor − ideal-frame error (pipeline frames; + = early).
    public var lastErrorFrames: Double
    /// Low-pass-filtered error the corrector acts on.
    public var filteredErrorFrames: Double
    /// Current varispeed ratio (input frames per output frame).
    public var ratio: Double
    /// Crossfaded cursor jumps performed (excluding the initial lock-on).
    public var jumps: UInt64
    /// Frames rendered as silence while the stream had started (underrun / late data).
    public var underrunFrames: UInt64
    /// Packets the producer wrote over unread data.
    public var overrunWrites: UInt64
    /// Callbacks whose timestamp had no valid host time (time was extrapolated).
    public var extrapolatedTimestamps: UInt64
    /// Callbacks larger than the preallocated scratch space (rendered as silence).
    public var oversizedCallbacks: UInt64
    /// Timeline frame currently being handed to the hardware.
    public var readFrame: Double

    public var lastErrorMillis: Double { lastErrorFrames * 1000 / Double(PCM.sampleRate) }
    public var filteredErrorMillis: Double { filteredErrorFrames * 1000 / Double(PCM.sampleRate) }
    public var ratioPPM: Double { (ratio - 1) * 1e6 }
}

// MARK: - Errors

public enum LocalOutputError: Error, Sendable, Equatable, CustomStringConvertible {
    case deviceNotFound(uid: String)
    case deviceNotAlive(name: String)
    case noOutputChannels(name: String)
    case missingDeviceUID(speakerID: String)
    case coreAudio(operation: String, status: Int32)
    case unsupportedPlatform
    /// The group latency is longer than the local ring buffer can hold ahead of the output.
    case latencyTooLarge(latencyMillis: Int, maxMillis: Int)

    public var description: String {
        switch self {
        case .latencyTooLarge(let l, let m):
            return "Group latency \(l) ms is longer than local outputs can buffer (max \(m) ms)"
        case .deviceNotFound(let uid): return "Output device \(uid) is not connected"
        case .deviceNotAlive(let name): return "Output device \(name) is not available"
        case .noOutputChannels(let name): return "Device \(name) has no output channels"
        case .missingDeviceUID(let id): return "Speaker \(id) is not a local output"
        case .coreAudio(let op, let status): return "\(op) failed (OSStatus \(status) \(LocalOutputError.fourCCString(status)))"
        case .unsupportedPlatform: return "Local output is not supported on this platform"
        }
    }

    static func fourCCString(_ status: Int32) -> String {
        let u = UInt32(bitPattern: status)
        let bytes = [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

// MARK: - Replaying broadcast stream

/// A value broadcaster whose every new subscriber first receives the current value.
final class ReplayingBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(_ initial: Value) { value = initial }

    var current: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func makeStream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let key = UUID()
        lock.lock()
        continuations[key] = continuation
        continuation.yield(value)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[key] = nil
            self.lock.unlock()
        }
        return stream
    }

    func send(_ newValue: Value) {
        lock.lock()
        value = newValue
        for c in continuations.values { c.yield(newValue) } // inside the lock: keeps order
        lock.unlock()
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}

extension ReplayingBroadcaster where Value: Equatable {
    /// Sends only if the value changed.
    func sendIfChanged(_ newValue: Value) {
        lock.lock()
        if value == newValue { lock.unlock(); return }
        value = newValue
        for c in continuations.values { c.yield(newValue) }
        lock.unlock()
    }
}
