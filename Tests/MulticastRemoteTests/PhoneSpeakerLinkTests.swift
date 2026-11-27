import Foundation
import MulticastAudio
import MulticastHubModel
import Testing
@testable import MulticastRemote

// A phone offering itself as a speaker, over real sockets on 127.0.0.1: a HubServer with a
// speaker host, a RemoteHubBackend with an output that records, TCP for the offer and UDP for
// the audio.

/// What the server hands to the hub, recorded.
final class RecordingSpeakerHost: @unchecked Sendable {
    private let state = Locked<(added: [SpeakerDescriptor], removed: [String], sink: (any AudioSink)?)>(([], [], nil))
    private let onDevice = Locked<[Bool]>([])

    var host: RemoteSpeakerHost {
        RemoteSpeakerHost(
            add: { [state, onDevice] descriptor, sink, volumeOnDevice in
                state.withLock { $0.added.append(descriptor); $0.sink = sink }
                onDevice.withLock { $0.append(volumeOnDevice) }
            },
            remove: { [state] id in state.withLock { $0.removed.append(id); $0.sink = nil } })
    }

    /// For each offer or route change, whether the phone said it sets its own system volume.
    var volumeOnDevice: [Bool] { onDevice.value }

    var added: [SpeakerDescriptor] { state.value.added }
    var removed: [String] { state.value.removed }
    var sink: (any AudioSink)? { state.value.sink }
}

/// A phone output that only counts, safe to call from the channel's queue.
final class CountingOutput: PhoneAudioOutput, @unchecked Sendable {
    private let state = Locked<(starts: [StreamTimeline], frames: [UInt64], stops: Int, flushes: Int, offset: Int64?, volume: Float?, trim: Int?)>(
        ([], [], 0, 0, nil, nil, nil))

    let mayStart = true
    var starts: [StreamTimeline] { state.value.starts }
    var frames: [UInt64] { state.value.frames }
    var stops: Int { state.value.stops }
    var flushes: Int { state.value.flushes }
    var clockOffset: Int64? { state.value.offset }
    var volume: Float? { state.value.volume }
    var trim: Int? { state.value.trim }

    func start(timeline: StreamTimeline) -> Bool {
        state.withLock { $0.starts.append(timeline) }
        return true
    }
    func setClockOffset(nanos: Int64) { state.withLock { $0.offset = nanos } }
    func write(_ packet: AudioPacket) { state.withLock { $0.frames.append(packet.firstFrame) } }
    func flush() { state.withLock { $0.flushes += 1 } }
    func setVolume(_ volume: Float) { state.withLock { $0.volume = volume } }
    func setOffset(millis: Int) { state.withLock { $0.trim = millis } }
    func stop() { state.withLock { $0.stops += 1 } }
}

extension PhoneSpeakerPhase {
    var isOn: Bool { if case .on = self { true } else { false } }
}

@Suite(.serialized) struct PhoneSpeakerLinkTests {
    private func start(_ speakers: RecordingSpeakerHost?, store: InMemoryPairingKeyStore,
                       backend: TestBackend = TestBackend()) async throws -> (HubServer, UInt16) {
        let server = HubServer(backend: backend, configuration: Fixture.serverConfig(), keyStore: store, speakerHost: speakers?.host)
        return (server, try await server.start())
    }

    /// Feeds the sink like the engine would: a packet every 8 ms, two seconds ahead.
    private func stream(_ sink: any AudioSink, packets: Int, from firstPacket: Int = 0, timeline: StreamTimeline) async {
        for i in firstPacket..<(firstPacket + packets) {
            sink.enqueue(AudioPacket(firstFrame: timeline.anchorFrame + UInt64(i * PCM.framesPerPacket), samples: testPacket(i)))
            try? await Task.sleep(nanoseconds: 7_980_000)
        }
    }

