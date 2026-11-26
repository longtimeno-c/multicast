import SwiftUI
import MulticastHubModel

// MARK: - Volume slider

/// The system slider, labelled for VoiceOver, reporting 0…1. Native on both platforms.
/// `isLive` false draws the fill in a neutral ink: the value is a preset for a speaker that is
/// off, still adjustable, but visibly not sounding.
struct VolumeSlider: View {
    var value: Double
    var label: String
    var isLive = true
    var onChange: (Double) -> Void
    /// The end of a drag (or a keyboard step), so the model can send the final value at once.
    var onCommit: () -> Void = {}

    var body: some View {
        Slider(value: Binding(get: { value }, set: onChange), in: 0...1) {
            Text(label)
        } onEditingChanged: { editing in
            if !editing { onCommit() }
        }
        .labelsHidden()
        .tint(isLive ? MC.accent : Color.secondary)
        .accessibilityLabel(label)
        .accessibilityValue("\(MC.Format.percent(value)) percent")
    }
}

// MARK: - Level meter

/// Two quiet bars, left over right, showing the outgoing mix. One ink; status colour only
/// if the signal clips. Silent, it fades out rather than showing two empty tracks.
struct LevelMeter: View {
    var levels: StereoLevels
    static let height: CGFloat = 6
    var barHeight: CGFloat = 2
    var gap: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: gap) {
            bar(levels.left)
            bar(levels.right)
        }
        .frame(height: barHeight * 2 + gap)
        .opacity(levels == .silent ? 0 : 1)
        .animation(MC.Motion.state(reduceMotion), value: levels == .silent)
        .accessibilityElement()
        .accessibilityLabel("Output level")
        .accessibilityValue(levels == .silent ? "Silent" : "Left \(Self.percent(levels.left)), right \(Self.percent(levels.right))")
    }

    private func bar(_ peak: Float) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(MC.Ink.faint)
                Capsule()
                    .fill(peak >= 0.999 ? AnyShapeStyle(MC.Status.failed) : AnyShapeStyle(MC.Ink.tertiary))
                    .frame(width: max(0, g.size.width * Self.display(peak)))
                    .animation(MC.Motion.meter, value: peak)
            }
        }
        .frame(height: barHeight)
    }

    /// Linear peak onto a 40 dB scale: typical music peaks (-6 to -14 dBFS) land between about
    /// 65 and 85 percent and visibly move; silence below -40 dB reads as empty.
    static let range: Double = 40
    static func display(_ peak: Float) -> CGFloat {
        guard peak > 0.0001 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(max(0, min(1, 1 + db / range)))
    }

    static func percent(_ peak: Float) -> String { "\(Int(display(peak) * 100)) percent" }
}

// MARK: - Stale status

extension EnvironmentValues {
    /// The status shown is the last known, not live (the link to the hub is down): status
    /// colours step down to the tertiary ink and spinners stop, so only live state looks live.
    @Entry var mcStatusIsStale = false
}

// MARK: - State badge

/// The mark in front of a speaker's status line. Each state owns one shape: a spinner for
/// connecting, a dot for connected (green once audio flows), a triangle for failure.
struct StateBadge: View {
    var state: SpeakerState
    static let size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mcStatusIsStale) private var isStale

    var body: some View {
        ZStack {
            switch state {
            case .off:
                EmptyView()
            case .connecting:
                if isStale {
                    Circle().strokeBorder(MC.Ink.tertiary, lineWidth: 1).frame(width: 7, height: 7)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            case .ready:
                Circle().fill(MC.Ink.tertiary).frame(width: 6, height: 6)
            case .playing:
                Circle().fill(isStale ? AnyShapeStyle(MC.Ink.tertiary) : AnyShapeStyle(MC.Status.playing))
                    .frame(width: 6, height: 6)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isStale ? AnyShapeStyle(MC.Ink.tertiary) : AnyShapeStyle(MC.Status.failed))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
        .accessibilityHidden(true)
    }
}

/// The second line of a speaker row: badge and words, changing in place. A new status word
/// pushes the old one out of the same slot rather than smudging through it.
struct SpeakerStatusLine: View {
    var speaker: SpeakerItem
    var onRetry: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mcStatusIsStale) private var isStale

    var body: some View {
        HStack(spacing: MC.Space.xs) {
            if speaker.state != .off {
                StateBadge(state: speaker.state)
            }
            Text(text)
                .foregroundStyle(isFailed && !isStale ? AnyShapeStyle(MC.Status.failed) : AnyShapeStyle(MC.Ink.secondary))
                .lineLimit(1)
                .id(text)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
            if isFailed, let onRetry {
                Button("Try again", action: onRetry)
                    .mcLinkButtonStyle()
                    .padding(.leading, MC.Space.xs)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .font(MC.Font.caption)
        .clipped()
        .animation(MC.Motion.state(reduceMotion), value: speaker.state)
    }

    private var isFailed: Bool {
        if case .failed = speaker.state { true } else { false }
    }

    private var text: String {
        switch speaker.state {
        case .off, .ready, .playing:
            // Still listed in case it comes back; say it has gone quiet rather than drop it.
            speaker.notSeenSince == nil ? speaker.kindDescription : "Not seen on the network"
        case .connecting: "Connecting\u{2026}"
        case .failed(let reason): reason
        }
    }

    static func accessibilityState(_ s: SpeakerState) -> String {
        switch s {
        case .off: "Off"
        case .connecting: "Connecting"
        case .ready: "Connected"
        case .playing: "Playing"
        case .failed(let reason): "Not working: \(reason)"
        }
    }
}

// MARK: - Checkbox

/// The speaker's on/off mark: a real Toggle drawn the way the system AirPlay pickers draw a
/// chosen destination, an empty circle that becomes a filled checkmark. The plain system
/// checkbox has no visible edge when unchecked on a grouped fill (about 1.2:1), and whether a
/// speaker is on is the reason this app exists; the circle clears 3:1 off and differs in shape,
/// not just colour, so it reads the same in a background window, in dark mode and on iOS.
struct SpeakerCheckbox: View {
    var isOn: Bool
    var label: String
    /// 16pt on the Mac; the phone draws it at 22pt (`MC.RowGrid.touch.checkbox`).
    var size: CGFloat = SpeakerToggleStyle.size
    var onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) { Text(label) }
            .labelsHidden()
            .toggleStyle(SpeakerToggleStyle(size: size))
            .accessibilityLabel(label)
    }
}

struct SpeakerToggleStyle: ToggleStyle {
    static let size: CGFloat = 16
    var size: CGFloat = SpeakerToggleStyle.size
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(MC.Ink.tertiary),
                                 MC.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
