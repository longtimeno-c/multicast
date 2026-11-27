import SwiftUI
import MulticastHubModel

/// The menu-bar extra: what's playing and every speaker, for quick toggling without the window.
struct MenuBarPanel: View {
    @Environment(HubModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(HubRuntime.self) private var runtime: HubRuntime?
    /// Snapshots have no menu-bar material behind them, so they ask for a solid surface.
    var solidBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            NowPlayingCompact(info: model.nowPlaying, artwork: model.artwork(model.nowPlaying?.artworkID),
                              transport: model.transport,
                              onPlayPause: model.togglePlayPause, onNext: model.next)
                .padding(.horizontal, MC.Space.m)

            GroupedSection {
                MasterVolumeRow(volume: model.masterVolume, levels: model.levels,
                                grid: .dense, showsBigNumber: false,
                                onChange: model.setMasterVolume, onCommit: model.commitMasterVolume)
            }

            if model.needsLocalNetwork || runtime?.localNetworkBlocked == true {
                GroupedSection {
                    HStack(alignment: .top, spacing: MC.Space.s) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MC.Ink.body)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: MC.Space.xxs) {
                            Text("Local Network access is off")
                                .font(MC.Font.body)
                                .foregroundStyle(MC.Ink.primary)
                            Text("No AirPlay speakers, and iPhone remotes can\u{2019}t find this Mac.")
                                .font(MC.Font.caption)
                                .foregroundStyle(MC.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Settings\u{2026}", action: LocalNetworkSettings.open)
                            .controlSize(.small)
                    }
                    .padding(MC.Space.m)
                    .accessibilityElement(children: .combine)
                }
            }

            if model.speakers.isEmpty || !model.usableSpeakers.isEmpty {
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
                    ForEach(Array(model.usableSpeakers.enumerated()), id: \.element.id) { index, speaker in
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
            }

            if !model.restrictedSpeakers.isEmpty, !(model.needsLocalNetwork || runtime?.localNetworkBlocked == true) {
                GroupedSection(title: RestrictedSpeakerWording.groupTitle,
                               trailing: RestrictedSpeakerWording.groupCaption(count: model.restrictedSpeakers.count)) {
                    ForEach(Array(model.restrictedSpeakers.enumerated()), id: \.element.id) { index, speaker in
                        VStack(spacing: 0) {
                            if index > 0 { RowDivider(leading: MC.RowGrid.dense.textLeading) }
                            RestrictedSpeakerRow(speaker: speaker, grid: .dense, density: .dense,
                                                 onCheckAgain: { model.checkAgain(speaker.id) })
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            HStack(spacing: MC.Space.s) {
                Button("Open Multicast") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: MC.Space.s)
                RefreshSpeakersButton()
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
