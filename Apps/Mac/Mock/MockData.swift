import Foundation

/// The house this will run in, and a small believable library. Artists and titles are made up.
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
                        model: nil, address: "192.168.1.60", isEnabled: false, volume: 0.45, state: .off, syncTrimMs: 0),
            SpeakerItem(id: hall, name: "Hall Sonos", transport: .airPlay2, glyph: .smartSpeaker,
                        model: "Sonos One", address: "192.168.1.53", isEnabled: false, volume: 0.55, state: .off, syncTrimMs: 0),
            SpeakerItem(id: mainBath, name: "Main Bedroom", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.168.1.42", isEnabled: false, volume: 0.35, state: .off, syncTrimMs: 40),
            SpeakerItem(id: masterBath, name: "Master Bedroom", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.168.1.41", isEnabled: false, volume: 0.40, state: .off, syncTrimMs: 40),
            SpeakerItem(id: patio, name: "Patio", transport: .airPlay1, glyph: .airportExpress,
                        model: nil, address: "192.168.1.47", isEnabled: false, volume: 0.70, state: .off, syncTrimMs: 0),
            SpeakerItem(id: macBook, name: "MacBook Air Speakers", transport: .builtIn, glyph: .laptop,
                        model: nil, address: "BuiltInSpeakerDevice", isEnabled: false, volume: 0.30, state: .off, syncTrimMs: 0),
            SpeakerItem(id: jbl, name: "JBL Flip 6", transport: .bluetooth, glyph: .portable,
                        model: nil, address: "4C:87:5D:2A:91:0E", isEnabled: false, volume: 0.60, state: .off, syncTrimMs: -180),
        ]
    }

    static var songs: [TrackItem] {
        [
            TrackItem(id: "s1", title: "Slow Weather", artist: "Juniper Hale", album: "Tidewater", duration: 252, artwork: MockArtwork.id(.sunOverWater)),
            TrackItem(id: "s2", title: "Paper Lanterns", artist: "The Ostrava Set", album: "Night Market", duration: 218, artwork: MockArtwork.id(.dots)),
            TrackItem(id: "s3", title: "Halcyon Drive", artist: "Mara Quell", album: "Halcyon", duration: 301, artwork: MockArtwork.id(.arcs)),
            TrackItem(id: "s4", title: "Low Orbit", artist: "Fen & Arlo", album: "Low Orbit", duration: 234, artwork: MockArtwork.id(.ring)),
            TrackItem(id: "s5", title: "Copper Light", artist: "Juniper Hale", album: "Tidewater", duration: 280, artwork: MockArtwork.id(.sunOverWater)),
            TrackItem(id: "s6", title: "Glasshouse", artist: "Kito Marr", album: "Glasshouse", duration: 201, artwork: MockArtwork.id(.bands)),
            TrackItem(id: "s7", title: "Northbound", artist: "The Ostrava Set", album: "Night Market", duration: 245, artwork: MockArtwork.id(.dots)),
            TrackItem(id: "s8", title: "Small Hours", artist: "Mara Quell", album: "Halcyon", duration: 227, artwork: MockArtwork.id(.arcs)),
            TrackItem(id: "s9", title: "Field Day", artist: "Odile Brandt", album: "Primary", duration: 196, artwork: MockArtwork.id(.split)),
            TrackItem(id: "s10", title: "Still Life With Radio", artist: "Kito Marr", album: "Glasshouse", duration: 263, artwork: MockArtwork.id(.bands)),
        ]
    }

    static var playlists: [PlaylistItem] {
        [
            PlaylistItem(id: "p1", name: "Sunday morning", trackCount: 24, artwork: MockArtwork.id(.sunOverWater)),
            PlaylistItem(id: "p2", name: "Kitchen", trackCount: 58, artwork: MockArtwork.id(.dots)),
            PlaylistItem(id: "p3", name: "Hall", trackCount: 41, artwork: MockArtwork.id(.stack)),
            PlaylistItem(id: "p4", name: "Dinner party", trackCount: 33, artwork: MockArtwork.id(.ring)),
            PlaylistItem(id: "p5", name: "Garden", trackCount: 19, artwork: MockArtwork.id(.arcs)),
        ]
    }

    static var spotifyTracks: [TrackItem] {
        [
            TrackItem(id: "sp1", title: "Evening Tide", artist: "Sola Wren", album: "Coastlines", duration: 238, artwork: MockArtwork.id(.horizon)),
            TrackItem(id: "sp2", title: "Waystation", artist: "Pelle Ash", album: "Waystation", duration: 212, artwork: MockArtwork.id(.stack)),
            TrackItem(id: "sp3", title: "Brightwater", artist: "Sola Wren", album: "Coastlines", duration: 255, artwork: MockArtwork.id(.horizon)),
            TrackItem(id: "sp4", title: "Second Floor", artist: "Hollis Grey", album: "Rooms", duration: 199, artwork: MockArtwork.id(.split)),
        ]
    }

    static var files: [TrackItem] {
        [
            TrackItem(id: "f1", title: "Dawn Chorus", artist: "Field recordings", album: "Garden, May", duration: 612, artwork: nil, format: "FLAC · 24-bit"),
            TrackItem(id: "f2", title: "Rehearsal take 3", artist: "Kitchen band", album: "Demos", duration: 184, artwork: nil, format: "WAV · 16-bit"),
            TrackItem(id: "f3", title: "Piano in the hall", artist: "Kitchen band", album: "Demos", duration: 241, artwork: nil, format: "ALAC"),
        ]
    }

    static let apps: [CapturableApp] = [
        CapturableApp(id: "com.apple.Safari", name: "Safari", isMakingSound: true),
        CapturableApp(id: "com.apple.podcasts", name: "Podcasts", isMakingSound: true),
        CapturableApp(id: "com.apple.TV", name: "TV", isMakingSound: false),
        CapturableApp(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player", isMakingSound: false),
        CapturableApp(id: "com.apple.FaceTime", name: "FaceTime", isMakingSound: false),
    ]

    static func nowPlaying(_ t: TrackItem) -> NowPlayingInfo {
        NowPlayingInfo(title: t.title, artist: t.artist, album: t.album, artwork: t.artwork, duration: t.duration, trackID: t.id)
    }

    static func nowPlaying(app: CapturableApp) -> NowPlayingInfo {
        NowPlayingInfo(title: app.name, artist: "Capturing app audio", album: nil,
                       artwork: MockArtwork.iconID(app.id), artworkIsIcon: true, duration: nil)
    }

    @MainActor static var artwork: [ArtworkID: Data] { MockArtwork.store(appBundleIDs: apps.map(\.id) + ["com.spotify.client"]) }

    static let grantedEverything: [HubPermission: PermissionStatus] =
        [.localNetwork: .granted, .appleMusic: .granted, .audioCapture: .granted]

    /// A fresh house: everything off, nothing playing.
    static var baseState: HubState {
        var s = HubState()
        s.speakers.speakers = speakers
        s.speakers.masterVolume = 0.62
        s.sources.library = LibrarySnapshot(songs: songs, playlists: playlists, upNext: Array(songs[1...4]))
        s.sources.files = files
        s.sources.capturableApps = apps
        s.sources.spotify = .running
        s.sources.spotifyHistory = Array(spotifyTracks.dropFirst())
        s.status.permissions = grantedEverything
        return s
    }
}

