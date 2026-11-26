import Foundation
import Testing
import MulticastHubModel
@testable import MulticastHub

@Suite struct PlayQueueTests {
    static func t(_ id: String) -> TrackItem { TrackItem(id: id, title: id, artist: "", album: "", duration: 200) }
    let list = ["a", "b", "c", "d"].map(PlayQueueTests.t)

    struct FixedRNG: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    @Test func contextExpansionQueuesWhatFollows() {
        var q = PlayQueue()
        let ok = q.play(list, source: .appleMusic, startingAt: "b")
        #expect(ok)
        #expect(q.current?.track.id == "b")
        #expect(q.upcoming.map(\.track.id) == ["c", "d"])
        let missing = q.play(list, source: .appleMusic, startingAt: "zz")
        #expect(!missing)
        #expect(q.current?.track.id == "b")
    }

    @Test func shuffledPlaylistKeepsEverySong() {
        var q = PlayQueue()
        var rng = FixedRNG()
        q.play(list, source: .appleMusic, shuffled: true, using: &rng)
        let all = [q.current!] + q.upcoming
        #expect(Set(all.map(\.track.id)) == Set(["a", "b", "c", "d"]))
        q.play(list, source: .appleMusic, shuffled: false, using: &rng)
        #expect(q.current?.track.id == "a")
    }

    @Test func shuffleAndPutBack() {
        var q = PlayQueue()
        var rng = FixedRNG()
        let many = (1...12).map { Self.t("s\($0)") }
        q.play(many, source: .appleMusic, startingAt: "s1")
        let ordered = q.upcoming.map(\.track.id)
        q.setShuffle(true, using: &rng)
        #expect(q.isShuffled && q.upcoming.map(\.track.id) != ordered && Set(q.upcoming.map(\.track.id)) == Set(ordered))
        q.insert([Self.t("next")], source: .spotify, at: .next)
        q.insert([Self.t("last")], source: .files, at: .last)
        q.advance()   // plays "next"
        q.setShuffle(false, using: &rng)
        #expect(!q.isShuffled)
        #expect(q.upcoming.map(\.track.id) == ordered + ["last"])
        // A shuffled playlist puts back into playlist order.
        q.play(many, source: .appleMusic, shuffled: true, using: &rng)
        #expect(q.isShuffled)
        let first = q.current!.track.id
        q.setShuffle(false, using: &rng)
        #expect(q.upcoming.map(\.track.id) == many.map(\.id).filter { $0 != first })
        q.play(many, source: .appleMusic, startingAt: "s3")
        #expect(!q.isShuffled)
    }

    @Test func insertNextAndLastMixSources() {
        var q = PlayQueue()
        q.play(list, source: .appleMusic, startingAt: "c")
        q.insert([Self.t("spotify:track:x")], source: .spotify, at: .next)
        q.insert([Self.t("f1")], source: .files, at: .last)
        #expect(q.upcoming.map(\.track.id) == ["spotify:track:x", "d", "f1"])
        #expect(q.upcoming.map(\.source) == [.spotify, .appleMusic, .files])
        #expect(Set((q.upcoming + [q.current!]).map(\.id)).count == 4)
    }

    @Test func advanceGoBackAndEnd() {
        var q = PlayQueue()
        q.play(list, source: .appleMusic, startingAt: "c")
        let n = q.advance()
        #expect(n?.track.id == "d")
        let back = q.goBack()
        #expect(back?.track.id == "c")
        #expect(q.upcoming.map(\.track.id) == ["d"])
        q.advance()
        let end = q.advance()
        #expect(end == nil)
        #expect(q.isEmpty)
    }

    @Test func jumpRemoveMoveClear() {
        var q = PlayQueue()
        q.play(list, source: .appleMusic, startingAt: "a")
        let ids = q.upcoming.map(\.id)          // b c d
        q.move(ids: [ids[2]], toOffset: 0)       // d b c
        #expect(q.upcoming.map(\.track.id) == ["d", "b", "c"])
        q.move(ids: [ids[2]], toOffset: 3)       // b c d
        #expect(q.upcoming.map(\.track.id) == ["b", "c", "d"])
        q.remove(ids: [ids[1]])
        #expect(q.upcoming.map(\.track.id) == ["b", "d"])
        let jumped = q.jump(to: ids[2])
        #expect(jumped?.track.id == "d")
        #expect(q.upcoming.isEmpty)
        q.insert(list, source: .appleMusic, at: .last)
        q.clearUpcoming()
        #expect(q.upcoming.isEmpty && q.current?.track.id == "d")
    }

