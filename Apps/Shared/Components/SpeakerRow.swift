import SwiftUI
import MulticastHubModel

/// One speaker: checkbox, glyph, name over live status, volume, value, and an accessory slot
/// (the Mac puts the detail button there). Every row uses the same `RowGrid`, so sliders,
/// values and accessories line up down the list and with the master row.
///
/// Clicking anywhere on the glyph or the words toggles the speaker, as in Control Center's
/// sound list; the slider, value and accessory stay separate targets. To VoiceOver the row is
/// one toggle whose adjustable value is the volume.
///
/// `.touch` is the phone's layout: the same parts, with the on/off mark at 22pt, the words and
/// the accessory on one 44pt line, and the volume slider on its own full-width line under the
/// words. The slider opens only while the speaker is on (its preset is in the detail sheet), so
/// the speakers that are playing are the ones with controls.
struct SpeakerRow<Accessory: View>: View {
    enum Density { case regular, dense, touch }

    var speaker: SpeakerItem
    var grid: MC.RowGrid = .regular
    var density: Density = .regular
    /// The master volume, to say what the speaker really plays at.
    var masterVolume: Double = 1
    /// False when the row itself takes keyboard focus (the Mac window), so Tab stops once per row.
    var controlsTakeFocus = true
    var onToggle: (Bool) -> Void
    var onVolume: (Double) -> Void
    var onCommitVolume: () -> Void = {}
    var onRetry: () -> Void
    var onDetails: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The phone's on/off mark and glyph grow with the text, so they never sit tiny beside it.
    @ScaledMetric(relativeTo: .body) private var touchMark: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var touchGlyph: CGFloat = 17
    /// Counts on/off taps made on this row, so the phone's haptic answers a touch and never a
    /// change that arrived from the hub.
    @State private var touchToggles = 0

    var body: some View {
        layout
            .padding(.horizontal, grid.inset)
            .padding(.vertical, grid.verticalPadding)
            .contentShape(Rectangle())
            .animation(MC.Motion.state(reduceMotion), value: speaker.state)
            .animation(MC.Motion.state(reduceMotion), value: speaker.isEnabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(speaker.name)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction { onToggle(!speaker.isEnabled) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onVolume(min(1, speaker.volume + 0.05)); onCommitVolume()
                case .decrement: onVolume(max(0, speaker.volume - 0.05)); onCommitVolume()
                @unknown default: break
                }
            }
            .accessibilityActions {
                if case .failed = speaker.state { Button("Try again", action: onRetry) }
                if let onDetails { Button("Details", action: onDetails) }
            }
    }

    @ViewBuilder private var layout: some View {
        if density == .touch { touchLayout } else { deskLayout }
    }

    private var isFailed: Bool {
        if case .failed = speaker.state { true } else { false }
    }

    /// Scaled with the text, but capped: past this the marks only take room from the name.
    private var markSize: CGFloat { min(max(grid.checkbox, touchMark), 30) }
    private var glyphSize: CGFloat { min(max(17, touchGlyph), 24) }

    private func touchToggle(_ on: Bool) {
        touchToggles += 1
        onToggle(on)
    }

