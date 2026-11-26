#!/usr/bin/env swift
// Draws Multicast's app icon and writes every size the Mac and iPhone apps need into
// Apps/Shared/Assets.xcassets/AppIcon.appiconset.
//
//   swift Apps/Scripts/make-icon.swift            (from the repository root)
//
// The mark is "one stream, many speakers": one source on the left whose stream fans out to
// three speakers on the right, in the app's one accent blue on a dark ground. The Mac icon sits
// on the macOS grid (an 824 pt rounded square centred in 1024, with a soft shadow); the iPhone
// icon fills the square edge to edge (iOS rounds the corners itself).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

/// The accent (the system blue in dark appearance) and the ground.
let accent = color(0x0A84FF)
let groundTop = color(0x2C2C30)
let groundBottom = color(0x141416)

/// Draws the mark into `rect` (the square the artwork occupies), in a 1024-unit design space.
func drawMark(_ c: CGContext, in rect: CGRect) {
    let s = rect.width / 1024
    // Below about 80 px a ring closes up into a blob: speakers become solid dots there, and the
    // stream gets heavier so it survives the Dock's smallest sizes.
    let small = rect.width < 80
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + (1024 - y) * s) }

    // Ground: a quiet vertical gradient, lighter at the top.
    c.saveGState()
    c.addRect(rect)
    c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [groundTop, groundBottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    c.restoreGState()

    let source = p(318, 512)
    let speakers = [p(716, 300), p(716, 512), p(716, 724)]

    // The stream: one line out of the source that splits into three, drawn as smooth curves.
    c.setStrokeColor(accent)
    c.setLineWidth((small ? 84 : 58) * s)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    let split = p(470, 512)
    c.move(to: source)
    c.addLine(to: split)
    c.strokePath()
    for target in speakers {
        c.move(to: split)
        let mid = CGPoint(x: (split.x + target.x) / 2, y: 0)
        c.addCurve(to: target, control1: CGPoint(x: mid.x, y: split.y), control2: CGPoint(x: mid.x, y: target.y))
        c.strokePath()
    }

    // The source: a solid disc. The speakers: rings, so the source reads as the one that plays.
    c.setFillColor(accent)
    let r0 = 112 * s
    c.fillEllipse(in: CGRect(x: source.x - r0, y: source.y - r0, width: r0 * 2, height: r0 * 2))
    let r1 = 70 * s
    if small {
        let rs = 92 * s
        for t in speakers { c.fillEllipse(in: CGRect(x: t.x - rs, y: t.y - rs, width: rs * 2, height: rs * 2)) }
        return
    }
    for t in speakers {
        c.setFillColor(groundBottom)
        c.fillEllipse(in: CGRect(x: t.x - r1, y: t.y - r1, width: r1 * 2, height: r1 * 2))
        c.setStrokeColor(accent)
        c.setLineWidth(40 * s)
        c.strokeEllipse(in: CGRect(x: t.x - r1, y: t.y - r1, width: r1 * 2, height: r1 * 2).insetBy(dx: 20 * s, dy: 20 * s))
    }
}

enum Style { case mac, ios }

func render(_ style: Style, pixels: Int) -> CGImage {
    let n = CGFloat(pixels)
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    switch style {
    case .ios:
        // Full bleed and opaque: iOS masks the corners.
        drawMark(c, in: CGRect(x: 0, y: 0, width: n, height: n))
    case .mac:
        // The macOS grid: an 824/1024 rounded square, centred a little high, with a soft shadow.
        let side = n * 824 / 1024
        let rect = CGRect(x: (n - side) / 2, y: (n - side) / 2 + n * 10 / 1024, width: side, height: side)
        let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        if pixels >= 64 {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -n * 10 / 1024), blur: n * 28 / 1024, color: color(0x000000, 0.35))
            c.addPath(shape)
            c.setFillColor(groundBottom)
            c.fillPath()
            c.restoreGState()
        }
        c.saveGState()
        c.addPath(shape)
        c.clip()
        drawMark(c, in: rect)
        c.restoreGState()
        // A hairline edge so the shape holds on a dark Dock.
        c.addPath(shape)
        c.setStrokeColor(color(0xFFFFFF, 0.12))
        c.setLineWidth(max(1, n / 512))
        c.strokePath()
    }
    return c.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = set.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// macOS: 16, 32, 128, 256 and 512 points at 1x and 2x.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        write(render(.mac, pixels: points * scale), name)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
// iOS: one 1024 image; Xcode makes the rest.
write(render(.ios, pixels: 1024), "ios-1024.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
// The icon is already dark: the same art for the dark appearance, so iOS shows it as drawn
// instead of darkening it further.
var dark: [String: Any] = ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"]
dark["appearances"] = [["appearance": "luminosity", "value": "dark"]]

let contents: [String: Any] = ["images": (images as [Any]) + [dark], "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: set.appendingPathComponent("Contents.json"))
let catalog: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(set.path)")
