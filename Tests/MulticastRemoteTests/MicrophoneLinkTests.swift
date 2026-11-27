import Foundation
import MulticastAudio
import MulticastCalibration
import MulticastHubModel
import Testing
@testable import MulticastRemote

// A phone lending its microphone to a sync calibration, over real sockets on 127.0.0.1: a
// HubServer with a microphone host, a RemoteHubBackend with a made-up microphone.

/// The phone's microphone: "hears" the sweep a fixed time into every stretch it is asked about.
final class ScriptedMicrophone: CalibrationMicrophone, @unchecked Sendable {
    let permission = Locked(MicrophoneAccess.granted)
    let hearsAfter = Locked<Double?>(0.123)
    let calls = Locked<[String]>([])
    let asked = Locked<[(from: UInt64, seconds: Double, signal: CalibrationSignal)]>([])

    func access(ask: Bool) async -> MicrophoneAccess {
        calls.withLock { $0.append("access \(ask)") }
        return permission.value
    }
    func start() async throws { calls.withLock { $0.append("start") } }
    func stop() async { calls.withLock { $0.append("stop") } }
    func listen(for signal: CalibrationSignal, fromHostNanos: UInt64, seconds: Double) async -> HeardSweep? {
        asked.withLock { $0.append((fromHostNanos, seconds, signal)) }
        let arrival = hearsAfter.value.map { fromHostNanos + UInt64($0 * 1e9) }
        return HeardSweep(arrivalHostNanos: arrival, strength: arrival == nil ? 4.2 : 33, trace: [1, 2, 255, 3], level: 0.02)
    }
}

/// What the server hands to the hub when a phone asks to tune a speaker.
final class RecordingMicrophoneHost: @unchecked Sendable {
    let tunes = Locked<[(speakerID: String, microphoneID: String, name: String)]>([])
    let microphone = Locked<(any CalibrationMicrophone)?>(nil)
    let refusal = Locked<HubCommandError?>(nil)

    var host: RemoteMicrophoneHost {
        RemoteMicrophoneHost { [self] speakerID, microphone, microphoneID, name in
            if let refusal = refusal.value { throw refusal }
            tunes.withLock { $0.append((speakerID, microphoneID, name)) }
            self.microphone.withLock { $0 = microphone }
        }
    }
}

@Suite(.serialized) struct MicrophoneLinkTests {
    private func connect(_ host: RecordingMicrophoneHost?, phone: ScriptedMicrophone?,
                         hubVersions: ClosedRange<Int> = RemoteProtocol.supportedVersions) async throws -> (HubServer, RemoteHubBackend) {
        let stores = Fixture.pairedStores()
        let server = HubServer(backend: TestBackend(), configuration: Fixture.serverConfig { $0.supportedVersions = hubVersions },
                               keyStore: stores.hub, microphoneHost: host?.host)
        let port = try await server.start()
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        remote.setCalibrationMicrophone(phone)
        remote.start()
        _ = try await first(remote.connectionStates(), "connected") { if case .connected = $0 { true } else { false } }
        return (server, remote)
    }

    @Test func thePhoneTunesASpeakerAndTheHubListensThroughIt() async throws {
        let host = RecordingMicrophoneHost(), phone = ScriptedMicrophone()
        let (server, remote) = try await connect(host, phone: phone)
        defer { Task { await remote.stop(); await server.stop() } }
        #expect(remote.canTuneSpeakers)

        try await remote.tuneSpeaker("542a1b003344")
        let tune = try #require(host.tunes.value.first)
        #expect(tune.speakerID == "542a1b003344" && tune.microphoneID == "phone:remote-a" && tune.name == "Test Phone")

        // The hub's calibration now drives the phone's microphone through the link.
        let microphone = try #require(host.microphone.value)
        #expect(await microphone.access(ask: true) == .granted)
        try await microphone.start()
        let signal = CalibrationSignal(sweepSeconds: 0.05, periodSeconds: 0.2)
        let from = HostClock.nowNanos() - 500_000_000
        let heard = try #require(await microphone.listen(for: signal, fromHostNanos: from, seconds: 0.3))
        // Same machine, same clock: what the phone heard 123 ms into the stretch comes back as
        // 123 ms after the hub's `from`, within the clock exchange's error.
        let arrival = try #require(heard.arrivalHostNanos)
        #expect(abs(Double(arrival) - Double(from) - 123e6) < 2e6, "off by \((Double(arrival) - Double(from) - 123e6) / 1e6) ms")
        #expect(heard.strength == 33 && heard.trace == [1, 2, 255, 3] && heard.level == 0.02)
        let asked = try #require(phone.asked.value.first)
        #expect(asked.signal == signal && asked.seconds == 0.3)
        #expect(abs(Double(asked.from) - Double(from)) < 2e6)

        // Not heard is said, not guessed.
        phone.hearsAfter.withLock { $0 = nil }
        let silence = try #require(await microphone.listen(for: signal, fromHostNanos: from, seconds: 0.3))
        #expect(silence.arrivalHostNanos == nil && silence.strength == 4.2)

        await microphone.stop()
        #expect(phone.calls.value == ["access true", "start", "stop"])
    }

