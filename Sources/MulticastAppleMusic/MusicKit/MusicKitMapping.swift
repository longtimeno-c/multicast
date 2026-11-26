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
