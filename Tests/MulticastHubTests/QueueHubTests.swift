import Foundation
import MulticastHubModel
import MulticastSources
import Testing
@testable import MulticastHub

/// The hub's play queue driving the Music app, Spotify and files (all fakes).
@Suite("LocalHub play queue")
struct QueueHubTests {
    static func t(_ id: String, _ d: TimeInterval = 200) -> TrackItem {
        TrackItem(id: id, title: "Song \(id)", artist: "Band", album: "LP", duration: d)
    }
    static let playlist = ["a1", "a2", "a3", "a4"].map { t($0) }
    static let spotifyURI = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"

    private func rig() async throws -> (Rig, FakeMusicPlayer) {
        let rig = Rig()
        await rig.start()
        let player = FakeMusicPlayer()
        player.playlistTracks.set(["p1": Self.playlist])
        player.playlistList.set([PlaylistItem(id: "p1", name: "Garden", trackCount: 4, artworkID: "art-p1")])
        await rig.hub.setMusicPlayer(player)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        return (rig, player)
    }

    private func musicPlays(_ player: FakeMusicPlayer, _ rig: Rig, _ id: String, at position: TimeInterval = 0, playing: Bool = true) {
        player.publish {
            $0.isPlaying = playing
            $0.nowPlaying = NowPlayingInfo(title: "Song \(id)", artist: "Band", duration: 200, trackID: id)
            $0.position = position
            $0.positionAsOf = rig.clock.now
        }
    }

    private func musicStops(_ player: FakeMusicPlayer) {
        player.publish { $0.isPlaying = false; $0.nowPlaying = nil; $0.position = 0 }
    }

    private func upNextIDs(_ rig: Rig) async throws -> [String] {
        try await rig.hub.upNext(.first).items.map(\.track.id)
    }

