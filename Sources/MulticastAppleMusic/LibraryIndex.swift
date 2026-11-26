import Foundation
import MulticastHubModel

/// An in-memory, sorted snapshot of a track list (the song library, one playlist), with paging
/// and search. Pure value type; both backends build one and page through it, so one round trip
/// to the Music app (or MusicKit) serves every page and every search until it is invalidated.
public struct LibraryIndex: Sendable, Equatable {
    public enum Order: Sendable, Equatable {
        /// Keep the order the backend returned (playlists, up next).
        case source
        /// Title, then artist, then album; Finder-style comparison ("Track 2" < "Track 10").
        case title
    }

    public private(set) var tracks: [TrackItem]
    /// Folded "title artist album" per track, parallel to `tracks`, for search.
    private var haystacks: [String]

    public init(tracks: [TrackItem], order: Order = .source) {
        var t = tracks
        if order == .title {
            t.sort { a, b in
                for (x, y) in [(a.title, b.title), (a.artist, b.artist), (a.album, b.album)] {
                    let r = x.localizedStandardCompare(y)
                    if r != .orderedSame { return r == .orderedAscending }
                }
                return a.id < b.id
            }
        }
        self.tracks = t
        self.haystacks = t.map { Self.fold("\($0.title) \($0.artist) \($0.album)") }
    }

    public var count: Int { tracks.count }

    public func page(_ request: PageRequest) -> Page<TrackItem> {
        Page.slice(tracks, request)
    }

    /// Tracks whose title, artist or album contain every word of `query` (case, diacritic and
    /// width insensitive), in index order. An empty query matches nothing.
    public func search(_ query: String) -> [TrackItem] {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var out: [TrackItem] = []
        for (i, hay) in haystacks.enumerated() where terms.allSatisfy({ hay.contains($0) }) {
            out.append(tracks[i])
        }
        return out
    }

    public func track(id: String) -> TrackItem? {
        tracks.first { $0.id == id }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Remembers the last few search results so paging through one query does not search again.
struct SearchCache: Sendable {
    private var entries: [(key: String, revision: UInt64, results: [TrackItem])] = []
    let capacity: Int

    init(capacity: Int = 4) { self.capacity = capacity }

    mutating func results(for query: String, revision: UInt64, compute: () -> [TrackItem]) -> [TrackItem] {
        let key = LibraryIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if let i = entries.firstIndex(where: { $0.key == key && $0.revision == revision }) {
            let hit = entries.remove(at: i)
            entries.append(hit)
            return hit.results
        }
        let r = compute()
        entries.append((key, revision, r))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return r
    }
}
