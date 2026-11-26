import Foundation
import MulticastAudio
import os
#if canImport(Darwin)
import Darwin
#endif

/// Counters for one sink's current/last session (for diagnostics and the probe).
public struct RAOPStatistics: Sendable, Equatable {
    public var packetsSent = 0
    public var packetsDroppedNotPlaying = 0
    /// Packets withheld on purpose by `Options.debugDropPacketIndices` (still answerable by retransmit).
    public var packetsDroppedForTest = 0
    public var sendErrors = 0
    public var syncPacketsSent = 0
    public var timingRequestsAnswered = 0
    public var resendRequests = 0
    public var packetsResent = 0
    public var resendMisses = 0
    public var bytesSent = 0
    public init() {}
}

/// The UDP side of one RAOP session: audio (RTP/ALAC), control (sync + retransmits) and timing.
///
/// Threading:
/// - Everything except the timing/control receive loop runs on `queue` (the sink's serial
///   network queue). `RAOPSink.enqueue` only does `queue.async`.
/// - A dedicated receive thread answers timing requests immediately (so the receiver's clock
///   estimate is not delayed by audio work) and forwards retransmit requests to `queue`.
/// - Statistics are behind an unfair lock touched only by `queue` and the receive thread,
///   never by the engine's pacing thread.
final class RAOPStreamer: @unchecked Sendable {
    let queue: DispatchQueue
    var log: (@Sendable (String) -> Void)?
    var verbose = false
    /// Test hook: packet indices (counted from each start) that are stored in the backlog but not sent.
    var debugDropPacketIndices: Set<Int> = []
    private var packetIndexSinceStart = 0

    private let stats = OSAllocatedUnfairLock(initialState: RAOPStatistics())

    // queue-confined state
    private var audioSocket: UDPSocket?
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var serverAudio: SocketAddress?
    private var serverControl: SocketAddress?
    private(set) var mapping: SyncMapping?
    private(set) var isStreaming = false
    private var needsMarker = true
    private var firstSyncPending = true
    private(set) var nextSeq: UInt16 = UInt16.random(in: 0...UInt16.max)
    private var lastSentRTP: UInt32?
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var backlog = RetransmitBacklog(capacity: 1024, maxPacketSize: RTPAudio.headerSize + ALACFramer.maxPacketBytes)
    private var packetBuffer = [UInt8](repeating: 0, count: RTPAudio.headerSize + ALACFramer.maxPacketBytes)
    private var resendBuffer = [UInt8](repeating: 0, count: ResendResponse.headerSize + RTPAudio.headerSize + ALACFramer.maxPacketBytes)
    private var syncTimer: DispatchSourceTimer?
    private var receiver: ReceiveLoop?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    var statistics: RAOPStatistics { stats.withLock { $0 } }

    // MARK: Setup (call on `queue` via queue.sync)

    /// Opens the control and timing sockets and starts answering timing requests.
    func open(family: Int32) throws -> (controlPort: UInt16, timingPort: UInt16) {
        dispatchPrecondition(condition: .onQueue(queue))
        closeSockets()
        stats.withLock { $0 = RAOPStatistics() }
        let audio = try UDPSocket(family: family)
        let control = try UDPSocket(family: family)
        let timing = try UDPSocket(family: family)
        audioSocket = audio
        controlSocket = control
        timingSocket = timing
        let loop = ReceiveLoop(timing: timing, control: control, streamer: self)
        receiver = loop
        loop.start()
        return (control.localPort, timing.localPort)
    }

    func setServer(peer: SocketAddress, audioPort: UInt16, controlPort: UInt16) {
        dispatchPrecondition(condition: .onQueue(queue))
        serverAudio = peer.withPort(audioPort)
        serverControl = peer.withPort(controlPort)
    }

