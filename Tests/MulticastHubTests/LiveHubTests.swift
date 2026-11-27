#if os(macOS)
import Foundation
import MulticastAudio
import MulticastHubModel
import MulticastKit
import Testing
@testable import MulticastHub

/// Plays through the REAL hub to real speakers. Runs only with MULTICAST_LIVE=1 and the speakers
/// named in MULTICAST_LIVE_TO (comma separated: names, unique prefixes or ids, as
/// `multicast-cli list` shows them). No speaker names live in this file.
///
///     MULTICAST_LIVE=1 MULTICAST_LIVE_TO="Desk Speakers,Main,Hall Sonos" swift test --filter LiveHub
///
/// The first two speakers are on from the start; the last joins mid-stream and the first then
/// leaves mid-stream. Every speaker plays at 0.10 (master 1.0), set before any audio, for about
/// 6 s of audible audio, then everything is torn down. Pass/fail is judged from HubState and
/// the RAOP packet counters, not by ear.
///
/// The hub is made without device volumes, so a Mac output among the speakers is turned down
/// inside Multicast like the others and the Mac's own output volume is neither read nor
/// changed: the 0.10 is on top of wherever the Mac's volume is.
@Suite("Live hub", .enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE"] == "1"), .serialized)
struct LiveHubTests {
    static let speakerVolume = 0.10
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    @Test func filesToRealSpeakersWithAMidStreamToggle() async throws {
        let queries = (ProcessInfo.processInfo.environment["MULTICAST_LIVE_TO"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try #require(queries.count >= 2, "MULTICAST_LIVE_TO needs at least two speakers")
        try #require(FileManager.default.isExecutableFile(atPath: Self.ffmpeg), "ffmpeg not found")
        #expect(Self.speakerVolume <= 0.12)

        // A quiet 12 s, 440 Hz tone file in a temp dir (never in the repo).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("multicast-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("live-tone.m4a")
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        ff.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=12",
                        "-af", "volume=0.5", "-metadata", "title=Multicast live check", "-metadata", "artist=Multicast",
                        "-c:a", "aac", "-b:a", "128k", file.path]
        try ff.run()
        ff.waitUntilExit()
        try #require(ff.terminationStatus == 0)

        let hub = LocalHub.live(settings: InMemorySettingsStore(HubSettings(masterVolume: 1.0)),
                                deviceVolumes: NoDeviceVolumes())
        let started = Date()
        func log(_ s: String) { print(String(format: "[live %5.2f] ", Date().timeIntervalSince(started)) + s) }
        var shutDown = false
        func teardown() async {
            guard !shutDown else { return }
            shutDown = true
            await hub.shutdown()
            log("hub shut down")
        }

        do {
            await hub.start()
            // Find the speakers.
            var ids: [SpeakerID] = []
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let list = hub.currentState.speakers
                let descriptors = list.map { SpeakerDescriptor(id: $0.id.rawValue, name: $0.name, transport: .local) }
                let found: [SpeakerID] = queries.compactMap {
                    if case .found(let d) = SpeakerMatching.resolve($0, in: descriptors) { return SpeakerID(d.id) }
                    return nil
                }
                if found.count == queries.count { ids = found; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try #require(ids.count == queries.count, "not all speakers were found")
            try #require(Set(ids).count == ids.count, "two queries matched the same speaker")
            log("speakers: " + ids.map { id in hub.currentState.speaker(id).map { "\($0.name) [\($0.transport.label)]" } ?? "?" }
                .joined(separator: ", "))

            // Volumes before anything is enabled.
            for id in ids { try await hub.perform(.setSpeakerVolume(id: id, volume: Self.speakerVolume)) }
            try await hub.perform(.setMasterVolume(volume: 1.0))
            for id in ids {
                let s = try #require(hub.currentState.speaker(id))
                #expect(s.effectiveVolume(master: hub.currentState.masterVolume) <= 0.12)
            }

            try await hub.perform(.addFiles(urls: [file]))
            let track = try #require(try await hub.files(.first).items.first)
            log("file: \(track.title) \(String(format: "%.1f", track.duration)) s \(track.format ?? "")")

            let initial = Array(ids.prefix(ids.count - 1))
            let joiner = ids.last!
            let leaver = ids.first!
            for id in initial { try await hub.perform(.setSpeakerEnabled(id: id, enabled: true)) }
            try await hub.perform(.playTrack(id: track.id, context: .files))
            let playAt = Date()
            log("play")

            var reachedPlaying = Set<SpeakerID>()
            var lastLine = ""
            func observe() {
                let s = hub.currentState
                for sp in s.speakers where sp.state == .playing { reachedPlaying.insert(sp.id) }
                let line = ids.compactMap { s.speaker($0) }.map { "\($0.name)=\(describe($0.state))" }.joined(separator: " ")
                    + " playing=\(s.transport.isPlaying)"
                if line != lastLine { log(line); lastLine = line }
            }
            func run(until seconds: TimeInterval) async throws {
                while Date().timeIntervalSince(playAt) < seconds {
                    observe()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            // Audio is heard from about +2 s (group latency). Join at +3.5 s, leave at +6 s, stop at +8 s.
            try await run(until: 3.5)
            try await hub.perform(.setSpeakerEnabled(id: joiner, enabled: true))
            log("enabled the joiner")
            try await run(until: 6)
            try await hub.perform(.setSpeakerEnabled(id: leaver, enabled: false))
            log("disabled the leaver")
            try await run(until: 8)
            observe()
            let atEnd = hub.currentState
            #expect(atEnd.speaker(leaver)?.state == .off)
            #expect(atEnd.transport.isPlaying, "still playing to the others after one left")

            if let kit = hub.deps.session as? KitSession {
                for d in kit.session.diagnostics() {
                    log("diag \(d.name): kind=\(d.kind.rawValue) packets=\(d.packetsSent.map(String.init) ?? "-") "
                        + "resends=\(d.resendRequests.map(String.init) ?? "-") timing=\(d.timingRequestsAnswered.map(String.init) ?? "-") "
                        + "callbacks=\(d.renderCallbacks.map(String.init) ?? "-") syncErr=\(d.syncErrorMillis.map { String(format: "%.2f ms", $0) } ?? "-")")
                    if d.kind == .raop { #expect((d.packetsSent ?? 0) > 100, "\(d.name) sent RTP packets") }
                    if d.kind == .local { #expect((d.renderCallbacks ?? 0) > 50, "\(d.name) rendered") }
                }
            }

            try await hub.perform(.pause)
            await hub.settle()
            log("paused")
            for id in ids { #expect(reachedPlaying.contains(id), "\(id) reached playing") }
            await teardown()
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    private func describe(_ s: SpeakerState) -> String {
        switch s {
        case .off: return "off"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .playing: return "playing"
        case .failed(let r): return "failed(\(r))"
        }
    }
}
#endif
