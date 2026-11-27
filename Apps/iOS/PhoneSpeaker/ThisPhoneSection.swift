import MulticastHubModel
import MulticastRemote
import SwiftUI

/// "This iPhone" on the Speakers screen: one row that turns this device into a speaker of the
/// hub, named after what it would play through, with the same switch, slider and details as
/// every other speaker, and one line underneath saying what to expect.
struct ThisPhoneSection: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var hubName: String

    private let grid = MC.RowGrid.touch

    var body: some View {
        let phone = session.phoneSpeaker
        let item = phone.row(in: model.speakers)
        VStack(alignment: .leading, spacing: MC.Space.s) {
            GroupedSection(title: "This iPhone") {
                SpeakerRow(
                    speaker: item,
                    grid: grid,
                    density: .touch,
                    masterVolume: model.masterVolume,
                    onToggle: { on in
                        withAnimation(MC.Motion.state(reduceMotion)) { phone.setOn(on) }
                    },
                    onVolume: { if let id = phone.speakerID { model.setVolume($0, for: id) } },
                    onCommitVolume: { if let id = phone.speakerID { model.commitVolume(for: id) } },
                    onRetry: phone.resume,
                    onDetails: phone.speakerID.map { id in { showDetail(id) } }
                ) {
                    if let id = phone.speakerID {
                        Button { showDetail(id) } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(MC.Ink.tertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name) details")
                        .transition(.opacity)
                    }
                }
            }
            Text(phone.footnote(hubName: hubName))
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MC.Space.m)
                .id(phone.footnote(hubName: hubName))
                .transition(.opacity)
        }
        .animation(MC.Motion.state(reduceMotion), value: phone.isOn)
        .animation(MC.Motion.state(reduceMotion), value: phone.route)
    }

    private func showDetail(_ id: SpeakerID) {
        session.navigation.speakerDetail = .init(id: id)
    }
}

/// In this device's own speaker details: how the link to the Mac is doing, in numbers.
struct PhoneLinkSection: View {
    var stats: PhoneSpeakerStats
    var output: PhoneOutputDiagnostics?

    var body: some View {
        GroupedSection(title: "Link to the Mac", trailing: nil) {
            VStack(spacing: 0) {
                line("Round trip", String(format: "%.1f ms", Double(stats.bestRoundTripNanos) / 1e6),
                     hint: "The clocks agree to within half of this.")
                RowDivider(leading: MC.Space.m)
                line("Clock drift", String(format: "%+.1f ppm", stats.clockDriftPPM))
                RowDivider(leading: MC.Space.m)
                line("Buffered", stats.isPlaying ? String(format: "%.1f s", stats.bufferedMillis / 1000) : "Not playing")
                RowDivider(leading: MC.Space.m)
                line("Packets asked for again", "\(stats.packetsRecovered)")
                RowDivider(leading: MC.Space.m)
                line("Packets lost", "\(stats.packetsConcealed)",
                     hint: stats.packetsConcealed == 0 ? nil : "Each is a gap of 8 ms, faded.")
                if let output {
                    RowDivider(leading: MC.Space.m)
                    line("Output delay", String(format: "%.0f ms", output.outputLatencyMillis),
                         hint: "What iOS reports for this output, already allowed for.")
                    RowDivider(leading: MC.Space.m)
                    line("Off the timeline by", String(format: "%+.2f ms", output.syncErrorMillis))
                    RowDivider(leading: MC.Space.m)
                    line("Speed correction", String(format: "%+.0f ppm", output.rateCorrectionPPM))
                    RowDivider(leading: MC.Space.m)
                    line("Dropouts", "\(output.underrunFrames * 1000 / 44_100) ms \u{00B7} \(output.jumps) jumps")
                }
            }
        }
    }

    private func line(_ title: String, _ value: String, hint: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MC.Space.m) {
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                if let hint {
                    Text(hint)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: MC.Space.s)
            Text(value)
                .font(MC.Font.value)
                .foregroundStyle(MC.Ink.body)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, MC.Space.m)
        .padding(.vertical, MC.Space.s)
        .accessibilityElement(children: .combine)
    }
}
