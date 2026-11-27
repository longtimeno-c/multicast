import Foundation
import Testing
import os
@testable import MulticastKit

/// A sink that records what the session/engine does to it.
final class RecordingSink: AudioSink, @unchecked Sendable {
    let id: String
    let displayName: String
    struct Log {
        var calls: [String] = []; var packets: [UInt64] = []; var volumes: [Float] = []
        /// First (left, right) sample of each packet, parallel to `packets`.
        var firstSamples: [(Int16, Int16)] = []
    }
    /// Makes `flush` slow (as a real speaker's FLUSH round trip is), to widen race windows.
    let flushDelayNanos = OSAllocatedUnfairLock(initialState: UInt64(0))
    let log = OSAllocatedUnfairLock(initialState: Log())
    private let state = OSAllocatedUnfairLock(initialState: SinkState.idle)

    init(_ d: SpeakerDescriptor) { id = d.id; displayName = d.name }

    func prepare(timeline: StreamTimeline) async throws {
        log.withLock { $0.calls.append("prepare") }
        state.withLock { $0 = .playing }
    }
    func enqueue(_ packet: AudioPacket) {
        guard state.withLock({ $0 }) == .playing else { return }
        let first: (Int16, Int16) = packet.samples.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return (p[0], p[1])
        }
        log.withLock { $0.packets.append(packet.firstFrame); $0.firstSamples.append(first) }
    }
    func setVolume(_ volume: Float) async { log.withLock { $0.calls.append("volume"); $0.volumes.append(volume) } }
    func setOffset(millis: Int) async { log.withLock { $0.calls.append("offset \(millis)") } }
    func flush() async {
        let delay = flushDelayNanos.withLock { $0 }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        log.withLock { $0.calls.append("flush") }
    }
    func stop() async { log.withLock { $0.calls.append("stop") }; state.withLock { $0 = .idle } }
    var stateUpdates: AsyncStream<SinkState> { AsyncStream { $0.yield(state.withLock { $0 }) } }
}

final class RecordingFactory: SinkProviding, @unchecked Sendable {
    let made = OSAllocatedUnfairLock(initialState: [String: RecordingSink]())
    func makeSink(for speaker: SpeakerDescriptor) throws -> AudioSink {
        let s = RecordingSink(speaker)
        made.withLock { $0[speaker.id] = s }
        return s
    }
    func sink(_ id: String) -> RecordingSink? { made.withLock { $0[id] } }
}

private func speaker(_ id: String, _ name: String, bridge: Bool = false) -> SpeakerDescriptor {
    SpeakerDescriptor(id: id, name: name, transport: bridge ? .airplay1 : .airplay2, host: "h.local", port: 7000,
                      raopTXT: bridge ? ["am": "airupnp", "et": "0,1"] : ["et": "0,4", "vn": "65537"])
}

private func makeSession(_ factory: RecordingFactory) -> MulticastSession {
    var c = MulticastSession.Configuration()
    c.directory = .init(includeNetwork: false, includeLocal: false)
    c.engine.latencyNanos = 300_000_000
    c.engine.minDeliveryLeadNanos = 50_000_000
    c.engine.realtimeThread = false
    c.fadeSeconds = 0.05
    return MulticastSession(configuration: c, factory: factory)
}

@Suite(.serialized) struct SessionTests {
    @Test func selectPushesVolumeBeforeAudioAndStreamsToAllSpeakers() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        session.start()
        let a = speaker("aaaaaaaaaaaa", "Alpha"), b = speaker("bbbbbbbbbbbb", "Beta")
        try await session.setSource(.tone(frequency: 440, amplitude: 0.1, duration: nil))
        try await session.select(a, volume: 0.12)
        try await session.select(b, volume: 0.1, offsetMillis: 25)
        try await session.select(a) // already selected: no-op
        #expect(session.selectedSpeakerIDs == [a.id, b.id])
        try await session.play()
        try await Task.sleep(nanoseconds: 600_000_000)