    /// A fresh RTP base for `timeline` that continues after whatever was sent before
    /// (receivers dislike timestamps jumping backwards after a FLUSH).
    func rtpBase(continuingInto timeline: StreamTimeline) -> UInt32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let last = lastSentRTP else { return UInt32.random(in: 0...UInt32.max) }
        let next = last &+ UInt32(PCM.framesPerPacket)
        return next &- UInt32(truncatingIfNeeded: timeline.anchorFrame)
    }

    /// Starts accepting audio on `mapping`: sends the first sync packet (0x90) and starts the 1 s sync timer.
    func start(mapping: SyncMapping) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.mapping = mapping
        needsMarker = true
        firstSyncPending = true
        isStreaming = true
        backlog.removeAll()
        packetIndexSinceStart = 0
        sendSync()
        let timer = DispatchSource.makeTimerSource(flags: [.strict], queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sendSync() }
        timer.resume()
        syncTimer?.cancel()
        syncTimer = timer
    }

    /// Stops accepting audio. Returns the seq / rtptime the next packet would carry (for FLUSH).
    @discardableResult
    func pause() -> (seq: UInt16, rtpTime: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        isStreaming = false
        syncTimer?.cancel()
        syncTimer = nil
        let rtp = (lastSentRTP ?? mapping.map { $0.rtp(forFrame: $0.timeline.anchorFrame) } ?? 0) &+ UInt32(PCM.framesPerPacket)
        return (nextSeq, rtp)
    }

    func updateOffset(nanos: Int64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var m = mapping else { return }
        m.offsetNanos = nanos
        mapping = m
        if isStreaming { sendSync() }
    }

    /// Stops the receive thread and closes all sockets.
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        _ = pause()
        closeSockets()
        mapping = nil
    }

    private func closeSockets() {
        receiver?.stopAndWait()
        receiver = nil
        audioSocket?.close()
        controlSocket?.close()
        timingSocket?.close()
        audioSocket = nil
        controlSocket = nil
        timingSocket = nil
        serverAudio = nil
        serverControl = nil
    }

    /// RTP time that is audible right now (for metadata `RTP-Info`).
    func currentRTP() -> UInt32? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let mapping else { return nil }
        return mapping.rtp(forFrame: mapping.frameAndTime(atHostNanos: HostClock.nowNanos()).frame)
    }

    // MARK: Audio path (on `queue`)

    func send(_ packet: AudioPacket) {
        guard isStreaming, let mapping, let socket = audioSocket, let destination = serverAudio else {
            stats.withLock { $0.packetsDroppedNotPlaying += 1 }
            return
        }
        let rtp = mapping.rtp(forFrame: packet.firstFrame)
        let seq = nextSeq
        let marker = needsMarker
        let total: Int = packetBuffer.withUnsafeMutableBytes { out in
            RTPAudio.writeHeader(into: out.baseAddress!, seq: seq, timestamp: rtp, ssrc: ssrc, marker: marker)
            let payload = UnsafeMutableRawBufferPointer(rebasing: out[RTPAudio.headerSize...])
            let n = packet.samples.withUnsafeBytes { pcm in
                ALACFramer.encode(pcm: pcm, frames: PCM.framesPerPacket, into: payload)
            }
            return RTPAudio.headerSize + n
        }
        let dropForTest = !debugDropPacketIndices.isEmpty && debugDropPacketIndices.contains(packetIndexSinceStart)
        let ok = packetBuffer.withUnsafeBytes { raw -> Bool in
            let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<total])
            backlog.store(seq: seq, packet: bytes)
            return dropForTest ? true : socket.send(bytes, to: destination)
        }
        nextSeq = seq &+ 1
        packetIndexSinceStart += 1
        needsMarker = false
        lastSentRTP = rtp
        stats.withLock {
            if dropForTest { $0.packetsDroppedForTest += 1 } else if ok { $0.packetsSent += 1; $0.bytesSent += total } else { $0.sendErrors += 1 }
        }
    }

    private func sendSync() {
        guard isStreaming, let mapping, let socket = controlSocket, let destination = serverControl else { return }
        let packet = mapping.syncPacket(atHostNanos: HostClock.nowNanos(), isFirst: firstSyncPending)
        let first = firstSyncPending
        firstSyncPending = false
        let ok = socket.send(packet.encoded(), to: destination)
        stats.withLock { if ok { $0.syncPacketsSent += 1 } else { $0.sendErrors += 1 } }
        if first, verbose {
            log?("   sync(first): rtpMinusLatency=\(packet.rtpMinusLatency) rtpNow=\(packet.rtpNow) ntp=\(String(packet.ntpTime, radix: 16)) -> \(destination)")
        }
    }

    // MARK: Retransmits (on `queue`)

    fileprivate func handleResend(_ request: ResendRequest, from: SocketAddress) {
        guard let socket = controlSocket else { return }
        var resent = 0
        var missed = 0
        let count = min(Int(request.count), backlog.capacity)
        for i in 0..<count {
            let seq = request.firstSeq &+ UInt16(truncatingIfNeeded: i)
            let found = backlog.withPacket(seq: seq) { original in
                let n = resendBuffer.withUnsafeMutableBytes { out in
                    ResendResponse.write(original: original, seq: seq, into: out.baseAddress!)
                }
                resendBuffer.withUnsafeBytes { raw in
                    _ = socket.send(UnsafeRawBufferPointer(rebasing: raw[0..<n]), to: from)
                }
            }
            if found { resent += 1 } else { missed += 1 }
        }
        let (r, m) = (resent, missed)
        stats.withLock {
            $0.resendRequests += 1
            $0.packetsResent += r
            $0.resendMisses += m
        }
        if verbose {
            log?("   resend request seq=\(request.firstSeq) count=\(request.count): resent \(resent), missing \(missed)")
        }
    }

    fileprivate func noteTimingAnswered(first: Bool, from: SocketAddress) {
        stats.withLock { $0.timingRequestsAnswered += 1 }
        if first, verbose { log?("   first timing request from \(from) answered") }
    }
}

