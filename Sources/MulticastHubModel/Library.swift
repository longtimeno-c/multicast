import Foundation

// MARK: - Library items (Apple Music, files, Spotify history)

/// Artwork travels by reference so state stays small enough to send to the iOS remote on every
/// change. The bytes come from `HubBackend.artwork(id:maxPixel:)`; an id always names the same
/// image, so clients may cache by id for as long as they like.
public typealias ArtworkID = String

public struct TrackItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    /// Unique within the hub's lists (library persistent id, file id, Spotify track id).
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: TimeInterval
    public var artworkID: ArtworkID?
    /// Files only: a short format note such as "FLAC · 24-bit".
    public var format: String?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval,
                artworkID: ArtworkID? = nil, format: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkID = artworkID
        self.format = format
    }
}

public struct PlaylistItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public var name: String
    public var trackCount: Int
    public var artworkID: ArtworkID?

    public init(id: String, name: String, trackCount: Int, artworkID: ArtworkID? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.artworkID = artworkID
    }
}

// MARK: - Paging

/// Which page of a list to fetch. `cursor` is nil for the first page, then the previous page's
/// `nextCursor`, passed back unchanged (it is opaque: backends may encode an offset, a token, …).
public struct PageRequest: Equatable, Hashable, Sendable, Codable {
    public var cursor: String?
    /// Requested page size; backends clamp it to `PageRequest.limitRange`.
    public var limit: Int

    /// Big enough to fill a screen and some scrolling, small enough to send in one message.
    public static let defaultLimit = 100
    public static let limitRange: ClosedRange<Int> = 1...500

    public init(cursor: String? = nil, limit: Int = PageRequest.defaultLimit) {
        self.cursor = cursor
        self.limit = limit
    }

    public static let first = PageRequest()

    /// `limit` clamped to `limitRange`.
    public var clampedLimit: Int { min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound) }

    /// For backends whose cursor is a plain offset into an array: the offset this request starts
    /// at (0 for a nil or unreadable cursor).
    public var offset: Int { cursor.flatMap(Int.init).map { max(0, $0) } ?? 0 }
}

/// One page of a list.
public struct Page<Item: Sendable & Codable & Equatable>: Equatable, Sendable, Codable {
    public var items: [Item]
    /// Pass back in `PageRequest.cursor` for the next page; nil when this is the last page.
    public var nextCursor: String?
    /// Total number of items in the list, when the backend knows it cheaply.
    public var totalCount: Int?

    public init(items: [Item], nextCursor: String? = nil, totalCount: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }

    public static var empty: Page<Item> { Page(items: []) }

    /// Slices an in-memory array with an offset cursor: the simplest correct backend paging.
    public static func slice(_ all: [Item], _ request: PageRequest) -> Page<Item> {
        let start = min(request.offset, all.count)
        let end = min(start + request.clampedLimit, all.count)
        return Page(items: Array(all[start..<end]), nextCursor: end < all.count ? String(end) : nil,
                    totalCount: all.count)
    }
}

/// Where a track was chosen, so the hub knows what plays after it.
///
/// Wire form (synthesized): `{"songs":{}}`, `{"playlist":{"id":"p1"}}`, `{"upNext":{}}`,
/// `{"search":{"query":"tide"}}`, `{"files":{}}`.
public enum TrackContext: Equatable, Hashable, Sendable, Codable {
    /// The whole song library, in library order.
    case songs
    /// A playlist, in playlist order.
    case playlist(id: String)
    /// Jump within the current up-next queue.
    case upNext
    /// A library search result list.
    case search(query: String)
    /// The file queue.
    case files
}
