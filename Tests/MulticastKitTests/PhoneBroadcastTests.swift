import Foundation
import Testing
import os
@testable import MulticastKit

/// A sink whose `prepare` always throws: a speaker that is switched off.
private final class UnreachableSink: AudioSink, @unchecked Sendable {
    struct Refused: Error, CustomStringConvertible { var description: String { "Not responding" } }
    let id: String
    let displayName: String
    init(_ d: SpeakerDescriptor) { id = d.id; displayName = d.name }
    func prepare(timeline: StreamTimeline) async throws { throw Refused() }
    func enqueue(_ packet: AudioPacket) {}
    func setVolume(_ volume: Float) async {}
    func setOffset(millis: Int) async {}
    func flush() async {}
    func stop() async {}
    var stateUpdates: AsyncStream<SinkState> { AsyncStream { $0.yield(.idle) } }
}

private struct UnreachableFactory: SinkProviding {
    func makeSink(for speaker: SpeakerDescriptor) throws -> AudioSink { UnreachableSink(speaker) }
}

private func speaker(_ id: String, _ name: String) -> SpeakerDescriptor {
    SpeakerDescriptor(id: id, name: name, transport: .airplay2, host: "speaker.invalid", port: 7000,
                      raopTXT: ["et": "0,4", "vn": "65537"])
}

private func makeStore() -> PhoneBroadcastStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multicast-broadcast-\(UUID().uuidString)")
    return PhoneBroadcastStore(directory: directory, notificationPrefix: "test.multicast.\(UUID().uuidString)")
}

private func options() -> PhoneBroadcastRunner.Options {
    var o = PhoneBroadcastRunner.Options()
    o.session.directory.includeNetwork = false
    o.session.engine.latencyNanos = 300_000_000
    o.session.engine.minDeliveryLeadNanos = 50_000_000
    o.session.engine.realtimeThread = false
    o.session.reconnectDelays = nil
    o.statusInterval = 0.05
    return o
}

/// Pushes a steady 48 kHz signal the way a broadcast would, until cancelled.
private func feed(_ source: PushedAudioSource, value: Int16 = 4000) -> Task<Void, Never> {
    Task.detached {
        let chunk = [Int16](repeating: value, count: 2 * 1024)
        let format = PushedAudioFormat(sampleRate: 48_000, channels: 2, sample: .int16)
        while !Task.isCancelled {
            _ = chunk.withUnsafeBytes { source.push(interleaved: $0, frames: 1024, format: format) }
            try? await Task.sleep(nanoseconds: 21_333_333)
        }
    }
}

