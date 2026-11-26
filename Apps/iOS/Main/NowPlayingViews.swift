import SwiftUI
import MulticastHubModel

/// Now playing in the bottom accessory: artwork, title over artist, play/pause and next. The
/// words open the full player; the buttons act in place.
struct MiniPlayer: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: MC.Space.m) {
            Button { session.navigation.showsNowPlaying = true } label: {
                HStack(spacing: MC.Space.m) {
                    ArtworkView(data: model.artwork(model.nowPlaying?.artworkID), size: 32, radius: MC.Radius.small + 2,
                                isIcon: model.nowPlaying?.artworkIsIcon ?? false)
                        .id(model.nowPlaying?.artworkID ?? "none")
                        .transition(.opacity)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.nowPlaying?.title ?? "Not Playing")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(model.nowPlaying == nil ? AnyShapeStyle(MC.Ink.secondary) : AnyShapeStyle(MC.Ink.primary))
                        Text(model.nowPlaying?.artist ?? "Choose music in the Music tab")
                            .font(.footnote)
                            .foregroundStyle(MC.Ink.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(MC.Motion.state(reduceMotion), value: model.nowPlaying?.identity)
            .accessibilityLabel(model.nowPlaying.map { "Now playing: \($0.title), \($0.artist)" } ?? "Not playing")
            .accessibilityHint("Opens the player")

            TransportButtons(isPlaying: model.transport.isPlaying, canPlay: model.canPlay,
                             canSkip: model.canPlay && model.transport.canSkip,
                             playSize: 19, skipSize: 15, showsPrevious: false, minTarget: 44,
                             onPlayPause: model.togglePlayPause, onNext: model.next, onPrevious: {})
                .buttonStyle(.plain)
        }
        .padding(.leading, MC.Space.m)
        .padding(.trailing, MC.Space.s)
        .disabled(session.linkProblem != nil)
    }
}