    @Test func anOfferBecomesASpeakerAndAudioArrivesInOrder() async throws {
        let speakers = RecordingSpeakerHost()
        let stores = Fixture.pairedStores()
        let (server, port) = try await start(speakers, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        let output = CountingOutput()
        remote.start()
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Sample Speaker", kind: .bluetooth), output: output)

        let phase = try await first(remote.phoneSpeakerPhases(), "speaker on") { $0.isOn }
        #expect(phase == .on(speakerID: "phone:remote-a"))
        try await eventually("listed on the hub") { speakers.added.count == 1 }
        let d = try #require(speakers.added.first)
        #expect(d.id == "phone:remote-a" && d.name == "Test Phone" && d.transport == .remote)
        #expect(d.model == "Sample Speaker" && d.localKind == .bluetooth)
        // Both ends are current: the phone sets its own system volume.
        #expect(speakers.volumeOnDevice == [true] && remote.phoneSpeakerVolumeIsSystemVolume)

        // The hub starts playing to it.
        let sink = try #require(speakers.sink)
        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)
        try await sink.prepare(timeline: timeline)
        await sink.setVolume(0.3)
        await sink.setOffset(millis: 40)
        await stream(sink, packets: 150, timeline: timeline)
        try await eventually("audio at the phone") { output.frames.count >= 140 }
        #expect(output.starts == [timeline])
        #expect(output.frames == output.frames.sorted() && output.frames.first == 0)
        #expect(output.volume == 0.3 && output.trim == 40)
        // Same machine, same clock: the estimated offset must be close to nothing.
        let offset = try #require(output.clockOffset)
        #expect(abs(offset) < 2_000_000, "offset \(Double(offset) / 1e6) ms")
        let stats = try #require(remote.phoneSpeakerStats)
        #expect(stats.isPlaying && stats.hubIsStreaming && stats.clockSamples >= 5)
        #expect(stats.packetsConcealed == 0)
        #expect(stats.bufferedMillis > 500)

        // Another output on the phone: same speaker, new descriptor.
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Speaker", kind: .builtIn), output: output)
        try await eventually("route told to the hub") { speakers.added.count == 2 }
        #expect(speakers.added.last?.model == "Speaker" && speakers.added.last?.localKind == .builtIn)
        #expect(speakers.removed.isEmpty)
        #expect(speakers.sink === sink)

        // Turned off on the phone.
        remote.stopPhoneSpeaker()
        try await eventually("removed on the hub") { speakers.removed == ["phone:remote-a"] }
        try await eventually("output closed") { output.stops == 1 }
        #expect(remote.phoneSpeakerPhase == .off)
        #expect(remote.phoneSpeakerStats == nil)
    }

