import Foundation
import CryptoKit
import MulticastAudio
import os

/// An AirPlay (RAOP) speaker as an `AudioSink`: ALAC over RTP/UDP, NTP-style timing,
/// sync packets mapped from the shared `StreamTimeline`, retransmits, volume and metadata.
///
/// One instance per network speaker; any number of instances can be prepared with the same
/// timeline and will play in sync (to the accuracy of each receiver's clock recovery plus
/// the per-sink offset trim).
///
/// Concurrency:
/// - RTSP (blocking TCP) runs on a private serial *control* queue; the async API hops onto it.
/// - UDP audio runs on a private serial *network* queue. `enqueue` only dispatches onto it.
/// - State fan-out uses an unfair lock never touched by `enqueue`.
public final class RAOPSink: AudioSink, @unchecked Sendable {
    public enum AuthSetupPolicy: Sendable {
        /// Send `POST /auth-setup` when the TXT record lists encryption type 4 (MFi-SAP), as AirPlay 2 devices do.
        case automatic
        case always
        case never
    }

    public struct Options: Sendable {
        /// Speaker password for HTTP Digest auth. A 401 without one fails with `RAOPError.passwordRequired`.
        public var password: String?
        public var userAgent: String = "AirPlay/381.13"
        public var connectTimeout: TimeInterval = 5
        public var requestTimeout: TimeInterval = 5
        public var keepAliveInterval: TimeInterval = 25
        public var authSetup: AuthSetupPolicy = .automatic
        /// When true, `prepare` fails (before any audio is sent) if the speaker does not answer
        /// the volume SET_PARAMETER with 200. Only meaningful when a volume was set.
        public var requireVolumeAck = false
        /// See `SyncMapping`: the 11025-frame bias receivers add to `rtpNow - rtpMinusLatency`.
        public var receiverBiasFrames: UInt32 = SyncMapping.defaultReceiverBiasFrames
        /// Diagnostic log (RTSP exchange, warnings). Never called from the pacing thread.
        public var log: (@Sendable (String) -> Void)?
        /// Also log first timing request, first sync packet and every retransmit request.
        public var verbose = false
        /// Test hook for exercising retransmits: packet indices (counted from each prepare) that are
        /// kept in the retransmit backlog but deliberately not sent. Leave empty in production.
        public var debugDropPacketIndices: Set<Int> = []

        public init(password: String? = nil, log: (@Sendable (String) -> Void)? = nil) {
            self.password = password
            self.log = log
        }
    }

    /// Connection failures, always on (the system log; names and addresses private).
    static let osLog = Logger(subsystem: "multicast.raop", category: "connect")

    public let id: String
    public let displayName: String
    public let descriptor: SpeakerDescriptor
    public let options: Options

    private let controlQueue: DispatchQueue
    private let streamer: RAOPStreamer
    private let shared: OSAllocatedUnfairLock<Shared>

    private struct Shared {
        var state: SinkState = .idle
        var subscribers: [UUID: AsyncStream<SinkState>.Continuation] = [:]
        var audioLatencyFrames: Int?
        /// Where the next connect goes. Starts as `descriptor.host/port`; discovery can move it
        /// (AirConnect bridges change ports when they restart).
        var host: String?
        var port: UInt16?
    }

    // control-queue-confined
    private var session: Session?
    private var volume: Float?
    private var offsetNanos: Int64 = 0

    private final class Session {
        let rtsp: RTSPClient
        let uri: String
        var sessionID: String?
        var keepAlive: DispatchSourceTimer?
        init(rtsp: RTSPClient, uri: String) {
            self.rtsp = rtsp
            self.uri = uri
        }
    }

