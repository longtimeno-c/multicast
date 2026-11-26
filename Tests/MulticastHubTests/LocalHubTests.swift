import Foundation
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import MulticastSources
import Testing
@testable import MulticastHub

@Suite("LocalHub speakers")
struct LocalHubSpeakerTests {
    @Test func mirrorsDiscoveredSpeakersWithStableIDs() async throws {
        let rig = Rig()
        await rig.start()
        let s = rig.state
        #expect(s.speakers.map(\.id.rawValue) == ["local:BuiltInSpeakerDevice", "542a1b001122", "542a1b003344"])
        let sonos = try #require(rig.speaker(Fixtures.hallSonos))
        #expect(sonos.transport == .airPlay2 && sonos.glyph == .smartSpeaker && sonos.model == "Sonos One")
        #expect(sonos.address == "192.0.2.20:7000")
        #expect(sonos.state == .off && !sonos.isEnabled && sonos.volume == 0.5)
        #expect(s.isDiscovering)
    }

    @Test func enableConnectsThenPlaysAndFailureCanBeRetried() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.waitFor("ready") { $0.speaker("542a1b001122")?.state == .ready }
        #expect(rig.session.calls.contains("select 542a1b001122"))
        // Engine not running: nothing to play yet.
        #expect(rig.session.transport == .stopped)

        rig.session.failOnPrepare("542a1b003344", "Speaker did not become ready within 10.0 s")
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("playing") {
            $0.speaker("542a1b001122")?.state == .playing && $0.speaker("542a1b003344")?.state == .failed(reason: "Not responding")
        }
        #expect(rig.session.transport == .playing)

