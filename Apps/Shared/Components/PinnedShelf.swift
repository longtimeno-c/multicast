import SwiftUI
import MulticastHubModel

/// Pinned playlists across the top of the library: one tap plays (in order), the context menu
/// shuffles or unpins. Apple Music and Spotify playlists side by side, the Spotify ones marked.
struct PinnedShelf: View {
    @Environment(HubModel.self) private var model
    var artworkSize: CGFloat

    var body: some View {
        if !model.pins.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: MC.Space.m) {
                    ForEach(model.pins) { pin in
                        PinnedTile(pin: pin, artworkSize: artworkSize)
                    }
                }
                .padding(.vertical, MC.Space.xxs)
            }
            .scrollClipDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned playlists")
        }
    }
}

private struct PinnedTile: View {
    @Environment(HubModel.self) private var model
    var pin: PinnedPlaylist
    var artworkSize: CGFloat

    var body: some View {
        Button { model.playPlaylist(pin.id) } label: {
            VStack(alignment: .leading, spacing: MC.Space.xs) {
                ArtworkView(data: model.artwork(pin.artworkID, maxPixel: 300), size: artworkSize, radius: MC.Radius.medium)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pin.name)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(MC.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(MC.Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.playPlaylist(pin.id) } label: { Label("Play", systemImage: "play") }
            Button { model.playPlaylist(pin.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Divider()
            Button { model.unpin(pin.id) } label: { Label("Unpin", systemImage: "pin.slash") }
        }
        .accessibilityLabel("\(pin.name), \(pin.source.title)")
        .accessibilityHint("Plays the playlist")
        .help("Play \(pin.name)")
    }

    /// Spotify pins say so; Apple Music ones give their length.
    private var detail: String {
        switch pin.source {
        case .appleMusic: pin.trackCount.map { $0 == 1 ? "1 song" : "\($0) songs" } ?? "Apple Music"
        default: pin.source.title
        }
    }
}