    public init(descriptor: SpeakerDescriptor, options: Options = Options()) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.displayName = descriptor.name
        let opts = options
        self.options = opts
        shared = OSAllocatedUnfairLock(initialState: Shared(host: descriptor.host, port: descriptor.port))
        controlQueue = DispatchQueue(label: "raop.control.\(descriptor.id)")
        streamer = RAOPStreamer(label: "raop.net.\(descriptor.id)")
        streamer.log = opts.log
        streamer.verbose = opts.verbose
        streamer.debugDropPacketIndices = opts.debugDropPacketIndices
    }

    /// Convenience: build from a resolved RAOP service. `name` may be the raw instance name
    /// ("542A1B001122@Hall Sonos"); the part before "@" becomes the id.
    public convenience init(host: String, port: UInt16, name: String, txt: [String: String] = [:], password: String? = nil, options: Options = Options()) {
        let parts = name.split(separator: "@", maxSplits: 1)
        let id = parts.count == 2 ? parts[0].lowercased() : name.lowercased()
        let display = parts.count == 2 ? String(parts[1]) : name
        let descriptor = SpeakerDescriptor(
            id: id, name: display, transport: (txt["vn"] == "65537" || txt["et"]?.contains("4") == true) ? .airplay2 : .airplay1,
            host: host, port: port, model: txt["am"], raopTXT: txt,
            requiresPassword: txt["pw"] == "true" || txt["pw"] == "1")
        var opts = options
        if let password { opts.password = password }
        self.init(descriptor: descriptor, options: opts)
    }

    deinit {
        // Best effort: never leak sockets if the owner forgot stop().
        let streamer = self.streamer
        streamer.queue.async { streamer.close() }
        session?.keepAlive?.cancel()
        session?.rtsp.close()
    }

    // MARK: Public state

    public var stateUpdates: AsyncStream<SinkState> {
        AsyncStream { continuation in
            let key = UUID()
            shared.withLock { s in
                s.subscribers[key] = continuation
                continuation.yield(s.state)
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.shared.withLock { $0.subscribers.removeValue(forKey: key) }
            }
        }
    }

    public var currentState: SinkState { shared.withLock { $0.state } }

    /// Host and port the next connection attempt will use.
    public var endpoint: (host: String?, port: UInt16?) { shared.withLock { ($0.host, $0.port) } }

    /// Points the sink at a new address (e.g. discovery re-resolved the service on another port).
    /// Takes effect at the next connect: an established session is not touched; if the speaker
    /// really moved, that session fails on its own and the next prepare/retry reconnects here.
    public func updateEndpoint(host: String?, port: UInt16?) {
        shared.withLock { $0.host = host; $0.port = port }
    }

    /// Counters of the current (or last) session.
    public var statistics: RAOPStatistics { streamer.statistics }

    /// `Audio-Latency` the speaker returned from RECORD (frames), if any.
    public var reportedAudioLatencyFrames: Int? { shared.withLock { $0.audioLatencyFrames } }

    private func setState(_ state: SinkState) {
        shared.withLock { s in
            guard s.state != state else { return }
            s.state = state
            for c in s.subscribers.values { c.yield(state) }
        }
    }

    private func log(_ message: String) {
        options.log?("[\(displayName)] \(message)")
    }

    // MARK: AudioSink

    public func prepare(timeline: StreamTimeline) async throws {
        try await onControl { try self.prepareOnControl(timeline) }
    }

    /// Runs on the engine's pacing thread. Cost per call: one `queue.async` (a heap-allocated
    /// closure capturing the packet, a dispatch continuation, and possibly a thread wake-up when
    /// the network queue is idle). No lock, no logging, no network I/O on the calling thread,
    /// but not allocation-free: ~125 allocations/s per RAOP speaker, and a burst of one per
    /// backfilled packet when a speaker joins late.
    public func enqueue(_ packet: AudioPacket) {
        let streamer = self.streamer
        streamer.queue.async { streamer.send(packet) }
    }

    public func setVolume(_ volume: Float) async {
        await onControlNonThrowing { self.setVolumeOnControl(volume) }
    }

    public func setOffset(millis: Int) async {
        await onControlNonThrowing {
            self.offsetNanos = Int64(millis) * 1_000_000
            let nanos = self.offsetNanos
            let streamer = self.streamer
            streamer.queue.sync { streamer.updateOffset(nanos: nanos) }
        }
    }

    /// Sends FLUSH and stops accepting packets; the RTSP session stays up and the state becomes
    /// `.idle` until the next `prepare(timeline:)` re-anchors (without reconnecting) and returns to `.playing`.
    public func flush() async {
        await onControlNonThrowing { self.flushOnControl() }
    }

    public func stop() async {
        await onControlNonThrowing { self.stopOnControl() }
    }

    /// Now-playing text and artwork (DMAP / JPEG via SET_PARAMETER) when the TXT `md` lists 0 / 1.
    /// Errors are logged, never fatal.
    public func setNowPlaying(title: String?, artist: String?, album: String?, artworkJPEG: Data?) async {
        await onControlNonThrowing { self.nowPlayingOnControl(title: title, artist: artist, album: album, artwork: artworkJPEG) }
    }

    /// Progress bar (`md` lists 2): elapsed / total seconds of the current item.
    public func setProgress(elapsedSeconds: Double, durationSeconds: Double) async {
        await onControlNonThrowing { self.progressOnControl(elapsed: elapsedSeconds, duration: durationSeconds) }
    }

    // MARK: Queue hopping

    private func onControl<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            controlQueue.async { c.resume(with: Result { try body() }) }
        }
    }

    private func onControlNonThrowing(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            controlQueue.async { body(); c.resume() }
        }
    }

    // MARK: Control-queue implementation

    private func prepareOnControl(_ timeline: StreamTimeline) throws {
        let probeMapping = SyncMapping(timeline: timeline, rtpBase: 0, receiverBiasFrames: options.receiverBiasFrames)
        guard probeMapping.isLatencyRepresentable else {
            throw RAOPError.latencyTooSmall("\(timeline.latencyNanos / 1_000_000) ms; RAOP needs more than \(options.receiverBiasFrames) frames")
        }
        if let existing = session {
            // Already connected (e.g. after flush()): just re-anchor.
            let streamer = self.streamer
            let wasStreaming = streamer.queue.sync { streamer.isStreaming }
            if wasStreaming { flushOnControl() }
            if let session = self.session, session === existing {
                startStreaming(timeline: timeline, session: session)
                log("re-anchored on new timeline (anchor frame \(timeline.anchorFrame))")
                setState(.playing)
                return
            }
            // The FLUSH failed and tore the session down: reconnect from scratch below rather
            // than "play" into closed sockets.
            log("re-anchor FLUSH failed; reconnecting")
        }
        setState(.connecting)
        do {
            let session = try connect(timeline: timeline)
            self.session = session
            startKeepAlive(session)
            setState(.playing)
        } catch {
            log("prepare failed: \(error)")
            teardownLocal()
            setState(.failed("\(error)"))
            throw error
        }
    }

    private func connect(timeline: StreamTimeline) throws -> Session {
        let (host, port) = endpoint
        guard let host, !host.isEmpty, let port else { throw RAOPError.missingAddress(displayName) }
        let connection: TCPConnection
        do {
            connection = try TCPConnection.connect(host: host, port: port, timeout: options.connectTimeout) { [displayName] attempt, error in
                if attempt == 1 || attempt % 8 == 0 {
                    Self.osLog.notice("\(displayName, privacy: .private) connect attempt \(attempt, privacy: .public) failed with errno \(error.code, privacy: .public); retrying")
                }
            }
        } catch {
            let code = (error as? RAOPSocketError)?.code ?? 0
            Self.osLog.error("\(self.displayName, privacy: .private) connect failed, errno \(code, privacy: .public): \(String(describing: error), privacy: .private)")
            throw RAOPError.connectFailed("\(host):\(port): \(error)")
        }
        log("connected to \(connection.peer) from \(connection.local)")

        let sessionNumber = UInt32.random(in: 1...UInt32.max)
        let clientInstance = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
        let localHost = connection.local.family == AF_INET6 ? "[\(connection.local.ipString)]" : connection.local.ipString
        let uri = "rtsp://\(localHost)/\(sessionNumber)"
        let baseHeaders = [
            RTSPHeader("User-Agent", options.userAgent),
            RTSPHeader("Client-Instance", clientInstance),
            RTSPHeader("DACP-ID", clientInstance),
            RTSPHeader("Active-Remote", String(UInt32.random(in: 1...UInt32.max))),
        ]
        let logger = options.log
        let name = displayName
        let rtsp = RTSPClient(connection: connection, baseHeaders: baseHeaders, password: options.password,
                              timeout: options.requestTimeout,
                              log: logger.map { l in { l("[\(name)] \($0)") } })
        let session = Session(rtsp: rtsp, uri: uri)

        _ = try rtsp.send(RTSPRequest(method: "OPTIONS", uri: "*"))

        if needsAuthSetup {
            var body = Data([0x01])
            body.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            let response = try rtsp.send(RTSPRequest(method: "POST", uri: "/auth-setup",
                                                     headers: [RTSPHeader("Content-Type", "application/octet-stream")], body: body))
            log("auth-setup answered with \(response.body.count) B")
        }

        let sdp = RAOPSDP.announce(sessionID: sessionNumber, localIP: connection.local.ipString, remoteIP: connection.peer.ipString,
                                   localIsIPv6: connection.local.family == AF_INET6, remoteIsIPv6: connection.peer.family == AF_INET6)
        _ = try rtsp.send(RTSPRequest(method: "ANNOUNCE", uri: uri,
                                      headers: [RTSPHeader("Content-Type", "application/sdp")], body: Data(sdp.utf8)))

        let streamer = self.streamer
        let ports = try streamer.queue.sync { try streamer.open(family: connection.peer.family) }
        let setup = try rtsp.send(RTSPRequest(method: "SETUP", uri: uri, headers: [
            RTSPHeader("Transport", RTSPHeaderValue.setupTransport(controlPort: ports.controlPort, timingPort: ports.timingPort)),
        ]))
        guard let transport = setup.header("Transport") else { throw RAOPError.badResponse("SETUP without Transport") }
        let params = RTSPHeaderValue.parseParameters(transport)
        guard let serverPort = params["server_port"].flatMap(UInt16.init) else {
            throw RAOPError.badResponse("SETUP Transport without server_port: \(transport)")
        }
        let serverControl = params["control_port"].flatMap(UInt16.init) ?? serverPort &+ 1
        session.sessionID = setup.header("Session")?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        if let sid = session.sessionID { rtsp.baseHeaders.append(RTSPHeader("Session", sid)) }
        streamer.queue.sync { streamer.setServer(peer: connection.peer, audioPort: serverPort, controlPort: serverControl) }

        // Volume before RECORD (some receivers refuse it here; that is fine, it is re-sent below).
        if let volume { _ = try? sendVolume(volume, session: session) }

        let mapping = makeMapping(timeline: timeline, rtpBase: UInt32.random(in: 0...UInt32.max))
        let firstSeq = streamer.queue.sync { streamer.nextSeq }
        // seq and rtptime describe the same packet: the first one this sink can still receive
        // (a late joiner's first packet is far past the anchor, not at it).
        let firstFrame = SyncMapping.firstReceivableFrame(timeline: timeline, atHostNanos: HostClock.nowNanos())
        let record = try rtsp.send(RTSPRequest(method: "RECORD", uri: uri, headers: [
            RTSPHeader("Range", "npt=0-"),
            RTSPHeader("RTP-Info", RTSPHeaderValue.rtpInfo(seq: firstSeq, rtpTime: mapping.rtp(forFrame: firstFrame))),
        ]))
        if let latency = record.header("Audio-Latency").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), latency >= 0 {
            shared.withLock { $0.audioLatencyFrames = latency }
            if UInt64(latency) >= PCM.frames(forNanos: timeline.latencyNanos) {
                log("WARNING: speaker reports Audio-Latency \(latency) frames, not less than the timeline latency")
            }
        }

        if let volume {
            let status = try sendVolume(volume, session: session)
            if status != 200 {
                log("volume SET_PARAMETER answered \(status)")
                if options.requireVolumeAck { throw RAOPError.volumeRejected(status) }
            }
        }

        streamer.queue.sync { streamer.start(mapping: mapping) }
        return session
    }

    private var needsAuthSetup: Bool {
        switch options.authSetup {
        case .always: return true
        case .never: return false
        case .automatic:
            let et = descriptor.raopTXT["et"] ?? ""
            return et.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "4" }
        }
    }

    private func makeMapping(timeline: StreamTimeline, rtpBase: UInt32) -> SyncMapping {
        SyncMapping(timeline: timeline, rtpBase: rtpBase, offsetNanos: offsetNanos, receiverBiasFrames: options.receiverBiasFrames)
    }

    private func startStreaming(timeline: StreamTimeline, session: Session) {
        let streamer = self.streamer
        streamer.queue.sync {
            let base = streamer.rtpBase(continuingInto: timeline)
            streamer.start(mapping: makeMapping(timeline: timeline, rtpBase: base))
        }
    }

    @discardableResult
    private func sendVolume(_ volume: Float, session: Session) throws -> Int {
        let body = RAOPVolume.parameterBody(forLinear: volume)
        let response = try session.rtsp.send(RTSPRequest(method: "SET_PARAMETER", uri: session.uri,
                                                         headers: [RTSPHeader("Content-Type", "text/parameters")],
                                                         body: Data(body.utf8)), expectOK: false)
        return response.statusCode
    }

    private func setVolumeOnControl(_ value: Float) {
        let clamped = max(0, min(1, value.isFinite ? value : 0))
        volume = clamped
        guard let session else { return }
        do {
            let status = try sendVolume(clamped, session: session)
            if status != 200 { log("volume SET_PARAMETER answered \(status)") }
        } catch {
            fail(error)
        }
    }

    private func flushOnControl() {
        let streamer = self.streamer
        let next = streamer.queue.sync { streamer.pause() }
        guard let session else { return }
        do {
            _ = try session.rtsp.send(RTSPRequest(method: "FLUSH", uri: session.uri, headers: [
                RTSPHeader("RTP-Info", RTSPHeaderValue.rtpInfo(seq: next.seq, rtpTime: next.rtpTime)),
            ]), expectOK: false)
            setState(.idle)
        } catch {
            fail(error)
        }
    }

    private func stopOnControl() {
        let streamer = self.streamer
        _ = streamer.queue.sync { streamer.pause() }
        if let session {
            session.keepAlive?.cancel()
            _ = try? session.rtsp.send(RTSPRequest(method: "TEARDOWN", uri: session.uri), expectOK: false)
        }
        teardownLocal()
        setState(.idle)
    }

    /// Closes sockets and forgets the session (no RTSP traffic).
    private func teardownLocal() {
        let streamer = self.streamer
        streamer.queue.sync { streamer.close() }
        session?.keepAlive?.cancel()
        session?.rtsp.close()
        session = nil
    }

    private func fail(_ error: Error) {
        log("session failed: \(error)")
        teardownLocal()
        setState(.failed("\(error)"))
    }

    private func startKeepAlive(_ session: Session) {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        let interval = max(1, options.keepAliveInterval)
        var lastKeepAlive = Date()
        // Every second: notice a receiver that dropped the RTSP connection (another sender took over,
        // power loss…) quickly; every `keepAliveInterval`: OPTIONS so idle receivers keep the session.
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            if session.rtsp.connection.peerHasClosed() {
                self.fail(RAOPError.connectionClosed)
                return
            }
            guard Date().timeIntervalSince(lastKeepAlive) >= interval else { return }
            lastKeepAlive = Date()
            do {
                _ = try session.rtsp.send(RTSPRequest(method: "OPTIONS", uri: "*"), expectOK: false)
            } catch {
                self.fail(error)
            }
        }
        timer.resume()
        session.keepAlive = timer
    }

    private var metadataKinds: Set<String> {
        Set((descriptor.raopTXT["md"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private func currentRTPInfo() -> String? {
        let streamer = self.streamer
        return streamer.queue.sync { streamer.currentRTP() }.map { "rtptime=\($0)" }
    }

    private func nowPlayingOnControl(title: String?, artist: String?, album: String?, artwork: Data?) {
        guard let session, let rtpInfo = currentRTPInfo() else { return }
        let kinds = metadataKinds
        do {
            if kinds.contains("0") {
                let r = try session.rtsp.send(RTSPRequest(method: "SET_PARAMETER", uri: session.uri, headers: [
                    RTSPHeader("Content-Type", "application/x-dmap-tagged"), RTSPHeader("RTP-Info", rtpInfo),
                ], body: DMAP.nowPlaying(title: title, artist: artist, album: album)), expectOK: false)
                if r.statusCode != 200 { log("metadata SET_PARAMETER answered \(r.statusCode)") }
            }
            if kinds.contains("1"), let artwork, !artwork.isEmpty {
                let r = try session.rtsp.send(RTSPRequest(method: "SET_PARAMETER", uri: session.uri, headers: [
                    RTSPHeader("Content-Type", "image/jpeg"), RTSPHeader("RTP-Info", rtpInfo),
                ], body: artwork), expectOK: false)
                if r.statusCode != 200 { log("artwork SET_PARAMETER answered \(r.statusCode)") }
            }
        } catch {
            fail(error)
        }
    }

    private func progressOnControl(elapsed: Double, duration: Double) {
        guard let session, metadataKinds.contains("2") else { return }
        let streamer = self.streamer
        guard let now = streamer.queue.sync(execute: { streamer.currentRTP() }) else { return }
        let rate = Double(PCM.sampleRate)
        let start = now &- UInt32(truncatingIfNeeded: Int64(max(0, elapsed) * rate))
        let end = start &+ UInt32(truncatingIfNeeded: Int64(max(0, duration) * rate))
        do {
            let r = try session.rtsp.send(RTSPRequest(method: "SET_PARAMETER", uri: session.uri, headers: [
                RTSPHeader("Content-Type", "text/parameters"),
            ], body: Data(DMAP.progressBody(start: start, current: now, end: end).utf8)), expectOK: false)
            if r.statusCode != 200 { log("progress SET_PARAMETER answered \(r.statusCode)") }
        } catch {
            fail(error)
        }
    }
}
