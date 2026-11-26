import Foundation
import MulticastHubModel

/// The pure part of `MusicKitPlayer`: MusicKit fields → hub types, and offset paging over
/// requests that do not report a total. Tested without MusicKit.
public enum MusicKitMapping {
    public static func track(id: String, title: String, artist: String, album: String?, duration: TimeInterval?,
                             hasArtwork: Bool) -> TrackItem {
        TrackItem(id: id, title: title.isEmpty ? "Unknown" : title, artist: artist, album: album ?? "",
                  duration: max(0, duration ?? 0),
                  artworkID: hasArtwork ? AppleMusicArtworkRef.musicKitItem(id: id).artworkID : nil)
    }

    /// A catalog song: the same fields under a `CatalogTrackID`, artwork keyed by the catalog id.
    public static func catalogTrack(catalogID: String, title: String, artist: String, album: String?,
                                    duration: TimeInterval?, hasArtwork: Bool) -> TrackItem {
        let t = track(id: catalogID, title: title, artist: artist, album: album, duration: duration, hasArtwork: hasArtwork)
        return TrackItem(id: CatalogTrackID.make(catalogID), title: t.title, artist: t.artist, album: t.album,
                         duration: t.duration, artworkID: t.artworkID)
    }

    /// Apple Music API returns at most this many search results per request.
    public static let catalogPageLimit = 25
    /// How deep a catalog search is paged before it stops offering more.
    public static let catalogResultLimit = 100

    /// The cursor after a catalog page that started at `offset` and returned `count` songs.
    public static func catalogNextCursor(offset: Int, count: Int, hasMore: Bool) -> String? {
        let next = offset + count
        return hasMore && count > 0 && next < catalogResultLimit ? String(next) : nil
    }

    public static func playlist(id: String, name: String, trackCount: Int, hasArtwork: Bool) -> PlaylistItem {
        PlaylistItem(id: id, name: name.isEmpty ? "Untitled Playlist" : name, trackCount: max(0, trackCount),
                     artworkID: hasArtwork ? AppleMusicArtworkRef.musicKitItem(id: id).artworkID : nil)
    }

    /// A page from a request made with `offset = request.offset` and `limit = request.clampedLimit + 1`
    /// (one extra item tells whether another page exists without a total count).
    public static func page<Item>(_ fetched: [Item], for request: PageRequest) -> Page<Item> {
        let limit = request.clampedLimit
        let items = Array(fetched.prefix(limit))
        let more = fetched.count > limit
        return Page(items: items, nextCursor: more ? String(request.offset + items.count) : nil, totalCount: nil)
    }

    /// `limit` to ask MusicKit for so `page(_:for:)` can tell whether more exist.
    public static func fetchLimit(for request: PageRequest) -> Int { request.clampedLimit + 1 }
}
