import Foundation

/// Every read-only request a hub answers besides the state stream. A network transport carries
/// these as they are and answers with `HubQueryResult`; `HubBackend.answer(_:)` maps one onto the
/// backend's methods.
///
/// Wire form (synthesized), e.g. `{"songs":{"page":{"limit":100}}}`,
/// `{"playlistTracks":{"playlistID":"p1","page":{"cursor":"100","limit":100}}}`,
/// `{"artwork":{"id":"cover.ring","maxPixel":300}}`.
public enum HubQuery: Equatable, Hashable, Sendable, Codable {
    case playlists(page: PageRequest)
    case playlistTracks(playlistID: String, page: PageRequest)
    case songs(page: PageRequest)
    /// Library search by title, artist or album. An empty query returns an empty page.
    case search(query: String, page: PageRequest)
    /// The hub's Up Next (answered with `.queue`).
    case upNext(page: PageRequest)
    case files(page: PageRequest)
    case spotifyHistory(page: PageRequest)
    /// `maxPixel` is the longest side the caller will draw, in pixels; 0 means original size.
    case artwork(id: ArtworkID, maxPixel: Int)
}

/// The answer to a `HubQuery`.
///
/// Wire form (synthesized), e.g. `{"tracks":{"page":{"items":[…],"nextCursor":"100"}}}`,
/// `{"artwork":{"data":"<base64>"}}`.
public enum HubQueryResult: Equatable, Sendable, Codable {
    case playlists(page: Page<PlaylistItem>)
    case tracks(page: Page<TrackItem>)
    case queue(page: Page<QueueItem>)
    /// Encoded image bytes (PNG or JPEG), nil when the id is unknown.
    case artwork(data: Data?)

    public var playlists: Page<PlaylistItem>? {
        if case .playlists(let p) = self { return p }
        return nil
    }

    public var tracks: Page<TrackItem>? {
        if case .tracks(let p) = self { return p }
        return nil
    }

    public var queue: Page<QueueItem>? {
        if case .queue(let p) = self { return p }
        return nil
    }

    public var artworkData: Data? {
        if case .artwork(let d) = self { return d }
        return nil
    }
}
