import Foundation
import Testing
@testable import MulticastHubModel

/// The wire format is a contract between the Mac hub and iOS remotes of different builds: these
/// tests pin field names, so renaming a case or a label fails here instead of in the field.
@Suite struct WireFormatTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        #expect(back == value)
    }

    @Test func commandsHaveStableNames() throws {
        #expect(try json(HubCommand.play) == #"{"play":{}}"#)
        #expect(try json(HubCommand.seek(position: 42.5)) == #"{"seek":{"position":42.5}}"#)
        #expect(try json(HubCommand.setSpeakerVolume(id: "542a1b001122", volume: 0.25))
                == #"{"setSpeakerVolume":{"id":"542a1b001122","volume":0.25}}"#)
        #expect(try json(HubCommand.setSpeakerEnabled(id: "local:BuiltInSpeakerDevice", enabled: true))
                == #"{"setSpeakerEnabled":{"enabled":true,"id":"local:BuiltInSpeakerDevice"}}"#)
        #expect(try json(HubCommand.setSpeakerSyncTrim(id: "a", milliseconds: -40))
                == #"{"setSpeakerSyncTrim":{"id":"a","milliseconds":-40}}"#)
        #expect(try json(HubCommand.playTrack(id: "s1", context: .playlist(id: "p1")))
                == #"{"playTrack":{"context":{"playlist":{"id":"p1"}},"id":"s1"}}"#)
        #expect(try json(HubCommand.playPlaylist(id: "p1", shuffled: true)) == #"{"playPlaylist":{"id":"p1","shuffled":true}}"#)
        #expect(try json(HubCommand.addToQueue(tracks: [TrackItem(id: "spotify:track:x", title: "T", artist: "A", album: "", duration: 3)],
                                               source: .spotify, placement: .next))
                == #"{"addToQueue":{"placement":"next","source":"spotify","tracks":[{"album":"","artist":"A","duration":3,"id":"spotify:track:x","title":"T"}]}}"#)
        #expect(try json(HubCommand.moveInQueue(ids: ["q2"], toOffset: 0)) == #"{"moveInQueue":{"ids":["q2"],"toOffset":0}}"#)
        #expect(try json(HubCommand.clearQueue) == #"{"clearQueue":{}}"#)
        #expect(try json(HubCommand.pinSpotifyLink(link: "https://open.spotify.com/playlist/x"))
                == #"{"pinSpotifyLink":{"link":"https:\/\/open.spotify.com\/playlist\/x"}}"#)
        #expect(try json(TrackContext.spotifyHistory) == #"{"spotifyHistory":{}}"#)
        #expect(try json(HubCommand.selectSource(source: .appleMusic)) == #"{"selectSource":{"source":"appleMusic"}}"#)
        #expect(try json(HubCommand.requestPermission(permission: .audioCapture))
                == #"{"requestPermission":{"permission":"audioCapture"}}"#)
    }

    @Test func everyCommandRoundTrips() throws {
        let all: [HubCommand] = [
            .play, .pause, .next, .previous, .seek(position: 1.5),
            .selectSource(source: .spotify), .playTrack(id: "t", context: .songs), .playTrack(id: "t", context: .upNext),
            .playTrack(id: "t", context: .search(query: "tide")), .playTrack(id: "f1", context: .files),
            .playPlaylist(id: "p", shuffled: false), .playTrack(id: "spotify:track:x", context: .spotifyHistory),
            .addToQueue(tracks: [TrackItem(id: "s", title: "S", artist: "", album: "", duration: 1)], source: .appleMusic, placement: .last),
            .addSpotifyLink(link: "spotify:track:x", placement: .next), .removeFromQueue(ids: ["q1"]),
            .moveInQueue(ids: ["q1", "q3"], toOffset: 4), .clearQueue, .pinPlaylist(id: "p"),
            .pinSpotifyLink(link: "spotify:playlist:x"), .unpinPlaylist(id: "p"), .captureApp(bundleID: "com.example.player"),
            .addFiles(urls: [URL(fileURLWithPath: "/tmp/a song.flac")]), .removeFiles(ids: ["f1", "f2"]),
            .openSpotify, .requestPermission(permission: .automation),
            .setSpeakerEnabled(id: "x", enabled: false), .setSpeakerVolume(id: "x", volume: 0.5),
            .setSpeakerSyncTrim(id: "x", milliseconds: 120), .retrySpeaker(id: "x"), .setMasterVolume(volume: 0.7),
        ]
        for c in all { try roundTrip(c) }
    }

    @Test func queriesAndResultsRoundTrip() throws {
        #expect(try json(HubQuery.songs(page: .first)) == #"{"songs":{"page":{"limit":100}}}"#)
        #expect(try json(HubQuery.playlistTracks(playlistID: "p1", page: PageRequest(cursor: "100", limit: 50)))
                == #"{"playlistTracks":{"page":{"cursor":"100","limit":50},"playlistID":"p1"}}"#)
        #expect(try json(HubQuery.artwork(id: "cover.ring", maxPixel: 300)) == #"{"artwork":{"id":"cover.ring","maxPixel":300}}"#)
        let queries: [HubQuery] = [.playlists(page: .first), .search(query: "a", page: .first), .upNext(page: .first),
                                   .files(page: .first), .spotifyHistory(page: .first)]
        for q in queries { try roundTrip(q) }

        let track = TrackItem(id: "s1", title: "Slow Weather", artist: "Juniper Hale", album: "Tidewater",
                              duration: 252, artworkID: "cover.sun")
        try roundTrip(HubQueryResult.tracks(page: Page(items: [track], nextCursor: "1", totalCount: 2)))
        try roundTrip(HubQueryResult.playlists(page: Page(items: [PlaylistItem(id: "p", name: "Garden", trackCount: 3)])))
        try roundTrip(HubQueryResult.artwork(data: Data([1, 2, 3])))
        let item = QueueItem(id: "q7", source: .spotify, track: track)
        try roundTrip(HubQueryResult.queue(page: Page(items: [item], totalCount: 1)))
        #expect(try json(item).hasPrefix(#"{"id":"q7","source":"spotify","track":{"#))
        try roundTrip(HubQueryResult.artwork(data: nil))
    }

    @Test func stateRoundTripsWithStableTopLevelNames() throws {
        var s = HubState(revision: 7, masterVolume: 0.62)
        s.speakers = [
            SpeakerItem(id: "542a1b001122", name: "Hall Sonos", transport: .airPlay2, glyph: .smartSpeaker,
                        model: "Sonos One", address: "192.0.2.53", isEnabled: true, volume: 0.55, state: .playing),
            SpeakerItem(id: "bbbb58000010", name: "Patio", transport: .airPlay1, glyph: .airportExpress,
                        isEnabled: true, volume: 0.7, state: .failed(reason: "Not responding"), syncTrimMs: 40),
        ]
        s.activeSource = .spotify
        s.nowPlaying = NowPlayingInfo(title: "Evening Tide", artist: "Sola Wren", artworkID: "cover.horizon", duration: 238)
        s.transport = TransportState(isPlaying: true, position: 64, positionAsOf: Date(timeIntervalSinceReferenceDate: 1000))
        s.capture = CaptureStatus(apps: [CapturableApp(id: "com.example.player", name: "Player", isMakingSound: true)])
        s.spotify = .running
        s.content = ContentRevisions(library: 1, upNext: 2, files: 3, spotifyHistory: 4)
        s.queue = QueueStatus(currentID: "q3", currentSource: .appleMusic, upcomingCount: 12, isHeld: false)
        s.pins = [PinnedPlaylist(id: "p1", source: .appleMusic, name: "Garden", trackCount: 3),
                  PinnedPlaylist(id: "spotify:playlist:x", source: .spotify, name: "Morning")]
        s.health = HubHealth(permissions: PermissionSet(localNetwork: .granted, audioCapture: .denied),
                             extraIssues: [.sourceAppNotRunning(source: .spotify, bundleID: "com.spotify.client", name: "Spotify")])
        try roundTrip(s)

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        #expect(Set(object.keys) == ["revision", "speakers", "masterVolume", "isDiscovering", "activeSource", "nowPlaying",
                                     "transport", "capture", "spotify", "content", "queue", "pins", "health"])
        #expect(try json(s.queue) == #"{"currentID":"q3","currentSource":"appleMusic","isHeld":false,"upcomingCount":12}"#)
        #expect(try json(SpeakerState.failed(reason: "Not responding")) == #"{"failed":{"reason":"Not responding"}}"#)
        #expect(try json(SpeakerID("542a1b001122")) == #""542a1b001122""#)
    }

    @Test func stateStaysSmall() throws {
        // A busy house: 16 speakers, 20 capturable apps, every issue. Must stay a few KB.
        var s = HubState()
        s.speakers = (0..<16).map {
            SpeakerItem(id: SpeakerID("speaker-\($0)"), name: "Speaker number \($0)", transport: .airPlay2,
                        glyph: .speaker, model: "Model", address: "speaker-\($0).local", volume: 0.5)
        }
        s.capture.apps = (0..<20).map { CapturableApp(id: "com.example.app\($0)", name: "App \($0)", isMakingSound: false) }
        s.health = HubHealth(permissions: PermissionSet(), extraIssues: [])
        let bytes = try JSONEncoder().encode(s).count
        #expect(bytes < 8_192)
    }

    @Test func commandErrorsTravel() throws {
        try roundTrip(HubCommandError(.unavailable, "Spotify isn\u{2019}t open"))
        let e: Error = HubCommandError(.notFound, "That speaker is gone")
        #expect(e.localizedDescription == "That speaker is gone")
    }
}
