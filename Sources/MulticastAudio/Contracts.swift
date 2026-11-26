import Foundation

// MARK: - Pipeline format

/// The single PCM format used everywhere between sources, the engine and sinks:
/// 44.1 kHz, 16-bit signed little-endian, interleaved stereo, in packets of 352 frames
/// (the AirPlay/RAOP packet size, so network sinks never have to re-chunk).
public enum PCM {
    public static let sampleRate: Int = 44_100
    public static let channels: Int = 2
    public static let bitsPerSample: Int = 16
    public static let bytesPerFrame: Int = 4
    public static let framesPerPacket: Int = 352
    public static let bytesPerPacket: Int = framesPerPacket * bytesPerFrame

    /// Duration of `frames` frames in nanoseconds (rounded down). 128-bit intermediate, so it
    /// never traps; saturates at `UInt64.max` (beyond ~584 years of audio).
    public static func nanos(forFrames frames: UInt64) -> UInt64 {
        let rate = UInt64(sampleRate)
        let product = frames.multipliedFullWidth(by: 1_000_000_000)
        guard product.high < rate else { return .max }
        return rate.dividingFullWidth(product).quotient
    }

    /// Number of whole frames in `nanos` nanoseconds (rounded down). 128-bit intermediate; the
    /// result is always smaller than `nanos`, so it never overflows.
    public static func frames(forNanos nanos: UInt64) -> UInt64 {
        let product = nanos.multipliedFullWidth(by: UInt64(sampleRate))
        return UInt64(1_000_000_000).dividingFullWidth(product).quotient
    }
}

// MARK: - Clock

/// The one monotonic clock every module schedules against.
public enum HostClock {
    /// Monotonic nanoseconds since boot. Same timebase as `mach_absolute_time()` and
    /// `AudioTimeStamp.mHostTime`, but already converted to nanoseconds.
    public static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Convert `mach_absolute_time()` ticks (e.g. `AudioTimeStamp.mHostTime`) to nanoseconds.
    public static func nanos(fromHostTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Convert nanoseconds to `mach_absolute_time()` ticks (for `mach_wait_until`).
    public static func hostTicks(fromNanos nanos: UInt64) -> UInt64 {
        nanos * UInt64(timebase.denom) / UInt64(timebase.numer)
    }
}

// MARK: - Timeline

/// Maps the stream's frame counter to the moment each frame must be AUDIBLE.
///
/// This is the whole sync contract: every sink, whatever its transport, must make frame `F`
/// leave its loudspeaker at `playoutHostNanos(forFrame: F)` (plus its own user offset trim).
/// The engine anchors the timeline `latencyNanos` in the future and delivers packets to sinks
/// in real time, i.e. roughly `latencyNanos` before they are due, so network sinks have that
/// long to buffer.
public struct StreamTimeline: Sendable, Equatable {
    /// Host time (see `HostClock`) at which `anchorFrame` is audible.
    public let anchorHostNanos: UInt64
    /// Frame index that is audible at `anchorHostNanos`.
    public let anchorFrame: UInt64
    /// How far ahead of playout the engine delivers packets. Default group latency is 2 s.
    public let latencyNanos: UInt64

    public static let defaultLatencyNanos: UInt64 = 2_000_000_000

    public init(anchorHostNanos: UInt64, anchorFrame: UInt64, latencyNanos: UInt64 = StreamTimeline.defaultLatencyNanos) {
        self.anchorHostNanos = anchorHostNanos
        self.anchorFrame = anchorFrame
        self.latencyNanos = latencyNanos
    }

    /// Host time at which `frame` must be audible.
    public func playoutHostNanos(forFrame frame: UInt64) -> UInt64 {
        if frame >= anchorFrame {
            return anchorHostNanos + PCM.nanos(forFrames: frame - anchorFrame)
        }
        let back = PCM.nanos(forFrames: anchorFrame - frame)
        return anchorHostNanos > back ? anchorHostNanos - back : 0
    }

    /// The (possibly fractional, possibly negative) frame that should be audible at `hostNanos`.
    public func frame(atHostNanos hostNanos: UInt64) -> Double {
        let deltaNanos = Double(Int64(bitPattern: hostNanos &- anchorHostNanos))
        return Double(anchorFrame) + deltaNanos * Double(PCM.sampleRate) / 1_000_000_000
    }
}

// MARK: - Packets

/// Exactly one packet (352 frames) of pipeline-format audio, stamped on the stream timeline.
public struct AudioPacket: Sendable {
    /// Index of this packet's first frame on the stream timeline. Always a multiple of
    /// `PCM.framesPerPacket` relative to the timeline's `anchorFrame`.
    public let firstFrame: UInt64
    /// Exactly `PCM.bytesPerPacket` bytes: interleaved S16LE stereo.
    public let samples: Data