    @Test func aRefusedMicrophoneAndARefusedTuningAreSaid() async throws {
        let host = RecordingMicrophoneHost(), phone = ScriptedMicrophone()
        phone.permission.withLock { $0 = .denied }
        let (server, remote) = try await connect(host, phone: phone)
        defer { Task { await remote.stop(); await server.stop() } }
        try await remote.tuneSpeaker("a")
        let microphone = try #require(host.microphone.value)
        #expect(await microphone.access(ask: true) == .denied)

        host.refusal.withLock { $0 = HubCommandError(.unavailable, "A speaker is being tuned.") }
        await #expect(throws: HubCommandError(.unavailable, "A speaker is being tuned.")) { try await remote.tuneSpeaker("a") }
        await #expect(throws: HubCommandError.self) { try await remote.tuneSpeaker(SpeakerID(String(repeating: "x", count: 5000))) }
    }

    @Test func aPhoneWithNoMicrophoneAnswersThatItHasNone() async throws {
        let host = RecordingMicrophoneHost()
        let (server, remote) = try await connect(host, phone: nil)
        defer { Task { await remote.stop(); await server.stop() } }
        try await remote.tuneSpeaker("a")
        let microphone = try #require(host.microphone.value)
        #expect(await microphone.access(ask: false) == .denied)
        await #expect(throws: (any Error).self) { try await microphone.start() }
    }

    @Test func aHubThatTakesNoMicrophonesOrIsTooOldRefuses() async throws {
        do {
            let (server, remote) = try await connect(nil, phone: ScriptedMicrophone())
            defer { Task { await remote.stop(); await server.stop() } }
            await #expect(throws: HubCommandError.self) { try await remote.tuneSpeaker("a") }
        }
        // A hub that speaks only up to version 5 is never sent the new messages.
        let host = RecordingMicrophoneHost()
        let (server, remote) = try await connect(host, phone: ScriptedMicrophone(), hubVersions: RemoteProtocol.oldestVersion...5)
        defer { Task { await remote.stop(); await server.stop() } }
        #expect(!remote.canTuneSpeakers)
        await #expect(throws: HubCommandError.self) { try await remote.tuneSpeaker("a") }
        await #expect(throws: HubCommandError.self) { try await remote.perform(.calibrateSpeakerSync(id: "a")) }
        await #expect(throws: HubCommandError.self) { try await remote.perform(.cancelSyncCalibration) }
        #expect(host.tunes.value.isEmpty)
        // The link is still up: an ordinary command goes through.
        try await remote.perform(.pause)
    }

    @Test func whenThePhoneLeavesTheHubHearsNothingMore() async throws {
        let host = RecordingMicrophoneHost(), phone = ScriptedMicrophone()
        let (server, remote) = try await connect(host, phone: phone)
        defer { Task { await server.stop() } }
        try await remote.tuneSpeaker("a")
        let microphone = try #require(host.microphone.value)
        try await microphone.start()
        await remote.stop()
        let started = Date()
        #expect(await microphone.listen(for: CalibrationSignal(), fromHostNanos: HostClock.nowNanos(), seconds: 1) == nil)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func messagesHaveStableNames() throws {
        func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try WireJSON.encode(v), as: UTF8.self) }
        #expect(try json(ClientMessage.tuneSpeaker(id: 7, speakerID: "a")) == #"{"tuneSpeaker":{"id":7,"speakerID":"a"}}"#)
        #expect(try json(HubMessage.microphoneRequest(id: 3, request: .clock)) == #"{"microphoneRequest":{"id":3,"request":{"clock":{}}}}"#)
        #expect(try json(ClientMessage.microphoneAnswer(id: 3, answer: .clock(receivedNanos: 5, sentNanos: 6)))
                == #"{"microphoneAnswer":{"answer":{"clock":{"receivedNanos":5,"sentNanos":6}},"id":3}}"#)
        let listen = MicrophoneRequest.listen(signal: CalibrationSignal(), fromNanos: 9, seconds: 1)
        #expect(try WireJSON.decode(MicrophoneRequest.self, WireJSON.encode(listen)) == listen)
        #expect(RemoteProtocol.currentVersion == 6 && RemoteProtocol.calibrationVersion == 6)
    }

    @Test func thePhoneBoundsWhatItWillListenFor() async {
        let phone = ScriptedMicrophone()
        let responder = MicrophoneResponder(microphone: phone)
        #expect(await responder.answer(.listen(signal: CalibrationSignal(), fromNanos: 1, seconds: 600), received: 0) == .heard(nil))
        #expect(await responder.answer(.listen(signal: CalibrationSignal(sweepSeconds: 30), fromNanos: 1, seconds: 1), received: 0) == .heard(nil))
        #expect(phone.asked.value.isEmpty)
        guard case .clock(let received, let sent) = await responder.answer(.clock, received: 42) else { Issue.record("no clock"); return }
        #expect(received == 42 && sent > 42)
    }
}
