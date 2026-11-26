import Foundation

// MARK: - Now playing and transport

public struct NowPlayingInfo: Equatable, Hashable, Sendable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    public var artworkID: ArtworkID?
    /// The artwork is an app icon (a captured app), shown unclipped.
    public var artworkIsIcon: Bool
    /// Seconds; nil when the source has no notion of length (a captured app).
    public var duration: TimeInterval?
    /// Library or file track id when the item came from the hub's own lists, so they can mark it.
    public var trackID: String?

    public init(title: String, artist: String, album: String? = nil, artworkID: ArtworkID? = nil,
                artworkIsIcon: Bool = false, duration: TimeInterval? = nil, trackID: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkID = artworkID
        self.artworkIsIcon = artworkIsIcon
        self.duration = duration
        self.trackID = trackID
    }

    /// What makes it a different item rather than an update to the same one.
    public var identity: String { trackID ?? "\(title)\u{1F}\(artist)" }
}

public struct TransportState: Equatable, Hashable, Sendable, Codable {
    public var isPlaying: Bool
    /// Seconds into the item at `positionAsOf`. Views extrapolate while playing instead of the
    /// backend publishing every tick.
    public var position: TimeInterval
    /// Wall-clock time of `position`, in the clock of whoever produced the state. A network
    /// client re-bases it to its own clock on receipt (the hub's and the phone's clocks differ).
    public var positionAsOf: Date
    public var canSkip: Bool
    public var canSeek: Bool

    public init(isPlaying: Bool = false, position: TimeInterval = 0, positionAsOf: Date = .distantPast,
                canSkip: Bool = true, canSeek: Bool = true) {
        self.isPlaying = isPlaying
        self.position = position
        self.positionAsOf = positionAsOf
        self.canSkip = canSkip
        self.canSeek = canSeek
    }

    public func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return position + max(0, date.timeIntervalSince(positionAsOf))
    }
}

/// Peak levels of the outgoing mix, 0…1 (linear, post-master).
public struct StereoLevels: Equatable, Hashable, Sendable, Codable {
    public var left: Float
    public var right: Float

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }

    public static let silent = StereoLevels(left: 0, right: 0)
}
