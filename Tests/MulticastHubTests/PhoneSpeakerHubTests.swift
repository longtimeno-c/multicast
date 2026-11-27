import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastKit
import Testing
@testable import MulticastHub

private final class NullSink: AudioSink, @unchecked Sendable {
    let id: String
    let displayName: String
    init(_ d: SpeakerDescriptor) { id = d.id; displayName = d.name }
    func prepare(timeline: StreamTimeline) async throws {}
    func enqueue(_ packet: AudioPacket) {}
    func setVolume(_ volume: Float) async {}
    func setOffset(millis: Int) async {}
    func flush() async {}
    func stop() async {}
    var stateUpdates: AsyncStream<SinkState> { AsyncStream { $0.yield(.idle) } }
}

/// A paired iPhone that offers itself: listed and turned on while it is there, with volume and
/// trim remembered per output, and gone when it leaves.
@Suite("LocalHub phone speakers")
struct PhoneSpeakerHubTests {
    private static let id = SpeakerID("phone:remote-a")

    private static func phone(_ output: String = "Speaker", kind: SpeakerDescriptor.LocalKind = .builtIn) -> SpeakerDescriptor {
        SpeakerDescriptor(id: id.rawValue, name: "Sample iPhone", transport: .remote, model: output, localKind: kind)
    }

