import SwiftUI
import MulticastHubModel

/// A folder's cover: the covers of up to four playlists inside it, two by two (one fills the
/// square), or a folder glyph when it has none.
struct FolderArtwork: View {
    @Environment(HubModel.self) private var model
    var artworkIDs: [ArtworkID]
    var side: CGFloat
    var maxPixel: Int

    var body: some View {
        let ids = Self.fill(Array(artworkIDs.prefix(4)))
        let radius = side < 48 ? MC.Radius.small : MC.Radius.medium
        Group {
            if ids.count >= 2 {
                let half = (side - 1) / 2
                VStack(spacing: 1) {
                    HStack(spacing: 1) { cell(ids, 0, half); cell(ids, 1, half) }
                    HStack(spacing: 1) { cell(ids, 2, half); cell(ids, 3, half) }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
            } else if let only = ids.first {
                ArtworkView(data: model.artwork(only, maxPixel: maxPixel), size: side, radius: radius)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(MC.Surface.well)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: side * 0.36, weight: .regular))
                            .foregroundStyle(MC.Ink.tertiary)
                    }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Two or three covers repeat to fill the square (two cross over the diagonal).
    static func fill(_ ids: [ArtworkID]) -> [ArtworkID] {
        switch ids.count {
        case 2: [ids[0], ids[1], ids[1], ids[0]]
        case 3: ids + [ids[0]]
        default: ids
        }
    }

    @ViewBuilder private func cell(_ ids: [ArtworkID], _ i: Int, _ size: CGFloat) -> some View {
        if i < ids.count, let data = model.artwork(ids[i], maxPixel: maxPixel / 2), let image = ArtworkView.decode(data) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Rectangle().fill(MC.Surface.well).frame(width: size, height: size)
        }
    }
}
