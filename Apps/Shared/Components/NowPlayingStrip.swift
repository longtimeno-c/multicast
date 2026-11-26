import SwiftUI
import MulticastHubModel

/// Previous, play/pause, next. The play triangle sits a little toward its point so it reads
/// centred; pause is symmetric and doesn't move.
struct TransportButtons: View {
    var isPlaying: Bool
    var canPlay: Bool
    var canSkip: Bool
    var playSize: CGFloat = 22
    var skipSize: CGFloat = 15
    var showsPrevious = true
    /// Room between the buttons; the phone's full player spreads them for thumbs.
    var spacing: CGFloat = MC.Space.xs
    /// The smallest side of each button's target (44 on the phone); the glyph stays its size.
    var minTarget: CGFloat = 0
    var onPlayPause: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    /// A disabled ancestor (the phone while its link is down) dims the glyphs too: the explicit
    /// inks below would otherwise keep them looking live.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: spacing) {
            if showsPrevious {
                glyphButton("backward.fill", size: skipSize, label: "Previous", enabled: canSkip, action: onPrevious)
            }
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playSize, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: isPlaying ? 0 : playSize * 0.09)
                    .frame(width: max(minTarget, playSize + 14), height: max(minTarget, playSize + 14))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canPlay && isEnabled ? AnyShapeStyle(MC.Ink.primary) : AnyShapeStyle(MC.Ink.tertiary.opacity(0.5)))
            .disabled(!canPlay)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            glyphButton("forward.fill", size: skipSize, label: "Next", enabled: canSkip, action: onNext)
        }
    }

    /// Disabled glyphs step down to the tertiary ink at half strength: clearly off, still
    /// present. The explicit style would otherwise keep them looking live.
    private func glyphButton(_ symbol: String, size: CGFloat, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: max(minTarget, size + 14), height: max(minTarget, size + 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled && isEnabled ? AnyShapeStyle(MC.Ink.body) : AnyShapeStyle(MC.Ink.tertiary.opacity(0.5)))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Elapsed, a progress bar you can click to seek, remaining. Extrapolates between updates.
struct PlaybackPosition: View {
    var transport: TransportState
    var duration: TimeInterval
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = min(duration, transport.position(at: context.date))
            HStack(spacing: MC.Space.s) {
                Text(MC.Format.time(position))
                    .frame(minWidth: 34, alignment: .leading)
                    .contentTransition(.numericText(countsDown: false))
                ProgressView(value: position, total: max(duration, 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .overlay {
                        GeometryReader { g in
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { location in
                                    onSeek(duration * Double(location.x / max(g.size.width, 1)))
                                }
                        }
                    }
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(MC.Format.time(position)) of \(MC.Format.time(duration))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onSeek(min(duration, position + 10))
                        case .decrement: onSeek(max(0, position - 10))
                        @unknown default: break
                        }
                    }
                Text("\u{2212}" + MC.Format.time(duration - position))
                    .frame(minWidth: 38, alignment: .trailing)
                    .contentTransition(.numericText(countsDown: true))
            }
            .font(MC.Font.captionValue)
            .foregroundStyle(MC.Ink.secondary)
            .animation(MC.Motion.feedback, value: Int(position))
        }
    }
}

/// Artwork, title and artist, transport, and position when the source has one. The strip
/// keeps one height whatever is playing, so the speakers below never jump.
struct NowPlayingStrip: View {
    var info: NowPlayingInfo?
    /// The artwork bytes for `info.artworkID`, from the model's cache.
    var artwork: Data?
    var transport: TransportState
    var showsPosition: Bool
    /// Shown in place of the position for sources without one ("Live from Safari").
    var liveCaption: String?
    var emptyTitle = "Not playing"
    var emptySubtitle = "Choose something to play"
    var artworkSize: CGFloat = 64
    var onPlayPause: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onSeek: (TimeInterval) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A new item crossfades its artwork and words on one clock; position ticks don't animate.
    private var itemKey: String { info.map { $0.trackID ?? "\($0.title)|\($0.artist)" } ?? "" }

    var body: some View {
        HStack(alignment: .center, spacing: MC.Space.l) {
            ZStack {
                ArtworkView(data: artwork, size: artworkSize, radius: MC.Radius.medium,
                            isIcon: info?.artworkIsIcon ?? false)
                    .id(info?.artworkID ?? "none")
                    .transition(.opacity)
            }
            .animation(MC.Motion.state(reduceMotion), value: info?.artworkID)
            .animation(MC.Motion.feedback, value: artwork != nil)

            VStack(alignment: .leading, spacing: MC.Space.s) {
                HStack(alignment: .center, spacing: MC.Space.m) {
                    VStack(alignment: .leading, spacing: MC.Space.xxs) {
                        Text(info?.title ?? emptyTitle)
                            .font(MC.Font.title)
                            .foregroundStyle(info == nil ? AnyShapeStyle(MC.Ink.secondary) : AnyShapeStyle(MC.Ink.primary))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        Text(subtitle)
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .animation(MC.Motion.state(reduceMotion), value: itemKey)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(info.map { "Now playing: \($0.title), \(subtitle)" } ?? emptyTitle)

                    TransportButtons(isPlaying: transport.isPlaying, canPlay: info != nil,
                                     canSkip: info != nil && transport.canSkip,
                                     onPlayPause: onPlayPause, onNext: onNext, onPrevious: onPrevious)
                }

                positionRow
                    .frame(height: 14)
            }
        }
        .frame(height: artworkSize)
    }

    private var subtitle: String {
        guard let info else { return emptySubtitle }
        if let album = info.album, !album.isEmpty { return "\(info.artist) \u{2014} \(album)" }
        return info.artist
    }

    @ViewBuilder private var positionRow: some View {
        if let info, showsPosition, let duration = info.duration {
            PlaybackPosition(transport: transport, duration: duration, onSeek: onSeek)
        } else if info != nil, let liveCaption {
            HStack(spacing: MC.Space.xs) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                Text(liveCaption)
            }
            .font(MC.Font.caption)
            .foregroundStyle(MC.Ink.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }
}

/// The menu-bar and phone-sized version: artwork, two lines, play/pause.
struct NowPlayingCompact: View {
    var info: NowPlayingInfo?
    var artwork: Data?
    var transport: TransportState
    var artworkSize: CGFloat = 40
    var onPlayPause: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: artwork, size: artworkSize, radius: MC.Radius.small + 2,
                        isIcon: info?.artworkIsIcon ?? false)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(info?.title ?? "Not playing")
                    .font(MC.Font.bodyEmphasis)
                    .foregroundStyle(info == nil ? AnyShapeStyle(MC.Ink.secondary) : AnyShapeStyle(MC.Ink.primary))
                    .lineLimit(1)
                if let info {
                    Text(info.artist)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            TransportButtons(isPlaying: transport.isPlaying, canPlay: info != nil,
                             canSkip: info != nil && transport.canSkip,
                             playSize: 17, skipSize: 13, showsPrevious: false,
                             onPlayPause: onPlayPause, onNext: onNext, onPrevious: {})
        }
    }
}
