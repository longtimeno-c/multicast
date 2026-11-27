import Foundation
import MulticastAudio
import os

/// The loudspeaker end on the phone: something that plays timeline-stamped packets through the
/// device's current output. The app supplies it (an `AVAudioEngine` sink on iOS); the tests
/// supply one that records what it was given.
///
/// All calls come from one serial context (the receiver's). `start` may take a moment (it opens
/// the audio hardware); the others must be quick.
public protocol PhoneAudioOutput: AnyObject, Sendable {
    /// Open the output and get ready to play packets stamped on `timeline`, which is on the
    /// HUB's clock: `setClockOffset` says how that clock relates to this device's. Called again
    /// on a running output to move to a new timeline. False when the output can't start now
    /// (a call is in progress, another app holds the audio session).
    func start(timeline: StreamTimeline) -> Bool
    /// Hub clock minus this device's clock, in nanoseconds. Updated a few times a second in
    /// small steps as the estimate improves and the clocks drift.
    func setClockOffset(nanos: Int64)
    /// The next packet, in timeline order.
    func write(_ packet: AudioPacket)
    /// Drop everything buffered (the hub paused, sought or changed source).
    func flush()
    func setVolume(_ volume: Float)
    func setOffset(millis: Int)
    /// Close the output and release the audio session.
    func stop()
    /// False while the output must not be started (interrupted by a call or another app and not
    /// yet told to resume).
    var mayStart: Bool { get }
}

/// What the phone knows about how well it is playing, for the UI and for measurements.
public struct PhoneSpeakerStats: Sendable, Equatable {
    /// The output is open and following the hub's timeline.
    public var isPlaying = false
    /// The hub is sending a stream.
    public var hubIsStreaming = false
    public var clockSamples = 0
    /// Hub clock minus the phone's, as applied to the output now.
    public var clockOffsetNanos: Int64 = 0
    public var clockDriftPPM: Double = 0
    /// The fastest round trip seen: the offset is wrong by at most half of this.
    public var bestRoundTripNanos: UInt64 = 0
    public var lastRoundTripNanos: UInt64 = 0
    public var packetsReceived: UInt64 = 0
    public var packetsRecovered: UInt64 = 0
    public var packetsConcealed: UInt64 = 0
    public var packetsLate: UInt64 = 0
    public var duplicates: UInt64 = 0
    public var nacksSent: UInt64 = 0
    /// Milliseconds of audio between the newest packet handed to the output and what is due now.
    public var bufferedMillis: Double = 0
    public var rejectedDatagrams: UInt64 = 0

    public init() {}
}

/// The phone's end of the audio channel, without the network: datagrams come in through
/// `receive`, go out through `transmit`, and `tick` (every 10–20 ms) drives everything timed.
/// Not thread-safe by itself: `PhoneSpeakerClient` calls it on one queue; the tests call it
/// directly with a simulated clock.
final class PhoneSpeakerReceiver {
    struct Configuration {
        /// Clock pings: quick at first so playback can start, then steady.
        var fastPingNanos: UInt64 = 60_000_000
        var steadyPingNanos: UInt64 = 250_000_000
        var fastPings = 24
        /// Exchanges needed before the first audio is scheduled.
        var samplesToStart = 5
        /// A hole is given up this long before it would be heard.
        var dueMarginNanos: UInt64 = 150_000_000
        /// Largest change of the applied clock offset per second while slewing (0.5 ms/s: well
        /// inside what the output's rate correction follows without a jump).
        var slewNanosPerSecond: Int64 = 500_000
        /// A correction larger than this is applied at once (the output crossfades).
        var stepThresholdNanos: Int64 = 20_000_000
        /// With no audio for this long the output is closed (the hub has been paused a while); it
        /// reopens with the next packet. Long on purpose: while the output is open (playing
        /// silence) iOS keeps the app running with the screen locked, so a pause of a few
        /// minutes doesn't cost the phone its place in the group.
        var idleCloseNanos: UInt64 = 600_000_000_000
        /// No control datagram for this long: the hub is gone.
        var controlTimeoutNanos: UInt64 = 4_000_000_000
        var retryStartNanos: UInt64 = 2_000_000_000
        /// Packets kept while the output isn't open yet (clock not ready).
        var maxPrestart = 400
    }

