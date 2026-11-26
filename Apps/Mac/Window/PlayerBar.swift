import SwiftUI
import MulticastHubModel

/// The player across the top of the window, read like Music's: transport and shuffle on the
/// left, what is playing with its position in the middle, Up Next on the right.
struct PlayerBar: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        ZStack {
            NowPlayingDisplay()
                .frame(maxWidth: 520)
                .padding(.horizontal, 200)
            HStack(spacing: MC.Space.m) {
                ShuffleButton()
                TransportButtons(isPlaying: model.transport.isPlaying, canPlay: model.canPlay,
                                 canSkip: model.canPlay && model.transport.canSkip,
                                 playSize: 20, skipSize: 14,
                                 onPlayPause: model.togglePlayPause, onNext: model.next, onPrevious: model.previous)
                Spacer(minLength: 0)
                UpNextButton()
            }
        }
        // Room for the window's close, minimise and zoom buttons.
        .padding(.leading, 84)
        .padding(.trailing, MC.Space.l)
        .padding(.vertical, MC.Space.s)
        .frame(height: 64)
        .background(MC.Surface.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MC.Ink.faint).frame(height: 0.5)
        }
    }
}

/// Artwork, title over artist, and the position (or the live caption of a captured app), on a
/// quiet panel like Music's display.
private struct NowPlayingDisplay: View {
    @Environment(HubModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(info?.artworkID), size: 40, radius: MC.Radius.small,
                        isIcon: info?.artworkIsIcon ?? false)
                .id(info?.artworkID ?? "none")
                .transition(.opacity)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info?.title ?? "Not Playing")
                        .font(MC.Font.bodyEmphasis)
                        .foregroundStyle(info == nil ? AnyShapeStyle(MC.Ink.secondary) : AnyShapeStyle(MC.Ink.primary))
                    Text(subtitle)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(info.map { "Now playing: \($0.title), \(subtitle)" } ?? "Not playing")
                position
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MC.Space.s)
        .padding(.vertical, MC.Space.xs)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: MC.Radius.medium, style: .continuous).fill(MC.Surface.group))
        .animation(MC.Motion.state(reduceMotion), value: info?.identity)
    }

    private var info: NowPlayingInfo? { model.nowPlaying }

    private var subtitle: String {
        guard let info else { return "Choose a playlist to play" }
        if let album = info.album, !album.isEmpty { return "\(info.artist) \u{2014} \(album)" }
        return info.artist
    }

    @ViewBuilder private var position: some View {
        if let info, model.hasPosition, let duration = info.duration {
            PlaybackPosition(transport: model.transport, duration: duration, onSeek: model.seek(to:))
        } else if info != nil, model.activeSource == .app {
            HStack(spacing: MC.Space.xs) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                Text("Live")
            }
            .font(MC.Font.caption)
            .foregroundStyle(MC.Ink.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }
}

/// Shuffles Up Next, or puts it back; the accent says it's on.
private struct ShuffleButton: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        let on = model.queue.isShuffled
        Button(action: model.toggleShuffle) {
            Image(systemName: "shuffle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(on ? AnyShapeStyle(MC.accent) : AnyShapeStyle(MC.Ink.body))
        .disabled(!model.canPlay && model.upNext.items.isEmpty)
        .help(on ? "Shuffle is on: Up Next plays in a random order" : "Shuffle Up Next")
        .accessibilityLabel("Shuffle")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Opens and closes Up Next beside the library.
private struct UpNextButton: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        Button(action: model.toggleUpNext) {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
                .background {
                    if model.showsUpNext {
                        RoundedRectangle(cornerRadius: MC.Radius.small + 2, style: .continuous).fill(MC.Surface.well)
                    }
                }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(model.showsUpNext ? AnyShapeStyle(MC.Ink.primary) : AnyShapeStyle(MC.Ink.body))
        .keyboardShortcut("u", modifiers: [.command, .option])
        .help(model.showsUpNext ? "Hide Up Next" : "Show Up Next")
        .accessibilityLabel("Up Next")
        .accessibilityValue(model.showsUpNext ? "Shown" : "Hidden")
    }
}

// MARK: - Up Next

/// What is playing, then the queue: a click plays a song, drag reorders, Delete or the context
/// menu removes, Clear empties it.
struct UpNextPanel: View {
    @Environment(HubModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var activation = RowActivation()

    var body: some View {
        List(selection: $selection) {
            if let info = model.nowPlaying {
                SourceSectionTitle("Now Playing", isFirst: true)
                NowPlayingRow(info: info)
                    .selectionDisabled()
                    .sourceRow()
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: MC.Space.xxs) {
                    Text("Up Next")
                        .font(MC.Font.captionEmphasis)
                        .foregroundStyle(MC.Ink.secondary)
                        .accessibilityAddTraits(.isHeader)
                    if let note { Text(note).font(MC.Font.caption).foregroundStyle(MC.Ink.secondary).lineLimit(nil) }
                }
                Spacer(minLength: MC.Space.s)
                Button("Clear") { model.clearQueue() }
                    .buttonStyle(.borderless)
                    .disabled(model.upNext.items.isEmpty)
                    .help("Remove every song from Up Next")
            }
            .padding(.top, model.nowPlaying == nil ? 0 : MC.Space.l)
            .selectionDisabled()
            .sourceRow()
            UpNextRows(filter: "", activate: { id in activation.once { model.playQueued(id) } })
            SpotifyLinkField(kind: .song)
                .selectionDisabled()
                .sourceRow()
        }
        .sourceList()
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Play") { ids.first.map { model.playQueued($0) } }
            Divider()
            Button("Remove from Up Next") { model.removeFromQueue(Array(ids)) }
        } primaryAction: { ids in
            ids.first.map { id in activation.once { model.playQueued(id) } }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            model.removeFromQueue(Array(selection))
            selection = []
        }
    }

    private var note: String? {
        let n = model.upNext.totalCount ?? model.upNext.items.count
        if model.queue.isHeld { return "Something else is playing. These \(songs(n)) wait; Next carries on with them." }
        if n == 0 { return nil }
        return model.queue.isShuffled ? "\(songs(n)), shuffled" : songs(n)
    }
}

private struct NowPlayingRow: View {
    @Environment(HubModel.self) private var model
    var info: NowPlayingInfo

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(info.artworkID), size: 40, radius: MC.Radius.small, isIcon: info.artworkIsIcon)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(info.title).font(MC.Font.bodyEmphasis).foregroundStyle(MC.Ink.primary)
                Text(info.artist).font(MC.Font.caption).foregroundStyle(MC.Ink.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: MC.Space.s)
            if model.transport.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MC.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, MC.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}
