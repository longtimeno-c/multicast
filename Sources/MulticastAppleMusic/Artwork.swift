import CoreGraphics
import Foundation
import ImageIO
import MulticastHubModel
import UniformTypeIdentifiers

/// What an Apple Music `ArtworkID` points at. The id is a stable, self-describing string, so the
/// hub (and the remote's cache) can key on it and the provider can resolve it again later
/// without remembering every id it handed out.
///
/// Forms: `am.track.<persistentID>` (a Music app track: its first artwork) and
/// `mk.item.<musicItemID>` (a MusicKit song or playlist).
public enum AppleMusicArtworkRef: Equatable, Hashable, Sendable {
    case musicAppTrack(persistentID: String)
    case musicKitItem(id: String)

    static let musicAppPrefix = "am.track."
    static let musicKitPrefix = "mk.item."

    public var artworkID: ArtworkID {
        switch self {
        case .musicAppTrack(let pid): return Self.musicAppPrefix + pid
        case .musicKitItem(let id): return Self.musicKitPrefix + id
        }
    }

    /// nil for ids this module did not make (another source's artwork, garbage).
    public init?(artworkID: ArtworkID) {
        if artworkID.hasPrefix(Self.musicAppPrefix) {
            let pid = String(artworkID.dropFirst(Self.musicAppPrefix.count))
            guard Self.isPersistentID(pid) else { return nil }
            self = .musicAppTrack(persistentID: pid)
        } else if artworkID.hasPrefix(Self.musicKitPrefix) {
            let id = String(artworkID.dropFirst(Self.musicKitPrefix.count))
            guard !id.isEmpty, id.count <= 128, !id.contains(where: \.isWhitespace) else { return nil }
            self = .musicKitItem(id: id)
        } else {
            return nil
        }
    }

    /// Music app persistent ids are 16 hex digits; accept 1…32 so a format change does not
    /// break artwork, but nothing that could smuggle script text.
    static func isPersistentID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.allSatisfy(\.isHexDigit)
    }
}

/// Scales encoded images for `artwork(id:maxPixel:)`. Pure ImageIO; works on macOS and iOS.
public enum ArtworkScaler {
    /// Returns `data` unchanged when `maxPixel` is 0 or the image already fits; otherwise a
    /// re-encoded thumbnail whose longer side is `maxPixel` (JPEG, or PNG when the image has
    /// alpha). nil when `data` is not a decodable image.
    public static func scale(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        guard maxPixel > 0 else { return data }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if w > 0, h > 0, max(w, h) <= maxPixel { return data }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let hasAlpha: Bool
        switch thumb.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, thumb, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Thread-safe wrapper around the hub model's byte-bounded `ArtworkCache`.
final class LockedArtworkCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: ArtworkCache

    init(byteLimit: Int = 24 * 1024 * 1024) {
        cache = ArtworkCache(byteLimit: byteLimit)
    }

    func data(for key: ArtworkCache.Key) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return cache.data(for: key)
    }

    func insert(_ data: Data, for key: ArtworkCache.Key) {
        lock.lock(); defer { lock.unlock() }
        cache.insert(data, for: key)
    }
}