        try await rig.hub.perform(.retrySpeaker(id: "542a1b003344"))
        try await rig.waitFor("retried") { $0.speaker("542a1b003344")?.state == .playing }
        #expect(rig.session.calls.contains("retry 542a1b003344"))
    }

    @Test func sinkCreationFailureShowsAndRetrySelectsAgain() async throws {
        let rig = Rig()
        await rig.start()
        rig.session.inner.update { $0.selectErrors["542a1b003344"] = NSError(domain: "t", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open Hall Sonos: Hall Sonos has no resolved host/port yet"]) }
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.waitFor("failed") {
            if case .failed = $0.speaker("542a1b003344")?.state { return true } else { return false }
        }
        try await rig.hub.perform(.retrySpeaker(id: "542a1b003344"))
        try await rig.waitFor("ready") { $0.speaker("542a1b003344")?.state == .ready }
    }

    @Test func volumeAndTrimAreKeptWhileOffAndAppliedOnJoin() async throws {
        let rig = Rig()
        await rig.start()
        try await rig.hub.perform(.setSpeakerVolume(id: "542a1b001122", volume: 0.12))
        try await rig.hub.perform(.setSpeakerSyncTrim(id: "542a1b001122", milliseconds: 900))
        let off = try #require(rig.speaker(Fixtures.mainBedroom))
        #expect(off.state == .off && off.volume == 0.12 && off.syncTrimMs == 500)  // trim clamped to the range
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        await rig.hub.settle()
        let i = rig.session.inner.get()
        #expect(i.selectVolumes["542a1b001122"] == 0.12)
        #expect(i.selectOffsets["542a1b001122"] == 500)
        // While on, changes go straight to the session.
        try await rig.hub.perform(.setSpeakerVolume(id: "542a1b001122", volume: 1.7))
        #expect(rig.session.calls.contains("volume 542a1b001122 1.0"))
        #expect(rig.speaker(Fixtures.mainBedroom)?.volume == 1)
        await #expect(throws: HubCommandError.self) {
            try await rig.hub.perform(.setSpeakerVolume(id: "nope", volume: 0.1))
        }
    }

    @Test func settingsPersistAcrossLaunches() async throws {
        let store = InMemorySettingsStore()
        do {
            let rig = Rig(settings: store)
            await rig.start()
            try await rig.hub.perform(.setSpeakerVolume(id: "542a1b003344", volume: 0.25))
            try await rig.hub.perform(.setSpeakerSyncTrim(id: "542a1b003344", milliseconds: -40))
            try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
            try await rig.hub.perform(.setMasterVolume(volume: 0.4))
            await rig.hub.settle()
            await rig.hub.shutdown()
        }
        let saved = store.load()
        #expect(saved.masterVolume == 0.4)
        #expect(saved.speakers["542a1b003344"] == .init(volume: 0.25, syncTrimMs: -40, isEnabled: true))

        // Next launch: the speaker is not on the network at first; once found it is enabled again.
        let rig = Rig(settings: store, speakers: [Fixtures.local()])
        await rig.start()
        #expect(rig.state.masterVolume == 0.4)
        #expect(rig.session.inner.get().master == 0.4)
        rig.session.setSpeakers([Fixtures.local(), Fixtures.hallSonos])
        try await rig.waitFor("restored") { $0.speaker("542a1b003344")?.state == .ready }
        let s = try #require(rig.speaker(Fixtures.hallSonos))
        #expect(s.isEnabled && s.volume == 0.25 && s.syncTrimMs == -40)
        #expect(rig.session.inner.get().selectVolumes["542a1b003344"] == 0.25)

        // Turning it off is remembered too.
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: false))
        #expect(store.load().speakers["542a1b003344"]?.isEnabled == false)
    }

    @Test func twoAdvertisementsOfOneReceiverAreRefusedTogether() async throws {
        let rig = Rig(speakers: [Fixtures.denonBridge, Fixtures.denonNative])
        await rig.start()
        try await rig.hub.perform(.setSpeakerEnabled(id: "bbbb0a0b0c0d", enabled: true))
        try await rig.hub.perform(.setSpeakerEnabled(id: "000a0b0c0d0e", enabled: true))
        await rig.hub.settle()
        let native = try #require(rig.speaker(Fixtures.denonNative))
        guard case .failed(let reason) = native.state else {
            Issue.record("expected failed, got \(native.state)")
            return
        }
        #expect(reason.contains("Same receiver as \u{201C}Lounge Receiver+\u{201D}"))
        #expect(rig.session.inner.get().selected == ["bbbb0a0b0c0d"])
        // Still refused on retry while the other is on; accepted once it is off.
        try await rig.hub.perform(.retrySpeaker(id: "000a0b0c0d0e"))
        await rig.hub.settle()
        #expect(rig.session.inner.get().selected == ["bbbb0a0b0c0d"])
        try await rig.hub.perform(.setSpeakerEnabled(id: "bbbb0a0b0c0d", enabled: false))
        try await rig.hub.perform(.retrySpeaker(id: "000a0b0c0d0e"))
        try await rig.waitFor("native on") { $0.speaker("000a0b0c0d0e")?.state == .ready }
        #expect(rig.session.inner.get().selected == ["000a0b0c0d0e"])
        // A refused speaker is not remembered as enabled.
        #expect(rig.settings.load().speakers["000a0b0c0d0e"]?.isEnabled == true)
        #expect(rig.settings.load().speakers["bbbb0a0b0c0d"]?.isEnabled == false)
    }

    @Test func revisionsOnlyGrowAndNoOpsPublishNothing() async throws {
        let rig = Rig()
        await rig.start()
        let collected = Locked<[UInt64]>([])
        let stream = await rig.hub.states()
        let reader = Task { for await s in stream { collected.update { $0.append(s.revision) } } }
        let before = rig.state.revision
        try await rig.hub.perform(.setMasterVolume(volume: 0.6))  // the default: no change
        await rig.hub.settle()
        #expect(rig.state.revision == before)
        for v in stride(from: 0.1, through: 0.5, by: 0.1) {
            try await rig.hub.perform(.setSpeakerVolume(id: "542a1b001122", volume: v))
        }
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.waitFor("ready") { $0.speaker("542a1b001122")?.state == .ready }
        try await Task.sleep(nanoseconds: 50_000_000)
        reader.cancel()
        let revs = collected.get()
        #expect(revs.count >= 2)
        #expect(zip(revs, revs.dropFirst()).allSatisfy { $0 < $1 })
        // A late subscriber gets the current state at once.
        var it = await rig.hub.states().makeAsyncIterator()
        let first = await it.next()
        #expect(first?.revision == rig.state.revision)
    }
}

