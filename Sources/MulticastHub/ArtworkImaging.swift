import Foundation
import ImageIO
import MulticastHubModel
import UniformTypeIdentifiers

/// Downscaling and re-encoding of cover images with ImageIO (no AppKit, so it runs anywhere).
public enum ArtworkImaging {
    /// `data` scaled so its longer side is at most `maxPixel` (0 = unchanged), in its original
    /// encoding when no scaling is needed, otherwise JPEG (PNG when it has alpha).
    public static func scaled(_ data: Data, maxPixel: Int) -> Data? {
        guard maxPixel > 0 else { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if max(w, h) <= maxPixel, w > 0 { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        return encode(image, as: hasAlpha ? .png : .jpeg)
    }

    /// JPEG bytes for an AirPlay speaker's display (which takes JPEG only), at most `maxPixel`.
    public static func jpeg(_ data: Data, maxPixel: Int = 600) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let type = CGImageSourceGetType(src) as String?, type == UTType.jpeg.identifier,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           max((props[kCGImagePropertyPixelWidth] as? Int) ?? .max, (props[kCGImagePropertyPixelHeight] as? Int) ?? .max) <= maxPixel {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return encode(image, as: .jpeg)
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// The hub's own artwork by id (file covers, fetched Spotify covers), byte-limited, oldest
/// dropped first. Scaled variants are cached separately in an `ArtworkCache`.
struct ArtworkStore {
    private var originals: [ArtworkID: Data] = [:]
    private var order: [ArtworkID] = []
    private var bytes = 0
    let byteLimit: Int
    var scaledCache = ArtworkCache(byteLimit: 16 << 20)

    init(byteLimit: Int = 64 << 20) { self.byteLimit = byteLimit }

    func original(_ id: ArtworkID) -> Data? { originals[id] }

    mutating func insert(_ data: Data, for id: ArtworkID) {
        if let old = originals[id] {
            bytes -= old.count
            order.removeAll { $0 == id }
        }
        originals[id] = data
        order.append(id)
        bytes += data.count
        while bytes > byteLimit, order.count > 1 {
            let victim = order.removeFirst()
            bytes -= originals.removeValue(forKey: victim)?.count ?? 0
        }
    }

    mutating func remove(_ id: ArtworkID) {
        guard let old = originals.removeValue(forKey: id) else { return }
        bytes -= old.count
        order.removeAll { $0 == id }
    }

    /// The original scaled to `maxPixel` (cached).
    mutating func data(for id: ArtworkID, maxPixel: Int) -> Data? {
        guard let original = originals[id] else { return nil }
        if maxPixel <= 0 { return original }
        let key = ArtworkCache.Key(id: id, maxPixel: maxPixel)
        if let hit = scaledCache.data(for: key) { return hit }
        guard let scaled = ArtworkImaging.scaled(original, maxPixel: maxPixel) else { return original }
        scaledCache.insert(scaled, for: key)
        return scaled
    }
}
