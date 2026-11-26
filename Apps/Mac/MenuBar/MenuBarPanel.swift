import SwiftUI

/// The menu-bar extra: what's playing and every speaker, for quick toggling without the window.
struct MenuBarPanel: View {
    @Environment(HubModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Snapshots have no menu-bar material behind them, so they ask for a solid surface.
    var solidBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            NowPlayingCompact(info: model.nowPlaying, artwork: model.artwork(model.nowPlaying?.artwork),
                              transport: model.transport,
                              onPlayPause: model.togglePlayPause, onNext: model.next)
                .padding(.horizontal, MC.Space.m)

            GroupedSection {
                MasterVolumeRow(volume: model.masterVolume, levels: model.levels,
                                grid: .dense, showsBigNumber: false,
                                onChange: model.setMasterVolume, onCommit: model.commitMasterVolume)
            }

            GroupedSection {
                if model.speakers.isEmpty {
                    HStack(spacing: MC.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking for speakers\u{2026}")
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MC.Space.m)
                }
                ForEach(Array(model.speakers.enumerated()), id: \.element.id) { index, speaker in
                    VStack(spacing: 0) {
                        if index > 0 { RowDivider(leading: MC.RowGrid.dense.textLeading) }
                        SpeakerRow(speaker: speaker, grid: .dense, density: .dense,
                                   masterVolume: model.masterVolume,
                                   onToggle: { model.setEnabled($0, for: speaker.id) },
                                   onVolume: { model.setVolume($0, for: speaker.id) },
                                   onCommitVolume: { model.commitVolume(for: speaker.id) },
                                   onRetry: { model.retry(speaker.id) })
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            HStack(spacing: MC.Space.s) {
                Button("Open Multicast") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: MC.Space.s)
                SettingsLink {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(MC.Ink.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, MC.Space.m)
        }
        .padding(.vertical, MC.Space.m)
        .padding(.horizontal, MC.Space.s)
        .frame(width: 392)
        .onRaisedSurface()
        .background {
            if solidBackground { Rectangle().fill(MC.Surface.raised) }
        }
    }
}
