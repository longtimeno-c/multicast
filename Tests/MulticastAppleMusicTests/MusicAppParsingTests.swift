#if os(macOS)
import AppKit
import Carbon
import Foundation
import MulticastHubModel
import MulticastSources
import Testing
@testable import MulticastAppleMusic

// Fixtures are hand-built Apple Event descriptors shaped like the Music app's replies to
// `MusicAppScript`, with made-up ids and names.

private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let l = NSAppleEventDescriptor.list()
    for (i, d) in items.enumerated() { l.insert(d, at: i + 1) }
    return l
}
private func s(_ v: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: v) }
private func r(_ v: Double) -> NSAppleEventDescriptor { NSAppleEventDescriptor(double: v) }
private func i(_ v: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: v) }
private func b(_ v: Bool) -> NSAppleEventDescriptor { NSAppleEventDescriptor(boolean: v) }
private let missing = NSAppleEventDescriptor(typeCode: DescType(cMissingValue))

private func columns(_ ids: [NSAppleEventDescriptor], _ names: [NSAppleEventDescriptor], _ artists: [NSAppleEventDescriptor],
                     _ albums: [NSAppleEventDescriptor], _ durations: [NSAppleEventDescriptor]) -> [NSAppleEventDescriptor] {
    [list(ids), list(names), list(artists), list(albums), list(durations)]
}