@Suite("LocalHub engine policy and files")
struct LocalHubPlaybackTests {
    @Test func playNeedsASpeakerAndTheLastSpeakerOffStopsTheEngine() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a"], in: dir)
        try await rig.hub.perform(.selectSource(source: .files))
        await #expect(throws: HubCommandError(.unavailable, LocalHub.needsSpeaker)) {
            try await rig.hub.perform(.play)
        }
        #expect(rig.session.transport == .stopped)

        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.play)
        try await rig.waitFor("playing") { $0.transport.isPlaying && $0.speaker("542a1b001122")?.state == .playing }
        #expect(rig.session.transport == .playing)

        // Add and remove mid-stream.
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.waitFor("joined") { $0.speaker("542a1b003344")?.state == .playing }
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: false))
        try await rig.waitFor("left") { $0.speaker("542a1b001122")?.state == .off }
        #expect(rig.session.transport == .playing)

        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: false))
        try await rig.waitFor("stopped") { !$0.transport.isPlaying }
        await rig.hub.settle()
        #expect(rig.session.transport == .stopped)
    }

    @Test func filesAdvanceOnEndOfStreamAndStopAfterTheLast() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a"], durations: [30, 40], in: dir)
        #expect(rig.state.content.files == 1)
        let page = try await rig.hub.files(.first)
        #expect(page.items.map(\.title) == ["one", "two"])

        try await rig.hub.perform(.setSpeakerEnabled(id: "local:BuiltInSpeakerDevice", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("one playing") { $0.nowPlaying?.trackID == "file-1" && $0.transport.isPlaying }
        #expect(rig.state.activeSource == .files)
        #expect(rig.state.transport.canSeek && rig.state.transport.canSkip)
        #expect(rig.state.nowPlaying?.duration == 30)

        rig.session.markEnded()
        rig.session.endOfStream()
        try await rig.waitFor("two") { $0.nowPlaying?.trackID == "file-2" }
        await rig.hub.settle()
        #expect(rig.sources.opened.get().map(\.url.lastPathComponent) == ["one.m4a", "two.m4a"])
        #expect((rig.session.currentSource as? FakeFileSource)?.url.lastPathComponent == "two.m4a")
        #expect(rig.session.transport == .playing)

        rig.session.markEnded()
        rig.session.endOfStream()
        try await rig.waitFor("rewound") { !$0.transport.isPlaying && $0.nowPlaying?.trackID == "file-1" }
        await rig.hub.settle()
        #expect(rig.session.transport == .stopped)
        #expect(rig.state.transport.position == 0)

        // Play again: the first file is reopened.
        try await rig.hub.perform(.play)
        try await rig.waitFor("again") { $0.transport.isPlaying }
        await rig.hub.settle()
        #expect(rig.sources.opened.get().count == 3)
        #expect(rig.session.transport == .playing)
    }

    @Test func seekNextPreviousAndPositionAreTruthful() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a"], durations: [30, 40], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("playing") { $0.transport.isPlaying }

        // Heard one group latency (2 s) after the engine starts.
        let t0 = rig.state.transport
        #expect(t0.position == 0)
        #expect(t0.positionAsOf == rig.clock.now.addingTimeInterval(2))

        try await rig.hub.perform(.seek(position: 99))
        await rig.hub.settle()
        #expect(rig.session.inner.get().seeks.last == 30)  // clamped to the file
        try await rig.hub.perform(.seek(position: 12))
        await rig.hub.settle()
        #expect(rig.session.inner.get().seeks.last == 12)
        #expect(rig.state.transport.position == 12)

        rig.clock.advance(10)  // 8 s heard since the seek
        // previous after > 3 s restarts the track
        try await rig.hub.perform(.previous)
        await rig.hub.settle()
        #expect(rig.session.inner.get().seeks.last == 0)
        #expect(rig.state.nowPlaying?.trackID == "file-1")

        try await rig.hub.perform(.next)
        try await rig.waitFor("two") { $0.nowPlaying?.trackID == "file-2" }
        try await rig.hub.perform(.previous)  // at 0 s: goes back a track
        try await rig.waitFor("one") { $0.nowPlaying?.trackID == "file-1" }

        // Pause freezes the position where it was heard.
        rig.clock.advance(5)  // 2 s latency + 3 s heard
        try await rig.hub.perform(.pause)
        await rig.hub.settle()
        let paused = rig.state.transport
        #expect(!paused.isPlaying)
        #expect(abs(paused.position - 3) < 0.001)
        #expect(rig.session.transport == .paused)

        // Seeking while paused sets a fresh source at the target, so the audio the engine kept
        // for the resume is dropped instead of being heard first.
        let opened = rig.sources.opened.get().count
        try await rig.hub.perform(.seek(position: 7))
        await rig.hub.settle()
        let fresh = try #require(rig.sources.opened.get().last)
        #expect(rig.sources.opened.get().count == opened + 1)
        #expect(fresh.seeks.get() == [7])
        #expect(rig.session.currentSource === fresh)
        #expect(rig.state.transport.position == 7 && !rig.state.transport.isPlaying)
    }

    @Test func removingFilesUpdatesTheQueue() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a", "three.m4a"], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-2", context: .files))
        try await rig.waitFor("two") { $0.nowPlaying?.trackID == "file-2" }
        try await rig.hub.perform(.removeFiles(ids: ["file-2"]))
        try await rig.waitFor("three") { $0.nowPlaying?.trackID == "file-3" && $0.transport.isPlaying }
        #expect(try await rig.hub.files(.first).items.map(\.id) == ["file-1", "file-3"])
        try await rig.hub.perform(.removeFiles(ids: ["file-1", "file-3"]))
        try await rig.waitFor("empty") { $0.activeSource == nil && !$0.transport.isPlaying }
        await rig.hub.settle()
        #expect(rig.session.transport == .stopped)
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.selectSource(source: .files)) }
    }

    @Test func levelsFollowMetersScaledByMaster() async throws {
        let rig = Rig()
        await rig.start()
        try await rig.hub.perform(.setMasterVolume(volume: 0.5))
        let stream = await rig.hub.levels()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == .silent)
        rig.session.meters.send(MeterReading(peakLeft: 0.8, peakRight: 0.4, rmsLeft: 0, rmsRight: 0, frame: 0, audibleFrame: 0))
        #expect(await it.next() == StereoLevels(left: 0.4, right: 0.2))
    }

    @Test func nowPlayingReachesNetworkSpeakerDisplays() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], durations: [30], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.setSpeakerEnabled(id: "local:BuiltInSpeakerDevice", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("playing") { $0.speaker("542a1b001122")?.state == .playing }
        await rig.hub.settle()
        let i = rig.session.inner.get()
        #expect(i.metadata.map(\.0) == ["542a1b001122"])  // network speakers only
        #expect(i.metadata.first?.1.title == "one" && i.metadata.first?.1.artist == "Tester")
        #expect(i.progress.first?.0 == "542a1b001122" && i.progress.first?.2 == 30)
    }
}

