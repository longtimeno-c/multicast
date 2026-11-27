import CryptoKit
import Foundation
import MulticastAudio
import os

/// What a paired phone says about the output it would play through.
public struct PhoneRoute: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case builtIn, bluetooth, headphones, airPlay, car, usb, other
    }

    /// The output's name as iOS shows it ("Speaker", or the Bluetooth speaker's name).
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Capped and cleaned: this text comes from another device.
    var sanitized: PhoneRoute {
        PhoneRoute(name: PeerText.displayName(name, fallback: "iPhone"), kind: kind)
    }
}

/// The hub's end of the audio channel: an `AudioSink` whose loudspeaker is a paired phone.
///
/// The engine hands it packets like any other sink; each is sealed and sent as one datagram, and
/// kept for two seconds so the phone can ask for it again. The phone does the rest: it turns the
/// timeline into its own clock and plays through its current output. Volume and sync trim are
/// applied on the phone, carried in the control datagram.
///
/// Transport is a closure (`transmit`), so the tests can put a lossy fake network in between.
public final class PhoneSpeakerSink: AudioSink, @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var packetsSent: UInt64 = 0
        public var packetsResent: UInt64 = 0
        public var resendMisses: UInt64 = 0
        public var hellos: UInt64 = 0
        public var rejected: UInt64 = 0
    }

    public static func speakerID(remoteID: String) -> String { "phone:\(remoteID)" }

    public let id: String
    public let displayName: String

    private struct State {
        var sealer: DatagramSealer
        var opener: DatagramOpener
        var epoch: UInt32 = 0
        var active = false
        var timeline = StreamTimeline(anchorHostNanos: 0, anchorFrame: 0)
        var volume: Float = 1
        var offsetMillis: Int32 = 0
        var history: [(epoch: UInt32, firstFrame: UInt64, samples: Data)?]
        var historyAt = 0
        var lastHello: UInt64?
        var phoneStatus: UInt8 = 0
        var transmit: (@Sendable (Data) -> Void)?
        var counters = Counters()
        var shutDown = false
    }

    private static let historyPackets = 256
    /// A phone silent this long is treated as gone.
    static let silenceNanos: UInt64 = 6_000_000_000

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> UInt64
    private let stateBroadcast = Broadcast<SinkState>(replaysLatest: true, policy: .bufferingNewest(8))
    private let helloWaitNanos: UInt64

    init(id: String, displayName: String, keys: AudioChannelKeys, helloWait: TimeInterval = 3,
         now: @escaping @Sendable () -> UInt64 = { HostClock.nowNanos() }) {
        self.id = id
        self.displayName = displayName
        self.now = now
        helloWaitNanos = UInt64(helloWait * 1e9)
        state = OSAllocatedUnfairLock(uncheckedState: State(
            sealer: DatagramSealer(key: keys.send), opener: DatagramOpener(key: keys.receive),
            history: Array(repeating: nil, count: Self.historyPackets)))
        stateBroadcast.yield(.idle)
    }

    public var counters: Counters { state.withLockUnchecked { $0.counters } }
    /// The status byte of the phone's last hello (0 = playing or ready, 1 = its output is taken).
    public var phoneStatus: UInt8 { state.withLockUnchecked { $0.phoneStatus } }

    public var stateUpdates: AsyncStream<SinkState> { stateBroadcast.stream() }

    /// Where sealed datagrams go. Set by the channel once it knows the phone's address.
    func setTransmit(_ transmit: (@Sendable (Data) -> Void)?) {
        state.withLockUnchecked { $0.transmit = transmit }
    }

    private static func control(_ s: State) -> StreamControl {
        StreamControl(epoch: s.epoch, isActive: s.active, timeline: s.timeline, volume: s.volume, offsetMillis: s.offsetMillis)
    }

    /// Seals and sends under the lock, so sequence numbers leave in order.
    private static func send(_ datagram: AudioDatagram, _ s: inout State) {
        guard let transmit = s.transmit, !s.shutDown, let sealed = s.sealer.seal(datagram) else { return }
        transmit(sealed)
    }

    private func sendControl(times: Int = 1) {
        state.withLockUnchecked { s in
            for _ in 0..<times { Self.send(.control(Self.control(s)), &s) }
        }
    }

    // MARK: From the phone

    /// A datagram from the network. True when it was authentic (so its sender is the phone).
    @discardableResult
    func receive(_ raw: Data) -> Bool {
        let t2 = now()
        return state.withLockUnchecked { s in
            guard !s.shutDown, let datagram = s.opener.open(raw) else {
                s.counters.rejected += 1
                return false
            }
            switch datagram {
            case .hello(let t1, let status):
                s.lastHello = t2
                s.phoneStatus = status
                s.counters.hellos += 1
                Self.send(.clockReply(t1: t1, t2: t2, t3: now()), &s)
            case .nack(let epoch, let frames):
                guard epoch == s.epoch else { break }
                for frame in frames {
                    if let hit = s.history.first(where: { $0?.epoch == epoch && $0?.firstFrame == frame }), let hit {
                        Self.send(.audio(epoch: hit.epoch, firstFrame: hit.firstFrame, samples: hit.samples), &s)
                        s.counters.packetsResent += 1
                    } else {
                        s.counters.resendMisses += 1
                    }
                }
            case .audio, .control, .clockReply:
                break   // hub → phone only
            }
            return true
        }
    }

    /// Call a few times a second: repeats the control datagram and notices a phone gone quiet.
    func tick() {
        let t = now()
        let lost: Bool = state.withLockUnchecked { s in
            Self.send(.control(Self.control(s)), &s)
            guard s.active, let heard = s.lastHello else { return false }
            return t > heard + Self.silenceNanos
        }
        if lost, stateBroadcast.latest == .playing {
            stateBroadcast.yield(.failed("The iPhone is not responding"))
        }
    }

    // MARK: AudioSink

    public func prepare(timeline: StreamTimeline) async throws {
        let wasActive: Bool = state.withLockUnchecked { s in
            defer {
                s.active = true
                s.timeline = timeline
            }
            guard s.active, s.timeline == timeline else {
                s.epoch &+= 1
                return false
            }
            return true
        }
        if !wasActive { stateBroadcast.yield(.connecting) }
        sendControl(times: 3)
        // The phone must be there: it answers a hello every fraction of a second.
        // Counted in sleeps, not on `now`, which the tests drive by hand.
        var waits = Int((Double(helloWaitNanos) / 50_000_000).rounded(.up))
        while true {
            let t = now()
            let alive = state.withLockUnchecked { s in s.lastHello.map { t <= $0 + Self.silenceNanos } ?? false }
            if alive { break }
            waits -= 1
            if waits < 0 || Task.isCancelled {
                state.withLockUnchecked { $0.active = false }
                stateBroadcast.yield(.failed("The iPhone is not responding"))
                throw PhoneSpeakerError.notResponding
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            sendControl()
        }
        stateBroadcast.yield(.playing)
    }

    public func enqueue(_ packet: AudioPacket) {
        state.withLockUnchecked { s in
            guard s.active, !s.shutDown else { return }
            s.history[s.historyAt] = (s.epoch, packet.firstFrame, packet.samples)
            s.historyAt = (s.historyAt + 1) % Self.historyPackets
            guard s.transmit != nil else { return }
            Self.send(.audio(epoch: s.epoch, firstFrame: packet.firstFrame, samples: packet.samples), &s)
            s.counters.packetsSent += 1
        }
    }

    public func setVolume(_ volume: Float) async {
        state.withLockUnchecked { $0.volume = volume.isFinite ? min(1, max(0, volume)) : 0 }
        sendControl()
    }

    public func setOffset(millis: Int) async {
        state.withLockUnchecked { $0.offsetMillis = Int32(clamping: millis) }
        sendControl()
    }

    public func flush() async {
        state.withLockUnchecked { s in
            s.epoch &+= 1
            for i in s.history.indices { s.history[i] = nil }
        }
        sendControl(times: 2)
    }

    public func stop() async {
        state.withLockUnchecked { s in
            s.active = false
            s.epoch &+= 1
            for i in s.history.indices { s.history[i] = nil }
        }
        sendControl(times: 3)
        stateBroadcast.yield(.idle)
    }

    /// The phone left: nothing more is sent.
    func shutDown() {
        sendControlInactive()
        state.withLockUnchecked {
            $0.shutDown = true
            $0.transmit = nil
        }
        stateBroadcast.finish()
    }

    private func sendControlInactive() {
        state.withLockUnchecked { s in
            s.active = false
            Self.send(.control(Self.control(s)), &s)
        }
    }
}

public enum PhoneSpeakerError: Error, Equatable, Sendable, CustomStringConvertible {
    case notResponding

    public var description: String {
        switch self {
        case .notResponding: "The iPhone is not responding"
        }
    }
}