@Suite struct MusicAppParsingTests {
    @Test func parsesTrackColumnsWithMissingValuesAndMixedNumberTypes() throws {
        let d = list(columns(
            [s("0A1B2C3D4E5F6071"), s("0A1B2C3D4E5F6072"), missing, s("0A1B2C3D4E5F6074")],
            [s("Low Tide"), missing, s("Ghost Row"), s("Lantern")],
            [s("Paper Comets"), s("Aster Field"), s("x"), missing],
            [s("Shore"), missing, s("x"), s("Night Bus")],
            [r(201.4), i(95), r(1), s("187,5")]))
        let tracks = try MusicAppParsing.trackColumns(d)
        #expect(tracks.map(\.id) == ["0A1B2C3D4E5F6071", "0A1B2C3D4E5F6072", "0A1B2C3D4E5F6074"]) // row without id skipped
        #expect(tracks[0] == TrackItem(id: "0A1B2C3D4E5F6071", title: "Low Tide", artist: "Paper Comets", album: "Shore",
                                       duration: 201.4, artworkID: "am.track.0A1B2C3D4E5F6071"))
        #expect(tracks[1].title == "Unknown")
        #expect(tracks[1].album == "")
        #expect(tracks[1].duration == 95)
        #expect(tracks[2].artist == "")
        #expect(tracks[2].duration == 187.5)
    }

    @Test func emptyLibraryParses() throws {
        #expect(try MusicAppParsing.trackColumns(list(columns([], [], [], [], []))).isEmpty)
    }

    @Test func rejectsMalformedColumns() {
        #expect(throws: MusicAppParsing.ParseError.self) {
            try MusicAppParsing.trackColumns(list(columns([s("01")], [], [s("a")], [s("b")], [r(1)])))
        }
        #expect(throws: MusicAppParsing.ParseError.self) {
            try MusicAppParsing.trackColumns(list([list([]), list([])]))
        }
        #expect(throws: MusicAppParsing.ParseError.self) {
            try MusicAppParsing.trackColumns(s("OK"))
        }
    }

    @Test func parsesPlaylistsWithFirstTrackArtwork() throws {
        let d = list([
            list([s("1111AAAA2222BBBB"), s("Morning Drive"), i(12), s("0A1B2C3D4E5F6071")]),
            list([s("3333CCCC4444DDDD"), s(""), i(0), s("")]),
            list([missing, s("No id"), i(3), s("")]),
        ])
        let p = try MusicAppParsing.playlists(d)
        #expect(p == [
            PlaylistItem(id: "1111AAAA2222BBBB", name: "Morning Drive", trackCount: 12, artworkID: "am.track.0A1B2C3D4E5F6071"),
            PlaylistItem(id: "3333CCCC4444DDDD", name: "Untitled Playlist", trackCount: 0, artworkID: nil),
        ])
        #expect(throws: MusicAppParsing.ParseError.self) { try MusicAppParsing.playlists(list([list([s("1")])])) }
    }

    @Test func parsesPlayingState() throws {
        let d = list([s("playing"), b(true), i(35), r(42.25),
                      list([s("0A1B2C3D4E5F6071"), s("Low Tide"), s("Paper Comets"), s("Shore"), r(201.4)])])
        let st = try MusicAppParsing.playerState(d)
        #expect(st.state == .playing)
        #expect(st.shuffle)
        #expect(st.volume == 35)
        #expect(st.position == 42.25)
        #expect(st.track == .init(persistentID: "0A1B2C3D4E5F6071", title: "Low Tide", artist: "Paper Comets", album: "Shore", duration: 201.4))

        let at = Date(timeIntervalSinceReferenceDate: 500)
        let snap = MusicAppParsing.snapshot(st, sampledAt: at, upNextRevision: 3, libraryRevision: 7)
        #expect(snap.nowPlaying == NowPlayingInfo(title: "Low Tide", artist: "Paper Comets", album: "Shore",
                                                  artworkID: "am.track.0A1B2C3D4E5F6071", duration: 201.4, trackID: "0A1B2C3D4E5F6071"))
        #expect(snap.transport == TransportState(isPlaying: true, position: 42.25, positionAsOf: at, canSkip: true, canSeek: true))
        #expect(snap.upNextRevision == 3 && snap.libraryRevision == 7)
    }

    @Test func parsesStoppedStateAndRawEnumCodes() throws {
        let stopped = try MusicAppParsing.playerState(list([s("stopped"), b(false), i(100), missing, list([])]))
        #expect(stopped.state == .stopped)
        #expect(stopped.position == nil)
        #expect(stopped.track == nil)
        let snap = MusicAppParsing.snapshot(stopped, sampledAt: .distantPast, upNextRevision: 0, libraryRevision: 0)
        #expect(snap.nowPlaying == nil)
        #expect(!snap.transport.isPlaying && !snap.transport.canSkip && !snap.transport.canSeek)

        // Terminology-less replies carry the four-char code; a stream has no duration.
        let paused = try MusicAppParsing.playerState(list([s("kPSp"), b(false), i(50), r(3),
                                                           list([s("0A"), s("Radio"), s(""), s(""), i(0)])]))
        #expect(paused.state == .paused)
        #expect(paused.track?.duration == nil)
        #expect(!MusicAppParsing.snapshot(paused, sampledAt: .distantPast, upNextRevision: 0, libraryRevision: 0).transport.canSeek)
    }

    @Test func parsesUpNextMarkersAndTracks() throws {
        #expect(try MusicAppParsing.upNext(list([s("stopped")])) == .stopped)
        #expect(try MusicAppParsing.upNext(list([s("shuffled")])) == .shuffled)
        #expect(try MusicAppParsing.upNext(list([s("unknown")])) == .unknown)
        let ok = list([s("ok"), i(9)] + columns([s("0B"), s("0C")], [s("One"), s("Two")], [s("A"), s("B")], [s("X"), s("Y")], [r(60), r(61)]))
        guard case .tracks(let items, let remaining) = try MusicAppParsing.upNext(ok) else {
            Issue.record("expected tracks"); return
        }
        #expect(items.map(\.id) == ["0B", "0C"])
        #expect(remaining == 9)
        #expect(throws: MusicAppParsing.ParseError.self) { try MusicAppParsing.upNext(list([s("weird")])) }
        #expect(throws: MusicAppParsing.ParseError.self) { try MusicAppParsing.upNext(list([s("ok"), i(1)])) }
    }

    @Test func mapsAppleScriptErrorsToHubErrors() {
        #expect(MusicAppParsing.commandError(code: -1743, message: "").code == .permissionMissing)
        #expect(MusicAppParsing.commandError(code: -1744, message: "").code == .permissionMissing)
        #expect(MusicAppParsing.commandError(code: -1728, message: "Can't get track").code == .notFound)
        #expect(MusicAppParsing.commandError(code: -1719, message: "").code == .notFound)
        #expect(MusicAppParsing.commandError(code: -600, message: "").code == .unavailable)
        #expect(MusicAppParsing.commandError(code: -1712, message: "").code == .failed)
        #expect(MusicAppParsing.commandError(code: -2700, message: "Boom") == HubCommandError(.failed, "Boom"))
    }

    @available(macOS 14.2, *)
    @Test func refusesIDsThatCannotBePersistentIDs() {
        #expect(throws: Never.self) { try MusicAppPlayer.validate(id: "0A1B2C3D4E5F6071") }
        for bad in ["", "0A\" & quit app \"Music", "zz", "0A 1B", String(repeating: "F", count: 40)] {
            #expect(throws: HubCommandError.self) { try MusicAppPlayer.validate(id: bad) }
        }
    }

    /// The real script must compile against the installed Music app's terminology. Compiling
    /// reads Music's scripting dictionary; it must not launch Music.
    @Test func scriptCompilesWithoutLaunchingMusic() throws {
        try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil, "Music not installed")
        let wasRunning = MediaAppController.isRunning(.music)
        let script = try #require(NSAppleScript(source: MusicAppScript.source))
        var err: NSDictionary?
        let compiled = script.compileAndReturnError(&err)
        #expect(compiled, "\(String(describing: err))")
        if !wasRunning { #expect(!MediaAppController.isRunning(.music)) }
    }
}
#endif