    var configuration = Configuration()
    private let output: any PhoneAudioOutput
    private let now: () -> UInt64
    private let transmit: (Data) -> Void
    private var sealer: DatagramSealer
    private var opener: DatagramOpener

    private(set) var clock = ClockEstimator()
    private var reorderer = PacketReorderer()
    private var control: StreamControl?
    private var lastControlAt: UInt64 = 0
    private var lastAudioAt: UInt64 = 0
    private var lastPingAt: UInt64?
    private var pingsSent = 0
    private var started = false
    private var startedTimeline: StreamTimeline?
    private var lastStartAttempt: UInt64?
    private var appliedOffset: Int64?
    private var lastOffsetAt: UInt64 = 0
    private var appliedVolume: Float?
    private var appliedTrim: Int32?
    private var prestart: [AudioPacket] = []
    private var newestWritten: UInt64?
    private var rejected: UInt64 = 0
    private var lastRoundTrip: UInt64 = 0

    init(keys: AudioChannelKeys, output: any PhoneAudioOutput, now: @escaping () -> UInt64,
         transmit: @escaping (Data) -> Void) {
        self.output = output
        self.now = now
        self.transmit = transmit
        sealer = DatagramSealer(key: keys.send)
        opener = DatagramOpener(key: keys.receive)
    }

    // MARK: In

    func receive(_ raw: Data) {
        let t = now()
        guard let datagram = opener.open(raw) else {
            rejected += 1
            return
        }
        switch datagram {
        case .clockReply(let t1, let t2, let t3):
            if let s = clock.add(t1: t1, t2: t2, t3: t3, t4: t) { lastRoundTrip = s.delay }
        case .control(let c):
            lastControlAt = t
            apply(c)
        case .audio(let epoch, let firstFrame, let samples):
            guard let c = control, c.epoch == epoch, c.isActive else { return }
            lastAudioAt = t
            deliver(reorderer.insert(firstFrame: firstFrame, samples: samples, now: t))
        case .hello, .nack:
            break   // phone → hub only
        }
    }

    private func apply(_ c: StreamControl) {
        let old = control
        // Epochs only go up (mod 2^32): an old control datagram arriving late changes nothing.
        if let old, Int32(bitPattern: c.epoch &- old.epoch) < 0 { return }
        control = c
        if old?.epoch != c.epoch {
            reorderer.reset()
            prestart.removeAll(keepingCapacity: true)
            newestWritten = nil
            if started { output.flush() }
        }
        if appliedVolume != c.volume {
            appliedVolume = c.volume
            output.setVolume(c.volume)
        }
        if appliedTrim != c.offsetMillis {
            appliedTrim = c.offsetMillis
            output.setOffset(millis: Int(c.offsetMillis))
        }
        if started, c.isActive, startedTimeline != c.timeline {
            startedTimeline = c.timeline
            _ = output.start(timeline: c.timeline)
        }
    }

    private func deliver(_ packets: [AudioPacket]) {
        guard !packets.isEmpty else { return }
        if started {
            for p in packets { output.write(p) }
            newestWritten = packets.last?.firstFrame
        } else {
            prestart.append(contentsOf: packets)
            if prestart.count > configuration.maxPrestart { prestart.removeFirst(prestart.count - configuration.maxPrestart) }
        }
    }

    // MARK: Timed work

    func tick() {
        let t = now()
        ping(t)
        updateClockOffset(t)
        lifecycle(t)

        var due: UInt64?
        if let c = control, let offset = appliedOffset {
            let hubTime = UInt64(bitPattern: Int64(bitPattern: t &+ configuration.dueMarginNanos) &+ offset)
            let frame = c.timeline.frame(atHostNanos: hubTime)
            due = frame > 0 ? UInt64(frame) : 0
        }
        let (packets, nacks) = reorderer.poll(now: t, dueFrame: due)
        deliver(packets)
        if !nacks.isEmpty, let c = control { send(.nack(epoch: c.epoch, frames: nacks)) }
    }

    private func send(_ datagram: AudioDatagram) {
        if let sealed = sealer.seal(datagram) { transmit(sealed) }
    }

