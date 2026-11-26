import SwiftUI
import ImageIO

/// Album artwork from encoded image data, or a quiet placeholder. Album art gets the hairline
/// edge Music uses, so a black or cream cover keeps its square on any ground. `isIcon` shows an
/// app icon unclipped and scaled past its transparent margin, so the visible squircle fills the
/// box and its edge sits on the column like a cover's would.
struct ArtworkView: View {
    var data: Data?
    var size: CGFloat
    var radius: CGFloat = MC.Radius.medium
    var isIcon = false

    var body: some View {
        Group {
            if let image = Self.decode(data) {
                if isIcon {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .scaleEffect(Self.iconBleed)
                } else {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        }
                }
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(MC.Surface.well)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.36, weight: .regular))
                            .foregroundStyle(MC.Ink.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// macOS and iOS app icons draw their shape in about the middle 824/1024 of the canvas.
    static let iconBleed: CGFloat = 1024 / 824

    private static let cache = NSCache<NSData, CGImage>()

    static func decode(_ data: Data?) -> CGImage? {
        guard let data else { return nil }
        if let hit = cache.object(forKey: data as NSData) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache.setObject(image, forKey: data as NSData)
        return image
    }
}