    @Test func anOfferIsListedAsAPhoneAndTurnedOn() async throws {
        let rig = Rig()
        await rig.start()
        let d = Self.phone()
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d))
        try await rig.waitFor("phone on") { $0.speaker(Self.id)?.isEnabled == true && $0.speaker(Self.id)?.state != .connecting }
        let item = try #require(rig.state.speaker(Self.id))
        #expect(item.name == "Sample iPhone" && item.transport == .phone && item.glyph == .phone)
        #expect(item.model == "Speaker" && item.address == nil)
        #expect(item.kindDescription == "iPhone \u{00B7} Speaker")
        #expect(rig.session.inner.get().selected == [Self.id.rawValue])
        // Listed after the speakers that were found, not instead of them.
        #expect(rig.state.speakers.count == 4)
        let calls = rig.session.calls
        #expect(calls.firstIndex(of: "addExternal phone:remote-a Speaker")! < calls.firstIndex(of: "select phone:remote-a")!)
    }

    @Test func volumeAndTrimAreRememberedPerOutput() async throws {
        let rig = Rig()
        await rig.start()
        let sink = NullSink(Self.phone())
        await rig.hub.addExternalSpeaker(Self.phone(), sink: sink)
        try await rig.waitFor { $0.speaker(Self.id)?.isEnabled == true }
        try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.2))
        try await rig.hub.perform(.setSpeakerSyncTrim(id: Self.id, milliseconds: 10))

        // A Bluetooth speaker connects to the phone: same row, its own settings, still on.
        await rig.hub.addExternalSpeaker(Self.phone("Sample Speaker", kind: .bluetooth), sink: sink)
        try await rig.waitFor("route shown") { $0.speaker(Self.id)?.model == "Sample Speaker" }
        var item = try #require(rig.state.speaker(Self.id))
        #expect(item.isEnabled && item.volume == 0.5 && item.syncTrimMs == 0)
        try await rig.hub.perform(.setSpeakerSyncTrim(id: Self.id, milliseconds: -180))
        try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.35))
        #expect(rig.session.calls.contains("offset phone:remote-a -180"))

        // Back to the phone's own speaker: what was set for it returns, and reaches the sink.
        await rig.hub.addExternalSpeaker(Self.phone(), sink: sink)
        try await rig.waitFor("route shown") { $0.speaker(Self.id)?.model == "Speaker" }
        item = try #require(rig.state.speaker(Self.id))
        #expect(item.volume == 0.2 && item.syncTrimMs == 10 && item.isEnabled)
        #expect(rig.session.calls.suffix(4).contains("offset phone:remote-a 10"))
        #expect(rig.session.calls.suffix(4).contains("volume phone:remote-a 0.2"))

        let saved = rig.settings.load().speakers
        #expect(saved["phone:remote-a#Sample Speaker"] == HubSettings.SpeakerPreset(volume: 0.35, syncTrimMs: -180, isEnabled: true))
        #expect(saved["phone:remote-a#Speaker"]?.syncTrimMs == 10)
        #expect(saved["phone:remote-a"] == nil)
    }

    @Test func aPhoneThatSetsItsOwnVolumeIsHeldAtFullGainAndItsVolumeIsOnlyKept() async throws {
        let rig = Rig()
        await rig.start()
        let sink = NullSink(Self.phone())
        await rig.hub.addExternalSpeaker(Self.phone(), sink: sink, volumeOnDevice: true)
        try await rig.waitFor { $0.speaker(Self.id)?.isEnabled == true }
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.id.rawValue] == 1)

        // From the Mac's slider or from the phone reporting its buttons: kept and published,
        // never applied to the audio.
        try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.2))
        #expect(rig.state.speaker(Self.id)?.volume == 0.2)
        #expect(rig.settings.load().speakers["phone:remote-a#Speaker"]?.volume == 0.2)
        let gains = { rig.session.calls.filter { $0.hasPrefix("volume phone:remote-a ") } }
        #expect(gains().allSatisfy { $0 == "volume phone:remote-a 1.0" })
        // The master still reaches it like any speaker.
        try await rig.hub.perform(.setMasterVolume(volume: 0.4))
        #expect(rig.session.inner.get().master == 0.4)

        // Another output: the value kept for it is shown until the phone says where it is,
        // and the gain stays at full.
        await rig.hub.addExternalSpeaker(Self.phone("Sample Speaker", kind: .bluetooth), sink: sink, volumeOnDevice: true)
        try await rig.waitFor("route shown") { $0.speaker(Self.id)?.model == "Sample Speaker" }
        #expect(rig.state.speaker(Self.id)?.volume == 0.5)
        try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.7))
        #expect(rig.state.speaker(Self.id)?.volume == 0.7)
        #expect(gains().allSatisfy { $0 == "volume phone:remote-a 1.0" })
        #expect(rig.settings.load().speakers["phone:remote-a#Speaker"]?.volume == 0.2)
    }

    @Test func aPhoneOnAnOlderBuildKeepsItsVolumeAsAGain() async throws {
        let rig = Rig()
        await rig.start()
        let d = Self.phone()
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d))
        try await rig.waitFor { $0.speaker(Self.id)?.isEnabled == true }
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.id.rawValue] == 0.5)
        try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.2))
        #expect(rig.session.calls.contains("volume phone:remote-a 0.2"))

        // The same phone after an update: it leaves and offers itself again.
        await rig.hub.removeExternalSpeaker(id: Self.id.rawValue)
        await rig.hub.settle()
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d), volumeOnDevice: true)
        try await rig.waitFor("back on") { $0.speaker(Self.id)?.isEnabled == true }
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.id.rawValue] == 1)
        #expect(rig.state.speaker(Self.id)?.volume == 0.2)
    }

    @Test func aPhoneThatLeavesIsDroppedAndPlaybackStopsWithTheLastSpeaker() async throws {
        let rig = Rig()
        await rig.start()
        try await rig.addFiles(["one.m4a"], in: temporaryDirectory())
        let d = Self.phone()
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d))
        try await rig.waitFor { $0.speaker(Self.id)?.isEnabled == true }
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("playing") { $0.transport.isPlaying && $0.speaker(Self.id)?.state == .playing }

        await rig.hub.removeExternalSpeaker(id: Self.id.rawValue)
        try await rig.waitFor("gone") { $0.speaker(Self.id) == nil }
        await rig.hub.settle()
        #expect(rig.state.speakers.count == 3)
        #expect(!rig.state.transport.isPlaying)
        #expect(rig.session.inner.get().selected.isEmpty)
        #expect(rig.session.calls.contains("removeExternal phone:remote-a"))
        // Commands for it are refused like for any speaker that is gone.
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.setSpeakerVolume(id: Self.id, volume: 0.1)) }

        // It comes back (a reconnect): on again without anyone asking, with a fresh sink.
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d))
        try await rig.waitFor("back on") { $0.speaker(Self.id)?.isEnabled == true }
        await rig.hub.settle()
        #expect(rig.session.inner.get().selected == [Self.id.rawValue])
    }

    @Test func turnedOffOnTheMacItStaysListedAndOff() async throws {
        let rig = Rig()
        await rig.start()
        let d = Self.phone()
        await rig.hub.addExternalSpeaker(d, sink: NullSink(d))
        try await rig.waitFor { $0.speaker(Self.id)?.isEnabled == true }
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: false))
        try await rig.waitFor("off") { $0.speaker(Self.id)?.state == .off }
        await rig.hub.settle()
        #expect(rig.state.speaker(Self.id)?.isEnabled == false)
        #expect(rig.session.inner.get().selected.isEmpty)
        // A route change doesn't turn it back on.
        await rig.hub.addExternalSpeaker(Self.phone("Sample Speaker", kind: .bluetooth), sink: NullSink(d))
        await rig.hub.settle()
        #expect(rig.state.speaker(Self.id)?.isEnabled == false)
    }
}