// MARK: - Fixed scenes for snapshots and previews

enum MockScene: String, CaseIterable {
    case idle, appleMusic, spotify, appPicker, firstRun, localNetworkDenied

    var browsing: SourceKind {
        switch self {
        case .idle, .appleMusic, .firstRun, .localNetworkDenied: .appleMusic
        case .spotify: .spotify
        case .appPicker: .app
        }
    }

    var levels: StereoLevels {
        switch self {
        case .appleMusic, .spotify, .appPicker: StereoLevels(left: 0.30, right: 0.24)
        default: .silent
        }
    }

    var state: HubState {
        var s = MockData.baseState
        func set(_ id: SpeakerID, _ state: SpeakerState) {
            guard let i = s.speakers.speakers.firstIndex(where: { $0.id == id }) else { return }
            s.speakers.speakers[i].isEnabled = state != .off
            s.speakers.speakers[i].state = state
        }
        switch self {
        case .idle:
            break
        case .appleMusic:
            s.playback.activeSource = .appleMusic
            s.playback.nowPlaying = MockData.nowPlaying(s.sources.library.songs[0])
            s.playback.transport = TransportState(isPlaying: true, position: 102, positionAsOf: .now)
            set(MockData.hall, .playing)
            set(MockData.denon, .playing)
            set(MockData.mainBath, .playing)
            set(MockData.macBook, .playing)
            set(MockData.masterBath, .connecting)
            set(MockData.patio, .failed(reason: "Not responding"))
        case .spotify:
            s.playback.activeSource = .spotify
            s.playback.nowPlaying = MockData.nowPlaying(MockData.spotifyTracks[0])
            s.playback.transport = TransportState(isPlaying: true, position: 64, positionAsOf: .now)
            set(MockData.hall, .playing)
            set(MockData.denon, .playing)
            set(MockData.jbl, .playing)
        case .appPicker:
            s.playback.activeSource = .app
            s.playback.capturedAppID = "com.apple.podcasts"
            s.playback.nowPlaying = MockData.nowPlaying(app: MockData.apps[1])
            s.playback.transport = TransportState(isPlaying: true, position: 0, positionAsOf: .now, canSkip: false, canSeek: false)
            set(MockData.denon, .playing)
            set(MockData.mainBath, .playing)
            set(MockData.masterBath, .playing)
        case .firstRun:
            // The first second after launch: nothing found yet, Apple Music not yet allowed.
            s.speakers.speakers = []
            s.speakers.isDiscovering = true
            s.sources.library = LibrarySnapshot()
            s.status.permissions = [.localNetwork: .granted, .appleMusic: .notDetermined, .audioCapture: .notDetermined]
        case .localNetworkDenied:
            // Local network refused: only this Mac's own outputs can be found.
            s.speakers.speakers = s.speakers.speakers.filter { !$0.transport.isNetwork }
            s.status.permissions[.localNetwork] = .denied
        }
        return s
    }
}
