import SwiftUI
import MulticastHubModel

/// The detail column: what's playing, then every speaker under one master volume.
struct SpeakersPanel: View {
    @Environment(HubModel.self) private var model
    @Environment(HubRuntime.self) private var runtime: HubRuntime?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedSpeaker: SpeakerID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MC.Space.xxl) {
                NowPlayingStrip(
                    info: model.nowPlaying,
                    artwork: model.artwork(model.nowPlaying?.artworkID),
                    transport: model.transport,
                    showsPosition: model.hasPosition,
                    liveCaption: liveCaption,
                    emptySubtitle: "Choose something to play, then pick speakers",
                    onPlayPause: model.togglePlayPause,
                    onNext: model.next,
                    onPrevious: model.previous,
                    onSeek: model.seek(to:)
                )

                VStack(alignment: .leading, spacing: MC.Space.l) {
                    HStack(alignment: .firstTextBaseline, spacing: MC.Space.s) {
                        Text("Speakers")
                            .font(MC.Font.title)
                            .foregroundStyle(MC.Ink.primary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: MC.Space.s)
                        SpeakerSummary(counts: model.speakerCounts, isDiscovering: model.isDiscovering,
                                       playingOnMacOnly: playingOnMacOnly)
                        RefreshSpeakersButton()
                    }

                    if localNetworkOff {
                        LocalNetworkNotice()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    GroupedSection {
                        MasterVolumeRow(volume: model.masterVolume, levels: model.levels,
                                        onChange: model.setMasterVolume, onCommit: model.commitMasterVolume)
                    }

                    if model.speakers.isEmpty {
                        if !localNetworkOff {
                            LookingForSpeakers()
                                .transition(.opacity)
                        }
                    } else {
                        if !localNetworkOff, !model.networkSpeakers.isEmpty {
                            speakerGroup("AirPlay", model.networkSpeakers)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if !model.localSpeakers.isEmpty {
                            speakerGroup("This Mac", model.localSpeakers)
                        }
                    }
                }
            }
            .padding(.horizontal, MC.Space.xxl)
            .padding(.vertical, MC.Space.xl)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(MC.Surface.canvas)
    }

    /// Local Network access is off: the hub's discovery or its server for remotes was refused.
    private var localNetworkOff: Bool { model.needsLocalNetwork || runtime?.localNetworkBlocked == true }

    /// A media app plays with no speaker on: it is heard on the Mac only, and joins a speaker
    /// as soon as one is turned on.
    private var playingOnMacOnly: Bool {
        (model.activeSource == .appleMusic || model.activeSource == .spotify) && model.transport.isPlaying
            && !model.speakers.contains(where: \.isEnabled)
    }

    private var liveCaption: String? {
        guard model.activeSource == .app, let name = model.nowPlaying?.title else { return nil }
        return "Live from \(name)"
    }

    private func speakerGroup(_ title: String, _ speakers: [SpeakerItem]) -> some View {
        GroupedSection(title: title) {
            ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                // A newly found speaker opens its room and carries the rows below with it.
                VStack(spacing: 0) {
                    if index > 0 {
                        RowDivider(leading: MC.RowGrid.regular.textLeading)
                    }
                    FocusableSpeakerRow(speaker: speaker, focused: $focusedSpeaker,
                                        order: model.speakers.map(\.id))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// "4 playing · 1 connecting · 1 not responding". Digits roll; the line holds its right edge.
private struct SpeakerSummary: View {
    var counts: HubModel.SpeakerCounts
    var isDiscovering: Bool
    var playingOnMacOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(MC.Font.caption)
            .foregroundStyle(MC.Ink.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(MC.Motion.state(reduceMotion), value: counts)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
    }

    private var text: String {
        var parts: [String] = []
        if counts.playing > 0 { parts.append("\(counts.playing) playing") }
        if counts.ready > 0 { parts.append("\(counts.ready) ready") }
        if counts.connecting > 0 { parts.append("\(counts.connecting) connecting") }
        if counts.failed > 0 { parts.append("\(counts.failed) not responding") }
        if parts.isEmpty {
            if playingOnMacOnly { return "Playing on this Mac only \u{00B7} turn on a speaker" }
            return isDiscovering ? "Searching" : "None selected"
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A message in the speakers list, on the speaker rows' grid: its mark in the glyph column,
/// its words on the text column, an optional action where the slider would be.
private struct SpeakerNoticeRow<Mark: View, Action: View>: View {
    var title: String
    var message: String
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var action: () -> Action
    private let grid = MC.RowGrid.regular

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mark()
                .frame(width: grid.glyph, height: 16)
                .padding(.leading, grid.inset + grid.checkbox + MC.Space.s)
                .padding(.trailing, MC.Space.s)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                Text(message)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
                .padding(.leading, MC.Space.m)
        }
        .padding(.trailing, grid.inset)
        .padding(.vertical, grid.verticalPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Discovery has found nothing yet: say so in the place the list will fill.
private struct LookingForSpeakers: View {
    var body: some View {
        GroupedSection {
            SpeakerNoticeRow(
                title: "Looking for speakers\u{2026}",
                message: "AirPlay speakers on this network and this Mac\u{2019}s outputs appear here as they\u{2019}re found."
            ) {
                ProgressView().controlSize(.small)
            } action: { EmptyView() }
        }
    }
}

/// Looks for speakers again: known ones stay listed while the network answers afresh.
struct RefreshSpeakersButton: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        Button(action: model.refreshSpeakers) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MC.Ink.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.isDiscovering)
        .help("Refresh speakers")
        .accessibilityLabel("Refresh speakers")
    }
}

enum LocalNetworkSettings {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Local Network access refused: AirPlay can't be found, iPhones can't find the Mac, and only
/// System Settings can fix it.
private struct LocalNetworkNotice: View {
    var body: some View {
        GroupedSection(title: "AirPlay") {
            SpeakerNoticeRow(
                title: "Local Network access is off",
                message: "Multicast can\u{2019}t find AirPlay speakers, and iPhone remotes can\u{2019}t find this Mac. Turn it on for Multicast in Privacy & Security; it takes effect within a few seconds."
            ) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MC.Ink.body)
            } action: {
                Button("Open Settings\u{2026}", action: LocalNetworkSettings.open)
            }
        }
    }
}

/// A speaker row as one keyboard stop: up and down move between speakers, left and right
/// change its volume, return turns it on or off, Command-I opens its details. Its checkbox,
/// slider and info button stay mouse targets but don't add Tab stops.
private struct FocusableSpeakerRow: View {
    @Environment(HubModel.self) private var model
    var speaker: SpeakerItem
    var focused: FocusState<SpeakerID?>.Binding
    var order: [SpeakerID]
    @State private var showsDetail = false

    var body: some View {
        SpeakerRow(
            speaker: speaker,
            masterVolume: model.masterVolume,
            controlsTakeFocus: false,
            onToggle: { model.setEnabled($0, for: speaker.id) },
            onVolume: { model.setVolume($0, for: speaker.id) },
            onCommitVolume: { model.commitVolume(for: speaker.id) },
            onRetry: { model.retry(speaker.id) },
            onDetails: { showsDetail = true }
        ) {
            Button {
                showsDetail.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(MC.Ink.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Details and sync trim (\u{2318}I)")
            .popover(isPresented: $showsDetail, arrowEdge: .trailing) {
                SpeakerDetailView(speakerID: speaker.id)
                    .environment(model)
            }
        }
        .focusable()
        .focused(focused, equals: speaker.id)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.leftArrow) { model.nudgeVolume(-0.05, for: speaker.id); return .handled }
        .onKeyPress(.rightArrow) { model.nudgeVolume(0.05, for: speaker.id); return .handled }
        .onKeyPress(.return) { model.toggle(speaker.id); return .handled }
        .onKeyPress(keys: ["i"]) { press in
            guard press.modifiers == .command else { return .ignored }
            showsDetail = true
            return .handled
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let i = order.firstIndex(of: speaker.id) else { return .ignored }
        let j = i + delta
        guard order.indices.contains(j) else { return .handled }
        focused.wrappedValue = order[j]
        return .handled
    }
}

/// The popover behind a row's info button: sync trim and the details nobody needs every day.
struct SpeakerDetailView: View {
    @Environment(HubModel.self) private var model
    var speakerID: SpeakerID

    var body: some View {
        if let speaker = model.speaker(speakerID) {
            content(speaker)
                .onRaisedSurface()
        }
    }

    private func content(_ speaker: SpeakerItem) -> some View {
        VStack(alignment: .leading, spacing: MC.Space.l) {
            HStack(spacing: MC.Space.m) {
                // Leading ink on the content edge, like every line below it.
                Image(systemName: speaker.glyph.symbolName)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(MC.Ink.body)
                    .frame(width: 20, height: 28, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MC.Space.xxs) {
                    Text(speaker.name)
                        .font(MC.Font.title)
                        .foregroundStyle(MC.Ink.primary)
                    SpeakerStatusLine(speaker: speaker, onRetry: { model.retry(speaker.id) })
                }
            }

            VStack(alignment: .leading, spacing: MC.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: MC.Space.s) {
                    Text("Sync trim")
                        .font(MC.Font.bodyEmphasis)
                        .foregroundStyle(MC.Ink.primary)
                    Spacer(minLength: MC.Space.s)
                    Text(MC.Format.trim(speaker.syncTrimMs))
                        .font(MC.Font.value)
                        .foregroundStyle(MC.Ink.primary)
                        .contentTransition(.numericText(value: Double(speaker.syncTrimMs)))
                        .animation(MC.Motion.feedback, value: speaker.syncTrimMs)
                        .accessibilityHidden(true)
                    Stepper("Sync trim", value: Binding(
                        get: { speaker.syncTrimMs },
                        set: { model.setSyncTrim($0, for: speaker.id); model.commitSyncTrim(for: speaker.id) }
                    ), in: SpeakerItem.syncTrimRange, step: 5)
                    .labelsHidden()
                    .accessibilityValue(MC.Format.trim(speaker.syncTrimMs))
                }

                Slider(value: Binding(
                    get: { Double(speaker.syncTrimMs) },
                    set: { model.setSyncTrim(Int(($0 / 5).rounded()) * 5, for: speaker.id) }
                ), in: Double(SpeakerItem.syncTrimRange.lowerBound)...Double(SpeakerItem.syncTrimRange.upperBound)) {
                    Text("Sync trim")
                } minimumValueLabel: {
                    Text("Earlier")
                } maximumValueLabel: {
                    Text("Later")
                } onEditingChanged: { editing in
                    if !editing { model.commitSyncTrim(for: speaker.id) }
                }
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .labelsHidden()
                .accessibilityValue(MC.Format.trim(speaker.syncTrimMs))

                Text("Move this speaker earlier if it lags behind the rest of the house. Bluetooth speakers usually need about 150 to 250 ms.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupedSection {
                detailRow("Plays at", "\(effective(speaker))%")
                    .help("This speaker\u{2019}s \(MC.Format.percent(speaker.volume)) under the master\u{2019}s \(MC.Format.percent(model.masterVolume))")
                RowDivider()
                detailRow("Connection", speaker.transport.label)
                RowDivider()
                detailRow(speaker.transport.isNetwork ? "Address" : "Device", speaker.address ?? "\u{2014}")
            }

            HStack {
                Spacer()
                Button("Reset trim") {
                    model.setSyncTrim(0, for: speaker.id)
                    model.commitSyncTrim(for: speaker.id)
                }
                .disabled(speaker.syncTrimMs == 0)
            }
        }
        .padding(MC.Space.l)
        .frame(width: 320)
    }

    private func effective(_ speaker: SpeakerItem) -> Int {
        Int((speaker.effectiveVolume(master: model.masterVolume) * 100).rounded())
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: MC.Space.m) {
            Text(label)
                .foregroundStyle(MC.Ink.secondary)
            Spacer(minLength: MC.Space.m)
            Text(value)
                .foregroundStyle(MC.Ink.primary)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(MC.Font.body)
        .padding(.horizontal, MC.Space.m)
        .padding(.vertical, MC.Space.s)
        .accessibilityElement(children: .combine)
    }
}
