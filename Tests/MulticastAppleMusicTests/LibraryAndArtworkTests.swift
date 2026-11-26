import CoreGraphics
import Foundation
import ImageIO
import MulticastHubModel
import Testing
import UniformTypeIdentifiers
@testable import MulticastAppleMusic

// Made-up library: no real titles.
private func t(_ id: String, _ title: String, _ artist: String = "Lantern Fold", _ album: String = "Quiet Rooms") -> TrackItem {
    TrackItem(id: id, title: title, artist: artist, album: album, duration: 200)
}

@Suite struct ArtworkRefTests {
    @Test func roundTripsBothKinds() {
        let a = AppleMusicArtworkRef.musicAppTrack(persistentID: "0A1B2C3D4E5F6071")
        #expect(a.artworkID == "am.track.0A1B2C3D4E5F6071")
        #expect(AppleMusicArtworkRef(artworkID: a.artworkID) == a)
        let k = AppleMusicArtworkRef.musicKitItem(id: "i.AbCdEf123")
        #expect(k.artworkID == "mk.item.i.AbCdEf123")
        #expect(AppleMusicArtworkRef(artworkID: k.artworkID) == k)
    }

    @Test func rejectsForeignAndMalformedIDs() {
        for bad in ["", "am.track.", "am.track.XYZ", "am.track.12 34", "am.track.\" & quit", "am.track." + String(repeating: "A", count: 33),
                    "mk.item.", "mk.item.a b", "file.cover.1", "spotify:track:1", "AM.TRACK.0A1B"] {
            #expect(AppleMusicArtworkRef(artworkID: bad) == nil, "\(bad)")
        }
    }
}

@Suite struct ArtworkScalerTests {
    static func image(width: Int, height: Int, alpha: Bool) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func size(_ data: Data) -> (Int, Int, String?) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int, CGImageSourceGetType(src) as String?)
    }

    @Test func downscalesLongerSideToMaxPixel() throws {
        let src = Self.image(width: 64, height: 32, alpha: false)
        let out = try #require(ArtworkScaler.scale(src, maxPixel: 16))
        let (w, h, type) = Self.size(out)
        #expect(w == 16 && h == 8)
        #expect(type == UTType.jpeg.identifier)
    }

    @Test func keepsAlphaAsPNG() throws {
        let out = try #require(ArtworkScaler.scale(Self.image(width: 40, height: 40, alpha: true), maxPixel: 10))
        let (w, h, type) = Self.size(out)
        #expect(w == 10 && h == 10)
        #expect(type == UTType.png.identifier)
    }

    @Test func returnsOriginalWhenUncappedOrAlreadySmall() {
        let src = Self.image(width: 20, height: 10, alpha: false)
        #expect(ArtworkScaler.scale(src, maxPixel: 0) == src)
        #expect(ArtworkScaler.scale(src, maxPixel: 20) == src)
        #expect(ArtworkScaler.scale(src, maxPixel: 600) == src)
    }

    @Test func rejectsNonImages() {
        #expect(ArtworkScaler.scale(Data("not an image".utf8), maxPixel: 100) == nil)
        #expect(ArtworkScaler.scale(Data(), maxPixel: 0) == nil)
    }
}

@Suite struct LibraryIndexTests {
    let tracks = [
        t("A1", "Track 10"), t("A2", "Track 2"), t("A3", "Échoes", "Marigold Lane"),
        t("A4", "after hours", "Paper Comets", "Night Bus"), t("A5", "Track 2", "Aster Field"),
    ]

    @Test func titleOrderIsFinderLikeWithArtistTieBreak() {
        let ids = LibraryIndex(tracks: tracks, order: .title).tracks.map(\.id)
        // "after hours" < "Échoes" < "Track 2" (Aster Field) < "Track 2" (Lantern Fold) < "Track 10"
        #expect(ids == ["A4", "A3", "A5", "A2", "A1"])
    }

    @Test func sourceOrderIsKept() {
        #expect(LibraryIndex(tracks: tracks).tracks.map(\.id) == tracks.map(\.id))
    }

    @Test func pagingWalksEveryTrackOnce() {
        let many = (0..<257).map { t(String(format: "%04X", $0), "Song \($0)") }
        let index = LibraryIndex(tracks: many, order: .title)
        var seen: [String] = []
        var req: PageRequest? = PageRequest(limit: 100)
        var pages = 0
        while let r = req {
            let page = index.page(r)
            #expect(page.totalCount == 257)
            seen += page.items.map(\.id)
            req = page.nextCursor.map { PageRequest(cursor: $0, limit: 100) }
            pages += 1
        }
        #expect(pages == 3)
        #expect(seen == index.tracks.map(\.id))
        #expect(Set(seen).count == 257)
    }