/// The full player: artwork, what it is and where it comes from, a scrubber when the source
/// can seek, transport, the master volume, and the speakers one tap away.
struct NowPlayingSheet: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { largeTextLayout } else { regularLayout }
        }
        .background(MC.Surface.canvas)
        .presentationDragIndicator(.visible)
        .presentationBackground(MC.Surface.canvas)
        .disabled(session.linkProblem != nil)
    }

    /// Large accessibility text: everything scrolls, the artwork steps down first, words get
    /// two lines, and the speakers button stays pinned in view.
    private var largeTextLayout: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.5, 220)
            ScrollView {
                VStack(spacing: MC.Space.xl) {
                    sourceLine
                        .padding(.top, MC.Space.xxl)
                    ArtworkView(data: model.artwork(model.nowPlaying?.artworkID), size: side, radius: MC.Radius.large,
                                isIcon: model.nowPlaying?.artworkIsIcon ?? false)
                        .id(model.nowPlaying?.artworkID ?? "none")
                        .frame(width: side, height: side)
                    VStack(alignment: .leading, spacing: MC.Space.xl) {
                        titles
                        position
                        TransportButtons(isPlaying: model.transport.isPlaying, canPlay: model.canPlay,
                                         canSkip: model.canPlay && model.transport.canSkip,
                                         playSize: 40, skipSize: 28, spacing: MC.Space.xxl,
                                         onPlayPause: model.togglePlayPause, onNext: model.next, onPrevious: model.previous)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        masterVolume
                    }
                }
                .padding(.horizontal, MC.Space.xxl)
                .padding(.bottom, MC.Space.l)
                .frame(width: geo.size.width)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                speakersButton
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MC.Space.m)
                    .background(MC.Surface.canvas)
            }
        }
    }

    private var regularLayout: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - MC.Space.xxl * 2, geo.size.height * 0.45, 400)
            VStack(spacing: 0) {
                sourceLine
                    .padding(.top, MC.Space.xxl)

                Spacer(minLength: MC.Space.l)

                ZStack {
                    ArtworkView(data: model.artwork(model.nowPlaying?.artworkID), size: side, radius: MC.Radius.large,
                                isIcon: model.nowPlaying?.artworkIsIcon ?? false)
                        .id(model.nowPlaying?.artworkID ?? "none")
                        .transition(.opacity)
                }
                .frame(width: side, height: side)
                .scaleEffect(model.transport.isPlaying || reduceMotion ? 1 : 0.92)
                .animation(MC.Motion.state(reduceMotion), value: model.transport.isPlaying)

                Spacer(minLength: MC.Space.l)

                VStack(alignment: .leading, spacing: MC.Space.xl) {
                    titles
                    position
                    TransportButtons(isPlaying: model.transport.isPlaying, canPlay: model.canPlay,
                                     canSkip: model.canPlay && model.transport.canSkip,
                                     playSize: 40, skipSize: 28, spacing: MC.Space.xxxl + MC.Space.l,
                                     onPlayPause: model.togglePlayPause, onNext: model.next, onPrevious: model.previous)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    masterVolume
                    speakersButton
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, MC.Space.l)
            }
            .padding(.horizontal, MC.Space.xxl)
            .frame(width: geo.size.width)
            .animation(MC.Motion.state(reduceMotion), value: model.nowPlaying?.identity)
        }
    }

    private var sourceLine: some View {
        HStack(spacing: MC.Space.xs) {
            if let source = model.activeSource {
                Image(systemName: source.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text("Playing from \(source.title) on \(session.hub?.name ?? "your Mac")")
            } else {
                Text("Nothing playing on \(session.hub?.name ?? "your Mac")")
            }
        }
        .font(MC.Font.caption)
        .foregroundStyle(MC.Ink.secondary)
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        .accessibilityElement(children: .combine)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: MC.Space.xxs) {
            Text(model.nowPlaying?.title ?? "Not Playing")
                .font(.title2.weight(.semibold))
                .foregroundStyle(model.nowPlaying == nil ? AnyShapeStyle(MC.Ink.secondary) : AnyShapeStyle(MC.Ink.primary))
                .contentTransition(.opacity)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(MC.Ink.secondary)
                .contentTransition(.opacity)
        }
        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        guard let info = model.nowPlaying else { return "Choose music in the Music tab" }
        if let album = info.album, !album.isEmpty { return "\(info.artist) \u{2014} \(album)" }
        return info.artist
    }

    /// A scrubber where the source can seek; a live caption for a captured app; the same
    /// height either way, so the controls below never jump.
    @ViewBuilder private var position: some View {
        ZStack {
            if let duration = model.nowPlaying?.duration, model.hasPosition {
                ScrubBar(transport: model.transport, duration: duration,
                         canSeek: model.transport.canSeek, onSeek: model.seek(to:))
            } else if model.activeSource == .app, let name = model.nowPlaying?.title {
                HStack(spacing: MC.Space.xs) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Live from \(name)")
                }
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 52)
    }

    private var masterVolume: some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(MC.Ink.tertiary)
                .accessibilityHidden(true)
            VolumeSlider(value: model.masterVolume, label: "Master volume",
                         onChange: model.setMasterVolume, onCommit: model.commitMasterVolume)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(MC.Ink.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var speakersButton: some View {
        Button {
            session.navigation.showSpeakers()
        } label: {
            Label(speakersText, systemImage: "hifispeaker.2.fill")
                .font(MC.Font.bodyEmphasis)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .accessibilityHint("Shows the speakers")
    }

    private var speakersText: String {
        let c = model.speakerCounts
        let on = c.playing + c.ready + c.connecting + c.failed
        if on == 0 { return "Choose Speakers" }
        return on == 1 ? "1 Speaker" : "\(on) Speakers"
    }
}

/// Elapsed, a draggable scrubber, remaining. While a finger holds it the scrubber follows the
/// finger, and the seek is sent once, on release.
struct ScrubBar: View {
    var transport: TransportState
    var duration: TimeInterval
    var canSeek: Bool
    var onSeek: (TimeInterval) -> Void
    @State private var dragging: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = dragging ?? min(duration, transport.position(at: context.date))
            VStack(spacing: MC.Space.xs) {
                Slider(value: Binding(get: { position }, set: { dragging = $0 }),
                       in: 0...max(duration, 1)) {
                    Text("Position")
                } onEditingChanged: { editing in
                    if !editing, let value = dragging {
                        onSeek(value)
                        dragging = nil
                    }
                }
                .tint(MC.Ink.secondary)
                .disabled(!canSeek)
                .accessibilityValue("\(MC.Format.time(position)) of \(MC.Format.time(duration))")
                HStack {
                    Text(MC.Format.time(position))
                    Spacer(minLength: MC.Space.s)
                    Text("\u{2212}" + MC.Format.time(duration - position))
                }
                .font(MC.Font.captionValue)
                .foregroundStyle(MC.Ink.secondary)
                .accessibilityHidden(true)
            }
        }
    }
}
