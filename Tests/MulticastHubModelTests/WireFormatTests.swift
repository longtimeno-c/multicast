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
        #expect(try json(HubCommand.setShuffle(enabled: true)) == #"{"setShuffle":{"enabled":true}}"#)
        #expect(try json(HubCommand.pinSpotifyLink(link: "https://open.spotify.com/playlist/x"))
                == #"{"pinSpotifyLink":{"link":"https:\/\/open.spotify.com\/playlist\/x"}}"#)
        #expect(try json(TrackContext.spotifyHistory) == #"{"spotifyHistory":{}}"#)
        #expect(try json(TrackContext.catalog(query: "tide")) == #"{"catalog":{"query":"tide"}}"#)
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
            .playTrack(id: "catalog:1234", context: .catalog(query: "tide")),
            .addToQueue(tracks: [TrackItem(id: "s", title: "S", artist: "", album: "", duration: 1)], source: .appleMusic, placement: .last),
            .addSpotifyLink(link: "spotify:track:x", placement: .next), .removeFromQueue(ids: ["q1"]),
            .moveInQueue(ids: ["q1", "q3"], toOffset: 4), .clearQueue, .setShuffle(enabled: false), .pinPlaylist(id: "p"),
            .pinSpotifyLink(link: "spotify:playlist:x"), .unpinPlaylist(id: "p"), .captureApp(bundleID: "com.example.player"),
            .addFiles(urls: [URL(fileURLWithPath: "/tmp/a song.flac")]), .removeFiles(ids: ["f1", "f2"]),
            .openSpotify, .requestPermission(permission: .automation),
            .setSpeakerEnabled(id: "x", enabled: false), .setSpeakerVolume(id: "x", volume: 0.5),
            .setSpeakerSyncTrim(id: "x", milliseconds: 120), .retrySpeaker(id: "x"), .setMasterVolume(volume: 0.7),
            .refreshSpeakers, .calibrateSync, .cancelSyncCalibration,
        ]
        for c in all { try roundTrip(c) }
    }

    @Test func queriesAndResultsRoundTrip() throws {
        #expect(try json(HubQuery.songs(page: .first)) == #"{"songs":{"page":{"limit":100}}}"#)
        #expect(try json(HubQuery.playlistTracks(playlistID: "p1", page: PageRequest(cursor: "100", limit: 50)))
                == #"{"playlistTracks":{"page":{"cursor":"100","limit":50},"playlistID":"p1"}}"#)
        #expect(try json(HubQuery.artwork(id: "cover.ring", maxPixel: 300)) == #"{"artwork":{"id":"cover.ring","maxPixel":300}}"#)
        #expect(try json(HubQuery.catalogSearch(query: "tide", page: PageRequest(limit: 25)))
                == #"{"catalogSearch":{"page":{"limit":25},"query":"tide"}}"#)
        let queries: [HubQuery] = [.playlists(page: .first), .search(query: "a", page: .first), .upNext(page: .first),
                                   .catalogSearch(query: "a", page: PageRequest(cursor: "25", limit: 25)),
                                   .files(page: .first), .spotifyHistory(page: .first)]
        for q in queries { try roundTrip(q) }

        let track = TrackItem(id: "s1", title: "Slow Weather", artist: "Juniper Hale", album: "Tidewater",
                              duration: 252, artworkID: "cover.sun")
        try roundTrip(HubQueryResult.tracks(page: Page(items: [track], nextCursor: "1", totalCount: 2)))
        try roundTrip(HubQueryResult.playlists(page: Page(items: [PlaylistItem(id: "p", name: "Garden", trackCount: 3)])))
        // Folders: two optional keys, omitted for a plain playlist, so older builds read and write it unchanged.
        #expect(try json(PlaylistItem(id: "p", name: "Garden", trackCount: 3)) == #"{"id":"p","name":"Garden","trackCount":3}"#)
        let folder = PlaylistItem(id: "f", name: "Evenings", trackCount: 9, isFolder: true, parentID: "top")
        #expect(try json(folder) == #"{"id":"f","isFolder":true,"name":"Evenings","parentID":"top","trackCount":9}"#)
        try roundTrip(folder)
        let old = try JSONDecoder().decode(PlaylistItem.self, from: Data(#"{"id":"p","name":"Garden","trackCount":3,"artworkID":"a"}"#.utf8))
        #expect(!old.isFolder && old.parentID == nil && old.artworkID == "a")
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
        #expect(try json(s.queue) == #"{"currentID":"q3","currentSource":"appleMusic","isHeld":false,"isShuffled":false,"upcomingCount":12}"#)
        #expect(try json(SpeakerState.failed(reason: "Not responding")) == #"{"failed":{"reason":"Not responding"}}"#)
        #expect(try json(SpeakerID("542a1b001122")) == #""542a1b001122""#)
    }

    /// A speaker that turned the hub away travels as one optional key: absent when false, so
    /// older remotes and hubs read and write every other speaker exactly as before.
    @Test func restrictedSpeakerIsOneOptionalKey() throws {
        let plain = SpeakerItem(id: "542a1b001122", name: "Hall Sonos", transport: .airPlay2, glyph: .smartSpeaker,
                                volume: 0.5)
        #expect(try json(plain)
                == #"{"glyph":"smartSpeaker","id":"542a1b001122","isEnabled":false,"name":"Hall Sonos","state":{"off":{}},"syncTrimMs":0,"transport":"airPlay2","volume":0.5}"#)

        let restricted = SpeakerItem(id: "cccc00000001", name: "Neighbour\u{2019}s HomePod", transport: .airPlay2,
                                     glyph: .smartSpeaker, model: "HomePod mini", address: "192.0.2.70:7000",
                                     volume: 0.5, isRestricted: true)
        #expect(try json(restricted).contains(#""isRestricted":true"#))
        try roundTrip(restricted)
        #expect(try !json(restricted).contains("isCheckingAccess"))
        // Being asked again: one more optional key, and the state stays off.
        var checking = restricted
        checking.isCheckingAccess = true
        checking.notSeenSince = Date(timeIntervalSinceReferenceDate: 500)
        #expect(try json(checking).contains(#""isCheckingAccess":true"#))
        #expect(try json(checking).contains(#""state":{"off":{}}"#))
        try roundTrip(checking)
        #expect(try !json(plain).contains("isCheckingAccess"))

        // What an older hub sends: no key, so not restricted.
        let old = try JSONDecoder().decode(SpeakerItem.self, from: Data(
            #"{"id":"bbbb58000010","name":"Patio","transport":"airPlay1","glyph":"airportExpress","isEnabled":true,"volume":0.7,"state":{"failed":{"reason":"Not responding"}},"syncTrimMs":40}"#.utf8))
        #expect(!old.isRestricted && old.isEnabled && old.state == .failed(reason: "Not responding") && old.syncTrimMs == 40)
        #expect(old.model == nil && old.address == nil && old.notSeenSince == nil)

        // What an older remote does with a new hub's speaker: synthesized decoding skips the key.
        struct OlderSpeakerItem: Decodable {
            var id: SpeakerID, name: String, isEnabled: Bool, state: SpeakerState
        }
        let seenByOld = try JSONDecoder().decode(OlderSpeakerItem.self, from: JSONEncoder().encode(restricted))
        #expect(seenByOld.name == "Neighbour\u{2019}s HomePod" && !seenByOld.isEnabled && seenByOld.state == .off)
        // Even while it is being asked again: an older remote sees an off speaker, not a
        // connecting one it would count.
        let checkingSeenByOld = try JSONDecoder().decode(OlderSpeakerItem.self, from: JSONEncoder().encode(checking))
        #expect(!checkingSeenByOld.isEnabled && checkingSeenByOld.state == .off)
        let oldCheckingDecoded = try JSONDecoder().decode(SpeakerItem.self, from: Data(
            #"{"id":"bbbb58000010","name":"Patio","transport":"airPlay1","glyph":"airportExpress","isEnabled":false,"volume":0.7,"state":{"off":{}},"syncTrimMs":0}"#.utf8))
        #expect(!oldCheckingDecoded.isCheckingAccess)

        var s = HubState(revision: 3)
        s.speakers = [plain, restricted]
        try roundTrip(s)
    }

    @Test func aPhoneSpeakerHasItsOwnTransportAndGlyph() throws {
        let phone = SpeakerItem(id: "phone:remote-a", name: "Sample iPhone", transport: .phone, glyph: .phone,
                                model: "Garden Speaker", isEnabled: true, volume: 0.4, state: .playing, syncTrimMs: -160)
        let data = try JSONEncoder().encode(phone)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["transport"] as? String == "phone")
        #expect(object["glyph"] as? String == "phone")
        #expect(try JSONDecoder().decode(SpeakerItem.self, from: data) == phone)
        #expect(phone.kindDescription == "iPhone \u{00B7} Garden Speaker")
        #expect(!SpeakerTransport.phone.isNetwork)
        #expect(SpeakerGlyph.phone.symbolName == "iphone")
        // The names older builds know are unchanged.
        #expect(SpeakerTransport.allCases.map(\.rawValue) == ["airPlay1", "airPlay2", "builtIn", "bluetooth", "usb", "phone"])
    }

    @Test func calibrationHasStableNamesAndIsAbsentUntilThereIsOne() throws {
        #expect(try json(HubCommand.calibrateSync) == #"{"calibrateSync":{}}"#)
        #expect(try json(HubCommand.cancelSyncCalibration) == #"{"cancelSyncCalibration":{}}"#)
        #expect(HubCommand.calibrateSync.category == .speaker)

        // No calibration: the key isn't written, so a state reads the same to older builds.
        let plain = HubState(revision: 1)
        #expect(!(try json(plain)).contains("calibration"))
        // And a state from a build that predates it decodes.
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        older["calibration"] = nil
        #expect(try JSONDecoder().decode(HubState.self, from: JSONSerialization.data(withJSONObject: older)).calibration == nil)

        var s = HubState(revision: 2)
        s.calibration = SyncCalibrationStatus(isRunning: false, speakers: [
            .init(id: "a", outcome: .aligned(lagMs: 172.4, trimMs: -172, reachedLimit: false)),
            .init(id: "b", outcome: .notHeard), .init(id: "c", outcome: .measuring), .init(id: "d"),
            .init(id: "e", outcome: .unclear), .init(id: "f", outcome: .skipped),
        ])
        try roundTrip(s)
        #expect(try json(s.calibration!.speakers[0])
                == #"{"id":"a","outcome":{"aligned":{"lagMs":172.4,"reachedLimit":false,"trimMs":-172}}}"#)
        #expect(try json(s.calibration!.speakers[1]) == #"{"id":"b","outcome":{"notHeard":{}}}"#)
        #expect(s.hasSameContent(as: s) && !s.hasSameContent(as: plain))
    }

    @Test func calibrationWording() {
        typealias Outcome = SyncCalibrationStatus.Outcome
        #expect(Outcome.aligned(lagMs: 172.4, trimMs: -172, reachedLimit: false).caption == "Was 172 ms late \u{00B7} trim \u{2212}172 ms")
        #expect(Outcome.aligned(lagMs: 0.2, trimMs: 0, reachedLimit: false).caption == "In step \u{00B7} no trim")
        #expect(Outcome.aligned(lagMs: -12, trimMs: 12, reachedLimit: false).caption == "Was 12 ms early \u{00B7} trim +12 ms")
        #expect(Outcome.aligned(lagMs: 900, trimMs: -500, reachedLimit: true).caption.hasSuffix("the most it allows"))
        #expect(Outcome.notHeard.caption == "Couldn\u{2019}t hear this speaker")

        func status(_ outcomes: [Outcome], running: Bool = false, problem: String? = nil) -> SyncCalibrationStatus {
            SyncCalibrationStatus(isRunning: running, speakers: outcomes.enumerated().map { .init(id: SpeakerID("s\($0.offset)"), outcome: $0.element) },
                                  problem: problem)
        }
        let done = Outcome.aligned(lagMs: 0, trimMs: 0, reachedLimit: false)
        #expect(status([done, done, done]).summary == "All 3 speakers are lined up.")
        #expect(status([done, .notHeard, done]).summary == "2 of 3 speakers lined up.")
        #expect(status([.notHeard, .unclear]).summary == "Couldn\u{2019}t hear any speaker from here.")
        #expect(status([done]).summary == "Measured 1 speaker. Turn on another to line them up.")
        #expect(status([.measuring, .waiting], running: true).summary == nil)
        #expect(status([.skipped], problem: "No microphone.").summary == "No microphone.")
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

    @Test func catalogTrackIDsAreTellableFromLibraryIDs() {
        #expect(CatalogTrackID.make("1440857781") == "catalog:1440857781")
        #expect(CatalogTrackID.catalogID(from: "catalog:1440857781") == "1440857781")
        #expect(CatalogTrackID.isCatalog("catalog:i.AbC-12"))
        for other in ["1440857781", "0A1B2C3D4E5F6071", "spotify:track:x", "catalog:", "catalog:a b", "catalog:\"quit", "Catalog:1",
                      "catalog:" + String(repeating: "9", count: 65)] {
            #expect(!CatalogTrackID.isCatalog(other), "\(other)")
        }
    }

    /// A backend without a catalog says so, and the query maps onto the method.
    @Test func catalogSearchDefaultsToUnsupported() async {
        final class Plain: HubBackend, @unchecked Sendable {
            func states() async -> AsyncStream<HubState> { AsyncStream { $0.finish() } }
            func levels() async -> AsyncStream<StereoLevels> { AsyncStream { $0.finish() } }
            func artwork(id: ArtworkID, maxPixel: Int) async -> Data? { nil }
            func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .empty }
            func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
            func songs(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
            func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
            func upNext(_ page: PageRequest) async throws -> Page<QueueItem> { .empty }
            func files(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
            func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
            func perform(_ command: HubCommand) async throws {}
        }
        do {
            _ = try await Plain().answer(.catalogSearch(query: "tide", page: .first))
            Issue.record("answered")
        } catch {
            #expect((error as? HubCommandError)?.code == .unsupported)
        }
    }
}
