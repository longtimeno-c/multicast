import Foundation
import Testing
@testable import MulticastHubModel

@Suite struct LockScreenPlaybackTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func song(duration: TimeInterval? = 240, album: String? = "An Album") -> NowPlayingInfo {
        NowPlayingInfo(title: "A Song", artist: "An Artist", album: album, artworkID: "cover.1", duration: duration, trackID: "t1")
    }

    private func playing(at position: TimeInterval = 30, canSkip: Bool = true, canSeek: Bool = true) -> TransportState {
        TransportState(isPlaying: true, position: position, positionAsOf: t0, canSkip: canSkip, canSeek: canSeek)
    }

    @Test func nothingPlayingClearsTheControls() {
        #expect(LockScreenPlayback(state: HubState(), at: t0) == nil)
        #expect(LockScreenPlayback(nowPlaying: song(), transport: playing(), source: nil, at: t0) == nil)
        #expect(LockScreenPlayback(nowPlaying: nil, transport: playing(), source: .appleMusic, at: t0) == nil)
    }

    @Test func aPlayingSongCarriesItsFieldsAndExtrapolatedPosition() throws {
        let state = HubState(activeSource: .appleMusic, nowPlaying: song(), transport: playing(at: 30))
        let p = try #require(LockScreenPlayback(state: state, at: t0.addingTimeInterval(12)))
        #expect(p.title == "A Song")
        #expect(p.artist == "An Artist")
        #expect(p.album == "An Album")
        #expect(p.artworkID == "cover.1")
        #expect(p.identity == "t1")
        #expect(p.duration == 240)
        #expect(p.elapsed == 42)
        #expect(p.rate == 1)
        #expect(p.isPlaying)
        #expect(!p.isLive)
        #expect(p.commands == .init(playPause: true, next: true, previous: true, seek: true))
    }

    @Test func aPausedSongStaysWhereItStopped() throws {
        let transport = TransportState(isPlaying: false, position: 75, positionAsOf: t0)
        let p = try #require(LockScreenPlayback(nowPlaying: song(), transport: transport, source: .spotify, at: t0.addingTimeInterval(500)))
        #expect(p.elapsed == 75)
        #expect(p.rate == 0)
        #expect(!p.isPlaying)
        #expect(p.elapsed(at: t0.addingTimeInterval(900)) == 75)
    }

    @Test func positionIsKeptInsideTheSong() throws {
        let late = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(at: 230), source: .files, at: t0.addingTimeInterval(60)))
        #expect(late.elapsed == 240)
        let negative = TransportState(isPlaying: false, position: -3, positionAsOf: t0)
        let early = try #require(LockScreenPlayback(nowPlaying: song(), transport: negative, source: .files, at: t0))
        #expect(early.elapsed == 0)
    }

    @Test func emptyArtistAndAlbumAreLeftOut() throws {
        let info = NowPlayingInfo(title: "Only A Title", artist: "", album: "", duration: 100)
        let p = try #require(LockScreenPlayback(nowPlaying: info, transport: playing(), source: .files, at: t0))
        #expect(p.artist == nil)
        #expect(p.album == nil)
        #expect(p.artworkID == nil)
    }

    @Test func aCapturedAppIsLiveWithOnlyPlayPause() throws {
        for source in [SourceKind.app, .macOutput] {
            // Even if a length slipped through, a capture has no position to show or seek.
            let p = try #require(LockScreenPlayback(nowPlaying: song(duration: 200), transport: playing(), source: source, at: t0))
            #expect(p.isLive)
            #expect(p.duration == nil)
            #expect(p.elapsed == nil)
            #expect(p.commands == .init(playPause: true))
            #expect(p.command(for: .next) == nil)
            #expect(p.command(for: .previous) == nil)
            #expect(p.command(for: .seek(position: 10)) == nil)
            #expect(p.command(for: .pause) == .pause)
        }
    }

    @Test func aSongWithoutALengthHasNoScrubber() throws {
        for duration in [nil, 0 as TimeInterval?] {
            let p = try #require(LockScreenPlayback(nowPlaying: song(duration: duration), transport: playing(), source: .spotify, at: t0))
            #expect(p.isLive)
            #expect(!p.commands.seek)
            #expect(p.commands.next)
        }
    }

    @Test func theHubsTransportFlagsTurnControlsOff() throws {
        let p = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(canSkip: false, canSeek: false),
                                                source: .appleMusic, at: t0))
        #expect(p.commands == .init(playPause: true))
        #expect(p.duration == 240)   // still shown, just not draggable
        #expect(p.command(for: .seek(position: 10)) == nil)
    }

    @Test func actionsBecomeHubCommands() throws {
        let on = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(), source: .appleMusic, at: t0))
        #expect(on.command(for: .pause) == .pause)
        #expect(on.command(for: .play) == nil)
        #expect(on.command(for: .togglePlayPause) == .pause)
        #expect(on.command(for: .next) == .next)
        #expect(on.command(for: .previous) == .previous)
        #expect(on.command(for: .seek(position: 100)) == .seek(position: 100))
        #expect(on.command(for: .seek(position: 999)) == .seek(position: 240))
        #expect(on.command(for: .seek(position: -5)) == .seek(position: 0))
        #expect(on.command(for: .seek(position: .nan)) == nil)

        let off = try #require(LockScreenPlayback(nowPlaying: song(), transport: TransportState(positionAsOf: t0),
                                                  source: .appleMusic, at: t0))
        #expect(off.command(for: .play) == .play)
        #expect(off.command(for: .pause) == nil)
        #expect(off.command(for: .togglePlayPause) == .play)
    }

    @Test func aLaterReadingOfTheSameStateNeedsNoRepublish() throws {
        let transport = playing(at: 30)
        let first = try #require(LockScreenPlayback(nowPlaying: song(), transport: transport, source: .appleMusic, at: t0))
        let later = try #require(LockScreenPlayback(nowPlaying: song(), transport: transport, source: .appleMusic,
                                                    at: t0.addingTimeInterval(90)))
        #expect(later.continues(first))

        // A seek, a pause, another song or a changed control all need publishing.
        let sought = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(at: 120), source: .appleMusic,
                                                     at: t0.addingTimeInterval(1)))
        #expect(!sought.continues(first))
        let paused = try #require(LockScreenPlayback(nowPlaying: song(),
                                                     transport: TransportState(isPlaying: false, position: 31, positionAsOf: t0),
                                                     source: .appleMusic, at: t0.addingTimeInterval(1)))
        #expect(!paused.continues(first))
        var other = song()
        other.trackID = "t2"
        let next = try #require(LockScreenPlayback(nowPlaying: other, transport: transport, source: .appleMusic, at: t0))
        #expect(!next.continues(first))
        let locked = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(at: 30, canSeek: false),
                                                     source: .appleMusic, at: t0))
        #expect(!locked.continues(first))

        // Small clock re-basing of the same position is not a seek.
        let nudged = try #require(LockScreenPlayback(nowPlaying: song(), transport: playing(at: 30.3), source: .appleMusic, at: t0))
        #expect(nudged.continues(first))
    }

    @Test func liveItemsCompareWithoutAPosition() throws {
        let a = try #require(LockScreenPlayback(nowPlaying: song(duration: nil), transport: playing(), source: .app, at: t0))
        let b = try #require(LockScreenPlayback(nowPlaying: song(duration: nil), transport: playing(at: 400), source: .app,
                                                at: t0.addingTimeInterval(50)))
        #expect(b.continues(a))
    }
}
