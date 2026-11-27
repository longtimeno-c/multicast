import Foundation
import Testing
@testable import MulticastHubModel

private struct Item: Identifiable, Codable, Equatable, Sendable {
    var id: Int
}

@Suite struct PagingTests {
    @Test func sliceWalksAnArrayWithOffsetCursors() {
        let all = (0..<250).map(Item.init)
        let p1 = Page.slice(all, PageRequest(limit: 100))
        #expect(p1.items.map(\.id) == Array(0..<100))
        #expect(p1.nextCursor == "100")
        #expect(p1.totalCount == 250)
        let p3 = Page.slice(all, PageRequest(cursor: "200", limit: 100))
        #expect(p3.items.map(\.id) == Array(200..<250))
        #expect(p3.nextCursor == nil)
        #expect(Page.slice(all, PageRequest(cursor: "999")).items.isEmpty)
        #expect(Page.slice(all, PageRequest(cursor: "junk", limit: 5)).items.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func limitsAreClamped() {
        #expect(PageRequest(limit: 0).clampedLimit == 1)
        #expect(PageRequest(limit: 10_000).clampedLimit == PageRequest.limitRange.upperBound)
        #expect(PageRequest(cursor: "-4").offset == 0)
    }

    @Test func pagedListLoadsPagesInOrder() {
        let all = (0..<250).map(Item.init)
        var list = PagedList<Item>()
        #expect(list.canLoadMore)
        var request = list.nextRequest()!
        #expect(request.cursor == nil)
        while let r = list.nextRequest() {
            request = r
            let ok = list.receive(Page.slice(all, r), for: r, revision: 0)
            #expect(ok)
        }
        #expect(list.items == all)
        #expect(!list.canLoadMore)
        #expect(list.isLoaded)
        #expect(request.cursor == "200")
    }

    @Test func pagedListDropsStalePages() {
        let all = (0..<10).map(Item.init)
        var list = PagedList<Item>()
        let first = list.nextRequest(limit: 4)!
        list.receive(Page.slice(all, first), for: first, revision: 0)
        let second = list.nextRequest(limit: 4)!
        // The list changes on the backend before the second page arrives.
        list.invalidate(revision: 1)
        let stale = list.receive(Page.slice(all, second), for: second, revision: 0)
        #expect(!stale)
        #expect(list.items.map(\.id) == [0, 1, 2, 3], "old items stay visible until the new first page")
        #expect(list.nextRequest(limit: 4)?.cursor == nil)
        // A page for the wrong cursor is ignored too.
        let wrongCursor = list.receive(Page.slice(all, second), for: second, revision: 1)
        #expect(!wrongCursor)
        let fresh = list.nextRequest(limit: 4)!
        let accepted = list.receive(Page.slice(Array(all.reversed()), fresh), for: fresh, revision: 1)
        #expect(accepted)
        #expect(list.items.map(\.id) == [9, 8, 7, 6])
    }

    @Test func pagedListSkipsDuplicatesAtThePageSeam() {
        var list = PagedList<Item>()
        let r1 = list.nextRequest()!
        list.receive(Page(items: [Item(id: 1), Item(id: 2)], nextCursor: "2"), for: r1, revision: 0)
        let r2 = list.nextRequest()!
        list.receive(Page(items: [Item(id: 2), Item(id: 3)], nextCursor: nil), for: r2, revision: 0)
        #expect(list.items.map(\.id) == [1, 2, 3])
    }

    @Test func loadMoreNearTheEnd() {
        var list = PagedList<Item>()
        let r = list.nextRequest()!
        list.receive(Page(items: (0..<100).map(Item.init), nextCursor: "100"), for: r, revision: 0)
        #expect(!list.shouldLoadMore(after: 10))
        #expect(list.shouldLoadMore(after: 85))
        #expect(!PagedList(items: [Item(id: 1)]).shouldLoadMore(after: 1))
    }
}

@Suite struct ArtworkCacheTests {
    private func key(_ id: String) -> ArtworkCache.Key { .init(id: id, maxPixel: 0) }

    @Test func evictsLeastRecentlyUsedByBytes() {
        var cache = ArtworkCache(byteLimit: 30)
        cache.insert(Data(count: 10), for: key("a"))
        cache.insert(Data(count: 10), for: key("b"))
        cache.insert(Data(count: 10), for: key("c"))
        #expect(cache.totalBytes == 30)
        _ = cache.data(for: key("a"))           // a is now the most recent
        cache.insert(Data(count: 10), for: key("d"))
        #expect(cache.peek(key("b")) == nil, "b was least recently used")
        #expect(cache.peek(key("a")) != nil)
        #expect(cache.peek(key("d")) != nil)
        #expect(cache.totalBytes == 30)
    }

