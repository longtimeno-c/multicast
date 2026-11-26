import Foundation
import MulticastHubModel

/// What the hub learned about a file when it was added.
public struct InspectedFile: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval
    /// Encoded cover image, if the file has one.
    public var artwork: Data?
    /// Short format note, e.g. "FLAC · 24-bit".
    public var format: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, duration: TimeInterval,
                artwork: Data? = nil, format: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.format = format
    }
}

/// The Files source's play queue: an ordered list with a cursor. Pure value type; unit-tested.
public struct FileQueue: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var track: TrackItem
    }

    public private(set) var entries: [Entry] = []
    /// Index of the current item (the one playing, paused, or cued), nil when empty.
    public private(set) var currentIndex: Int?
    private var nextSerial = 1

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var tracks: [TrackItem] { entries.map(\.track) }
    public var current: Entry? { currentIndex.map { entries[$0] } }

    public static func artworkID(forTrack id: String) -> ArtworkID { "hub.file-art:\(id)" }

    /// Appends files; returns the new tracks. The first file ever added becomes current.
    @discardableResult
    public mutating func append(_ files: [(URL, InspectedFile)]) -> [TrackItem] {
        var added: [TrackItem] = []
        for (url, info) in files {
            let id = "file-\(nextSerial)"
            nextSerial += 1
            let title = info.title ?? url.deletingPathExtension().lastPathComponent
            let track = TrackItem(id: id, title: title, artist: info.artist ?? "", album: info.album ?? "",
                                  duration: info.duration,
                                  artworkID: info.artwork == nil ? nil : Self.artworkID(forTrack: id),
                                  format: info.format)
            entries.append(Entry(url: url, track: track))
            added.append(track)
        }
        if currentIndex == nil, !entries.isEmpty { currentIndex = 0 }
        return added
    }

    /// Removes tracks. Returns true when the current item was among them (the cursor then moves
    /// to the item that followed it, or to the first item, or to nil when the queue is empty).
    @discardableResult
    public mutating func remove(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        let currentID = current?.track.id
        let oldIndex = currentIndex ?? 0
        let removedBefore = entries.prefix(oldIndex).filter { ids.contains($0.track.id) }.count
        entries.removeAll { ids.contains($0.track.id) }
        guard !entries.isEmpty else {
            currentIndex = nil
            return currentID != nil
        }
        if let currentID, !ids.contains(currentID) {
            currentIndex = entries.firstIndex { $0.track.id == currentID }
            return false
        }
        // The current item went: what followed it is now at oldIndex - removedBefore.
        let candidate = oldIndex - removedBefore
        currentIndex = candidate < entries.count ? candidate : 0
        return currentID != nil
    }

    /// Makes `id` current. Returns false if it is not in the queue.
    public mutating func select(id: String) -> Bool {
        guard let i = entries.firstIndex(where: { $0.track.id == id }) else { return false }
        currentIndex = i
        return true
    }

    /// Moves to the next item; returns false (cursor unchanged) at the end.
    public mutating func advance() -> Bool {
        guard let i = currentIndex, i + 1 < entries.count else { return false }
        currentIndex = i + 1
        return true
    }

    /// Moves to the previous item; returns false (cursor unchanged) at the start.
    public mutating func goBack() -> Bool {
        guard let i = currentIndex, i > 0 else { return false }
        currentIndex = i - 1
        return true
    }

    /// Back to the first item (after the queue played to its end).
    public mutating func rewind() {
        currentIndex = entries.isEmpty ? nil : 0
    }

    public func entry(id: String) -> Entry? { entries.first { $0.track.id == id } }
}

/// Which files a folder or a dropped list contains. Pure aside from the directory walk.
public enum AudioFileFilter {
    public static let extensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "mp4", "alac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "ogg", "opus",
    ]

    public static func isAudioFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Files as given, folders expanded recursively (sorted by path, hidden files skipped).
    public static func expand(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let found = (fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL } ?? [])
                    .filter(isAudioFile)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                out.append(contentsOf: found)
            } else if isAudioFile(url) {
                out.append(url)
            }
        }
        return out
    }
}
