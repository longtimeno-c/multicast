import Foundation
import MulticastHubModel
import Testing
@testable import MulticastHub

@Suite("LocalHub Mac output")
struct MacOutputHubTests {
    @Test func refusedWhileTheDeviceIsNotInstalled() async throws {
        let rig = Rig()
        await rig.start()
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.selectSource(source: .macOutput)) }
        #expect(rig.state.activeSource != .macOutput)
        #expect(rig.sources.macOutputLatencies.get().isEmpty)
    }

    @Test func playsLiveAndReportsTheHubLatencyToTheDevice() async throws {
        let rig = Rig()
        await rig.start()
        rig.sources.macOutputInstalled.set(true)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.selectSource(source: .macOutput))
        try await rig.waitFor("mac output playing") { $0.activeSource == .macOutput && $0.transport.isPlaying }
        await rig.hub.settle()
        let s = rig.state
        #expect(s.nowPlaying?.title == "Mac output")
        #expect(!s.transport.canSeek && !s.transport.canSkip)
        #expect(rig.session.transport == .playing)
        #expect(rig.session.calls.contains("setSource Mac output"))
        // Group latency (2 s in the fake) plus the capture ring's fill target.
        #expect(rig.sources.macOutputLatencies.get() == [2 + LocalHub.macOutputCaptureDelay])
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.next) }
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.seek(position: 3)) }

        try await rig.hub.perform(.pause)
        try await rig.waitFor("paused") { !$0.transport.isPlaying }
        try await rig.hub.perform(.play)
        try await rig.waitFor("playing again") { $0.transport.isPlaying }
    }

    @Test func withoutASpeakerItIsChosenButAsksForOne() async throws {
        let rig = Rig()
        await rig.start()
        rig.sources.macOutputInstalled.set(true)
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.selectSource(source: .macOutput)) }
        #expect(rig.state.activeSource == .macOutput && !rig.state.transport.isPlaying)
    }

    @Test func liveCaptureFlags() {
        #expect(SourceKind.macOutput.isLiveCapture && SourceKind.app.isLiveCapture)
        #expect(!SourceKind.macOutput.canSkip && !SourceKind.macOutput.hasPosition)
        #expect(!SourceKind.files.isLiveCapture)
        #expect(SourceKind.macOutput.title == "Mac output")
    }
}