    public init(firstFrame: UInt64, samples: Data) {
        precondition(samples.count == PCM.bytesPerPacket, "AudioPacket must hold exactly \(PCM.bytesPerPacket) bytes")
        self.firstFrame = firstFrame
        self.samples = samples
    }
}

// MARK: - Sources

/// Something that produces pipeline-format audio: a tone, a file, a captured app.
public protocol AudioSource: AnyObject, Sendable {
    var displayName: String { get }
    /// `true` for capture-style sources that cannot be paused or sought (the engine keeps
    /// pulling and treats shortfalls as silence); `false` for finite/seekable sources.
    var isLive: Bool { get }

    func start() async throws
    func stop() async

    /// Pull up to `frameCount` frames of interleaved S16 stereo at 44.1 kHz into `buffer`.
    /// MUST NOT block, allocate large memory or take contended locks: it is called from the
    /// engine's real-time pacing thread. Returns the number of frames written (the engine pads
    /// the rest with silence), or `nil` once a finite source has reached its end.
    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int?
}

// MARK: - Sinks

public enum SinkState: Sendable, Equatable {
    case idle
    case connecting
    case playing
    case failed(String)
}

/// One speaker (network or local) that plays packets in sync with the shared timeline.
public protocol AudioSink: AnyObject, Sendable {
    /// Stable identifier; equals the `SpeakerDescriptor.id` the sink was built from.
    var id: String { get }
    var displayName: String { get }

    /// Connect / open the device and get ready to play packets stamped on `timeline`.
    /// May be called again on an already-prepared sink (after `flush()`) to re-anchor to a new
    /// timeline without reconnecting. Throws if the speaker cannot be reached or refuses us.
    func prepare(timeline: StreamTimeline) async throws

    /// Hand over the next packet. Called from the engine's pacing thread in timeline order,
    /// roughly `timeline.latencyNanos` before the packet is due. MUST NOT block.
    /// A sink that is not `playing` silently drops packets.
    func enqueue(_ packet: AudioPacket)

    /// Linear perceptual volume 0…1 (0 = mute). Applied device-side where the transport allows.
    func setVolume(_ volume: Float) async

    /// Per-speaker sync trim in milliseconds; positive plays later, negative earlier.
    func setOffset(millis: Int) async

    /// Drop everything buffered (pause, seek, source change). The sink stays connected.
    func flush() async

    /// Tear down the connection / close the device. The sink can be prepared again afterwards.
    func stop() async

    /// State changes, for UI. Replays the current state to each new subscriber.
    var stateUpdates: AsyncStream<SinkState> { get }
}

// MARK: - Speakers

/// Everything known about one speaker the user can pick, wherever it was found.
public struct SpeakerDescriptor: Identifiable, Hashable, Sendable, Codable {
    public enum Transport: String, Sendable, Codable {
        /// Classic AirPlay / RAOP only (AirPort Express, AirConnect bridges, shairport…).
        case airplay1
        /// Advertises AirPlay 2 (`_airplay._tcp` with AirPlay 2 feature bits).
        case airplay2
        /// An audio output of this machine (built-in, Bluetooth, USB, HDMI…).
        case local
    }

    public enum LocalKind: String, Sendable, Codable {
        case builtIn, bluetooth, usb, hdmi, displayPort, airplaySystem, virtual, aggregate, other
    }

    /// Stable across launches. Network speakers: lowercase device id / MAC without separators
    /// (e.g. "542a1b001122"). Local outputs: "local:" + the Core Audio device UID.
    public var id: String
    public var name: String
    public var transport: Transport

    // Network speakers
    /// Resolved host name or IP literal of the RAOP service.
    public var host: String?
    /// RAOP (RTSP) port.
    public var port: UInt16?
    public var model: String?
    /// Raw TXT record of the `_raop._tcp` service (keys as advertised: et, cn, ft, sf, pw, am, vn…).
    public var raopTXT: [String: String]
    /// Raw TXT record of the `_airplay._tcp` service, if the device has one.
    public var airplayTXT: [String: String]
    public var requiresPassword: Bool

    // Local outputs
    public var localDeviceUID: String?
    public var localKind: LocalKind?

    public init(
        id: String,
        name: String,
        transport: Transport,
        host: String? = nil,
        port: UInt16? = nil,
        model: String? = nil,
        raopTXT: [String: String] = [:],
        airplayTXT: [String: String] = [:],
        requiresPassword: Bool = false,
        localDeviceUID: String? = nil,
        localKind: LocalKind? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.port = port
        self.model = model
        self.raopTXT = raopTXT
        self.airplayTXT = airplayTXT
        self.requiresPassword = requiresPassword
        self.localDeviceUID = localDeviceUID
        self.localKind = localKind
    }
}