@Suite("LocalHub sources and health")
struct LocalHubSourceTests {
    private let spotifyID = LocalHub.spotifyBundleID

    @Test func spotifyStatusSwitchingTransportAndHistory() async throws {
        let rig = Rig()
        await rig.start()
        #expect(rig.state.spotify == .notInstalled)
        #expect(rig.state.health.issues.contains(.sourceAppNotInstalled(source: .spotify, bundleID: spotifyID, name: "Spotify")))
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.selectSource(source: .spotify)) }

        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        await rig.hub.tick()
        #expect(rig.state.spotify == .notRunning)
        try await rig.hub.perform(.openSpotify)
        try await rig.waitFor("running") { $0.spotify == .running }
        #expect(rig.apps.launched.get() == [spotifyID])

        // Files playing, then switch to Spotify: Spotify's own state decides.
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("files") { $0.transport.isPlaying }
        try await rig.hub.perform(.selectSource(source: .spotify))
        await rig.hub.settle()
        #expect(rig.sources.captures.get().map(\.bundleID) == [spotifyID])
        #expect(rig.session.currentSource is FakeCaptureSource)
        let sampled = rig.clock.now
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Song A", artist: "Band", album: "LP",
                                           duration: 180, position: 10, trackID: "spotify:track:a",
                                           artworkURL: URL(string: "https://img.example/a.jpg"), sampledAt: sampled))
        try await rig.waitFor("spotify playing") { $0.nowPlaying?.title == "Song A" && $0.transport.isPlaying }
        await rig.hub.settle()
        let t = rig.state.transport
        #expect(t.canSeek && t.canSkip)
        #expect(t.position == 10 && t.positionAsOf == sampled.addingTimeInterval(2))  // heard after the latency
        #expect(rig.state.nowPlaying?.artworkID == "hub.url:https://img.example/a.jpg")
        #expect(rig.session.transport == .playing)
        // Seeking goes to Spotify and flushes the speakers.
        try await rig.hub.perform(.seek(position: 170))
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().last == "seek 170")

        // Transport goes to Spotify; skip flushes and re-anchors the speakers.
        let before = rig.session.calls.filter { $0 == "pause" }.count
        try await rig.hub.perform(.next)
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().last == "next")
        #expect(rig.session.calls.filter { $0 == "pause" }.count == before + 1)
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Song B", artist: "Band",
                                           trackID: "spotify:track:b", sampledAt: rig.clock.now))
        try await rig.waitFor("history") { $0.nowPlaying?.trackID == "spotify:track:b" && $0.content.spotifyHistory >= 2 }
        // The current song first, then the earlier ones.
        #expect(try await rig.hub.spotifyHistory(.first).items.map(\.id) == ["spotify:track:b", "spotify:track:a"])

        try await rig.hub.perform(.pause)
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().last == "pause")

        // Spotify paused by the user in Spotify: the engine pauses too.
        try await rig.hub.perform(.play)
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .paused, title: "Song B", artist: "Band",
                                           trackID: "spotify:track:b", sampledAt: rig.clock.now))
        try await rig.waitFor("paused") { !$0.transport.isPlaying }
        await rig.hub.settle()
        #expect(rig.session.transport == .paused)

        // Spotify quits.
        rig.apps.setRunning(spotifyID, false)
        try await rig.waitFor("not running") { $0.spotify == .notRunning }
        #expect(rig.state.health.issues(for: .spotify).contains(.sourceAppNotRunning(source: .spotify, bundleID: spotifyID, name: "Spotify")))
    }

    @Test func leavingAPlayingSpotifyPausesIt() async throws {
        let rig = Rig()
        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        rig.apps.running.update { _ = $0.insert(spotifyID) }
        await rig.start()
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.selectSource(source: .spotify))
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Song A", trackID: "a", sampledAt: rig.clock.now))
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.selectSource(source: .files))
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().contains("pause"))
        #expect(rig.state.activeSource == .files)
        #expect(rig.state.transport.isPlaying)  // the play intent carries over
        #expect(rig.session.currentSource is FakeFileSource)
    }

    @Test func automationDenialIsAHealthFlag() async throws {
        let rig = Rig()
        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        rig.apps.running.update { _ = $0.insert(spotifyID) }
        rig.spotify.automation.set(.notDetermined)
        await rig.start()
        await rig.hub.tick()
        #expect(rig.state.health.permission(.automation) == .notDetermined)
        #expect(rig.spotify.askCount.get() == 0)  // never prompts on its own

        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.selectSource(source: .spotify))
        rig.spotify.failWith.set(HubCommandError(.permissionMissing, "Allow it"))
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.play) }
        #expect(rig.state.health.permission(.automation) == .denied)
        #expect(rig.state.health.issues(for: .spotify).contains(.permissionMissing(permission: .automation, status: .denied)))
        // Asking again when denied opens System Settings instead.
        try await rig.hub.perform(.requestPermission(permission: .automation))
        #expect(rig.system.opened.get() == [.automation])
    }

    @Test func otherAppCaptureAndCapturePermission() async throws {
        let rig = Rig()
        await rig.start()
        rig.capturable.set([CapturableApp(id: "com.example.player", name: "Example Player", isMakingSound: true,
                                          iconArtworkID: "hub.icon:com.example.player")])
        rig.apps.running.update { _ = $0.insert("com.example.player") }
        try await rig.waitFor("apps") { $0.capture.apps.count == 1 }
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.captureApp(bundleID: "com.example.none")) }

        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.captureApp(bundleID: "com.example.player"))
        try await rig.waitFor("capturing") { $0.activeSource == .app && $0.transport.isPlaying }
        await rig.hub.settle()
        let s = rig.state
        #expect(s.capture.capturedAppID == "com.example.player")
        #expect(s.nowPlaying?.title == "Example Player" && s.nowPlaying?.artworkIsIcon == true)
        #expect(s.nowPlaying?.duration == nil)
        #expect(!s.transport.canSeek && !s.transport.canSkip)
        #expect(rig.session.transport == .playing)
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.seek(position: 1)) }
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.next) }
        #expect(await rig.hub.artwork(id: "hub.icon:com.example.player", maxPixel: 64) == Data("icon:com.example.player".utf8))

        // The tap reports silence-by-TCC: System Audio Recording is flagged.
        rig.sources.captures.get()[0].evidence.send(.denied)
        try await rig.waitFor("capture denied") { $0.health.permission(.audioCapture) == .denied }
        #expect(rig.state.health.issues(for: .app).contains(.permissionMissing(permission: .audioCapture, status: .denied)))
        try await rig.hub.perform(.requestPermission(permission: .audioCapture))
        #expect(rig.system.opened.get() == [.audioCapture])

        // The app quits.
        rig.apps.setRunning("com.example.player", false)
        try await rig.waitFor("app gone") {
            $0.health.issues.contains(.sourceAppNotRunning(source: .app, bundleID: "com.example.player", name: "Example Player"))
        }
    }

    @Test func localNetworkDenialFromDiscoveryError() async throws {
        let rig = Rig(speakers: [Fixtures.local()])
        await rig.start()
        #expect(rig.state.health.permission(.localNetwork) == .notDetermined)
        rig.session.setDiscoveryError(-65570)
        try await rig.waitFor("denied") { $0.health.permission(.localNetwork) == .denied }
        let rig2 = Rig()
        await rig2.start()
        try await rig2.waitFor("granted") { $0.health.permission(.localNetwork) == .granted }
    }

    @Test func appleMusicIsUnavailableUntilAPlayerIsInjected() async throws {
        let rig = Rig()
        await rig.start()
        await #expect(throws: HubCommandError(.unavailable, LocalHub.appleMusicUnavailable)) {
            try await rig.hub.perform(.selectSource(source: .appleMusic))
        }
        await #expect(throws: HubCommandError(.unavailable, LocalHub.appleMusicUnavailable)) {
            _ = try await rig.hub.songs(.first)
        }
        await #expect(throws: HubCommandError(.unavailable, LocalHub.appleMusicUnavailable)) {
            try await rig.hub.perform(.requestPermission(permission: .appleMusic))
        }

        let player = FakeMusicPlayer()
        await rig.hub.setMusicPlayer(player)
        #expect(rig.state.health.permission(.appleMusic) == .granted)
        #expect(try await rig.hub.songs(.first).items.map(\.id) == ["s1"])
        #expect(try await rig.hub.answer(.songs(page: .first)).tracks?.items.count == 1)
        #expect(await rig.hub.artwork(id: "lib-art-1", maxPixel: 100) == Data("art:lib-art-1".utf8))

        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.playTrack(id: "s1", context: .songs))
        #expect(player.commands.get() == ["once s1"])
        player.publish {
            $0.isPlaying = true
            $0.nowPlaying = NowPlayingInfo(title: "Tide", artist: "Harbour", duration: 200, trackID: "s1")
            $0.position = 4
            $0.positionAsOf = rig.clock.now
            $0.libraryRevision = 1
        }
        try await rig.waitFor("music playing") { $0.activeSource == .appleMusic && $0.transport.isPlaying }
        await rig.hub.settle()
        #expect(rig.session.transport == .playing)
        #expect(rig.state.nowPlaying?.trackID == "s1")
        let lib = rig.state.content.library
        player.publish { $0.libraryRevision = 2 }
        try await rig.waitFor("library bumped") { $0.content.library == lib + 1 }
        try await rig.hub.perform(.seek(position: 30))
        #expect(player.commands.get().last == "seek 30")
    }
}

