#if os(macOS)
import Foundation
import MulticastCalibration
import MulticastHubModel
import Testing
@testable import MulticastHub

/// Calibrates the REAL Mac: test sweeps out of this Mac's own speakers, heard by its own
/// microphone. Runs only with MULTICAST_LIVE_CALIBRATION=1, needs Microphone access for the
/// process that runs the tests, and plays quietly (speaker 0.08 under the hub's own master)
/// for a few seconds per run. No other speaker is ever turned on.
///
///     MULTICAST_LIVE_CALIBRATION=1 swift test --filter LiveCalibration
///
/// With one speaker there is nothing to line up, so the check is on the measurement itself:
/// measured three times, with the speaker's sync trim at 0, at +40 ms and at 0 again. The
/// second must come out 40 ms later than the first (the whole chain: where the sweeps sit on
/// the timeline, the sink's trim, the microphone's clock, the estimator), the third the same
/// as the first (repeatability).
@Suite("Live calibration", .enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE_CALIBRATION"] == "1"), .serialized)
struct LiveCalibrationTests {
    @Test func theMacsOwnSpeakersMeasureConsistently() async throws {
        let microphone = MacMicrophone()
        let access = await microphone.access(ask: true)
        try #require(access == .granted, "Microphone access is \(access) for the process running the tests")

        // The speaker is held to 0.08 here, far below where anyone listens, so the sweep itself is
        // sent at full level to make up some of it (still quieter than the app's sweep at a
        // speaker's usual volume).
        var configuration = LocalHub.Configuration()
        configuration.calibration.signal.amplitude = 0.9
        let hub = LocalHub.live(settings: InMemorySettingsStore(HubSettings(masterVolume: 1.0)), configuration: configuration)
        await hub.start()
        var shutDown = false
        func teardown() async {
            guard !shutDown else { return }
            shutDown = true
            await hub.shutdown()
        }
        func waitFor(_ what: String, timeout: TimeInterval, _ condition: (HubState) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition(hub.currentState) { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            await teardown()
            throw TimeoutError(what: what, state: hub.currentState)
        }

        try await waitFor("the built-in speakers", timeout: 10) { $0.speakers.contains { $0.transport == .builtIn } }
        let speaker = try #require(hub.currentState.speakers.first { $0.transport == .builtIn })
        try await hub.perform(.setSpeakerVolume(id: speaker.id, volume: 0.08))
        try await hub.perform(.setSpeakerEnabled(id: speaker.id, enabled: true))
        try await waitFor("speaker ready", timeout: 10) { $0.speaker(speaker.id)?.state == .ready }

        var readings: [(trim: Int, ms: Double, spreadMs: Double)] = []
        for trim in [0, 40, 0] {
            try await hub.perform(.setSpeakerSyncTrim(id: speaker.id, milliseconds: trim))
            try await hub.perform(.calibrateSpeakerSync(id: speaker.id))
            try await waitFor("calibration finished", timeout: 30) { $0.calibration?.isRunning == false }
            let status = try #require(hub.currentState.calibration)
            print("[live calibration] trim \(trim): \(status.speakers.map(\.outcome.caption)) \(status.problem ?? "")")
            guard case .measured(let seconds, let spread) = await hub.calibrationReadings[speaker.id.rawValue] else {
                await teardown()
                Issue.record("not measured at trim \(trim): \(String(describing: await hub.calibrationReadings))")
                return
            }
            print(String(format: "[live calibration] trim %+d ms: heard %.2f ms after due, spread %.2f ms", trim, seconds * 1000, spread * 1000))
            readings.append((trim, seconds * 1000, spread * 1000))
            // A single speaker keeps its trim.
            #expect(hub.currentState.speaker(speaker.id)?.syncTrimMs == trim)
            try await hub.perform(.cancelSyncCalibration)
        }
        await teardown()

        let step = readings[1].ms - readings[0].ms
        let repeatability = readings[2].ms - readings[0].ms
        print(String(format: "[live calibration] +40 ms of trim measured as %+.2f ms; repeat differs by %+.2f ms", step, repeatability))
        #expect(abs(step - 40) < 1.5)
        #expect(abs(repeatability) < 1.5)
        #expect(readings.allSatisfy { $0.spreadMs < 2 })
    }
}
#endif
