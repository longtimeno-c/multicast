#if os(macOS)
import Carbon
import Foundation
import MulticastHubModel
import MulticastSources

/// Turns the Music app's Apple Event replies (see `MusicAppScript`) into hub types. Pure;
/// tested with hand-built descriptors.
public enum MusicAppParsing {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { "Music app reply: \(message)" }
    }

    /// The player as the `playerstate` handler reports it.
    public struct PlayerState: Equatable, Sendable {
        public struct Track: Equatable, Sendable {
            public var persistentID: String
            public var title: String
            public var artist: String
            public var album: String
            public var duration: TimeInterval?
        }

        public var state: MediaPlayerState
        public var shuffle: Bool
        /// Music's own volume, 0…100.
        public var volume: Int
        /// Seconds; nil when stopped.
        public var position: TimeInterval?
        public var track: Track?
    }

    /// What the `upnext` handler reports.
    public enum UpNext: Equatable, Sendable {
        /// The tracks after the current one in the playlist Music is playing, and how many
        /// follow it in total.
        case tracks([TrackItem], remaining: Int)
        /// Nothing is playing.
        case stopped
        /// Shuffle is on: Music does not tell other apps its shuffled order.
        case shuffled
        /// Music is playing something that is not in a playlist it exposes (e.g. a radio station).
        case unknown
    }

    static let missingValue = DescType(cMissingValue)

    // MARK: Scalars

    static func isMissing(_ d: NSAppleEventDescriptor) -> Bool {
        (d.descriptorType == typeType && d.typeCodeValue == missingValue) || d.descriptorType == typeNull
    }

    static func string(_ d: NSAppleEventDescriptor) -> String? {
        guard !isMissing(d) else { return nil }
        return d.stringValue
    }

    static func double(_ d: NSAppleEventDescriptor) -> Double? {
        guard !isMissing(d) else { return nil }
        switch d.descriptorType {
        case typeUnicodeText, typeUTF8Text, typeChar:
            return d.stringValue.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        default:
            let v = d.doubleValue
            return v.isFinite ? v : nil
        }
    }

    static func int(_ d: NSAppleEventDescriptor) -> Int? {
        double(d).map { Int($0.rounded()) }
    }

    static func items(_ d: NSAppleEventDescriptor, _ what: String) throws -> [NSAppleEventDescriptor] {
        guard d.descriptorType == typeAEList else { throw ParseError("\(what) is not a list") }
        let n = d.numberOfItems
        guard n > 0 else { return [] }
        return (1...n).compactMap { d.atIndex($0) }
    }

    // MARK: Lists

    /// `{ids, names, artists, albums, durations}` → tracks. Rows without an id are skipped;
    /// a missing title becomes "Unknown", missing artist/album become "".
    public static func trackColumns(_ d: NSAppleEventDescriptor) throws -> [TrackItem] {
        let cols = try items(d, "track columns")
        guard cols.count == 5 else { throw ParseError("expected 5 track columns, got \(cols.count)") }
        return try trackColumns(cols[0], cols[1], cols[2], cols[3], cols[4])
    }

    static func trackColumns(_ idsD: NSAppleEventDescriptor, _ namesD: NSAppleEventDescriptor, _ artistsD: NSAppleEventDescriptor,
                             _ albumsD: NSAppleEventDescriptor, _ durationsD: NSAppleEventDescriptor) throws -> [TrackItem] {
        let ids = try items(idsD, "ids"), names = try items(namesD, "names")
        let artists = try items(artistsD, "artists"), albums = try items(albumsD, "albums")
        let durations = try items(durationsD, "durations")
        let n = ids.count
        guard names.count == n, artists.count == n, albums.count == n, durations.count == n else {
            throw ParseError("track columns differ in length (\(n)/\(names.count)/\(artists.count)/\(albums.count)/\(durations.count))")
        }
        var out: [TrackItem] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let id = string(ids[i]), !id.isEmpty else { continue }
            out.append(TrackItem(
                id: id,
                title: nonEmpty(string(names[i])) ?? "Unknown",
                artist: string(artists[i]) ?? "",
                album: string(albums[i]) ?? "",
                duration: max(0, double(durations[i]) ?? 0),
                artworkID: AppleMusicArtworkRef.musicAppTrack(persistentID: id).artworkID))
        }
        return out
    }

    /// `{{id, name, trackCount, firstTrackID}, …}` → playlists, artwork from their first track.
    public static func playlists(_ d: NSAppleEventDescriptor) throws -> [PlaylistItem] {
        try items(d, "playlists").compactMap { row in
            let f = try items(row, "playlist row")
            // {id, name, count, firstTrackID} or, with folders, {…, isFolder, parentID}.
            guard f.count == 4 || f.count == 6 else { throw ParseError("playlist row has \(f.count) fields") }
            guard let id = string(f[0]), !id.isEmpty else { return nil }
            let first = string(f[3]).flatMap(nonEmpty)
            let isFolder = f.count == 6 && f[4].booleanValue
            let parent = f.count == 6 ? string(f[5]).flatMap(nonEmpty) : nil
            return PlaylistItem(
                id: id, name: nonEmpty(string(f[1])) ?? (isFolder ? "Untitled Folder" : "Untitled Playlist"),
                trackCount: max(0, int(f[2]) ?? 0),
                artworkID: first.map { AppleMusicArtworkRef.musicAppTrack(persistentID: $0).artworkID },
                isFolder: isFolder, parentID: parent)
        }
    }

    public static func playerState(_ d: NSAppleEventDescriptor) throws -> PlayerState {
        let f = try items(d, "player state")
        guard f.count == 5 else { throw ParseError("player state has \(f.count) fields") }
        let position = double(f[3]).flatMap { $0 < 0 ? nil : $0 }
        var track: PlayerState.Track?
        let info = try items(f[4], "current track")
        if info.count == 5, let id = string(info[0]), !id.isEmpty {
            let duration = double(info[4]).flatMap { $0 > 0 ? $0 : nil }
            track = PlayerState.Track(persistentID: id, title: nonEmpty(string(info[1])) ?? "Unknown",
                                      artist: string(info[2]) ?? "", album: string(info[3]) ?? "", duration: duration)
        }
        return PlayerState(state: MediaPlayerState(scriptValue: string(f[0]) ?? ""), shuffle: f[1].booleanValue,
                           volume: int(f[2]) ?? 0, position: position, track: track)
    }

    public static func upNext(_ d: NSAppleEventDescriptor) throws -> UpNext {
        let f = try items(d, "up next")
        guard let marker = f.first.flatMap(string) else { throw ParseError("up next has no marker") }
        switch marker {
        case "stopped": return .stopped
        case "shuffled": return .shuffled
        case "unknown": return .unknown
        case "ok":
            guard f.count == 7 else { throw ParseError("up next has \(f.count) fields") }
            let tracks = try trackColumns(f[2], f[3], f[4], f[5], f[6])
            return .tracks(tracks, remaining: max(0, int(f[1]) ?? 0))
        default:
            throw ParseError("unexpected up next marker \(marker)")
        }
    }

    // MARK: Mapping

    /// The hub's view of the player at `sampledAt`.
    public static func snapshot(_ s: PlayerState, sampledAt: Date, upNextRevision: UInt64,
                                libraryRevision: UInt64) -> AppleMusicSnapshot {
        let playing = s.state == .playing || s.state == .fastForwarding || s.state == .rewinding
        let np = s.track.map {
            NowPlayingInfo(title: $0.title, artist: $0.artist, album: $0.album.isEmpty ? nil : $0.album,
                           artworkID: AppleMusicArtworkRef.musicAppTrack(persistentID: $0.persistentID).artworkID,
                           artworkIsIcon: false, duration: $0.duration, trackID: $0.persistentID)
        }
        let transport = TransportState(
            isPlaying: playing && np != nil, position: s.position ?? 0, positionAsOf: sampledAt,
            canSkip: np != nil, canSeek: np?.duration != nil)
        return AppleMusicSnapshot(nowPlaying: np, transport: transport, upNextRevision: upNextRevision,
                                  libraryRevision: libraryRevision)
    }

    /// AppleScript error dictionary → the hub's error vocabulary.
    public static func commandError(code: Int, message: String) -> HubCommandError {
        switch code {
        case -1743:
            return HubCommandError(.permissionMissing, "Multicast isn't allowed to control Music. Turn it on in System Settings › Privacy & Security › Automation.")
        case -1744:
            return HubCommandError(.permissionMissing, "Multicast needs permission to control Music.")
        case -1728, -1719:
            return HubCommandError(.notFound, "That item is no longer in your Music library.")
        case -600, -609, -10810:
            return HubCommandError(.unavailable, "Music isn't open.")
        case -1712:
            return HubCommandError(.failed, "Music didn't answer in time.")
        default:
            return HubCommandError(.failed, message.isEmpty ? "Music reported error \(code)." : message)
        }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}

extension AppleMusicSnapshot {
    /// True when `self` differs from `previous` in a way the hub should publish: different
    /// track or tags, play/pause, capabilities, revisions, or a position jump (seek) of more
    /// than `seekTolerance` from where `previous` would be by now. Play progress is not a change.
    public func isSignificantChange(from previous: AppleMusicSnapshot?, seekTolerance: TimeInterval = 1.5) -> Bool {
        guard let previous else { return true }
        if nowPlaying != previous.nowPlaying || upNextRevision != previous.upNextRevision
            || libraryRevision != previous.libraryRevision || transport.isPlaying != previous.transport.isPlaying
            || transport.canSkip != previous.transport.canSkip || transport.canSeek != previous.transport.canSeek {
            return true
        }
        let expected = previous.transport.position(at: transport.positionAsOf)
        return abs(transport.position - expected) > seekTolerance
    }
}
#endif
