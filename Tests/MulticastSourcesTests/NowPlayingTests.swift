import Foundation
import Testing
@testable import MulticastSources

@Suite struct NowPlayingTests {
    let US = "\u{1F}"

    @Test func parsesNotRunning() throws {
        #expect(try AppleScriptNowPlayingParser.parse("NOT_RUNNING", app: .spotify) == nil)
    }

    @Test func parsesStateOnly() throws {
        let np = try #require(try AppleScriptNowPlayingParser.parse("OK\(US)stopped", app: .music))
        #expect(np.state == .stopped)
        #expect(!np.hasTrack)
    }

    @Test func parsesSpotifyTrackWithMillisecondDuration() throws {
        let out = ["OK", "playing", "Song", "Artist", "Album", "215000", "12.5",
                   "https://i.scdn.co/image/abc", "spotify:track:123"].joined(separator: US)
        let np = try #require(try AppleScriptNowPlayingParser.parse(out, app: .spotify))
        #expect(np.state == .playing)
        #expect(np.title == "Song" && np.artist == "Artist" && np.album == "Album")
        #expect(np.duration == 215)
        #expect(np.position == 12.5)
        #expect(np.artworkURL?.absoluteString == "https://i.scdn.co/image/abc")
        #expect(np.trackID == "spotify:track:123")
    }

    @Test func parsesMusicTrackWithLocaleCommaAndMissingFields() throws {
        let out = ["OK", "paused", "Titel", "", "missing value", "245,317", "3,25", "", "ABCDEF0123"].joined(separator: US)
        let np = try #require(try AppleScriptNowPlayingParser.parse(out, app: .music))
        #expect(np.state == .paused)
        #expect(np.title == "Titel")
        #expect(np.artist == nil && np.album == nil)
        #expect(abs((np.duration ?? 0) - 245.317) < 1e-9)
        #expect(np.position == 3.25)
        #expect(np.artworkURL == nil)
        #expect(np.trackID == "ABCDEF0123")
    }

    @Test func numberParsing() {
        #expect(AppleScriptNowPlayingParser.number("1,234.5") == 1234.5)
        #expect(AppleScriptNowPlayingParser.number("1.234,5") == 1234.5)
        #expect(AppleScriptNowPlayingParser.number("7") == 7)
        #expect(AppleScriptNowPlayingParser.number("1.5E+2") == 150)
        #expect(AppleScriptNowPlayingParser.number("") == nil)
        #expect(AppleScriptNowPlayingParser.number("missing value") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: AppleScriptNowPlayingParser.ParseError.self) {
            try AppleScriptNowPlayingParser.parse("hello", app: .spotify)
        }
    }

    @Test func playerStateValues() {
        #expect(MediaPlayerState(scriptValue: "playing") == .playing)
        #expect(MediaPlayerState(scriptValue: "Paused\n") == .paused)
        #expect(MediaPlayerState(scriptValue: "fast forwarding") == .fastForwarding)
        #expect(MediaPlayerState(scriptValue: "kPSP") == .playing)
        #expect(MediaPlayerState(scriptValue: "kPSp") == .paused)
        #expect(MediaPlayerState(scriptValue: "???") == .unknown)
    }

    @Test func codableRoundTrip() throws {
        let np = NowPlaying(app: .music, state: .playing, title: "a", artist: "b", album: "c", duration: 10,
                            position: 1, trackID: "id", artworkURL: nil, artworkData: Data([1, 2, 3]),
                            sampledAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(np)
        let back = try JSONDecoder().decode(NowPlaying.self, from: data)
        #expect(back == np)
    }

    @Test func significantChangeIgnoresNormalProgressButCatchesSeeksAndTracks() {
        let t0 = Date(timeIntervalSince1970: 0)
        let a = NowPlaying(app: .spotify, state: .playing, title: "x", duration: 200, position: 10, trackID: "1", sampledAt: t0)
        var b = a
        b.sampledAt = t0.addingTimeInterval(5)
        b.position = 15.3
        #expect(!b.isSignificantChange(from: a))
        b.position = 40
        #expect(b.isSignificantChange(from: a))
        var c = a
        c.trackID = "2"
        #expect(c.isSignificantChange(from: a))
        var d = a
        d.state = .paused
        #expect(d.isSignificantChange(from: a))
        #expect(a.isSignificantChange(from: nil))
        // Paused: position does not advance.
        var p = a
        p.state = .paused
        var p2 = p
        p2.sampledAt = t0.addingTimeInterval(30)
        #expect(!p2.isSignificantChange(from: p))
    }

    @Test func estimatedPositionClampsToDuration() {
        let np = NowPlaying(app: .music, state: .playing, duration: 12, position: 10, sampledAt: Date(timeIntervalSince1970: 0))
        #expect(np.estimatedPosition(at: Date(timeIntervalSince1970: 1)) == 11)
        #expect(np.estimatedPosition(at: Date(timeIntervalSince1970: 100)) == 12)
    }

    #if os(macOS)
    @Test func scriptsGuardAgainstLaunching() {
        for app in MediaApp.allCases {
            let s = MediaAppController.stateScript(for: app)
            #expect(s.contains("if application id \"\(app.bundleID)\" is running then"))
            let c = MediaAppController.commandScript(for: app, command: "pause")
            #expect(c.hasPrefix("if application id \"\(app.bundleID)\" is running then"))
        }
        #expect(MediaAppController.musicArtworkScript().hasPrefix("if application id \"com.apple.Music\" is running"))
    }

    @Test func scriptErrorMapping() {
        func map(_ code: Int) -> MediaAppController.MediaControlError {
            MediaAppController.mapScriptError([NSAppleScript.errorNumber: NSNumber(value: code),
                                               NSAppleScript.errorMessage: "m"] as NSDictionary)
        }
        #expect(map(-1743) == .automationDenied)
        #expect(map(-1744) == .automationConsentRequired)
        #expect(map(-600) == .notRunning)
        #expect(map(-1728) == .scriptError(code: -1728, message: "m"))
        #expect(MediaAppController.mapPermission(0) == .granted)
        #expect(MediaAppController.mapPermission(-1743) == .denied)
        #expect(MediaAppController.mapPermission(-1744) == .notDetermined)
        #expect(MediaAppController.mapPermission(-600) == .appNotRunning)
    }
    #endif
}
