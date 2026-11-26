import Foundation
import MulticastAudio

// MARK: - Snapshot (mirrored verbatim by the iOS remote; keep field names stable)

/// Everything a UI (local or remote) needs to render the engine. Codable with stable,
/// plain field names and only primitive / String-backed enum members, so it can be sent
/// over the wire as JSON and decoded on another device.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public enum TransportState: String, Codable, Sendable {
        case stopped
        case playing
        case paused
        /// A finite source reached its end. Sinks keep playing what they buffered.
        case ended
    }

    public enum SinkStatus: String, Codable, Sendable {
        /// Not part of the current playback (engine stopped/paused, or never prepared).
        case idle
        /// Being prepared for the current timeline, or the device reports it is reconnecting.
        case connecting
        /// Prepared on the current timeline and receiving packets.
        case playing
        /// Prepare threw / timed out, or the device reported a failure. Kept in the list; retry.
        case failed
        /// Excluded from the group by the user (settings are kept).
        case disabled
    }

    public struct SinkEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var state: SinkStatus
        /// Human readable reason when `state == .failed`.
        public var error: String?
        /// Per-speaker volume 0…1 (before master volume and mute).
        public var volume: Float
        public var muted: Bool
        public var enabled: Bool
        public var offsetMillis: Int
        /// What actually gets pushed to the device: `muted ? 0 : volume * master`.
        public var effectiveVolume: Float

        public init(id: String, name: String, state: SinkStatus, error: String? = nil, volume: Float,
                    muted: Bool, enabled: Bool, offsetMillis: Int, effectiveVolume: Float) {
            self.id = id
            self.name = name
            self.state = state
            self.error = error
            self.volume = volume
            self.muted = muted
            self.enabled = enabled
            self.offsetMillis = offsetMillis
            self.effectiveVolume = effectiveVolume
        }
    }

    /// Increases by one on every published change. Lets a remote drop stale/out-of-order copies.
    public var revision: UInt64
    public var transport: TransportState
    public var sourceName: String?
    public var sourceIsLive: Bool
    public var masterVolume: Float
    public var latencyMillis: Int
    public var sinks: [SinkEntry]

    public init(revision: UInt64, transport: TransportState, sourceName: String?, sourceIsLive: Bool,
                masterVolume: Float, latencyMillis: Int, sinks: [SinkEntry]) {
        self.revision = revision
        self.transport = transport
        self.sourceName = sourceName
        self.sourceIsLive = sourceIsLive
        self.masterVolume = masterVolume
        self.latencyMillis = latencyMillis
        self.sinks = sinks
    }
}

// MARK: - Events

public enum EngineEvent: Sendable, Equatable {
    /// A finite source returned `nil`. `endFrame` is the first frame that was NOT produced;
    /// the last produced audio stops being audible at `audibleUntilHostNanos`. A player can
    /// call `setSource(_:)` right away: if it does so before the buffered tail runs out the
    /// next source continues gaplessly on the same timeline.
    case endOfStream(endFrame: UInt64, audibleUntilHostNanos: UInt64)
    /// A sink finished `prepare` and now receives packets. `timelineAnchorFrame` identifies the timeline.
    case sinkJoined(id: String, timelineAnchorFrame: UInt64)
    case sinkFailed(id: String, message: String)
    /// A new timeline was issued (play, resume, source change). Sinks are re-prepared on it.
    case timelineChanged(StreamTimeline)
}

// MARK: - Meters

/// Source level (pre-volume) over the last publishing window (~40 ms), linear 0…1 full scale.
public struct MeterReading: Codable, Sendable, Equatable {
    public var peakLeft: Float
    public var peakRight: Float
    public var rmsLeft: Float
    public var rmsRight: Float
    /// Frame index just after the last measured packet (where the stream "is" in production terms).
    public var frame: UInt64
    /// Frame that should be audible right now according to the timeline (for progress UI).
    public var audibleFrame: UInt64

    public init(peakLeft: Float, peakRight: Float, rmsLeft: Float, rmsRight: Float, frame: UInt64, audibleFrame: UInt64) {
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.rmsLeft = rmsLeft
        self.rmsRight = rmsRight
        self.frame = frame
        self.audibleFrame = audibleFrame
    }

    /// Converts a linear level to dBFS, clamped at `floor`.
    public static func decibels(_ linear: Float, floor: Float = -96) -> Float {
        guard linear > 0 else { return floor }
        return max(floor, 20 * log10(linear))
    }
}

// MARK: - Pacer statistics

public struct PacerStatistics: Codable, Sendable, Equatable {
    /// Packets handed to sinks (or discarded in live-pause mode).
    public var packetsEmitted: UInt64 = 0
    /// Packets skipped after a stall so long that they could no longer be delivered in time.
    public var packetsSkipped: UInt64 = 0
    /// Packets re-sent from history to late joiners.
    public var packetsBackfilled: UInt64 = 0
    /// Packets re-emitted on resume: audio that had been sent but was not yet audible when the
    /// stream was paused (the sinks flushed it), played again so pause/resume loses nothing.
    public var packetsReplayed: UInt64 = 0
    /// Frames the source did not supply that were padded with silence.
    public var framesPadded: UInt64 = 0
    /// Emission time minus scheduled emission time, over all emitted packets.
    public var meanLatenessNanos: Double = 0
    public var maxLatenessNanos: UInt64 = 0
    /// Time spent per packet on the pacer thread: source read + padding + metering + fan-out
    /// (i.e. including every sink's `enqueue`).
    public var meanWorkNanos: Double = 0
    public var maxWorkNanos: UInt64 = 0
    /// Largest number of packets emitted back to back without sleeping (catch-up).
    public var maxBurst: Int = 0
    /// Whether the time-constraint (real-time) scheduling policy was granted to the pacer thread.
    public var realtimePolicyApplied: Bool = false

    public init() {}
}

// MARK: - Errors

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSource
    case prepareTimedOut(seconds: Double)
    case unknownSink(String)

    public var description: String {
        switch self {
        case .noSource: return "No audio source is set"
        case .prepareTimedOut(let s): return String(format: "Speaker did not become ready within %.1f s", s)
        case .unknownSink(let id): return "Unknown speaker \(id)"
        }
    }
}