    @Test func replacingAnEntryKeepsTheByteCountRight() {
        var cache = ArtworkCache(byteLimit: 100)
        cache.insert(Data(count: 40), for: key("a"))
        cache.insert(Data(count: 10), for: key("a"))
        #expect(cache.totalBytes == 10)
        #expect(cache.count == 1)
    }

    @Test func anOversizedImageStillCaches() {
        var cache = ArtworkCache(byteLimit: 5)
        cache.insert(Data(count: 3), for: key("a"))
        cache.insert(Data(count: 50), for: key("big"))
        #expect(cache.peek(key("big")) != nil)
        #expect(cache.count == 1)
    }

    @Test func sizesAreSeparateEntries() {
        var cache = ArtworkCache()
        cache.insert(Data([1]), for: .init(id: "a", maxPixel: 64))
        #expect(cache.peek(.init(id: "a", maxPixel: 600)) == nil)
    }
}

@Suite struct HealthTests {
    @Test func permissionIssuesFollowThePermissions() {
        let p = PermissionSet(localNetwork: .granted, audioCapture: .denied, appleMusic: .notDetermined, automation: .granted)
        let h = HubHealth(permissions: p, extraIssues: [.sourceAppNotRunning(source: .spotify, bundleID: "com.spotify.client", name: "Spotify")])
        #expect(h.issues == [
            .permissionMissing(permission: .audioCapture, status: .denied),
            .permissionMissing(permission: .appleMusic, status: .notDetermined),
            .sourceAppNotRunning(source: .spotify, bundleID: "com.spotify.client", name: "Spotify"),
        ])
        #expect(h.issues(for: .spotify).count == 2)     // capture denied + app closed
        #expect(h.issues(for: .app) == [.permissionMissing(permission: .audioCapture, status: .denied)])
        #expect(h.issues(for: .appleMusic) == [.permissionMissing(permission: .audioCapture, status: .denied),
                                               .permissionMissing(permission: .appleMusic, status: .notDetermined)])
        #expect(h.issues(for: .files).isEmpty)
        let unknownCapture = HubHealth(permissions: PermissionSet(localNetwork: .granted, audioCapture: .notDetermined,
                                                                  appleMusic: .granted, automation: .granted), extraIssues: [])
        #expect(unknownCapture.issues(for: .app).count == 1)
        #expect(unknownCapture.shownIssues(for: .app).isEmpty)
        #expect(h.shownIssues(for: .app) == [.permissionMissing(permission: .audioCapture, status: .denied)])
        #expect(HubHealth(permissions: .allGranted, extraIssues: []).issues.isEmpty)
    }

    @Test func subscriptReadsAndWritesEachField() {
        var p = PermissionSet()
        for perm in HubPermission.allCases {
            p[perm] = .granted
            #expect(p[perm] == .granted)
        }
        #expect(p == .allGranted)
    }
}

@Suite struct CommandTests {
    @Test func categoriesAndCoalescing() {
        #expect(HubCommand.play.category == .transport)
        #expect(HubCommand.captureApp(bundleID: "x").category == .source)
        #expect(HubCommand.setMasterVolume(volume: 1).category == .speaker)
        #expect(HubCommand.clearQueue.category == .queue)
        #expect(HubCommand.pinPlaylist(id: "p").category == .queue)
        #expect(HubCommand.setSpeakerVolume(id: "a", volume: 0.1).coalescingKey
                == HubCommand.setSpeakerVolume(id: "a", volume: 0.9).coalescingKey)
        #expect(HubCommand.setSpeakerVolume(id: "a", volume: 0.1).coalescingKey
                != HubCommand.setSpeakerVolume(id: "b", volume: 0.1).coalescingKey)
        #expect(HubCommand.setSpeakerEnabled(id: "a", enabled: true).coalescingKey == nil)
    }
}