    private var touchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    SpeakerCheckbox(isOn: speaker.isEnabled, label: "Play on \(speaker.name)",
                                    size: markSize, onChange: touchToggle)
                        .frame(width: markSize)
                        .padding(.trailing, MC.Space.s)
                    Image(systemName: speaker.glyph.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: glyphSize, weight: speaker.glyph.weight))
                        .foregroundStyle(speaker.isEnabled ? AnyShapeStyle(MC.Ink.body) : AnyShapeStyle(MC.Ink.tertiary))
                        .frame(width: max(grid.glyph, glyphSize + 7), height: max(grid.glyph, glyphSize + 7))
                        .padding(.trailing, MC.Space.s)
                    VStack(alignment: .leading, spacing: MC.Space.xxs) {
                        Text(speaker.name)
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.primary)
                            // Large text wraps names rather than cutting "Main Bedroom" and
                            // "Master Bedroom" to the same few letters.
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        SpeakerStatusLine(speaker: speaker, onRetry: nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { touchToggle(!speaker.isEnabled) }

                if isFailed {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.leading, MC.Space.s)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
                accessory()
                    .frame(width: grid.accessory, height: 44)
            }

            if speaker.isEnabled {
                HStack(spacing: MC.Space.s) {
                    VolumeSlider(value: speaker.volume, label: "\(speaker.name) volume",
                                 onChange: onVolume, onCommit: onCommitVolume)
                    Text(MC.Format.percent(speaker.volume))
                        .font(MC.Font.value)
                        .foregroundStyle(MC.Ink.body)
                        .contentTransition(.numericText(value: speaker.volume))
                        .animation(MC.Motion.feedback, value: speaker.volume)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: grid.value, alignment: .trailing)
                }
                .padding(.leading, grid.textLeading - grid.inset)
                // The value's last digit sits under the accessory glyph's right edge.
                .padding(.trailing, (grid.accessory - 20) / 2)
                .padding(.bottom, MC.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sensoryFeedback(.selection, trigger: touchToggles)
    }

    private var deskLayout: some View {
        HStack(spacing: 0) {
            SpeakerCheckbox(isOn: speaker.isEnabled, label: "Play on \(speaker.name)", onChange: onToggle)
                .frame(width: grid.checkbox, alignment: .leading)
                .padding(.trailing, MC.Space.s)
                .focusable(controlsTakeFocus)

            HStack(spacing: 0) {
                Image(systemName: speaker.glyph.symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: speaker.glyph.weight))
                    .foregroundStyle(speaker.isEnabled ? AnyShapeStyle(MC.Ink.body) : AnyShapeStyle(MC.Ink.tertiary))
                    .frame(width: grid.glyph, height: grid.glyph)
                    .padding(.trailing, MC.Space.s)

                if grid.badge > 0 {
                    ZStack {
                        if speaker.state != .off { StateBadge(state: speaker.state) }
                    }
                    .frame(width: grid.badge, height: grid.badge)
                    .padding(.trailing, MC.Space.s)
                }

                labels
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle(!speaker.isEnabled) }
            .padding(.trailing, MC.Space.m)

            VolumeSlider(value: speaker.volume, label: "\(speaker.name) volume", isLive: speaker.isEnabled,
                         onChange: onVolume, onCommit: onCommitVolume)
                .controlSize(density == .dense ? .small : .regular)
                // Off: still adjustable (it's the level the speaker joins at), visibly not sounding.
                .opacity(speaker.isEnabled ? 1 : 0.5)
                .focusable(controlsTakeFocus)
                .frame(width: grid.slider)

            if density == .regular {
                Text(MC.Format.percent(speaker.volume))
                    .font(MC.Font.value)
                    .foregroundStyle(speaker.isEnabled ? AnyShapeStyle(MC.Ink.body) : AnyShapeStyle(MC.Ink.tertiary))
                    .contentTransition(.numericText(value: speaker.volume))
                    .animation(MC.Motion.feedback, value: speaker.volume)
                    .frame(width: grid.value, alignment: .trailing)
                    .padding(.leading, MC.Space.s)
                    .help(effectiveHelp)
                    .accessibilityHidden(true)

                accessory()
                    .frame(width: grid.accessory)
                    .padding(.leading, MC.Space.s)
            }
        }
    }

    private var effective: Int { Int((speaker.effectiveVolume(master: masterVolume) * 100).rounded()) }

    private var effectiveHelp: String {
        "Plays at \(effective)% with the master at \(MC.Format.percent(masterVolume))%"
    }

    private var accessibilityValue: String {
        let state = SpeakerStatusLine.accessibilityState(speaker.state)
        let volume = "volume \(MC.Format.percent(speaker.volume)) percent"
        guard speaker.isEnabled else { return "Off, \(volume)" }
        return "On, \(state), \(volume), plays at \(effective) percent"
    }

    @ViewBuilder private var labels: some View {
        switch density {
        case .regular, .touch:
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(speaker.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                    .lineLimit(1)
                SpeakerStatusLine(speaker: speaker, onRetry: onRetry)
            }
        case .dense:
            // One line; a failure adds its reason and the retry under the name, in place.
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(speaker.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if case .failed(let reason) = speaker.state {
                    HStack(spacing: MC.Space.xs) {
                        Text(reason)
                            .foregroundStyle(MC.Status.failed)
                            .lineLimit(1)
                        Button("Try again", action: onRetry)
                            .mcLinkButtonStyle()
                    }
                    .font(MC.Font.caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .help(SpeakerStatusLine.accessibilityState(speaker.state))
        }
    }
}

extension SpeakerRow where Accessory == EmptyView {
    init(speaker: SpeakerItem, grid: MC.RowGrid = .regular, density: Density = .regular, masterVolume: Double = 1,
         onToggle: @escaping (Bool) -> Void, onVolume: @escaping (Double) -> Void,
         onCommitVolume: @escaping () -> Void = {}, onRetry: @escaping () -> Void) {
        self.init(speaker: speaker, grid: grid, density: density, masterVolume: masterVolume,
                  onToggle: onToggle, onVolume: onVolume, onCommitVolume: onCommitVolume,
                  onRetry: onRetry, accessory: { EmptyView() })
    }
}

extension SpeakerGlyph {
    /// Symbols with no filled variant are drawn heavier, so the glyph column reads at one
    /// optical weight next to the filled speakers and receiver.
    var weight: Font.Weight {
        switch self {
        case .laptop, .display, .headphones, .usb: .semibold
        default: .regular
        }
    }
}

private extension VerticalAlignment {
    /// The master row's label and big number centre on the slider, not on slider + meter.
    enum SliderCentre: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let sliderCentre = VerticalAlignment(SliderCentre.self)
}

/// The master row: same grid as the speaker rows, with the one big number in the value and
/// accessory tracks and the output meter 8pt under its slider, end to end with its track.
struct MasterVolumeRow: View {
    var volume: Double
    var levels: StereoLevels
    var grid: MC.RowGrid = .regular
    var showsBigNumber = true
    var onChange: (Double) -> Void
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(alignment: .sliderCentre, spacing: 0) {
            Text("Master volume")
                .font(MC.Font.bodyEmphasis)
                .foregroundStyle(MC.Ink.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, MC.Space.m)

            VStack(spacing: MC.Space.s) {
                VolumeSlider(value: volume, label: "Master volume", onChange: onChange, onCommit: onCommit)
                    .controlSize(showsBigNumber ? .regular : .small)
                    .alignmentGuide(.sliderCentre) { $0[VerticalAlignment.center] }
                LevelMeter(levels: levels)
            }
            .frame(width: grid.slider)

            if showsBigNumber {
                Text(MC.Format.percent(volume))
                    .font(MC.Font.bigNumber)
                    .foregroundStyle(MC.Ink.primary)
                    .contentTransition(.numericText(value: volume))
                    .animation(MC.Motion.feedback, value: volume)
                    .frame(width: grid.value + MC.Space.s + grid.accessory, alignment: .trailing)
                    .padding(.leading, MC.Space.s)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, grid.inset)
        .padding(.vertical, grid.verticalPadding)
        // Without the big number the meter would sit the label high in its card; match the
        // meter's reach above the slider so label and slider stay on the card's centre line.
        .padding(.top, showsBigNumber ? 0 : MC.Space.s + LevelMeter.height)
    }
}

/// A grouped container: fill alone, no border; rows separated by an inset hairline. Inside a
/// popover or the menu-bar panel it steps up from the raised surface.
struct GroupedSection<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.mcOnRaisedSurface) private var onRaised

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.s) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: MC.Space.s) {
                    if let title {
                        Text(title)
                            .font(MC.Font.captionEmphasis)
                            .foregroundStyle(MC.Ink.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: MC.Space.s)
                    if let trailing {
                        Text(trailing)
                            .font(MC.Font.caption)
                            .foregroundStyle(MC.Ink.secondary)
                    }
                }
                .padding(.horizontal, MC.Space.m)
            }
            VStack(spacing: 0) { content() }
                .background(onRaised ? MC.Surface.groupOnRaised : MC.Surface.group,
                            in: RoundedRectangle(cornerRadius: MC.Radius.large, style: .continuous))
        }
    }
}

/// Hairline between rows, starting at the row's text column.
struct RowDivider: View {
    var leading: CGFloat = MC.Space.m
    @Environment(\.displayScale) private var displayScale
    @Environment(\.mcOnRaisedSurface) private var onRaised
    var body: some View {
        Rectangle()
            .fill(onRaised ? MC.Ink.faintOnRaised : MC.Ink.faint)
            .frame(height: 1 / displayScale)
            .padding(.leading, leading)
            .padding(.trailing, MC.Space.m)
            .accessibilityHidden(true)
    }
}