    @Test func playingASongInAPlaylistQueuesTheRest() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playTrack(id: "a2", context: .playlist(id: "p1")))
        await rig.hub.settle()
        #expect(player.commands.get() == ["once a2"])
        #expect(try await upNextIDs(rig) == ["a3", "a4"])
        #expect(rig.state.queue.currentSource == .appleMusic && rig.state.queue.upcomingCount == 2)
        #expect(try await rig.hub.answer(.upNext(page: .first)).queue?.items.count == 2)
    }

    @Test func shuffledPlaylistQueuesEverySong() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playPlaylist(id: "p1", shuffled: true))
        await rig.hub.settle()
        let first = try #require(player.commands.get().first?.replacingOccurrences(of: "once ", with: ""))
        #expect(Set([first] + (try await upNextIDs(rig))) == Set(Self.playlist.map(\.id)))
    }

    @Test func advancesWhenMusicStopsAfterTheSong() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playTrack(id: "a3", context: .playlist(id: "p1")))
        await rig.hub.settle()
        rig.clock.advance(5)
        musicPlays(player, rig, "a3", at: 190)
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        await rig.hub.settle()
        let pauses = rig.session.calls.filter { $0 == "pause" || $0 == "stop" }.count
        rig.clock.advance(10)
        musicStops(player)
        try await rig.waitFor("advanced") { _ in player.commands.get().last == "once a4" }
        musicPlays(player, rig, "a4")
        try await rig.waitFor("next playing") { $0.transport.isPlaying && $0.nowPlaying?.trackID == "a4" }
        #expect(try await upNextIDs(rig).isEmpty)
        // A song ending by itself doesn't flush or stop the speakers.
        #expect(rig.session.calls.filter { $0 == "pause" || $0 == "stop" }.count == pauses)
        #expect(rig.session.transport == .playing)
    }

    @Test func endOfTheQueueStops() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playTrack(id: "a4", context: .playlist(id: "p1")))
        await rig.hub.settle()
        rig.clock.advance(5)
        musicPlays(player, rig, "a4", at: 195)
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        rig.clock.advance(10)
        musicStops(player)
        try await rig.waitFor("stopped") { $0.queue.currentID == nil && !$0.transport.isPlaying }
        #expect(player.commands.get().last == "pause")
    }

    @Test func crossQueuesSpotifyAfterAppleMusic() async throws {
        let (rig, player) = try await rig()
        rig.apps.installed.update { _ = $0.insert(LocalHub.spotifyBundleID) }
        rig.apps.setRunning(LocalHub.spotifyBundleID, true)
        await rig.hub.tick()
        try await rig.hub.perform(.playTrack(id: "a3", context: .playlist(id: "p1")))
        let spotifySong = TrackItem(id: Self.spotifyURI, title: "Far", artist: "Other", album: "", duration: 150)
        try await rig.hub.perform(.addToQueue(tracks: [spotifySong], source: .spotify, placement: .next))
        #expect(try await upNextIDs(rig) == [Self.spotifyURI, "a4"])
        #expect(try await rig.hub.upNext(.first).items.map(\.source) == [.spotify, .appleMusic])

        rig.clock.advance(5)
        musicPlays(player, rig, "a3", at: 199)
        do { try await rig.waitFor("playing") { $0.transport.isPlaying } } catch {
            Issue.record("state: \(rig.state.activeSource as Any) \(rig.state.nowPlaying as Any) \(rig.state.queue) \(player.commands.get()) \(rig.spotify.commands.get())")
            throw error
        }
        rig.clock.advance(5)
        musicStops(player)
        try await rig.waitFor("spotify") { $0.activeSource == .spotify }
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().contains("play \(Self.spotifyURI)"))
        #expect(rig.state.queue.currentSource == .spotify)
        // The speaker stayed selected across the switch.
        #expect(rig.session.inner.get().selected.contains("542a1b003344"))

        // Spotify finishes its song (paused at the start again): back to Apple Music.
        rig.clock.advance(5)
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .playing, title: "Far", artist: "Other", duration: 150,
                                           position: 149, trackID: Self.spotifyURI, sampledAt: rig.clock.now))
        try await rig.waitFor("spotify sample") { $0.nowPlaying?.title == "Far" }
        rig.clock.advance(3)
        rig.spotify.fanout.send(NowPlaying(app: .spotify, state: .paused, title: "Far", artist: "Other", duration: 150,
                                           position: 0, trackID: Self.spotifyURI, sampledAt: rig.clock.now))
        try await rig.waitFor("back to music") { $0.activeSource == .appleMusic }
        await rig.hub.settle()
        #expect(player.commands.get().last == "once a4")
    }

    @Test func playingDirectlyInMusicHoldsTheQueue() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playTrack(id: "a1", context: .playlist(id: "p1")))
        await rig.hub.settle()
        rig.clock.advance(5)
        musicPlays(player, rig, "a1", at: 30)
        try await rig.waitFor("playing") { $0.transport.isPlaying }
        rig.clock.advance(5)
        musicPlays(player, rig, "zz", at: 2)
        try await rig.waitFor("held") { $0.queue.isHeld }
        #expect(rig.state.queue.currentID == nil && rig.state.queue.upcomingCount == 3)
        #expect(rig.state.nowPlaying?.trackID == "zz")
        // Next carries on with the queue.
        try await rig.hub.perform(.next)
        await rig.hub.settle()
        #expect(player.commands.get().last == "once a2")
        #expect(!rig.state.queue.isHeld)
    }

    @Test func editsUpNext() async throws {
        let (rig, player) = try await rig()
        try await rig.hub.perform(.playTrack(id: "a1", context: .playlist(id: "p1")))
        let ids = try await rig.hub.upNext(.first).items.map(\.id)   // a2 a3 a4
        try await rig.hub.perform(.moveInQueue(ids: [ids[2]], toOffset: 0))
        #expect(try await upNextIDs(rig) == ["a4", "a2", "a3"])
        try await rig.hub.perform(.removeFromQueue(ids: [ids[0]]))
        #expect(try await upNextIDs(rig) == ["a4", "a3"])
        try await rig.hub.perform(.playTrack(id: ids[1], context: .upNext))
        #expect(player.commands.get().last == "once a3")
        #expect(try await upNextIDs(rig).isEmpty)
        try await rig.hub.perform(.addToQueue(tracks: [Self.t("a1"), Self.t("a2")], source: .appleMusic, placement: .last))
        let before = rig.state.content.upNext
        try await rig.hub.perform(.setShuffle(enabled: true))
        #expect(rig.state.queue.isShuffled)
        try await rig.hub.perform(.setShuffle(enabled: false))
        let restored = try await upNextIDs(rig)
        #expect(!rig.state.queue.isShuffled && restored == ["a1", "a2"])
        try await rig.hub.perform(.clearQueue)
        #expect(try await upNextIDs(rig).isEmpty && rig.state.content.upNext > before)
        // Spotify songs without a track URI can't be queued.
        await #expect(throws: HubCommandError.self) {
            try await rig.hub.perform(.addToQueue(tracks: [Self.t("Song\u{1F}Band")], source: .spotify, placement: .last))
        }
    }

    @Test func spotifyLinksQueueWithTheirEmbedTitle() async throws {
        let (rig, _) = try await rig()
        let page = try #require(SpotifyLink.webURL(forURI: Self.spotifyURI))
        rig.system.embeds.set([page: SpotifyEmbedInfo(title: "Shared Song", thumbnailURL: URL(string: "https://img.example/s.jpg"))])
        try await rig.hub.perform(.addSpotifyLink(link: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x", placement: .last))
        let item = try #require(try await rig.hub.upNext(.first).items.first)
        #expect(item.source == .spotify && item.track.id == Self.spotifyURI && item.track.title == "Shared Song")
        #expect(item.track.artworkID == "hub.url:https://img.example/s.jpg")
        await #expect(throws: HubCommandError.self) {
            try await rig.hub.perform(.addSpotifyLink(link: "https://example.com/x", placement: .last))
        }
    }

    @Test func filesQueueGaplessly() async throws {
        let (rig, _) = try await rig()
        let dir = temporaryDirectory()
        try await rig.addFiles(["one.m4a", "two.m4a"], in: dir)
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("files") { $0.transport.isPlaying }
        #expect(try await upNextIDs(rig) == ["file-2"])
        rig.session.endOfStream()
        try await rig.waitFor("second file") { $0.nowPlaying?.trackID == "file-2" }
        #expect(rig.state.queue.upcomingCount == 0 && rig.state.transport.isPlaying)
    }

    @Test func pinsPersistAndSpotifyPinsPlayInSpotify() async throws {
        let (rig, _) = try await rig()
        try await rig.hub.perform(.pinPlaylist(id: "p1"))
        let link = "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=1"
        let uri = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
        rig.system.embeds.set([SpotifyLink.webURL(forURI: uri)!: SpotifyEmbedInfo(title: "Morning", thumbnailURL: nil)])
        try await rig.hub.perform(.pinSpotifyLink(link: link))
        #expect(rig.state.pins.map(\.id) == ["p1", uri])
        #expect(rig.state.pins.map(\.name) == ["Garden", "Morning"])
        #expect(rig.settings.load().pins.count == 2)

        rig.apps.installed.update { _ = $0.insert(LocalHub.spotifyBundleID) }
        rig.apps.setRunning(LocalHub.spotifyBundleID, true)
        await rig.hub.tick()
        try await rig.hub.perform(.playPlaylist(id: uri, shuffled: true))
        await rig.hub.settle()
        #expect(rig.spotify.commands.get().last == "play \(uri) shuffled true")
        #expect(rig.state.activeSource == .spotify)

        try await rig.hub.perform(.unpinPlaylist(id: "p1"))
        #expect(rig.state.pins.map(\.id) == [uri])
        // Settings written before pins existed still load.
        let old = Data(#"{"masterVolume":0.4,"speakers":{}}"#.utf8)
        #expect(try JSONDecoder().decode(HubSettings.self, from: old).pins.isEmpty)
    }

    // MARK: Apple Music catalog

    static let catalogHits = ["catalog:901", "catalog:902", "catalog:903"].map { t($0) }

    @Test func catalogSearchIsItsOwnQueryAndUnsupportedWithoutACatalog() async throws {
        let (rig, player) = try await rig()
        do {
            _ = try await rig.hub.answer(.catalogSearch(query: "tide", page: .first))
            Issue.record("answered without a catalog")
        } catch {
            #expect((error as? HubCommandError)?.code == .unsupported)
        }
        player.catalog.set(["tide": Self.catalogHits])
        let page = try #require(try await rig.hub.answer(.catalogSearch(query: "tide", page: .first)).tracks)
        #expect(page.items.map(\.id) == Self.catalogHits.map(\.id))
        // The library search stays the library's.
        #expect(try await rig.hub.search("tide", .first).items.isEmpty)
    }

    @Test func playingACatalogSongQueuesTheResultsAfterItWithoutSearchingAgain() async throws {
        let (rig, player) = try await rig()
        player.catalog.set(["tide": Self.catalogHits])
        _ = try await rig.hub.searchCatalog("tide", .first)
        try await rig.hub.perform(.playTrack(id: "catalog:902", context: .catalog(query: "Tide ")))
        await rig.hub.settle()
        #expect(player.commands.get() == ["once catalog:902"])
        #expect(player.catalogSearches.get() == ["tide"])
        #expect(try await upNextIDs(rig) == ["catalog:903"])
        #expect(rig.state.queue.currentSource == .appleMusic && rig.state.activeSource == .appleMusic)
    }

    @Test func aCatalogSongNotInTheRememberedResultsIsSearchedFor() async throws {
        let (rig, player) = try await rig()
        player.catalog.set(["tide": Self.catalogHits, "shore": [Self.t("catalog:77")]])
        _ = try await rig.hub.searchCatalog("shore", .first)
        try await rig.hub.perform(.playTrack(id: "catalog:901", context: .catalog(query: "tide")))
        await rig.hub.settle()
        #expect(player.commands.get() == ["once catalog:901"])
        #expect(player.catalogSearches.get() == ["shore", "tide"])
        await #expect(throws: HubCommandError.self) {
            try await rig.hub.perform(.playTrack(id: "catalog:5", context: .catalog(query: "tide")))
        }
    }

    @Test func catalogAndLibrarySongsShareUpNextAndAdvance() async throws {
        let (rig, player) = try await rig()
        player.catalog.set(["tide": Self.catalogHits])
        try await rig.hub.perform(.playTrack(id: "a4", context: .playlist(id: "p1")))
        try await rig.hub.perform(.addToQueue(tracks: [Self.catalogHits[0]], source: .appleMusic, placement: .next))
        await rig.hub.settle()
        #expect(try await upNextIDs(rig) == ["catalog:901"])
        try await rig.hub.perform(.next)
        await rig.hub.settle()
        #expect(player.commands.get().suffix(1) == ["once catalog:901"])
        musicPlays(player, rig, "catalog:901")
        try await rig.waitFor("the catalog song as now playing") { $0.nowPlaying?.trackID == "catalog:901" }
        #expect(rig.state.queue.currentID != nil && !rig.state.queue.isHeld)
    }
}