/// Dedicated thread polling the timing and control sockets.
private final class ReceiveLoop: @unchecked Sendable {
    private let timing: UDPSocket
    private let control: UDPSocket
    private weak var streamer: RAOPStreamer?
    private let stopFlag = OSAllocatedUnfairLock(initialState: false)
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(timing: UDPSocket, control: UDPSocket, streamer: RAOPStreamer) {
        self.timing = timing
        self.control = control
        self.streamer = streamer
    }

    func start() {
        let t = Thread { [self] in self.run() }
        t.name = "raop.receive"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stopAndWait() {
        stopFlag.withLock { $0 = true }
        if thread != nil {
            done.wait()
            thread = nil
        }
    }

    private func run() {
        var inBuffer = [UInt8](repeating: 0, count: 2048)
        var reply = [UInt8](repeating: 0, count: TimingPacket.size)
        var answeredAny = false
        let queue = streamer?.queue
        while !stopFlag.withLock({ $0 }) {
            var fds = [pollfd(fd: timing.fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: control.fd, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, 100)
            if n <= 0 { continue }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let received = inBuffer.withUnsafeMutableBytes { timing.receive(into: $0) }
                let receiveTime = NTPTime.now()
                if let (count, from) = received {
                    let origin = inBuffer.withUnsafeBytes { raw in
                        TimingPacket.requestTransmitTime(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                    }
                    if let origin {
                        reply.withUnsafeMutableBytes { out in
                            TimingPacket.writeReply(into: out.baseAddress!, origin: origin, receive: receiveTime, transmit: NTPTime.now())
                        }
                        _ = timing.send(reply, to: from)
                        streamer?.noteTimingAnswered(first: !answeredAny, from: from)
                        answeredAny = true
                    }
                }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let received = inBuffer.withUnsafeMutableBytes { control.receive(into: $0) }
                if let (count, from) = received {
                    let request = inBuffer.withUnsafeBytes { raw in
                        ResendRequest.parse(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                    }
                    if let request, let queue {
                        queue.async { [weak streamer] in streamer?.handleResend(request, from: from) }
                    }
                }
            }
        }
        done.signal()
    }
}