private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@Suite(.serialized) struct PhoneBroadcastTests {
    @Test func storeRoundTripsAndNotifies() async throws {
        let store = makeStore()
        #expect(store.loadConfiguration() == PhoneBroadcastConfiguration())
        #expect(store.loadStatus().phase == .idle)

        let changed = OSAllocatedUnfairLock(initialState: 0)
        let changes = store.configurationChanges
        let listener = Task { for await _ in changes { changed.withLock { $0 += 1 } } }
        try await Task.sleep(nanoseconds: 100_000_000)

        let configuration = PhoneBroadcastConfiguration(
            speakers: [.init(descriptor: speaker("aaaaaaaaaaaa", "Kitchen"), isOn: true, volume: 0.3, offsetMillis: -40),
                       .init(descriptor: speaker("bbbbbbbbbbbb", "Study"), isOn: false, volume: 0.5)],
            masterVolume: 0.8)
        store.save(configuration)
        #expect(store.loadConfiguration() == configuration)
        #expect(store.loadConfiguration().chosen.map(\.id) == ["aaaaaaaaaaaa"])
        #expect(await wait { changed.withLock { $0 } >= 1 })
        listener.cancel()
    }

    /// A speaker whose AirPlay access setting admits only its owner: the iPhone turns it off
    /// (so the broadcast drops it and the next one doesn't pick it), and nothing else.
    @Test func refusingSpeakersAreTurnedOffAndNothingElse() {
        let refusal = "the receiver refused access (403 Forbidden to OPTIONS): its AirPlay access setting does not admit this sender"
        let pod = speaker("cccc00000001", "Neighbour\u{2019}s HomePod")
        let hall = speaker("aaaa00000001", "Hall Sonos")
        let patio = speaker("aaaa00000002", "Patio")
        let porch = speaker("aaaa00000003", "Porch")
        var configuration = PhoneBroadcastConfiguration(speakers: [
            .init(descriptor: pod, isOn: true, volume: 0.4),
            .init(descriptor: hall, isOn: true, volume: 0.5),
            .init(descriptor: patio, isOn: true, volume: 0.5),
            .init(descriptor: porch, isOn: false, volume: 0.5),
        ])
        let status = PhoneBroadcastStatus(phase: .capturing, speakers: [
            .init(id: pod.id, name: pod.name, state: .failed, error: refusal),
            .init(id: hall.id, name: hall.name, state: .playing),
            // Unreachable and password failures are not refusals.
            .init(id: patio.id, name: patio.name, state: .failed, error: "cannot connect to 192.0.2.9:7000: Connection refused"),
            .init(id: porch.id, name: porch.name, state: .failed, error: "the speaker requires a password (401) and none was given"),
        ])
        #expect(status.speakers[0].refusedAccess)
        #expect(!status.speakers[2].refusedAccess && !status.speakers[3].refusedAccess)
        #expect(configuration.turnOffRefusals(in: status) == [pod.id])
        #expect(configuration.chosen.map(\.id) == [hall.id, patio.id])
        // Its volume is kept for if the owner lets it in later.
        #expect(configuration.speakers[0].volume == 0.4)
        // Already off: nothing more to do.
        #expect(configuration.turnOffRefusals(in: status).isEmpty)
        #expect(SpeakerAccessCheck.isRefusal(refusal) && !SpeakerAccessCheck.isRefusal(nil))
    }

    @Test func staleStatusIsNotRunning() {
        var status = PhoneBroadcastStatus(phase: .capturing, updated: Date())
        #expect(status.isRunning())
        status.updated = Date().addingTimeInterval(-10)
        #expect(!status.isRunning())
        #expect(!PhoneBroadcastStatus(phase: .ended).isRunning())
    }

    @Test func startingWithNoSpeakersIsRefusedInPlainWords() async {
        let store = makeStore()
        store.save(PhoneBroadcastConfiguration(speakers: [.init(descriptor: speaker("aaaaaaaaaaaa", "Kitchen"), isOn: false, volume: 0.3)]))
        let runner = PhoneBroadcastRunner(store: store, source: PushedAudioSource(displayName: "iPhone"),
                                          factory: RecordingFactory(), options: options()) { _ in }
        await #expect(throws: PhoneBroadcastError.noSpeakers) { try await runner.start() }
        #expect(store.loadStatus().phase == .ended)
        #expect(store.loadStatus().endedReason?.contains("No speakers are turned on") == true)
    }

    @Test func pushedAudioReachesTheChosenSpeakersAndStatusFollows() async throws {
        let store = makeStore()
        let kitchen = speaker("aaaaaaaaaaaa", "Kitchen"), study = speaker("bbbbbbbbbbbb", "Study"), hall = speaker("cccccccccccc", "Hall")
        store.save(PhoneBroadcastConfiguration(speakers: [
            .init(descriptor: kitchen, isOn: true, volume: 0.3, offsetMillis: 20),
            .init(descriptor: study, isOn: true, volume: 0.6),
            .init(descriptor: hall, isOn: false, volume: 0.4),
        ]))
        let factory = RecordingFactory()
        let source = PushedAudioSource(displayName: "iPhone")
        let runner = PhoneBroadcastRunner(store: store, source: source, factory: factory, options: options()) { _ in }
        try await runner.start()
        let feeding = feed(source)
        defer { feeding.cancel() }

        // The captured signal comes out of both speakers, and only those.
        #expect(await wait {
            (factory.sink(kitchen.id)?.log.withLock { $0.firstSamples.contains { $0.0 > 3000 } } ?? false)
                && (factory.sink(study.id)?.log.withLock { $0.firstSamples.contains { $0.0 > 3000 } } ?? false)
        })
        #expect(factory.sink(hall.id) == nil)
        let k = try #require(factory.sink(kitchen.id)).log.withLock { $0 }
        #expect(k.volumes.first.map { abs($0 - 0.3) < 1e-6 } == true)
        #expect(k.calls.contains("offset 20"))

        #expect(await wait {
            let s = store.loadStatus()
            return s.phase == .capturing && s.isHearingAudio && s.speakers.count == 2 && s.speakers.allSatisfy { $0.state == .playing }
                && s.peakLeft > 0.05
        })
        let status = store.loadStatus()
        #expect(status.isRunning())
        #expect(status.inputSampleRate == 48_000)
        #expect(status.speakers.map(\.name) == ["Kitchen", "Study"])

        // The app turns one speaker off, another on, and changes a volume, mid-broadcast.
        store.save(PhoneBroadcastConfiguration(speakers: [
            .init(descriptor: kitchen, isOn: true, volume: 0.1, offsetMillis: 20),
            .init(descriptor: study, isOn: false, volume: 0.6),
            .init(descriptor: hall, isOn: true, volume: 0.4),
        ]))
        #expect(await wait {
            let s = store.loadStatus()
            return s.speakers.map(\.id) == [kitchen.id, hall.id] && s.speakers.allSatisfy { $0.state == .playing }
        })
        #expect(await wait { factory.sink(kitchen.id)?.log.withLock { $0.volumes.last.map { abs($0 - 0.1) < 1e-6 } } == true })
        #expect(factory.sink(study.id)?.log.withLock { $0.calls.last } == "stop")
        #expect(await wait { factory.sink(hall.id)?.log.withLock { !$0.packets.isEmpty } == true })

        // Stopping tears every speaker down and says so.
        await runner.stop()
        #expect(factory.sink(kitchen.id)?.log.withLock { $0.calls.last } == "stop")
        #expect(factory.sink(hall.id)?.log.withLock { $0.calls.last } == "stop")
        let ended = store.loadStatus()
        #expect(ended.phase == .ended)
        #expect(ended.speakers.isEmpty)
        #expect(!ended.isRunning())
        await runner.stop() // twice is fine
    }

    @Test func silenceIsReportedAsSilence() async throws {
        let store = makeStore()
        store.save(PhoneBroadcastConfiguration(speakers: [.init(descriptor: speaker("aaaaaaaaaaaa", "Kitchen"), isOn: true, volume: 0.3)]))
        let source = PushedAudioSource(displayName: "iPhone")
        let runner = PhoneBroadcastRunner(store: store, source: source, factory: RecordingFactory(), options: options()) { _ in }
        try await runner.start()
        // Before anything arrives the broadcast is still "starting".
        #expect(await wait { store.loadStatus().speakers.first?.state == .playing })
        #expect(store.loadStatus().phase == .starting)
        let feeding = feed(source, value: 0)
        #expect(await wait { store.loadStatus().phase == .capturing })
        let status = store.loadStatus()
        #expect(status.hasReceivedAudio)
        #expect(!status.isHearingAudio)
        feeding.cancel()
        await runner.stop()
    }

    @Test func givesUpWhenNoSpeakerCanBeReached() async throws {
        let store = makeStore()
        store.save(PhoneBroadcastConfiguration(speakers: [.init(descriptor: speaker("aaaaaaaaaaaa", "Kitchen"), isOn: true, volume: 0.3)]))
        let failures = OSAllocatedUnfairLock(initialState: [PhoneBroadcastError]())
        var o = options()
        o.unreachableGrace = 0.3
        let runner = PhoneBroadcastRunner(store: store, source: PushedAudioSource(displayName: "iPhone"),
                                          factory: UnreachableFactory(), options: o) { failure in
            failures.withLock { $0.append(failure) }
        }
        try await runner.start()
        #expect(await wait { !failures.withLock { $0 }.isEmpty })
        #expect(store.loadStatus().speakers.first?.state == .failed)
        // Told once, not on every tick.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(failures.withLock { $0 } == [.noSpeakerReachable])
        let reason = PhoneBroadcastError.noSpeakerReachable.errorDescription
        await runner.stop(reason: reason)
        #expect(store.loadStatus().endedReason == reason)
    }
}
