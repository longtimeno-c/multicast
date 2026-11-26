#if os(macOS)
import Carbon
import Foundation
import Testing
@testable import MulticastHub
import MulticastSources

@Suite("Spotify raw Apple Events")
struct SpotifyEventsTests {
    private func enumDesc(_ s: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(enumCode: SpotifyEvents.fourCC(s))
    }

    @Test func readsAPlayingTrack() {
        let track = NSAppleEventDescriptor.record()
        track.setDescriptor(NSAppleEventDescriptor(string: "Glass Harbour"), forKeyword: SpotifyEvents.Code.name)
        track.setDescriptor(NSAppleEventDescriptor(string: "Lantern Fold"), forKeyword: SpotifyEvents.Code.artist)
        track.setDescriptor(NSAppleEventDescriptor(string: "Quiet Rooms"), forKeyword: SpotifyEvents.Code.album)
        track.setDescriptor(NSAppleEventDescriptor(int32: 215_000), forKeyword: SpotifyEvents.Code.duration)
        track.setDescriptor(NSAppleEventDescriptor(string: "spotify:track:abc123"), forKeyword: SpotifyEvents.Code.id)
        track.setDescriptor(NSAppleEventDescriptor(string: "https://example.com/cover.jpg"), forKeyword: SpotifyEvents.Code.artworkURL)
        let at = Date(timeIntervalSince1970: 1000)
        let np = SpotifyEvents.nowPlaying(state: enumDesc("kPSP"), position: NSAppleEventDescriptor(double: 12.5),
                                          track: track, sampledAt: at)
        #expect(np.state == .playing)
        #expect(np.title == "Glass Harbour")
        #expect(np.artist == "Lantern Fold")
        #expect(np.album == "Quiet Rooms")
        #expect(np.duration == 215)  // milliseconds from Spotify
        #expect(np.position == 12.5)
        #expect(np.trackID == "spotify:track:abc123")
        #expect(np.artworkURL == URL(string: "https://example.com/cover.jpg"))
        #expect(np.sampledAt == at)
    }

    @Test func statesAndMissingTrack() {
        #expect(SpotifyEvents.playerState(enumDesc("kPSp")) == .paused)
        #expect(SpotifyEvents.playerState(enumDesc("kPSS")) == .stopped)
        #expect(SpotifyEvents.playerState(enumDesc("zzzz")) == .unknown)
        let np = SpotifyEvents.nowPlaying(state: enumDesc("kPSS"), position: nil, track: nil, sampledAt: .distantPast)
        #expect(!np.hasTrack)
        #expect(np.position == nil)
    }

    @Test func errorCodesMapLikeTheScripts() {
        #expect(SpotifyEvents.mapError(-1743) == .automationDenied)
        #expect(SpotifyEvents.mapError(-1744) == .automationConsentRequired)
        #expect(SpotifyEvents.mapError(-600) == .notRunning)
    }

    /// Reads (never controls) the real Spotify: `MULTICAST_LIVE_SPOTIFY=1 swift test --filter SpotifyEvents`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE_SPOTIFY"] == "1"))
    func readsTheRealSpotify() throws {
        let started = Date()
        let np = try SpotifyEvents().nowPlaying()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("live Spotify read in \(ms) ms: state=\(np?.state.rawValue ?? "nil") hasTrack=\(np?.hasTrack ?? false) duration=\(np?.duration ?? -1) position=\(np?.position ?? -1)")
        #expect(np?.hasTrack == true)
    }
}
#endif
