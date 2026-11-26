import SwiftUI
import MulticastHubModel

/// One speaker in full: on/off, volume (its preset while off), sync trim, and the details
/// nobody needs every day. Half height first; sync trim is in reach without scrolling.
struct SpeakerDetailSheet: View {
    @Environment(HubModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var speakerID: SpeakerID
    @State private var toggles = 0

    var body: some View {
        NavigationStack {
            Group {
                if let speaker = model.speaker(speakerID) {
                    content(speaker)
                } else {
                    ContentUnavailableView("Speaker Gone", systemImage: "hifispeaker",
                                           description: Text("The hub no longer sees this speaker."))
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(MC.Surface.canvas)
        .sensoryFeedback(.selection, trigger: toggles)
    }

    private func content(_ speaker: SpeakerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MC.Space.xl) {
                GroupedSection {
                    onOffRow(speaker)
                    RowDivider()
                    volumeRow(speaker)
                }

                syncTrim(speaker)

                GroupedSection {
                    detailRow("Plays at", "\(effective(speaker))%")
                    RowDivider()
                    detailRow("Connection", speaker.transport.label)
                    if let m = speaker.model {
                        RowDivider()
                        detailRow("Model", m)
                    }
                    RowDivider()
                    detailRow(speaker.transport.isNetwork ? "Address" : "Device", speaker.address ?? "\u{2014}")
                }
            }
            .padding(.horizontal, MC.Space.l)
            .padding(.top, MC.Space.s)
            .padding(.bottom, MC.Space.xxl)
            .animation(MC.Motion.state(reduceMotion), value: speaker.state)
        }
    }

    // MARK: Rows

    private func onOffRow(_ speaker: SpeakerItem) -> some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: speaker.glyph.symbolName)
                .font(.system(size: 20, weight: speaker.glyph.weight))
                .foregroundStyle(speaker.isEnabled ? AnyShapeStyle(MC.Ink.body) : AnyShapeStyle(MC.Ink.tertiary))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text("Play on this speaker")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                SpeakerStatusLine(speaker: speaker, onRetry: nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .failed = speaker.state {
                Button("Try Again") { model.retry(speaker.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .transition(.opacity)
            }
            Toggle("Play on this speaker", isOn: Binding(
                get: { speaker.isEnabled },
                set: { on in
                    toggles += 1
                    withAnimation(MC.Motion.state(reduceMotion)) { model.setEnabled(on, for: speaker.id) }
                }
            ))
            .labelsHidden()
            // Blue for "on", as the list's checkmarks; green stays for audio that is flowing.
            .tint(MC.accent)
        }
        .padding(.horizontal, MC.Space.m)
        .padding(.vertical, MC.Space.m)
        .accessibilityElement(children: .contain)
    }

    private func volumeRow(_ speaker: SpeakerItem) -> some View {
        VStack(alignment: .leading, spacing: MC.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(speaker.isEnabled ? "Volume" : "Joins at")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                    .contentTransition(.opacity)
                Spacer(minLength: MC.Space.s)
                Text(MC.Format.percent(speaker.volume))
                    .font(MC.Font.value)
                    .foregroundStyle(MC.Ink.primary)
                    .contentTransition(.numericText(value: speaker.volume))
                    .animation(MC.Motion.feedback, value: speaker.volume)
                    .accessibilityHidden(true)
            }
            VolumeSlider(value: speaker.volume, label: "\(speaker.name) volume", isLive: speaker.isEnabled,
                         onChange: { model.setVolume($0, for: speaker.id) },
                         onCommit: { model.commitVolume(for: speaker.id) })
        }
        .padding(.horizontal, MC.Space.m)
        .padding(.vertical, MC.Space.m)
    }

    private func syncTrim(_ speaker: SpeakerItem) -> some View {
        VStack(alignment: .leading, spacing: MC.Space.s) {
            GroupedSection(title: "Sync trim", trailing: nil) {
                VStack(alignment: .leading, spacing: MC.Space.s) {
                    // One line when it fits; at the largest text sizes the controls drop under the value.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MC.Space.m) {
                            trimValue(speaker)
                            Spacer(minLength: MC.Space.s)
                            trimControls(speaker)
                        }
                        VStack(alignment: .leading, spacing: MC.Space.s) {
                            trimValue(speaker)
                            trimControls(speaker)
                        }
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
                .padding(.horizontal, MC.Space.m)
                .padding(.vertical, MC.Space.m)
            }
            Text("Move this speaker earlier if it lags behind the rest of the house. Bluetooth speakers usually need about 150 to 250 ms.")
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MC.Space.m)
        }
    }

    private func trimValue(_ speaker: SpeakerItem) -> some View {
        Text(MC.Format.trim(speaker.syncTrimMs))
            .font(.title3.monospacedDigit())
            .foregroundStyle(MC.Ink.primary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(value: Double(speaker.syncTrimMs)))
            .animation(MC.Motion.feedback, value: speaker.syncTrimMs)
            .accessibilityHidden(true)
    }

    private func trimControls(_ speaker: SpeakerItem) -> some View {
        HStack(spacing: MC.Space.m) {
            Button("Reset") {
                model.setSyncTrim(0, for: speaker.id)
                model.commitSyncTrim(for: speaker.id)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(speaker.syncTrimMs == 0)
            Stepper("Sync trim", value: Binding(
                get: { speaker.syncTrimMs },
                set: { model.setSyncTrim($0, for: speaker.id); model.commitSyncTrim(for: speaker.id) }
            ), in: SpeakerItem.syncTrimRange, step: 5)
            .labelsHidden()
            .fixedSize()
            .accessibilityValue(MC.Format.trim(speaker.syncTrimMs))
        }
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
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
