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

/// A playlist or a playlist folder. The playlists query lists both, flat, in library order;
/// `parentID` names the folder an item sits in (nil at the top), so clients build the tree.
/// A folder's `trackCount` counts every song inside it, and playing a folder plays them all.
///
/// Wire form: `{"id":"p1","name":"Garden","trackCount":3}`, plus `"isFolder":true` for a
/// folder and `"parentID":"f1"` inside one. Both are omitted when false / nil, and default when
/// missing, so builds from before folders read and write the same playlists.
public struct PlaylistItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public var name: String
    public var trackCount: Int
    public var artworkID: ArtworkID?
    /// A playlist folder (Music's "folder playlist").
    public var isFolder: Bool
    /// The folder this item sits in; nil at the top of the library.
    public var parentID: String?

    public init(id: String, name: String, trackCount: Int, artworkID: ArtworkID? = nil,
                isFolder: Bool = false, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.artworkID = artworkID
        self.isFolder = isFolder
        self.parentID = parentID
    }

    private enum CodingKeys: String, CodingKey { case id, name, trackCount, artworkID, isFolder, parentID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        trackCount = try c.decode(Int.self, forKey: .trackCount)
        artworkID = try c.decodeIfPresent(ArtworkID.self, forKey: .artworkID)
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(trackCount, forKey: .trackCount)
        try c.encodeIfPresent(artworkID, forKey: .artworkID)
        if isFolder { try c.encode(true, forKey: .isFolder) }
        try c.encodeIfPresent(parentID, forKey: .parentID)
    }
}

/// The playlist tree, from the flat list the playlists query returns.
public struct PlaylistTree: Equatable, Sendable {
    public let all: [PlaylistItem]
    private let children: [String: [PlaylistItem]]
    private let byID: [String: PlaylistItem]

    public init(_ items: [PlaylistItem]) {
        all = items
        let ids = Set(items.map(\.id))
        var children: [String: [PlaylistItem]] = [:]
        // An item whose folder isn't listed shows at the top rather than vanishing.
        for item in items { children[item.parentID.flatMap { ids.contains($0) ? $0 : nil } ?? "", default: []].append(item) }
        self.children = children
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The items directly in `folderID` (nil: the top of the library), folders first, each
    /// group in library order, as Music lists them.
    public func items(in folderID: String?) -> [PlaylistItem] {
        let list = children[folderID ?? ""] ?? []
        return list.filter(\.isFolder) + list.filter { !$0.isFolder }
    }

    public func item(_ id: String) -> PlaylistItem? { byID[id] }

    /// The folders from the top down to (not including) `id`.
    public func path(to id: String) -> [PlaylistItem] {
        var out: [PlaylistItem] = []
        var seen: Set<String> = [id]
        var next = byID[id]?.parentID
        while let p = next, let folder = byID[p], seen.insert(p).inserted {
            out.insert(folder, at: 0)
            next = folder.parentID
        }
        return out
    }

    /// Up to four covers for a folder's mosaic: its playlists first, then its sub-folders'.
    public func mosaic(for folderID: String, limit: Int = 4) -> [ArtworkID] {
        var out: [ArtworkID] = []
        var queue = [folderID]
        var seen: Set<String> = []
        while let f = queue.first, out.count < limit {
            queue.removeFirst()
            guard seen.insert(f).inserted else { continue }
            let items = children[f] ?? []
            for p in items where !p.isFolder { if let a = p.artworkID, !out.contains(a) { out.append(a) } }
            queue += items.filter(\.isFolder).map(\.id)
        }
        return Array(out.prefix(limit))
    }

    /// How many playlists sit anywhere inside `folderID`.
    public func playlistCount(in folderID: String) -> Int {
        var n = 0
        var queue = [folderID]
        var seen: Set<String> = []
        while let f = queue.popLast() {
            guard seen.insert(f).inserted else { continue }
            for p in children[f] ?? [] { if p.isFolder { queue.append(p.id) } else { n += 1 } }
        }
        return n
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
/// `{"search":{"query":"tide"}}`, `{"files":{}}`, `{"spotifyHistory":{}}`.
///
/// Playing a song from a context makes Up Next everything after it in that context.
public enum TrackContext: Equatable, Hashable, Sendable, Codable {
    /// The whole song library, in library order.
    case songs
    /// A playlist, in playlist order.
    case playlist(id: String)
    /// Jump to an entry of the hub's Up Next (`id` is a `QueueItem.id`).
    case upNext
    /// A library search result list.
    case search(query: String)
    /// The file queue.
    case files
    /// Spotify songs heard this session (`id` is a `spotify:track:` URI).
    case spotifyHistory
}
