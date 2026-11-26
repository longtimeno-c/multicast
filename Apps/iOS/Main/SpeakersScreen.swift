import SwiftUI
import MulticastHubModel

/// Every speaker the hub can reach, grouped as the Mac groups them, under a master volume that
/// stays pinned at the bottom, where the thumb is.
struct SpeakersScreen: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmsForget = false

    private let grid = MC.RowGrid.touch

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MC.Space.xl) {
                    if model.speakers.isEmpty {
                        LookingForSpeakers(hubName: hubName)
                            .transition(.opacity)
                    } else {
                        SpeakerSummary(counts: model.speakerCounts, isDiscovering: model.isDiscovering,
                                       isLastKnown: session.linkProblem != nil)
                            .padding(.horizontal, MC.Space.m)
                        if model.needsLocalNetwork {
                            LocalNetworkNotice(hubName: hubName)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if !model.networkSpeakers.isEmpty {
                            speakerGroup("AirPlay", model.networkSpeakers)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if !model.localSpeakers.isEmpty {
                            speakerGroup("On \(hubName)", model.localSpeakers)
                        }
                    }
                }
                .padding(.horizontal, MC.Space.l)
                .padding(.top, MC.Space.xs)
                .padding(.bottom, MC.Space.xl)
                // A speaker turned on opens its slider and carries the rows below, whether the
                // tap was here or the change came from the hub.
                .animation(MC.Motion.state(reduceMotion), value: model.speakers.map(\.isEnabled))
            }
            .softBottomEdge()
            .background(MC.Surface.canvas)
            .disabled(session.linkProblem != nil)
            // While the link is down the rows show the last known state, not a live one.
            .environment(\.mcStatusIsStale, session.linkProblem != nil)
            .navigationTitle("Speakers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { hubMenu }
            }
            .bottomBar {
                MasterVolumeBar()
                    // A pinned control keeps the list in view: it grows with text up to a point.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .disabled(session.linkProblem != nil)
            }
            .confirmationDialog("Forget \(hubName)?", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("Forget This Mac", role: .destructive) { session.forget() }
            } message: {
                Text("You\u{2019}ll need the code shown on the Mac to connect again.")
            }
        }
    }

    private var hubName: String { session.hub?.name ?? "Mac" }

    private var hubMenu: some View {
        Menu {
            Section(hubName) {
                Label(session.linkProblem == nil ? "Connected" : "Not connected",
                      systemImage: session.linkProblem == nil ? "checkmark.circle" : "wifi.exclamationmark")
            }
            Button(role: .destructive) { confirmsForget = true } label: {
                Label("Forget This Mac", systemImage: "xmark.circle")
            }
        } label: {
            Label(hubName, systemImage: "desktopcomputer")
        }
        .accessibilityLabel("\(hubName), hub")
    }

    private func speakerGroup(_ title: String, _ speakers: [SpeakerItem]) -> some View {
        GroupedSection(title: title) {
            ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                VStack(spacing: 0) {
                    if index > 0 { RowDivider(leading: grid.textLeading) }
                    row(speaker)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func row(_ speaker: SpeakerItem) -> some View {
        SpeakerRow(
            speaker: speaker,
            grid: grid,
            density: .touch,
            masterVolume: model.masterVolume,
            onToggle: { on in
                withAnimation(MC.Motion.state(reduceMotion)) { model.setEnabled(on, for: speaker.id) }
            },
            onVolume: { model.setVolume($0, for: speaker.id) },
            onCommitVolume: { model.commitVolume(for: speaker.id) },
            onRetry: { model.retry(speaker.id) },
            onDetails: { showDetail(speaker.id) }
        ) {
            Button { showDetail(speaker.id) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(MC.Ink.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(speaker.name) details")
        }
    }

    private func showDetail(_ id: SpeakerID) {
        session.navigation.speakerDetail = .init(id: id)
    }
}

/// "4 playing · 1 connecting · 1 not responding", under the title. Digits roll in place.
private struct SpeakerSummary: View {
    var counts: HubModel.SpeakerCounts
    var isDiscovering: Bool
    /// The link is down: these are the last counts the phone saw.
    var isLastKnown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(isLastKnown ? "Last known: \(text)" : text)
            .font(MC.Font.caption)
            .foregroundStyle(isLastKnown ? MC.Ink.tertiary : MC.Ink.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(MC.Motion.state(reduceMotion), value: counts)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        var parts: [String] = []
        if counts.playing > 0 { parts.append("\(counts.playing) playing") }
        if counts.ready > 0 { parts.append("\(counts.ready) ready") }
        if counts.connecting > 0 { parts.append("\(counts.connecting) connecting") }
        if counts.failed > 0 { parts.append("\(counts.failed) not responding") }
        if parts.isEmpty { return isDiscovering ? "Looking for speakers" : "No speakers on. Tap one to play there." }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A message in place of the list, on the rows' grid.
private struct SpeakerNotice<Mark: View>: View {
    var title: String
    var message: String
    @ViewBuilder var mark: () -> Mark
    private let grid = MC.RowGrid.touch

    var body: some View {
        HStack(alignment: .top, spacing: MC.Space.s) {
            mark()
                .frame(width: grid.checkbox + MC.Space.s + grid.glyph, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                Text(message)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, grid.inset)
        .padding(.vertical, MC.Space.m)
        .accessibilityElement(children: .combine)
    }
}

private struct LookingForSpeakers: View {
    var hubName: String
    var body: some View {
        GroupedSection {
            SpeakerNotice(title: "Looking for speakers\u{2026}",
                          message: "AirPlay speakers on your network and \(hubName)\u{2019}s own outputs appear here as they\u{2019}re found.") {
                ProgressView()
            }
        }
    }
}

private struct LocalNetworkNotice: View {
    var hubName: String
    var body: some View {
        GroupedSection(title: "AirPlay") {
            SpeakerNotice(title: "\(hubName) can\u{2019}t see AirPlay speakers",
                          message: "Turn on Local Network for Multicast in Privacy & Security on the Mac.") {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MC.Ink.body)
            }
        }
    }
}

/// The master volume, pinned above the tab bar: the same slider as every speaker, its value,
/// and the outgoing level meter under the track.
struct MasterVolumeBar: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        HStack(spacing: MC.Space.m) {
            Text("Master")
                .font(MC.Font.bodyEmphasis)
                .foregroundStyle(MC.Ink.primary)
                .lineLimit(1)
                .fixedSize()
            VolumeSlider(value: model.masterVolume, label: "Master volume",
                         onChange: model.setMasterVolume, onCommit: model.commitMasterVolume)
                .overlay(alignment: .bottom) {
                    LevelMeter(levels: model.levels)
                        .padding(.horizontal, MC.Space.xxs)
                        .offset(y: MC.Space.s + LevelMeter.height / 2)
                }
            Text(MC.Format.percent(model.masterVolume))
                .font(MC.Font.value)
                .foregroundStyle(MC.Ink.primary)
                .contentTransition(.numericText(value: model.masterVolume))
                .animation(MC.Motion.feedback, value: model.masterVolume)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: MC.RowGrid.touch.value, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.leading, MC.Space.m)
        // The value's last digit lines up with the speaker rows' values above.
        .padding(.trailing, MC.RowGrid.touch.inset + (MC.RowGrid.touch.accessory - 20) / 2)
        .padding(.top, MC.Space.s)
        .padding(.bottom, MC.Space.s + LevelMeter.height)
        // Chrome, not a list card: the bar material of the mini player and tab bar below it,
        // set off from the list by a gap, so Master never reads as one more speaker row.
        .masterBarBackground()
        .padding(.horizontal, MC.Space.l)
        .padding(.top, MC.Space.m)
        .padding(.bottom, MC.Space.s)
        // The list fades out fully before the bar's top edge: no row shows behind or against it.
        .background {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(MC.Surface.canvas)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .frame(height: MC.Space.xl)
                Rectangle().fill(MC.Surface.canvas)
            }
            .padding(.top, -MC.Space.xl)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

private extension View {
    @ViewBuilder func masterBarBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: MC.Radius.large, style: .continuous)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.bar, in: shape)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}