        let sa = try #require(factory.sink(a.id)), sb = try #require(factory.sink(b.id))
        let la = sa.log.withLock { $0 }, lb = sb.log.withLock { $0 }
        #expect(la.volumes.first == 0.12)
        #expect(lb.volumes.first.map { abs($0 - 0.1) < 1e-6 } == true)
        #expect(la.calls.firstIndex(of: "volume")! < la.calls.firstIndex(of: "prepare")!)
        #expect(lb.calls.contains("offset 25"))
        #expect(la.packets.count > 20 && lb.packets.count > 20)
        // Both speakers get the same frames on the same timeline.
        #expect(Array(la.packets.prefix(10)) == Array(lb.packets.prefix(10)))
        #expect(session.state.selectedSpeakerIDs == [a.id, b.id])
        #expect(session.state.engine.sinks.map(\.id) == [a.id, b.id])

        await session.shutdown()
        #expect(sa.log.withLock { $0.calls }.last == "stop")
        #expect(session.selectedSpeakerIDs.isEmpty)
    }

    @Test func aSpeakerThatBringsItsOwnSinkIsListedSelectedAndRemoved() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        session.start()
        let phone = SpeakerDescriptor(id: "phone:remote-a", name: "Sample iPhone", transport: .remote, model: "Speaker", localKind: .builtIn)
        // Nothing can build it: without its device it can't be selected.
        await #expect(throws: MulticastSession.SessionError.self) { try await session.select(phone) }
        #expect(session.selectedSpeakerIDs.isEmpty)

        let sink = RecordingSink(phone)
        await session.addExternalSpeaker(phone, sink: sink)
        #expect(session.state.speakers.map(\.id) == [phone.id])
        try await session.setSource(.tone(frequency: 440, amplitude: 0.1, duration: nil))
        try await session.select(phone, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(sink.log.withLock { $0.packets.count } > 20)
        #expect(factory.sink(phone.id) == nil)                 // the factory was never asked

        // Its output changed: same sink, new descriptor, still playing.
        var moved = phone
        moved.model = "Sample Speaker"
        moved.localKind = .bluetooth
        await session.addExternalSpeaker(moved, sink: sink)
        #expect(session.state.speakers.first?.model == "Sample Speaker")
        #expect(session.selectedSpeakerIDs == [phone.id])

        // A new link to the same phone: the old sink leaves the group.
        let second = RecordingSink(phone)
        await session.addExternalSpeaker(moved, sink: second)
        #expect(session.selectedSpeakerIDs.isEmpty)
        #expect(sink.log.withLock { $0.calls }.last == "stop")
        try await session.select(moved, volume: 0.1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(second.log.withLock { $0.packets.count } > 5)

        await session.removeExternalSpeaker(id: phone.id)
        #expect(session.state.speakers.isEmpty && session.selectedSpeakerIDs.isEmpty)
        #expect(second.log.withLock { $0.calls }.last == "stop")
        await session.shutdown()
    }

    @Test func samePhysicalDeviceIsRefused() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let native = speaker("8ca96f0011e9", "Denon AVR-X2800H")
        let bridge = speaker("bbbb6f0011e7", "Denon AVR-X2800H+", bridge: true)
        try await session.select(native, volume: 0.1)
        await #expect(throws: MulticastSession.SessionError.samePhysicalDevice("Denon AVR-X2800H+", "Denon AVR-X2800H")) {
            try await session.select(bridge, volume: 0.1)
        }
        #expect(session.selectedSpeakerIDs == [native.id])
        #expect(factory.sink(bridge.id) == nil)
        // After deselecting the native one, the bridge is allowed.
        await session.deselect(speakerID: native.id)
        try await session.select(bridge, volume: 0.1)
        #expect(session.selectedSpeakerIDs == [bridge.id])
        await session.shutdown()
    }

    @Test func deselectMidPlaybackStopsDeliveryToThatSpeakerOnly() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha"), b = speaker("bbbbbbbbbbbb", "Beta")
        try await session.setSource(.tone(duration: nil))
        try await session.select(a, volume: 0.1)
        try await session.select(b, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.deselect(speakerID: b.id)
        let sb = try #require(factory.sink(b.id))
        let countAtRemoval = sb.log.withLock { $0.packets.count }
        #expect(sb.log.withLock { $0.calls }.suffix(2) == ["flush", "stop"])
        let sa = try #require(factory.sink(a.id))
        let aBefore = sa.log.withLock { $0.packets.count }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sb.log.withLock { $0.packets.count } == countAtRemoval)
        #expect(sa.log.withLock { $0.packets.count } > aBefore)
        #expect(session.selectedSpeakerIDs == [a.id])
        await session.shutdown()
    }

    @Test func fadeOutStopEndsTheStreamAndStops() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha")
        try await session.setSource(.tone(duration: nil))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await session.stop(fadeOut: true)
        // ~latency (0.3 s) + fade (0.05 s) + margin, bounded well below the 3 s fallback.
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(session.state.engine.transport == .stopped)
        await session.shutdown()
    }

    // MARK: Transport lifecycle through the façade

    @Test func playAgainAfterAFadedStopProducesAudio() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha")
        try await session.setSource(.tone(duration: nil))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.stop(fadeOut: true)
        #expect(session.state.engine.transport == .stopped)
        let sa = try #require(factory.sink(a.id))
        let before = sa.log.withLock { $0.packets.count }
        try await session.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(session.state.engine.transport == .playing, "must not end at once")
        #expect(sa.log.withLock { $0.packets.count } > before + 30)
        await session.shutdown()
    }

    @Test func playAfterRequestFadeOutEndedResumesTheSource() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha")
        try await session.setSource(.tone(duration: nil))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 150_000_000)
        session.requestFadeOut()
        var waited = 0
        while session.state.engine.transport != .ended, waited < 100 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        #expect(session.state.engine.transport == .ended)
        let sa = try #require(factory.sink(a.id))
        let before = sa.log.withLock { $0.packets.count }
        try await session.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(session.state.engine.transport == .playing)
        #expect(sa.log.withLock { $0.packets.count } > before + 30)
        await session.shutdown()
    }

    @Test func pauseResumeContinuesFromWhatWasHeard() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)   // 300 ms latency
        let a = speaker("aaaaaaaaaaaa", "Alpha")
        let counting = CountingSource()
        try await session.setSource(.custom(counting))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 700_000_000)
        await session.pause()
        let sa = try #require(factory.sink(a.id))
        let atPause = sa.log.withLock { $0.packets.count }
        let lastSent = sa.log.withLock { CountingSource.position($0.firstSamples[atPause - 1]) }
        try await session.play()
        try await Task.sleep(nanoseconds: 600_000_000)
        await session.stop()
        let log = sa.log.withLock { $0 }
        let resumed = CountingSource.position(log.firstSamples[atPause])
        // About one latency (300 ms ≈ 37 packets) had been sent but not heard; it is replayed.
        #expect(resumed < lastSent)
        let unheard = Double(lastSent + 352 - resumed) / 44_100
        #expect(unheard > 0.2 && unheard < 0.45, "replayed \(unheard) s")
        for i in atPause..<log.firstSamples.count {
            #expect(CountingSource.position(log.firstSamples[i]) == resumed + UInt64(i - atPause) * 352)
        }
        await session.shutdown()
    }

    @Test func shutdownIsTerminal() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        session.start()
        await session.shutdown()
        #expect(session.hasShutDown)
        session.start()
        await #expect(throws: MulticastSession.SessionError.shutDown) { try await session.play() }
        await #expect(throws: MulticastSession.SessionError.shutDown) {
            try await session.select(speaker("aaaaaaaaaaaa", "Alpha"))
        }
        await #expect(throws: MulticastSession.SessionError.shutDown) { try await session.setSource(.tone()) }
        #expect(factory.sink("aaaaaaaaaaaa") == nil)
    }

    @Test func deselectDuringSlowEngineCommandNeverLeavesAnUntrackedSpeaker() async throws {
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha"), b = speaker("bbbbbbbbbbbb", "Beta")
        try await session.setSource(.tone(duration: nil))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 100_000_000)
        try #require(factory.sink(a.id)).flushDelayNanos.withLock { $0 = 400_000_000 }
        // pause() occupies the engine's command FIFO (slow flush); select(b) queues behind it and
        // deselect(b) is issued while that add is still pending.
        let pause = Task { await session.pause() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let sel = Task { try await session.select(b, volume: 0.1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await session.deselect(speakerID: b.id)
        _ = await pause.value
        try await sel.value
        #expect(!session.selectedSpeakerIDs.contains(b.id))
        #expect(!session.state.engine.sinks.map(\.id).contains(b.id), "engine must not keep an untracked sink")
        await session.shutdown()
    }

    @Test func stateRevisionIncreasesOnEveryPublishedChange() async throws {
        let session = makeSession(RecordingFactory())
        session.start()
        let r0 = session.state.revision
        try await session.select(speaker("aaaaaaaaaaaa", "Alpha"), volume: 0.1)
        let r1 = session.state.revision
        #expect(r1 > r0)
        await session.deselect(speakerID: "aaaaaaaaaaaa")
        #expect(session.state.revision > r1)
        await session.shutdown()
    }

    @Test func diagnosticsAreCodable() throws {
        var d = SinkDiagnostics(id: "x", name: "X", kind: .raop)
        d.packetsSent = 5
        let back = try JSONDecoder().decode(SinkDiagnostics.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func seekWhilePlayingFlushesAndPlaysTheTargetAfterOneLatency() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multicast-seek-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeIndexWAV(url: url, seconds: 12)
        let factory = RecordingFactory()
        let session = makeSession(factory)
        let a = speaker("aaaaaaaaaaaa", "Alpha")
        try await session.setSource(.file(url))
        try await session.select(a, volume: 0.1)
        try await session.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        let sa = try #require(factory.sink(a.id))
        let preparesBefore = sa.log.withLock { $0.calls.filter { $0 == "prepare" }.count }
        let countBefore = sa.log.withLock { $0.packets.count }
        try await session.seek(toSeconds: 8)
        try await Task.sleep(nanoseconds: 500_000_000)
        let log = sa.log.withLock { $0 }
        await session.shutdown()
        #expect(log.calls.filter { $0 == "prepare" }.count == preparesBefore + 1, "re-anchored")
        #expect(log.calls.contains("flush"))
        // After the seek, the first non-silent packet is from ~8 s (index = frame % 30000).
        let after = log.firstSamples[countBefore...].first { $0.0 != 0 }
        let target = (8 * 44_100) % 30_000
        let got = Int(try #require(after).0)
        #expect(abs(got - target) < 44_100 / 10 , "first content after seek \(got), expected about \(target)")
    }

    @Test func unknownSpeakerIDIsReported() async {
        let session = makeSession(RecordingFactory())
        await #expect(throws: MulticastSession.SessionError.unknownSpeaker("nope")) {
            try await session.select(speakerID: "nope")
        }
    }

    @Test func badToneFrequencyIsRejectedBeforeTouchingTheEngine() async {
        let session = makeSession(RecordingFactory())
        await #expect(throws: MulticastSession.SessionError.self) {
            try await session.setSource(.tone(frequency: 30_000))
        }
        #expect(session.currentSource == nil)
    }
}

/// Infinite source whose samples encode the frame position (left = pos % 32768, right = pos / 32768).
final class CountingSource: AudioSource, @unchecked Sendable {
    let displayName = "counting"
    let isLive = false
    private var position: UInt64 = 0   // pacer thread only
    func start() async throws {}
    func stop() async {}
    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        for i in 0..<frameCount {
            let p = position + UInt64(i)
            buffer[2 * i] = Int16(p % 32_768)
            buffer[2 * i + 1] = Int16((p / 32_768) % 32_768)
        }
        position += UInt64(frameCount)
        return frameCount
    }
    static func position(_ s: (Int16, Int16)) -> UInt64 { UInt64(s.1) * 32_768 + UInt64(s.0) }
}

/// 44.1 kHz stereo 16-bit WAV whose left channel is frame % 30000 (as an Int16 value).
func writeIndexWAV(url: URL, seconds: Int) throws {
    let frames = 44_100 * seconds
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(2)
    le32(44_100); le32(44_100 * 4); le16(4); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(UInt32(frames * 4))
    var pcm = [Int16](repeating: 0, count: frames * 2)
    for i in 0..<frames { pcm[2 * i] = Int16(i % 30_000); pcm[2 * i + 1] = -8_192 }
    pcm.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}
