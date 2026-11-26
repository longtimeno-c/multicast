#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation
import ImageIO
import MulticastHubModel
import UniformTypeIdentifiers

/// Stand-in album covers, drawn once: flat, graphic compositions of the kind real covers use,
/// so the mock screens carry artwork without borrowing anyone's.
enum MockArtwork {
    enum Design: CaseIterable {
        case sunOverWater, bands, arcs, dots, ring, split, stack, horizon
    }

    private static var cache: [String: Data] = [:]

    /// Artwork ids the mock state refers to; bytes are served by `MockHubBackend.artwork(id:maxPixel:)`.
    static func id(_ design: Design) -> ArtworkID { "cover.\(design)" }
    static func iconID(_ bundleID: String) -> ArtworkID { "icon.\(bundleID)" }

    /// Every image the mock can serve, drawn once on the main thread.
    @MainActor static func store(appBundleIDs: [String]) -> [ArtworkID: Data] {
        var out: [ArtworkID: Data] = [:]
        for d in Design.allCases { out[id(d)] = cover(d) }
        for b in appBundleIDs { if let data = appIcon(bundleID: b) { out[iconID(b)] = data } }
        return out
    }

    static func cover(_ design: Design) -> Data {
        let key = "\(design)"
        if let hit = cache[key] { return hit }
        let data = render(design)
        cache[key] = data
        return data
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func render(_ design: Design) -> Data {
        let n = 400
        let s = CGFloat(n)
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ hex: UInt32) { ctx.setFillColor(rgb(hex)) }
        func rect(_ r: CGRect, _ hex: UInt32) { fill(hex); ctx.fill(r) }
        func circle(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32) {
            fill(hex); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        switch design {
        case .sunOverWater:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0x1F3A5F)
            circle(CGPoint(x: s * 0.62, y: s * 0.58), s * 0.22, 0xF28C38)
            rect(CGRect(x: 0, y: 0, width: s, height: s * 0.42), 0x16304F)
            for i in 0..<6 {
                let y = s * 0.36 - CGFloat(i) * s * 0.055
                rect(CGRect(x: s * 0.46 + CGFloat(i) * 6, y: y, width: s * 0.32 - CGFloat(i) * 12, height: 5), 0xF28C38)
            }
        case .bands:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0xEFE6D6)
            for i in 0..<7 {
                let h = s * (0.02 + 0.012 * CGFloat(i))
                rect(CGRect(x: s * 0.12, y: s * 0.12 + CGFloat(i) * s * 0.11, width: s * 0.76, height: h), 0x1B1B1B)
            }
        case .arcs:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0x2F5D50)
            ctx.setLineWidth(s * 0.045)
            for i in 0..<5 {
                ctx.setStrokeColor(rgb(i.isMultiple(of: 2) ? 0xE9D8A6 : 0x94C9A9))
                ctx.addArc(center: CGPoint(x: 0, y: 0), radius: s * (0.3 + 0.13 * CGFloat(i)),
                           startAngle: 0, endAngle: .pi / 2, clockwise: false)
                ctx.strokePath()
            }
        case .dots:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0xE8B4B8)
            for x in 0..<6 { for y in 0..<6 {
                let big = (x + y) % 5 == 0
                circle(CGPoint(x: s * (0.15 + 0.14 * CGFloat(x)), y: s * (0.15 + 0.14 * CGFloat(y))),
                       big ? s * 0.045 : s * 0.022, big ? 0x7A1F2B : 0xA4505C)
            } }
        case .ring:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0x18181B)
            ctx.setLineWidth(s * 0.018)
            ctx.setStrokeColor(rgb(0xF4F1EA))
            ctx.strokeEllipse(in: CGRect(x: s * 0.24, y: s * 0.24, width: s * 0.52, height: s * 0.52))
            circle(CGPoint(x: s * 0.5, y: s * 0.76), s * 0.035, 0xD94F3D)
        case .split:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0xF2C14E)
            rect(CGRect(x: 0, y: 0, width: s * 0.5, height: s), 0x3A6EA5)
            circle(CGPoint(x: s * 0.5, y: s * 0.5), s * 0.18, 0xF7F4EC)
            rect(CGRect(x: s * 0.5, y: s * 0.32, width: s * 0.18, height: s * 0.36), 0xF2C14E)
        case .stack:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0xD9DCD6)
            let colors: [UInt32] = [0x2E4057, 0x4F6D7A, 0x8FA6AC, 0xC0D6DF]
            for (i, c) in colors.enumerated() {
                rect(CGRect(x: s * 0.18 + CGFloat(i) * s * 0.05, y: s * 0.18 + CGFloat(i) * s * 0.12,
                            width: s * 0.5, height: s * 0.2), c)
            }
        case .horizon:
            rect(CGRect(x: 0, y: 0, width: s, height: s), 0x5C3D6E)
            rect(CGRect(x: 0, y: 0, width: s, height: s * 0.38), 0x2A1B3D)
            circle(CGPoint(x: s * 0.3, y: s * 0.38), s * 0.14, 0xFFB38A)
            rect(CGRect(x: 0, y: 0, width: s, height: s * 0.38), 0x2A1B3D)
            rect(CGRect(x: 0, y: s * 0.38, width: s, height: 3), 0xFFB38A)
        }

        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// An installed app's icon as PNG, for the captured-app source. Mac only: iOS has no other
    /// apps' icons to draw, so the remote shows its placeholder.
    static func appIcon(bundleID: String, size: CGFloat = 128) -> Data? {
        #if canImport(AppKit)
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])
        cache[bundleID] = data
        return data
        #else
        return nil
        #endif
    }
}