/// A backend that only records: proves the named methods and `answer(_:)` route through the
/// protocol's two entry points.
private final class RecordingBackend: HubBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _performed: [HubCommand] = []
    var performed: [HubCommand] { lock.withLock { _performed } }
    let songsList = (0..<5).map { TrackItem(id: "s\($0)", title: "T\($0)", artist: "A", album: "B", duration: 1) }

    func states() async -> AsyncStream<HubState> { AsyncStream { $0.finish() } }
    func levels() async -> AsyncStream<StereoLevels> { AsyncStream { $0.finish() } }
    func artwork(id: ArtworkID, maxPixel: Int) async -> Data? { id == "known" ? Data([UInt8(maxPixel & 0xFF)]) : nil }
    func playlists(_ page: PageRequest) async throws -> Page<PlaylistItem> { .empty }
    func tracks(inPlaylist playlistID: String, _ page: PageRequest) async throws -> Page<TrackItem> {
        throw HubCommandError(.notFound, "No playlist \(playlistID)")
    }
    func songs(_ page: PageRequest) async throws -> Page<TrackItem> { .slice(songsList, page) }
    func search(_ query: String, _ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func upNext(_ page: PageRequest) async throws -> Page<QueueItem> { .empty }
    func files(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func spotifyHistory(_ page: PageRequest) async throws -> Page<TrackItem> { .empty }
    func perform(_ command: HubCommand) async throws {
        lock.withLock { _performed.append(command) }
    }
}

@Suite struct BackendExtensionTests {
    @Test func namedCommandsRouteThroughPerform() async throws {
        let b = RecordingBackend()
        try await b.play()
        try await b.setSpeaker("a", volume: 0.3)
        try await b.setSpeaker("a", syncTrimMs: -20)
        try await b.setSpeaker("a", enabled: true)
        try await b.playTrack(id: "s1", context: .songs)
        try await b.requestPermission(.appleMusic)
        #expect(b.performed == [.play, .setSpeakerVolume(id: "a", volume: 0.3), .setSpeakerSyncTrim(id: "a", milliseconds: -20),
                                .setSpeakerEnabled(id: "a", enabled: true), .playTrack(id: "s1", context: .songs),
                                .requestPermission(permission: .appleMusic)])
    }

    @Test func answerMapsQueries() async throws {
        let b = RecordingBackend()
        let r = try await b.answer(.songs(page: PageRequest(limit: 2)))
        #expect(r.tracks?.items.map(\.id) == ["s0", "s1"])
        #expect(r.tracks?.nextCursor == "2")
        #expect(try await b.answer(.artwork(id: "known", maxPixel: 7)).artworkData == Data([7]))
        #expect(try await b.answer(.artwork(id: "other", maxPixel: 7)) == .artwork(data: nil))
        await #expect(throws: HubCommandError.self) { try await b.answer(.playlistTracks(playlistID: "p", page: .first)) }
    }

    @Test func defaultAvailabilityIsConnected() async {
        var seen: [HubAvailability] = []
        for await a in await RecordingBackend().availability() { seen.append(a) }
        #expect(seen == [.connected])
    }
}

@Suite struct BroadcasterTests {
    @Test func newSubscribersGetTheCurrentStateAndRevisionsOnlyGrowOnChange() async {
        let b = HubStateBroadcaster(HubState(masterVolume: 0.5))
        var it = b.stream().makeAsyncIterator()
        #expect(await it.next()?.revision == 0)
        let same = b.update { $0.masterVolume = 0.5 }
        #expect(same.revision == 0, "a no-op update publishes nothing")
        b.update { $0.masterVolume = 0.6 }
        let next = await it.next()
        #expect(next?.revision == 1)
        #expect(next?.masterVolume == 0.6)
        // A caller can't move the revision itself.
        let s = b.update { $0.revision = 99; $0.isDiscovering = true }
        #expect(s.revision == 2)
    }

    @Test func slowReadersSeeOnlyTheNewestState() async {
        let b = HubStateBroadcaster()
        let stream = b.stream()
        for i in 1...50 { b.update { $0.masterVolume = Double(i) / 100 } }
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        #expect(first?.revision == 50)
        #expect(first?.masterVolume == 0.5)
    }

    @Test func finishEndsSubscriptionsAndCancelledOnesAreDropped() async {
        let b = HubStateBroadcaster()
        let task = Task { for await _ in b.stream() {} }
        while b.subscriberCount == 0 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(b.subscriberCount == 0)

        let stream = b.stream()
        b.finish()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1, "the initial state, then the end")
        var late = 0
        for await _ in b.stream() { late += 1 }
        #expect(late == 1)
    }
}

