import Foundation
import MulticastHubModel

/// A made-up house and a small believable library. Names, addresses, artists and titles are invented
/// (addresses are from the documentation ranges).
enum MockData {
    static let denon: SpeakerID = "airplay.denon"
    static let hall: SpeakerID = "airplay.hall"
    static let mainBath: SpeakerID = "airplay.main-bath"
    static let masterBath: SpeakerID = "airplay.master-bath"
    static let patio: SpeakerID = "airplay.patio"
    static let macBook: SpeakerID = "local.builtin"
    static let jbl: SpeakerID = "local.jbl"

    static var speakers: [SpeakerItem] {
        [
            SpeakerItem(id: denon, name: "Denon AVR-X2800H", transport: .airPlay2, glyph: .receiver,
                        model: nil, address: "192.0.2.60", isEnabled: false, volume: 0.45, state: .off, syncTrimMs: 0),
            SpeakerItem(id: hall, name: "Hall Sonos", transport: .airPlay2, glyph: .smartSpeaker,
                        model: "Sonos One", address: "192.0.2.53", isEnabled: false, volume: 0.55, state: .off, syncTrimMs: 0),
            SpeakerItem(id: mainBath, name: "Main Bedroom", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.0.2.42", isEnabled: false, volume: 0.35, state: .off, syncTrimMs: 40),
            SpeakerItem(id: masterBath, name: "Master Bedroom", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.0.2.41", isEnabled: false, volume: 0.40, state: .off, syncTrimMs: 40),
            SpeakerItem(id: patio, name: "Patio", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.0.2.47", isEnabled: false, volume: 0.70, state: .off, syncTrimMs: 0),
            SpeakerItem(id: macBook, name: "MacBook Air Speakers", transport: .builtIn, glyph: .laptop,
                        model: nil, address: "BuiltInSpeakerDevice", isEnabled: false, volume: 0.30, state: .off, syncTrimMs: 0),
            SpeakerItem(id: jbl, name: "JBL Flip 6", transport: .bluetooth, glyph: .portable,
                        model: nil, address: "00:00:5E:00:53:0E", isEnabled: false, volume: 0.60, state: .off, syncTrimMs: -180),
        ]
    }

    static var songs: [TrackItem] {
        [
            TrackItem(id: "s1", title: "Slow Weather", artist: "Juniper Hale", album: "Tidewater", duration: 252, artworkID: MockArtwork.id(.sunOverWater)),
            TrackItem(id: "s2", title: "Paper Lanterns", artist: "The Ostrava Set", album: "Night Market", duration: 218, artworkID: MockArtwork.id(.dots)),
            TrackItem(id: "s3", title: "Halcyon Drive", artist: "Mara Quell", album: "Halcyon", duration: 301, artworkID: MockArtwork.id(.arcs)),
            TrackItem(id: "s4", title: "Low Orbit", artist: "Fen & Arlo", album: "Low Orbit", duration: 234, artworkID: MockArtwork.id(.ring)),
            TrackItem(id: "s5", title: "Copper Light", artist: "Juniper Hale", album: "Tidewater", duration: 280, artworkID: MockArtwork.id(.sunOverWater)),
            TrackItem(id: "s6", title: "Glasshouse", artist: "Kito Marr", album: "Glasshouse", duration: 201, artworkID: MockArtwork.id(.bands)),
            TrackItem(id: "s7", title: "Northbound", artist: "The Ostrava Set", album: "Night Market", duration: 245, artworkID: MockArtwork.id(.dots)),
            TrackItem(id: "s8", title: "Small Hours", artist: "Mara Quell", album: "Halcyon", duration: 227, artworkID: MockArtwork.id(.arcs)),
            TrackItem(id: "s9", title: "Field Day", artist: "Odile Brandt", album: "Primary", duration: 196, artworkID: MockArtwork.id(.split)),
            TrackItem(id: "s10", title: "Still Life With Radio", artist: "Kito Marr", album: "Glasshouse", duration: 263, artworkID: MockArtwork.id(.bands)),
        ]
    }

    private static var playlistsWithoutCounts: [PlaylistItem] {
        [
            PlaylistItem(id: "p1", name: "Sunday morning", trackCount: 24, artworkID: MockArtwork.id(.sunOverWater)),
            PlaylistItem(id: "p2", name: "Kitchen", trackCount: 58, artworkID: MockArtwork.id(.dots)),
            PlaylistItem(id: "p3", name: "Hall", trackCount: 41, artworkID: MockArtwork.id(.stack)),
            PlaylistItem(id: "p4", name: "Dinner party", trackCount: 33, artworkID: MockArtwork.id(.ring)),
            PlaylistItem(id: "p5", name: "Garden", trackCount: 19, artworkID: MockArtwork.id(.arcs)),
        ]
    }

    static var spotifyTracks: [TrackItem] {
        [
            TrackItem(id: "sp1", title: "Evening Tide", artist: "Sola Wren", album: "Coastlines", duration: 238, artworkID: MockArtwork.id(.horizon)),
            TrackItem(id: "sp2", title: "Waystation", artist: "Pelle Ash", album: "Waystation", duration: 212, artworkID: MockArtwork.id(.stack)),
            TrackItem(id: "sp3", title: "Brightwater", artist: "Sola Wren", album: "Coastlines", duration: 255, artworkID: MockArtwork.id(.horizon)),
            TrackItem(id: "sp4", title: "Second Floor", artist: "Hollis Grey", album: "Rooms", duration: 199, artworkID: MockArtwork.id(.split)),
        ]
    }

    static var files: [TrackItem] {
        [
            TrackItem(id: "f1", title: "Dawn Chorus", artist: "Field recordings", album: "Garden, May", duration: 612, artworkID: nil, format: "FLAC · 24-bit"),
            TrackItem(id: "f2", title: "Rehearsal take 3", artist: "Kitchen band", album: "Demos", duration: 184, artworkID: nil, format: "WAV · 16-bit"),
            TrackItem(id: "f3", title: "Piano in the hall", artist: "Kitchen band", album: "Demos", duration: 241, artworkID: nil, format: "ALAC"),
        ]
    }

    static let apps: [CapturableApp] = [
        CapturableApp(id: "com.apple.Safari", name: "Safari", isMakingSound: true),
        CapturableApp(id: "com.apple.podcasts", name: "Podcasts", isMakingSound: true),
        CapturableApp(id: "com.apple.TV", name: "TV", isMakingSound: false),
        CapturableApp(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player", isMakingSound: false),
        CapturableApp(id: "com.apple.FaceTime", name: "FaceTime", isMakingSound: false),
    ].map { app in
        var app = app
        app.iconArtworkID = MockArtwork.iconID(app.id)
        return app
    }

    static func nowPlaying(_ t: TrackItem) -> NowPlayingInfo {
        NowPlayingInfo(title: t.title, artist: t.artist, album: t.album, artworkID: t.artworkID, duration: t.duration, trackID: t.id)
    }

    static func nowPlaying(app: CapturableApp) -> NowPlayingInfo {
        NowPlayingInfo(title: app.name, artist: "Capturing app audio", album: nil,
                       artworkID: MockArtwork.iconID(app.id), artworkIsIcon: true, duration: nil)
    }

    @MainActor static var artwork: [ArtworkID: Data] { MockArtwork.store(appBundleIDs: apps.map(\.id) + ["com.spotify.client"]) }

    /// Which songs each playlist holds, by index into `songs`.
    static let playlistSongs: [String: [Int]] = [
        "p1": [0, 4, 2, 7], "p2": [1, 6, 8, 3, 5], "p3": [9, 2, 0], "p4": [3, 5, 1, 7, 9, 4], "p5": [2, 7, 8],
    ]

    static var playlists: [PlaylistItem] {
        playlistsWithoutCounts.map { p in
            var p = p
            p.trackCount = playlistSongs[p.id]?.count ?? 0
            return p
        }
    }

    /// A fresh house: everything off, nothing playing.
    static var baseState: HubState {
        var s = HubState()
        s.speakers = speakers
        s.masterVolume = 0.62
        s.capture = CaptureStatus(apps: apps)
        s.spotify = .running
        s.pins = pins
        s.health = HubHealth(permissions: .allGranted, extraIssues: [])
        return s
    }

    /// The lists behind the paged queries.
    static var baseContent: MockContent {
        let songs = songs
        return MockContent(
            songs: songs, playlists: playlists,
            playlistTracks: playlistSongs.mapValues { $0.map { songs[$0] } },
            upNext: upNext, files: files, spotifyHistory: Array(spotifyTracks.dropFirst()))
    }

    /// Up Next after the first song: the rest of a playlist with a Spotify song played next.
    static var upNext: [QueueItem] {
        let songs = songs
        return [
            QueueItem(id: "q1", source: .spotify, track: spotifyTracks[1]),
            QueueItem(id: "q2", source: .appleMusic, track: songs[4]),
            QueueItem(id: "q3", source: .appleMusic, track: songs[2]),
            QueueItem(id: "q4", source: .appleMusic, track: songs[7]),
            QueueItem(id: "q5", source: .spotify, track: spotifyTracks[3]),
            QueueItem(id: "q6", source: .files, track: files[2]),
        ]
    }

    /// Pinned playlists: two from Apple Music and one Spotify share link.
    static var pins: [PinnedPlaylist] {
        [
            PinnedPlaylist(id: "p1", source: .appleMusic, name: "Sunday morning", artworkID: MockArtwork.id(.sunOverWater),
                           trackCount: playlistSongs["p1"]?.count),
            PinnedPlaylist(id: "spotify:playlist:0mockFridayNightMix01", source: .spotify, name: "Friday night mix",
                           artworkID: MockArtwork.id(.horizon)),
            PinnedPlaylist(id: "p4", source: .appleMusic, name: "Dinner party", artworkID: MockArtwork.id(.ring),
                           trackCount: playlistSongs["p4"]?.count),
        ]
    }
}

/// Everything the mock serves through paged queries rather than state.
struct MockContent: Equatable, Sendable {
    var songs: [TrackItem] = []
    var playlists: [PlaylistItem] = []
    var playlistTracks: [String: [TrackItem]] = [:]
    var upNext: [QueueItem] = []
    var files: [TrackItem] = []
    /// Tracks seen from Spotify this session, newest first.
    var spotifyHistory: [TrackItem] = []

    static let empty = MockContent()

    /// What a `HubModel` shows before it has fetched anything: for snapshots and previews.
    var preload: HubModel.Preload {
        HubModel.Preload(songs: songs, playlists: playlists, upNext: upNext, files: files, spotifyHistory: spotifyHistory)
    }
}

// MARK: - Fixed scenes for snapshots and previews

enum MockScene: String, CaseIterable, Sendable {
    case idle, appleMusic, upNext, spotify, appPicker, firstRun, localNetworkDenied

    var browsing: SourceKind {
        switch self {
        case .idle, .appleMusic, .upNext, .firstRun, .localNetworkDenied: .appleMusic
        case .spotify: .spotify
        case .appPicker: .app
        }
    }

    var levels: StereoLevels {
        switch self {
        case .appleMusic, .upNext, .spotify, .appPicker: StereoLevels(left: 0.30, right: 0.24)
        default: .silent
        }
    }

    var content: MockContent {
        switch self {
        case .firstRun: MockContent(files: MockData.files, spotifyHistory: MockData.baseContent.spotifyHistory)
        default: MockData.baseContent
        }
    }

    var state: HubState {
        var s = MockData.baseState
        let songs = MockData.songs
        func set(_ id: SpeakerID, _ state: SpeakerState) {
            guard let i = s.speakers.firstIndex(where: { $0.id == id }) else { return }
            s.speakers[i].isEnabled = state != .off
            s.speakers[i].state = state
        }
        switch self {
        case .idle:
            break
        case .appleMusic, .upNext:
            s.activeSource = .appleMusic
            s.nowPlaying = MockData.nowPlaying(songs[0])
            s.transport = TransportState(isPlaying: true, position: 102, positionAsOf: .now)
            s.queue = QueueStatus(currentID: "q0", currentSource: .appleMusic, upcomingCount: MockData.upNext.count)
            set(MockData.hall, .playing)
            set(MockData.denon, .playing)
            set(MockData.mainBath, .playing)
            set(MockData.macBook, .playing)
            set(MockData.masterBath, .connecting)
            set(MockData.patio, .failed(reason: "Not responding"))
        case .spotify:
            s.activeSource = .spotify
            s.nowPlaying = MockData.nowPlaying(MockData.spotifyTracks[0])
            s.transport = TransportState(isPlaying: true, position: 64, positionAsOf: .now)
            set(MockData.hall, .playing)
            set(MockData.denon, .playing)
            set(MockData.jbl, .playing)
        case .appPicker:
            s.activeSource = .app
            s.capture.capturedAppID = "com.apple.podcasts"
            s.nowPlaying = MockData.nowPlaying(app: MockData.apps[1])
            s.transport = TransportState(isPlaying: true, position: 0, positionAsOf: .now, canSkip: false, canSeek: false)
            set(MockData.denon, .playing)
            set(MockData.mainBath, .playing)
            set(MockData.masterBath, .playing)
        case .firstRun:
            // The first second after launch: nothing found yet, Apple Music not yet allowed.
            s.speakers = []
            s.isDiscovering = true
            s.health = HubHealth(permissions: PermissionSet(localNetwork: .granted, audioCapture: .notDetermined,
                                                            appleMusic: .notDetermined, automation: .notDetermined),
                                 extraIssues: [])
        case .localNetworkDenied:
            // Local network refused: only this Mac's own outputs can be found.
            s.speakers = s.speakers.filter { !$0.transport.isNetwork }
            var p = PermissionSet.allGranted
            p.localNetwork = .denied
            s.health = HubHealth(permissions: p, extraIssues: [])
        }
        return s
    }
}