    private func ping(_ t: UInt64) {
        let interval = pingsSent < configuration.fastPings ? configuration.fastPingNanos : configuration.steadyPingNanos
        if let last = lastPingAt, t < last + interval { return }
        lastPingAt = t
        pingsSent += 1
        // Stamped as late as possible: the clock is read again right before sealing.
        send(.hello(t1: now(), status: output.mayStart ? 0 : 1))
    }

    private func updateClockOffset(_ t: UInt64) {
        guard clock.sampleCount >= configuration.samplesToStart, let target = clock.offsetNanos(at: t) else { return }
        guard let applied = appliedOffset else {
            appliedOffset = target
            lastOffsetAt = t
            output.setClockOffset(nanos: target)
            return
        }
        let diff = target &- applied
        guard diff != 0 else {
            lastOffsetAt = t
            return
        }
        var next = target
        if abs(diff) <= configuration.stepThresholdNanos {
            let elapsed = Double(t - lastOffsetAt) / 1e9
            let limit = max(1, Int64(Double(configuration.slewNanosPerSecond) * elapsed))
            next = applied + min(limit, max(-limit, diff))
        }
        lastOffsetAt = t
        appliedOffset = next
        output.setClockOffset(nanos: next)
    }

    private var hubIsStreaming: Bool {
        guard let c = control else { return false }
        return c.isActive
    }

    private func lifecycle(_ t: UInt64) {
        let controlFresh = control != nil && t <= lastControlAt + configuration.controlTimeoutNanos
        let audioRecent = lastAudioAt != 0 && t <= lastAudioAt + configuration.idleCloseNanos
        let want = hubIsStreaming && controlFresh && audioRecent && appliedOffset != nil && output.mayStart
        if want, !started, let c = control {
            if let last = lastStartAttempt, t < last + configuration.retryStartNanos { return }
            lastStartAttempt = t
            if output.start(timeline: c.timeline) {
                started = true
                startedTimeline = c.timeline
                lastStartAttempt = nil
                if let v = appliedVolume { output.setVolume(v) }
                if let trim = appliedTrim { output.setOffset(millis: Int(trim)) }
                if let o = appliedOffset { output.setClockOffset(nanos: o) }
                // What piled up while the output was closed, less what is already past.
                let hubNow = UInt64(bitPattern: Int64(bitPattern: t) &+ (appliedOffset ?? 0))
                let playing = c.timeline.frame(atHostNanos: hubNow)
                for p in prestart where Double(p.firstFrame) > playing {
                    output.write(p)
                    newestWritten = p.firstFrame
                }
                prestart.removeAll(keepingCapacity: true)
            }
        } else if !want, started {
            started = false
            startedTimeline = nil
            newestWritten = nil
            output.stop()
        }
    }

    /// The app closed the output itself (an interruption): start again when allowed.
    func outputStopped() {
        started = false
        startedTimeline = nil
        newestWritten = nil
        lastStartAttempt = nil
    }

    func shutDown() {
        if started { output.stop() }
        started = false
    }

    // MARK: Out

    var stats: PhoneSpeakerStats {
        var s = PhoneSpeakerStats()
        let t = now()
        s.isPlaying = started
        s.hubIsStreaming = hubIsStreaming && t <= lastControlAt + configuration.controlTimeoutNanos
        s.clockSamples = clock.sampleCount
        s.clockOffsetNanos = appliedOffset ?? 0
        s.clockDriftPPM = clock.driftPPM
        s.bestRoundTripNanos = clock.bestDelayNanos ?? 0
        s.lastRoundTripNanos = lastRoundTrip
        let r = reorderer.stats
        s.packetsReceived = r.received
        s.packetsRecovered = r.recovered
        s.packetsConcealed = r.concealed
        s.packetsLate = r.late
        s.duplicates = r.duplicates
        s.nacksSent = r.nacksSent
        s.rejectedDatagrams = rejected
        if started, let newest = newestWritten, let c = control, let offset = appliedOffset {
            let hubNow = UInt64(bitPattern: Int64(bitPattern: t) &+ offset)
            let playing = c.timeline.frame(atHostNanos: hubNow)
            s.bufferedMillis = max(0, (Double(newest) + Double(PCM.framesPerPacket) - playing) * 1000 / Double(PCM.sampleRate))
        }
        return s
    }
}