    @Test func advancePolicy() {
        typealias P = QueueAdvancePolicy
        let playing = QueuePlayerObservation(state: .playing, trackID: "x", position: 50, duration: 200)
        #expect(P.decide(expectedTrackID: "x", observation: playing, lastPosition: 40, lastDuration: 200, sinceStart: 60) == .wait)
        let stopped = QueuePlayerObservation(state: .stopped, trackID: "x", position: 0, duration: 200)
        #expect(P.decide(expectedTrackID: "x", observation: stopped, lastPosition: 199, lastDuration: 200, sinceStart: 200) == .ended)
        #expect(P.decide(expectedTrackID: "x", observation: stopped, lastPosition: nil, lastDuration: nil, sinceStart: 1) == .wait)
        let pausedAtEnd = QueuePlayerObservation(state: .paused, trackID: "x", position: 0, duration: 200)
        #expect(P.decide(expectedTrackID: "x", observation: pausedAtEnd, lastPosition: 199, lastDuration: 200, sinceStart: 200) == .ended)
        let pausedMid = QueuePlayerObservation(state: .paused, trackID: "x", position: 80, duration: 200)
        #expect(P.decide(expectedTrackID: "x", observation: pausedMid, lastPosition: 80, lastDuration: 200, sinceStart: 90) == .wait)
        let other = QueuePlayerObservation(state: .playing, trackID: "y", position: 3, duration: 180)
        #expect(P.decide(expectedTrackID: "x", observation: other, lastPosition: 199, lastDuration: 200, sinceStart: 200) == .ended)
        #expect(P.decide(expectedTrackID: "x", observation: other, lastPosition: 60, lastDuration: 200, sinceStart: 70) == .externalTakeover)
        #expect(P.decide(expectedTrackID: "x", observation: other, lastPosition: nil, lastDuration: nil, sinceStart: 1) == .wait)
        // A stale report from before the song started is not its end, until the start times out.
        let stale = QueuePlayerObservation(state: .stopped, trackID: nil, position: 0, duration: nil)
        #expect(P.decide(expectedTrackID: "x", observation: stale, lastPosition: nil, lastDuration: nil, sinceStart: 6, hasStarted: false) == .wait)
        #expect(P.decide(expectedTrackID: "x", observation: stale, lastPosition: nil, lastDuration: nil, sinceStart: 20, hasStarted: false) == .ended)
        let now = Date()
        #expect(P.remaining(position: 190, duration: 200, sampledAt: now.addingTimeInterval(-4), isPlaying: true, now: now) == 6)
    }

    @Test func spotifyLinks() {
        let id = "4uLU6hMCjMI75M1A2tKUQC"
        #expect(SpotifyLink.trackURI(from: "https://open.spotify.com/track/\(id)?si=abc") == "spotify:track:\(id)")
        #expect(SpotifyLink.trackURI(from: "open.spotify.com/intl-de/track/\(id)") == "spotify:track:\(id)")
        #expect(SpotifyLink.trackURI(from: "spotify:track:\(id)") == "spotify:track:\(id)")
        #expect(SpotifyLink.trackURI(from: "https://open.spotify.com/album/\(id)") == nil)
        #expect(SpotifyLink.trackURI(from: "https://example.com/track/\(id)") == nil)
        #expect(SpotifyLink.trackURI(from: "spotify:track:bad id!") == nil)
        #expect(SpotifyLink.playlistURI(from: "https://open.spotify.com/playlist/\(id)?si=x") == "spotify:playlist:\(id)")
        #expect(SpotifyLink.playlistURI(from: "https://open.spotify.com/track/\(id)") == nil)
        #expect(SpotifyLink.webURL(forURI: "spotify:playlist:\(id)")?.absoluteString == "https://open.spotify.com/playlist/\(id)")
    }
}