@Suite struct PagedListEditTests {
    private func list() -> PagedList<QueueItem> {
        PagedList(items: ["a", "b", "c", "d"].map {
            QueueItem(id: $0, source: .appleMusic, track: TrackItem(id: "t\($0)", title: $0, artist: "", album: "", duration: 1))
        })
    }

    @Test func movesRemovesAndDropsThrough() {
        var l = list()
        l.move(fromOffsets: [3], toOffset: 0)
        #expect(l.items.map(\.id) == ["d", "a", "b", "c"])
        l.move(fromOffsets: [0, 1], toOffset: 4)
        #expect(l.items.map(\.id) == ["b", "c", "d", "a"])
        l.removeAll(ids: ["c"])
        #expect(l.items.map(\.id) == ["b", "d", "a"] && l.totalCount == 3)
        l.removeThrough("d")
        #expect(l.items.map(\.id) == ["a"] && l.totalCount == 1)
    }
}

@Suite struct PlaylistTreeTests {
    let items = [
        PlaylistItem(id: "p1", name: "Top", trackCount: 2, artworkID: "a1"),
        PlaylistItem(id: "f1", name: "Evenings", trackCount: 9, isFolder: true),
        PlaylistItem(id: "p2", name: "Dinner", trackCount: 4, artworkID: "a2", parentID: "f1"),
        PlaylistItem(id: "f2", name: "Weekends", trackCount: 5, isFolder: true, parentID: "f1"),
        PlaylistItem(id: "p3", name: "Sunday", trackCount: 5, artworkID: "a3", parentID: "f2"),
        PlaylistItem(id: "p4", name: "Lost", trackCount: 1, parentID: "gone"),
    ]

    @Test func buildsTheTree() {
        let t = PlaylistTree(items)
        #expect(t.items(in: nil).map(\.id) == ["f1", "p1", "p4"])   // folders first; an orphan shows at the top
        #expect(t.items(in: "f1").map(\.id) == ["f2", "p2"])
        #expect(t.path(to: "p3").map(\.id) == ["f1", "f2"])
        #expect(t.path(to: "p1").isEmpty)
        #expect(t.mosaic(for: "f1") == ["a2", "a3"])
        #expect(t.playlistCount(in: "f1") == 2)
    }

    @Test func survivesACycle() {
        let loop = [PlaylistItem(id: "a", name: "A", trackCount: 0, isFolder: true, parentID: "b"),
                    PlaylistItem(id: "b", name: "B", trackCount: 0, isFolder: true, parentID: "a")]
        let t = PlaylistTree(loop)
        #expect(t.path(to: "a").count <= 1)
        #expect(t.playlistCount(in: "a") == 0)
    }
}

@Suite struct SpeakerCountsTests {
    private func speaker(_ n: Int, _ state: SpeakerState, restricted: Bool = false) -> SpeakerItem {
        SpeakerItem(id: SpeakerID("s\(n)"), name: "Speaker \(n)", transport: .airPlay2, glyph: .speaker,
                    isEnabled: state != .off, volume: 0.5, state: state, isRestricted: restricted)
    }

    @Test func countsLiveStatesAndSaysThemInOrder() {
        let c = SpeakerCounts([speaker(1, .playing), speaker(2, .playing), speaker(3, .connecting),
                               speaker(4, .failed(reason: "Not responding")), speaker(5, .off), speaker(6, .ready)])
        #expect(c == { var e = SpeakerCounts(); e.playing = 2; e.ready = 1; e.connecting = 1; e.failed = 1; return e }())
        #expect(c.on == 5)
        #expect(c.summary == "2 playing \u{00B7} 1 ready \u{00B7} 1 connecting \u{00B7} 1 not responding")
        #expect(SpeakerCounts([speaker(1, .off)]).summary == nil)
    }

    /// A speaker that turned the hub away is neither failing nor on, even while it is asked again.
    @Test func restrictedSpeakersAreLeftOut() {
        let c = SpeakerCounts([speaker(1, .playing), speaker(2, .off, restricted: true),
                               speaker(3, .connecting, restricted: true),
                               speaker(4, .failed(reason: "Blocked by its AirPlay access setting"), restricted: true)])
        #expect(c.playing == 1 && c.connecting == 0 && c.failed == 0)
        #expect(c.summary == "1 playing")
        #expect(SpeakerCounts([speaker(2, .off, restricted: true)]).isEmpty)
    }
}
