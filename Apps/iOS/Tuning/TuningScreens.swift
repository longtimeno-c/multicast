import SwiftUI
import MulticastHubModel

/// "Tune speaker sync": every speaker with whether it has been tuned. Pick one, walk to it,
/// tune it there; the next one whenever you like. Each result is kept on the Mac.
struct TuneSpeakersScreen: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private let grid = MC.RowGrid.touch

    var body: some View {
        @Bindable var nav = session.navigation
        NavigationStack(path: $nav.tuningPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: MC.Space.xl) {
                    Text("Stand next to a speaker, hold your iPhone toward it and start. Do them in any order, whenever you like: each one is saved on \(hubName) and stays in step with the ones you tuned before.")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, MC.Space.m)

                    if !model.networkSpeakers.isEmpty { group("AirPlay", model.networkSpeakers) }
                    if !model.localSpeakers.isEmpty { group("On \(hubName)", model.localSpeakers) }
                    if !model.phoneSpeakers.isEmpty { group("iPhones", model.phoneSpeakers) }
                }
                .padding(.horizontal, MC.Space.l)
                .padding(.vertical, MC.Space.m)
            }
            .background(MC.Surface.canvas)
            .navigationTitle("Tune Speaker Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: SpeakerID.self) { id in
                TuningScreen(speakerID: id)
            }
        }
    }

    private var hubName: String { session.hub?.name ?? "the Mac" }

    private func group(_ title: String, _ speakers: [SpeakerItem]) -> some View {
        GroupedSection(title: title, trailing: tunedCount(speakers)) {
            ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                if index > 0 { RowDivider(leading: grid.inset + grid.glyph + MC.Space.m) }
                NavigationLink(value: speaker.id) { row(speaker) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tunedCount(_ speakers: [SpeakerItem]) -> String {
        "\(speakers.filter { $0.tunedAt != nil }.count) of \(speakers.count) tuned"
    }

    private func row(_ speaker: SpeakerItem) -> some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: speaker.glyph.symbolName)
                .font(.system(size: 17, weight: speaker.glyph.weight))
                .foregroundStyle(MC.Ink.body)
                .frame(width: grid.glyph)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(speaker.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                Text(TuningWording.state(of: speaker))
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
            Spacer(minLength: MC.Space.s)
            if speaker.tunedAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MC.Status.playing)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MC.Ink.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, grid.inset)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One speaker's tuning: where to stand, the stage while this iPhone listens, and what was
/// found.
struct TuningScreen: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var speakerID: SpeakerID

    var body: some View {
        let speaker = model.speaker(speakerID)
        let status = ownStatus
        let tuning = session.tuning
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: MC.Space.xl) {
                    TuningStage(speaker: speaker, status: status, microphoneWaveform: tuning.waveform)
                        .padding(.top, MC.Space.l)
                    if status == nil { instructions(speaker) }
                    if let failure = tuning.failure, status == nil {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(MC.Font.caption)
                            .foregroundStyle(MC.Status.failed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, MC.Space.xl)
                .animation(MC.Motion.state(reduceMotion), value: status == nil)
            }
            actions(status)
                .padding(.horizontal, MC.Space.xl)
                .padding(.vertical, MC.Space.m)
        }
        .background(MC.Surface.canvas)
        .navigationTitle(speaker?.name ?? "Speaker")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: status?.isRunning) { was, now in
            guard was == true, now == false, let entry = status?.speakers.first else { return }
            AccessibilityNotification.Announcement(entry.outcome.caption).post()
        }
        .onDisappear {
            // Walking away from the screen ends what it started; a finished result is put away.
            if ownStatus != nil { model.endCalibration() }
        }
    }

    /// The tuning on show when it is this speaker's.
    private var ownStatus: SyncCalibrationStatus? {
        guard let status = model.calibration, status.speaker(speakerID) != nil else { return nil }
        return status
    }

    /// Something else is being tuned (from the Mac, or another iPhone).
    private var busyElsewhere: Bool { model.calibration?.isRunning == true && ownStatus == nil }

    private func instructions(_ speaker: SpeakerItem?) -> some View {
        let name = speaker?.name ?? "the speaker"
        let isThisPhone = speakerID == session.phoneSpeaker.speakerID
        return VStack(spacing: MC.Space.s) {
            Text(isThisPhone ? "Put your iPhone next to \(name)" : "Stand next to \(name)")
                .font(MC.Font.title)
                .foregroundStyle(MC.Ink.primary)
                .multilineTextAlignment(.center)
            Text(isThisPhone
                 ? "This is what your iPhone is playing through. Keep the iPhone about an arm\u{2019}s length from it and start: it plays a few short chirps and listens for them."
                 : "Hold your iPhone toward it, about an arm\u{2019}s length away, and start. The speaker plays a few short chirps while your iPhone listens. Music pauses meanwhile.")
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let speaker, !speaker.isEnabled {
                Text("It\u{2019}s off now: it is turned on for the measurement and off again after.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder private func actions(_ status: SyncCalibrationStatus?) -> some View {
        let tuning = session.tuning
        if let status {
            if status.isRunning {
                Button(role: .cancel) { model.endCalibration() } label: { bigLabel("Stop") }
                    .buttonStyle(.bordered)
            } else {
                VStack(spacing: MC.Space.s) {
                    Button { dismiss() } label: { bigLabel(status.speakers.first?.outcome.isAligned == true ? "Next Speaker" : "Back to Speakers") }
                        .buttonStyle(.borderedProminent)
                    Button { tuning.tune(speakerID) } label: { bigLabel(status.speakers.first?.outcome.isAligned == true ? "Measure Again" : "Try Again") }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            VStack(spacing: MC.Space.s) {
                Button { tuning.tune(speakerID) } label: { bigLabel(tuning.isStarting ? "Starting\u{2026}" : "Start Listening") }
                    .buttonStyle(.borderedProminent)
                    .disabled(tuning.isStarting || busyElsewhere || !tuning.isAvailable)
                if busyElsewhere {
                    Text("Another speaker is being tuned. Wait for it to finish.")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                } else if !tuning.isAvailable {
                    Text("Update Multicast on the Mac to tune speakers from your iPhone.")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func bigLabel(_ text: String) -> some View {
        Text(text)
            .font(MC.Font.bodyEmphasis)
            .frame(maxWidth: .infinity, minHeight: 34)
    }
}
