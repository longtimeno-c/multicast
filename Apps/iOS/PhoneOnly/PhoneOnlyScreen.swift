import MulticastHubModel
import SwiftUI

/// iPhone Only: play what this iPhone is playing on AirPlay speakers, with no Mac. The phone
/// can only hear other apps through a screen broadcast, so the screen is three things in the
/// order they are used: the broadcast (start, and what it is doing), the speakers it plays
/// on, and what to expect from a mode that is an experiment.
struct PhoneOnlyScreen: View {
    @State var model: PhoneOnlyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trimTarget: TrimTarget?

    private let grid = MC.RowGrid.touch

    struct TrimTarget: Identifiable, Hashable { let id: SpeakerID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MC.Space.xl) {
                    Text("Experimental. Plays what this iPhone is playing on your AirPlay speakers, without a Mac.")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, MC.Space.m)

                    BroadcastCard(model: model)

                    speakerSection

                    WhatToExpect()
                }
                .padding(.horizontal, MC.Space.l)
                .padding(.top, MC.Space.xs)
                .padding(.bottom, MC.Space.xxl)
                .animation(MC.Motion.state(reduceMotion), value: model.speakers.map(\.isEnabled))
            }
            .refreshable {
                model.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
            .background(MC.Surface.canvas)
            .navigationTitle("iPhone Only")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $trimTarget) { target in
                PhoneOnlyTrimSheet(model: model, speakerID: target.id)
            }
        }
        .onAppear {
            model.reduceMotion = reduceMotion
            model.start()
        }
        .onChange(of: reduceMotion) { _, new in model.reduceMotion = new }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var speakerSection: some View {
        let speakers = model.speakers
        if speakers.isEmpty {
            GroupedSection(title: "AirPlay") {
                if model.isSearching {
                    notice(title: "Looking for speakers\u{2026}",
                           message: "AirPlay speakers on this Wi\u{2011}Fi network appear here as they\u{2019}re found.") {
                        ProgressView()
                    }
                } else {
                    notice(title: "No speakers found",
                           message: "Check the speakers are on and on this Wi\u{2011}Fi network, and that Local Network is on for Multicast Remote in Settings. Pull down to look again.") {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(MC.Ink.body)
                    }
                }
            }
            .transition(.opacity)
        } else {
            GroupedSection(title: "AirPlay") {
                ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                    VStack(spacing: 0) {
                        if index > 0 { RowDivider(leading: grid.textLeading) }
                        row(speaker)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func row(_ speaker: SpeakerItem) -> some View {
        SpeakerRow(
            speaker: speaker,
            grid: grid,
            density: .touch,
            onToggle: { on in
                withAnimation(MC.Motion.state(reduceMotion)) { model.setOn(on, for: speaker.id) }
            },
            onVolume: { model.setVolume($0, for: speaker.id) },
            onCommitVolume: { model.commitVolume(for: speaker.id) },
            // A broadcast retries a speaker by itself; there is nothing to send from here.
            onRetry: {},
            onDetails: { trimTarget = .init(id: speaker.id) }
        ) {
            Button { trimTarget = .init(id: speaker.id) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(MC.Ink.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(speaker.name) sync trim")
        }
    }

    private func notice<Mark: View>(title: String, message: String, @ViewBuilder mark: () -> Mark) -> some View {
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

// MARK: - The broadcast

/// What the broadcast is doing, in words, with the one button that starts or stops it.
private struct BroadcastCard: View {
    var model: PhoneOnlyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.s) {
            GroupedSection {
                VStack(alignment: .leading, spacing: MC.Space.m) {
                    HStack(alignment: .firstTextBaseline, spacing: MC.Space.s) {
                        mark
                            .frame(width: StateBadge.size, height: StateBadge.size)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        VStack(alignment: .leading, spacing: MC.Space.xxs) {
                            Text(title)
                                .font(MC.Font.bodyEmphasis)
                                .foregroundStyle(MC.Ink.primary)
                                .contentTransition(.opacity)
                            Text(detail)
                                .font(MC.Font.caption)
                                .foregroundStyle(isProblem ? AnyShapeStyle(MC.Status.failed) : AnyShapeStyle(MC.Ink.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.opacity)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)

                    if model.isRunning {
                        LevelMeter(levels: model.levels)
                            .frame(height: LevelMeter.height)
                            .transition(.opacity)
                    }

                    button
                }
                .padding(MC.Space.m)
                .animation(MC.Motion.state(reduceMotion), value: model.capture)
            }
            if !model.canBroadcast {
                Text("This copy of the app isn\u{2019}t signed to share settings with its broadcast, so a broadcast can\u{2019}t find these speakers.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MC.Space.m)
            }
        }
    }

    private var canStart: Bool { model.isRunning || model.chosenCount > 0 }

    @ViewBuilder private var button: some View {
        let label = Text(model.isRunning ? "Stop Broadcast" : "Start Broadcast")
            .font(MC.Font.bodyEmphasis)
            .frame(maxWidth: .infinity, minHeight: 28)
        Group {
            if model.usesSystemPicker {
                // The system's own button does the work; this one is what it looks like.
                styled(Button(action: {}) { label })
                    .allowsHitTesting(false)
                    .overlay {
                        if canStart { BroadcastPicker() }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.isRunning ? "Stop Broadcast" : "Start Broadcast")
                    .accessibilityAddTraits(.isButton)
            } else {
                styled(Button(action: model.toggleMockBroadcast) { label })
            }
        }
        .disabled(!canStart)
    }

    @ViewBuilder private func styled(_ button: some View) -> some View {
        if model.isRunning {
            button.buttonStyle(.bordered).controlSize(.large)
        } else {
            button.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder private var mark: some View {
        switch model.capture {
        case .idle: Circle().strokeBorder(MC.Ink.tertiary, lineWidth: 1).frame(width: 7, height: 7)
        case .starting: ProgressView().controlSize(.mini)
        case .capturing(let hearing):
            if model.playingCount == 0 {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(hearing ? AnyShapeStyle(MC.Status.playing) : AnyShapeStyle(MC.Ink.tertiary)).frame(width: 7, height: 7)
            }
        case .ended:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MC.Status.failed)
        }
    }

    private var isProblem: Bool {
        if case .ended = model.capture { return true }
        return false
    }

    private var title: String {
        switch model.capture {
        case .idle: "Not playing"
        case .starting: "Starting\u{2026}"
        case .capturing(let hearing):
            if model.playingCount == 0 { "Connecting to speakers\u{2026}" }
            else if !hearing { "Playing, but hearing silence" }
            else { model.playingCount == 1 ? "Playing on 1 speaker" : "Playing on \(model.playingCount) speakers" }
        case .ended: "Stopped"
        }
    }

    private var detail: String {
        switch model.capture {
        case .idle:
            model.chosenCount == 0
                ? "Turn on the speakers to play on, then start a broadcast."
                : "Start a broadcast, choose Multicast, then play something in any app."
        case .starting:
            "Connecting to your speakers."
        case .capturing(let hearing):
            if model.playingCount == 0 { "Sound starts when a speaker answers." }
            else if hearing { "Sound reaches the speakers about 2 seconds after this iPhone plays it." }
            else { "Nothing is playing, or the app that is playing keeps its sound out of broadcasts." }
        case .ended(let reason):
            reason
        }
    }
}

// MARK: - What to expect

private struct WhatToExpect: View {
    var body: some View {
        GroupedSection(title: "What to expect") {
            VStack(alignment: .leading, spacing: MC.Space.m) {
                item("clock", "Sound arrives about 2 seconds late, so video will be out of sync.")
                item("record.circle", "The red broadcast indicator stays on the whole time.")
                item("speaker.slash", "Some apps silence or hide themselves while the screen is being broadcast.")
                item("iphone", "This iPhone keeps playing too, ahead of the speakers.")
            }
            .padding(MC.Space.m)
        }
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MC.Space.m) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.body)
                .foregroundStyle(MC.Ink.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sync trim

/// One speaker's sync trim, for a speaker that plays a little behind or ahead of the others.
private struct PhoneOnlyTrimSheet: View {
    var model: PhoneOnlyModel
    var speakerID: SpeakerID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let speaker = model.speaker(speakerID) {
                    VStack(alignment: .leading, spacing: MC.Space.s) {
                        GroupedSection(title: "Sync trim") {
                            VStack(alignment: .leading, spacing: MC.Space.s) {
                                HStack(spacing: MC.Space.m) {
                                    Text(MC.Format.trim(speaker.syncTrimMs))
                                        .font(.title3.monospacedDigit())
                                        .foregroundStyle(MC.Ink.primary)
                                        .contentTransition(.numericText(value: Double(speaker.syncTrimMs)))
                                        .animation(MC.Motion.feedback, value: speaker.syncTrimMs)
                                        .accessibilityHidden(true)
                                    Spacer(minLength: MC.Space.s)
                                    Button("Reset") {
                                        model.setSyncTrim(0, for: speaker.id)
                                        model.commitSyncTrim(for: speaker.id)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(speaker.syncTrimMs == 0)
                                    Stepper("Sync trim", value: Binding(
                                        get: { speaker.syncTrimMs },
                                        set: { model.setSyncTrim($0, for: speaker.id); model.commitSyncTrim(for: speaker.id) }
                                    ), in: SpeakerItem.syncTrimRange, step: 5)
                                    .labelsHidden()
                                    .fixedSize()
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
                                .accessibilityValue(MC.Format.trim(speaker.syncTrimMs))
                            }
                            .padding(MC.Space.m)
                        }
                        Text("Move this speaker earlier if it plays behind the others, later if it plays ahead.")
                            .font(MC.Font.caption)
                            .foregroundStyle(MC.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, MC.Space.m)
                    }
                    .padding(.horizontal, MC.Space.l)
                    .padding(.top, MC.Space.s)
                }
            }
            .background(MC.Surface.canvas)
            .navigationTitle(model.speaker(speakerID)?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(MC.Surface.canvas)
    }
}