    @Test func searchFoldsCaseAndDiacriticsAndNeedsEveryWord() {
        let index = LibraryIndex(tracks: tracks, order: .title)
        #expect(index.search("echoes").map(\.id) == ["A3"])
        #expect(index.search("TRACK 2").map(\.id) == ["A5", "A2"])
        #expect(index.search("track aster").map(\.id) == ["A5"])
        #expect(index.search("night bus").map(\.id) == ["A4"])  // album
        #expect(index.search("marigold").map(\.id) == ["A3"])   // artist
        #expect(index.search("   ").isEmpty)
        #expect(index.search("zzz").isEmpty)
    }

    @Test func searchCacheReusesUntilRevisionChanges() {
        var cache = SearchCache(capacity: 2)
        var computed = 0
        let compute: () -> [TrackItem] = { computed += 1; return [t("A1", "x")] }
        _ = cache.results(for: "Tide", revision: 1, compute: compute)
        _ = cache.results(for: " tide ", revision: 1, compute: compute)
        #expect(computed == 1)
        _ = cache.results(for: "tide", revision: 2, compute: compute)
        #expect(computed == 2)
        _ = cache.results(for: "a", revision: 2, compute: compute)
        _ = cache.results(for: "b", revision: 2, compute: compute)
        _ = cache.results(for: "tide", revision: 2, compute: compute) // evicted by capacity 2
        #expect(computed == 5)
    }
}

@Suite struct MusicKitMappingTests {
    @Test func extraItemMeansAnotherPage() {
        let req = PageRequest(cursor: "200", limit: 3)
        #expect(MusicKitMapping.fetchLimit(for: req) == 4)
        let more = MusicKitMapping.page([1, 2, 3, 4], for: req)
        #expect(more.items == [1, 2, 3])
        #expect(more.nextCursor == "203")
        let last = MusicKitMapping.page([1, 2], for: req)
        #expect(last.items == [1, 2])
        #expect(last.nextCursor == nil)
        #expect(MusicKitMapping.page([1, 2, 3], for: req).nextCursor == nil)
    }

    @Test func mapsTracksAndPlaylists() {
        let a = MusicKitMapping.track(id: "i.Q1", title: "", artist: "Paper Comets", album: nil, duration: nil, hasArtwork: false)
        #expect(a == TrackItem(id: "i.Q1", title: "Unknown", artist: "Paper Comets", album: "", duration: 0, artworkID: nil))
        let b = MusicKitMapping.track(id: "i.Q2", title: "Low Tide", artist: "", album: "Shore", duration: 181.5, hasArtwork: true)
        #expect(b.artworkID == "mk.item.i.Q2")
        #expect(b.duration == 181.5)
        let p = MusicKitMapping.playlist(id: "p.X", name: "", trackCount: -1, hasArtwork: true)
        #expect(p == PlaylistItem(id: "p.X", name: "Untitled Playlist", trackCount: 0, artworkID: "mk.item.p.X"))
    }
}

@Suite struct SnapshotTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func snap(playing: Bool = true, position: TimeInterval = 10, at: Date, track: String? = "0A", upNext: UInt64 = 0) -> AppleMusicSnapshot {
        AppleMusicSnapshot(
            nowPlaying: track.map { NowPlayingInfo(title: "Low Tide", artist: "Paper Comets", duration: 200, trackID: $0) },
            transport: TransportState(isPlaying: playing, position: position, positionAsOf: at),
            upNextRevision: upNext)
    }

    @Test func progressIsNotAChangeButSeekPauseAndTrackAre() {
        let a = snap(at: t0)
        #expect(!snap(position: 12, at: t0.addingTimeInterval(2)).isSignificantChange(from: a))
        #expect(snap(position: 40, at: t0.addingTimeInterval(2)).isSignificantChange(from: a))
        #expect(snap(playing: false, position: 12, at: t0.addingTimeInterval(2)).isSignificantChange(from: a))
        #expect(snap(position: 12, at: t0.addingTimeInterval(2), track: "0B").isSignificantChange(from: a))
        #expect(snap(position: 12, at: t0.addingTimeInterval(2), upNext: 1).isSignificantChange(from: a))
        #expect(a.isSignificantChange(from: nil))
    }

    @Test func fanoutGivesLatestToLateSubscribersAndReportsActivity() async {
        let flags = Flags()
        let fan = SnapshotFanout<Int> { flags.append($0) }
        fan.publish(1)
        let s1 = fan.stream()
        var it = s1.makeAsyncIterator()
        #expect(await it.next() == 1)
        fan.publish(2)
        #expect(await it.next() == 2)
        let s2 = fan.stream()
        var it2 = s2.makeAsyncIterator()
        #expect(await it2.next() == 2)
        #expect(fan.subscriberCount == 2)
        fan.finish()
        #expect(await it.next() == nil)
        #expect(flags.values.first == true)
    }
}

final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Bool] = []
    func append(_ b: Bool) { lock.lock(); v.append(b); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return v }
}