@Suite("LocalHub review fixes")
struct LocalHubReviewFixTests {
    private let spotifyID = LocalHub.spotifyBundleID

    @Test func aFileThatCantBeOpenedLeavesTheTransportStoppedAndPlayCanBeRetried() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a"], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("playing") { $0.transport.isPlaying }

        // The queue plays to its end (rewound, stopped), then the file goes away.
        rig.session.markEnded()
        rig.session.endOfStream()
        try await rig.waitFor("ended") { !$0.transport.isPlaying }
        rig.sources.unopenable.update { _ = $0.insert("one.m4a") }

        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.play) }
        await rig.hub.settle()
        #expect(!rig.state.transport.isPlaying)
        #expect(rig.session.transport != .playing)
        // Not stuck: each Play tries again, and works once the file is back.
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.play) }
        rig.sources.unopenable.set([])
        try await rig.hub.perform(.play)
        try await rig.waitFor("playing again") { $0.transport.isPlaying }
    }

    @Test func choosingAFileThatCantBeOpenedDoesNotClaimToPlayIt() async throws {
        let rig = Rig()
        await rig.start()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a"], in: dir)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        rig.sources.unopenable.update { _ = $0.insert("two.m4a") }
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.playTrack(id: "file-2", context: .files)) }
        await rig.hub.settle()
        #expect(!rig.state.transport.isPlaying)
        #expect(rig.session.transport != .playing)
    }

    @Test func askingForAppleMusicAccessAnswersAtOnceAndReportsLater() async throws {
        let rig = Rig()
        await rig.start()
        let player = FakeMusicPlayer()
        player.auth.set(.notDetermined)
        player.holdsRequests.set(true)
        await rig.hub.setMusicPlayer(player)

        // Nobody is at the Mac to answer the prompt: the command still returns at once.
        let started = Date()
        try await rig.hub.perform(.requestPermission(permission: .appleMusic))
        #expect(Date().timeIntervalSince(started) < 0.5)
        try await rig.hub.perform(.setMasterVolume(volume: 0.3))   // the next command isn't stuck behind it
        #expect(rig.state.masterVolume == 0.3)
        #expect(rig.state.health.permission(.appleMusic) == .notDetermined)

        let deadline = Date().addingTimeInterval(2)
        while player.pendingRequest.get() == nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let library = rig.state.content.library
        player.auth.set(.granted)
        player.answerRequest()
        try await rig.waitFor("answered") { $0.health.permission(.appleMusic) == .granted && $0.content.library > library }
    }

    @Test func appleMusicClosedSinceLaunchIsLookedUpBeforeRefusing() async throws {
        let rig = Rig()
        await rig.start()
        let player = FakeMusicPlayer()
        player.auth.set(.notDetermined)      // Music closed: its status can't be read
        player.refreshed.set(.granted)       // opened hidden: allowed long ago
        await rig.hub.setMusicPlayer(player)
        #expect(rig.state.health.permission(.appleMusic) == .notDetermined)
        try await rig.hub.perform(.selectSource(source: .appleMusic))
        #expect(rig.state.activeSource == .appleMusic)
        #expect(rig.state.health.permission(.appleMusic) == .granted)

        let denied = Rig()
        await denied.start()
        let player2 = FakeMusicPlayer()
        player2.auth.set(.notDetermined)
        player2.refreshed.set(.notDetermined)
        await denied.hub.setMusicPlayer(player2)
        await #expect(throws: HubCommandError.self) { try await denied.hub.perform(.selectSource(source: .appleMusic)) }
    }

    @Test func quittingWhileSpotifyPlaysPausesSpotify() async throws {
        let rig = Rig()
        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        rig.apps.running.update { _ = $0.insert(spotifyID) }
        await rig.start()
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.selectSource(source: .spotify))
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Song A", trackID: "a", sampledAt: rig.clock.now))
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        #expect(!rig.spotify.commands.get().contains("pause"))
        await rig.hub.shutdown()
        #expect(rig.spotify.commands.get().last == "pause")
        #expect(rig.session.calls.last == "shutdown")
    }

    @Test func quittingWithNothingPlayingSendsNoMediaCommands() async throws {
        let rig = Rig()
        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        rig.apps.running.update { _ = $0.insert(spotifyID) }
        await rig.start()
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.selectSource(source: .spotify))
        await rig.hub.shutdown()
        #expect(rig.spotify.commands.get().isEmpty)
    }

    @Test func artworkURLsAreFetchedOnlyWhenTheHubMintedThem() async throws {
        let rig = Rig()
        rig.apps.installed.update { _ = $0.insert(spotifyID) }
        rig.apps.running.update { _ = $0.insert(spotifyID) }
        await rig.start()
        let mine = URL(string: "https://img.example/a.jpg")!
        let other = URL(string: "https://192.0.2.1/admin")!
        rig.system.images.set([mine: Data("cover".utf8), other: Data("secret".utf8)])

        // A remote naming any https address gets nothing, and nothing is fetched for it.
        #expect(await rig.hub.artwork(id: "hub.url:\(other.absoluteString)", maxPixel: 0) == nil)
        #expect(await rig.hub.artwork(id: "hub.url:\(mine.absoluteString)", maxPixel: 0) == nil)

        try await rig.hub.perform(.selectSource(source: .spotify))
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Song A", trackID: "a",
                                           artworkURL: mine, sampledAt: rig.clock.now))
        try await rig.waitFor("now playing") { $0.nowPlaying?.artworkID == "hub.url:\(mine.absoluteString)" }
        #expect(await rig.hub.artwork(id: "hub.url:\(mine.absoluteString)", maxPixel: 0) == Data("cover".utf8))
        #expect(await rig.hub.artwork(id: "hub.url:\(other.absoluteString)", maxPixel: 0) == nil)
    }

    @Test func onlyAppsTheCapturableListOffersCanBeCaptured() async throws {
        let rig = Rig()
        await rig.start()
        rig.capturable.set([CapturableApp(id: "com.example.player", name: "Example Player", isMakingSound: true,
                                          iconArtworkID: "hub.icon:com.example.player")])
        // Running, but not offered (a call app, or this process itself): refused, nothing tapped.
        rig.apps.running.update { $0.formUnion(["com.example.player", "com.example.calls"]) }
        try await rig.waitFor("apps") { $0.capture.apps.count == 1 }
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b001122", enabled: true))
        await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.captureApp(bundleID: "com.example.calls")) }
        if let me = Bundle.main.bundleIdentifier {
            rig.apps.running.update { _ = $0.insert(me) }
            await #expect(throws: HubCommandError.self) { try await rig.hub.perform(.captureApp(bundleID: me)) }
        }
        #expect(rig.sources.captures.get().isEmpty)
        try await rig.hub.perform(.captureApp(bundleID: "com.example.player"))
        #expect(rig.sources.captures.get().map(\.bundleID) == ["com.example.player"])
    }
}
