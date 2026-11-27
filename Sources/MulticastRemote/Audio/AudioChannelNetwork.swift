import Foundation
import MulticastAudio
import Network

// The audio channel's two UDP ends. Everything that decides what a datagram means is in
// `PhoneSpeakerSink` (hub) and `PhoneSpeakerReceiver` (phone); these only move bytes.

private func udpParameters(loopbackOnly: Bool) -> NWParameters {
    let params = NWParameters.udp
    params.includePeerToPeer = false
    params.serviceClass = .interactiveVoice
    if loopbackOnly { params.requiredInterfaceType = .loopback }
    return params
}

/// Hub side: a UDP port for one phone's offer. Datagrams reach the sink; the sink answers to
/// whichever address last sent it an authentic datagram, so a phone that changes address (or
/// port) is followed without ceremony, and anyone else is ignored.
final class HubAudioChannel: @unchecked Sendable {
    let sink: PhoneSpeakerSink
    private let queue = DispatchQueue(label: "multicast.audio-channel.hub")
    private let loopbackOnly: Bool
    private var listener: NWListener?
    private var current: NWConnection?
    private var strangers: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?
    private static let maxStrangers = 8

    init(sink: PhoneSpeakerSink, loopbackOnly: Bool) {
        self.sink = sink
        self.loopbackOnly = loopbackOnly
    }

    /// Starts listening. Returns the port.
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: udpParameters(loopbackOnly: loopbackOnly), on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { c.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    listener.cancel()
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { c.resume(throwing: error) }
                case .cancelled:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        c.resume(throwing: RemoteLinkError.closed("The audio channel closed."))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.sink.tick() }
            timer.resume()
            self.timer = timer
        }
        sink.setTransmit { [weak self] data in self?.transmit(data) }
        return port
    }

    func stop() {
        sink.shutDown()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            current?.cancel()
            current = nil
            for c in strangers.values { c.cancel() }
            strangers.removeAll()
        }
    }

    /// Called from the engine's pacing thread (through the sink): hand off, never block.
    private func transmit(_ data: Data) {
        queue.async { [self] in
            current?.send(content: data, completion: .idempotent)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard strangers.count < Self.maxStrangers else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        strangers[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let connection else { return }
                self.strangers[ObjectIdentifier(connection)] = nil
                if self.current === connection { self.current = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if self.sink.receive(data) {
                    if self.current !== connection {
                        // The phone, from a new address: answer there from now on.
                        self.strangers[ObjectIdentifier(connection)] = nil
                        self.current?.cancel()
                        self.current = connection
                    }
                } else if self.current !== connection {
                    connection.cancel()   // not ours: say nothing
                    return
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }
}

/// Phone side: the UDP connection to the hub's port, the receiver, and the timer that drives it.
final class PhoneSpeakerClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "multicast.audio-channel.phone", qos: .userInteractive)
    private let connection: NWConnection
    private var receiver: PhoneSpeakerReceiver?
    private var timer: DispatchSourceTimer?

    init(host: NWEndpoint.Host, port: UInt16, keys: AudioChannelKeys, output: any PhoneAudioOutput, loopbackOnly: Bool = false) {
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port) ?? .any,
                                      using: udpParameters(loopbackOnly: loopbackOnly))
        self.connection = connection
        receiver = PhoneSpeakerReceiver(keys: keys, output: output, now: { HostClock.nowNanos() },
                                        transmit: { [weak connection] data in
            connection?.send(content: data, completion: .idempotent)
        })
    }

    func start() {
        connection.start(queue: queue)
        receiveNext()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(15), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.receiver?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.receiver?.receive(data) }
            if error == nil { self.receiveNext() }
        }
    }

    var stats: PhoneSpeakerStats { queue.sync { receiver?.stats ?? PhoneSpeakerStats() } }

    /// The app closed the output itself (an interruption).
    func outputStopped() { queue.async { self.receiver?.outputStopped() } }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            receiver?.shutDown()
            receiver = nil
        }
        connection.cancel()
    }
}