    @Test func aPhoneOnTheVersionBeforeSystemVolumeIsStillASpeakerWithItsVolumeAsAGain() async throws {
        let speakers = RecordingSpeakerHost()
        let stores = Fixture.pairedStores()
        let (server, port) = try await start(speakers, store: stores.hub)
        defer { Task { await server.stop() } }
        let old = RemoteProtocol.oldestVersion...(RemoteProtocol.phoneSystemVolumeVersion - 1)
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port) { $0.supportedVersions = old }, keyStore: stores.remote)
        defer { Task { await remote.stop() } }
        remote.start()
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Speaker", kind: .builtIn), output: CountingOutput())
        _ = try await first(remote.phoneSpeakerPhases(), "speaker on") { $0.isOn }
        try await eventually("listed on the hub") { speakers.added.count == 1 }
        #expect(speakers.volumeOnDevice == [false])
        #expect(!remote.phoneSpeakerVolumeIsSystemVolume)
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Sample Speaker", kind: .bluetooth), output: CountingOutput())
        try await eventually("route told to the hub") { speakers.added.count == 2 }
        #expect(speakers.volumeOnDevice == [false, false])
    }

    @Test func theOfferIsMadeAgainAfterAReconnectAndDroppedWhenThePhoneLeaves() async throws {
        let speakers = RecordingSpeakerHost()
        let stores = Fixture.pairedStores()
        let (server, port) = try await start(speakers, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        let output = CountingOutput()
        // Offered before there is a connection: made once there is.
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Speaker", kind: .builtIn), output: output)
        #expect(remote.phoneSpeakerPhase == .off || remote.phoneSpeakerPhase == .waitingForHub)
        remote.start()
        _ = try await first(remote.phoneSpeakerPhases(), "speaker on") { $0.isOn }
        try await eventually("listed") { speakers.added.count == 1 }

        // The phone goes away without a word.
        await remote.stop()
        try await eventually("dropped with the session") { speakers.removed.count == 1 }
        #expect(remote.phoneSpeakerPhase == .waitingForHub)

        remote.start()
        _ = try await first(remote.phoneSpeakerPhases(), "speaker on again") { $0.isOn }
        try await eventually("listed again") { speakers.added.count == 2 }
        #expect(speakers.sink != nil)
        await remote.stop()
    }

    @Test func aHubWithoutSpeakersOrAnOlderOneSaysSo() async throws {
        let stores = Fixture.pairedStores()
        let (server, port) = try await start(nil, store: stores.hub)
        defer { Task { await server.stop() } }
        let remote = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        remote.start()
        remote.startPhoneSpeaker(route: PhoneRoute(name: "Speaker", kind: .builtIn), output: CountingOutput())
        let refused = try await first(remote.phoneSpeakerPhases(), "refusal") {
            if case .unsupported = $0 { true } else { false }
        }
        #expect(refused == .unsupported(message: "Studio Mac can\u{2019}t play to an iPhone."))
        await remote.stop()

        // A version 3 link never carries the offer.
        let old = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port) { $0.supportedVersions = 2...3 },
                                   keyStore: stores.remote)
        old.start()
        old.startPhoneSpeaker(route: PhoneRoute(name: "Speaker", kind: .builtIn), output: CountingOutput())
        let tooOld = try await first(old.phoneSpeakerPhases(), "too old") {
            if case .unsupported = $0 { true } else { false }
        }
        #expect(tooOld == .unsupported(message: "Update Multicast on the Mac to play on this iPhone."))
        await old.stop()
    }

    @Test func anOlderRemoteSeesAPhoneSpeakerAsABuiltInOne() async throws {
        let backend = TestBackend()
        backend.broadcaster.update { state in
            state.speakers.append(SpeakerItem(id: "phone:remote-b", name: "Sample iPhone", transport: .phone, glyph: .phone,
                                              model: "Sample Speaker", volume: 0.5))
        }
        let stores = Fixture.pairedStores()
        let (server, port) = try await start(nil, store: stores.hub, backend: backend)
        defer { Task { await server.stop() } }
        let old = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port) { $0.supportedVersions = 2...3 },
                                   keyStore: stores.remote)
        defer { Task { await old.stop() } }
        let seen = try await first(await old.states(), "state") { $0.speakers.count == 3 }
        #expect(seen.speakers.last?.transport == .builtIn && seen.speakers.last?.glyph == .portable)
        #expect(seen.speakers.last?.name == "Sample iPhone")

        let current = RemoteHubBackend(configuration: Fixture.remoteConfig(port: port), keyStore: stores.remote)
        defer { Task { await current.stop() } }
        let now = try await first(await current.states(), "state") { $0.speakers.count == 3 }
        #expect(now.speakers.last?.transport == .phone && now.speakers.last?.glyph == .phone)
    }

    @Test func theNewMessagesRoundTrip() throws {
        let route = PhoneRoute(name: "Sample Speaker", kind: .bluetooth)
        let client: [ClientMessage] = [.speakerOffer(id: 4, route: route), .speakerRoute(route: route), .speakerWithdraw]
        for m in client { #expect(try WireJSON.decode(ClientMessage.self, WireJSON.encode(m)) == m) }
        let hub = HubMessage.speakerAccepted(id: 4, port: 50123, salt: Data(repeating: 5, count: 16), speakerID: "phone:remote-a")
        #expect(try WireJSON.decode(HubMessage.self, WireJSON.encode(hub)) == hub)
        #expect(String(decoding: try WireJSON.encode(ClientMessage.speakerWithdraw), as: UTF8.self) == #"{"speakerWithdraw":{}}"#)
        #expect(RemoteProtocol.supportedVersions.contains(3) && RemoteProtocol.supportedVersions.contains(4))
        #expect(RemoteProtocol.currentVersion == 5 && RemoteProtocol.phoneSystemVolumeVersion == 5)
        // Text from the phone is cleaned before the hub shows it.
        let odd = PhoneRoute(name: String(repeating: "x", count: 500) + "\n", kind: .other).sanitized
        #expect(odd.name.count < 200 && !odd.name.contains("\n"))
    }
}
