import SwiftUI
import MulticastHubModel

/// The words for a speaker that turned the hub away, the same on the Mac and the iPhone.
enum RestrictedSpeakerWording {
    /// The group they are listed in, under the speakers this person can use.
    static let groupTitle = "Not available to you"
    /// The row's one caption.
    static let caption = "Only its owner can play to it"
    /// While the hub asks it again.
    static let checking = "Checking\u{2026}"
    /// The one action: ask it again (the owner may have changed the setting).
    static let checkAgain = "Check Again"
    /// The detail's explanation.
    static let explanation = "Its AirPlay access setting lets only its owner play to it, so Multicast has turned it off and won\u{2019}t try it again by itself."
    static let checkAgainHint = "If the owner changes that setting, Check Again moves it back to your speakers."
}

/// A speaker this person may not play to: listed, so nobody wonders where it went, but out of
/// the way. No on/off control and no volume: a lock sits in the on/off column, the glyph and
/// the name are dimmed (still at text contrast), one plain caption, and one quiet action.
/// Nothing here is red: it isn't broken, it isn't theirs.
///
/// Same grid as `SpeakerRow`, so its glyph and words line up with the speakers above.
struct RestrictedSpeakerRow<Accessory: View>: View {
    var speaker: SpeakerItem
    var grid: MC.RowGrid = .regular
    var density: SpeakerRow<EmptyView>.Density = .regular
    var onCheckAgain: () -> Void
    var onDetails: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var touchMark: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var touchGlyph: CGFloat = 17

    /// The hub is asking it again.
    private var isChecking: Bool { speaker.state == .connecting }
    private var caption: String { isChecking ? RestrictedSpeakerWording.checking : RestrictedSpeakerWording.caption }

    var body: some View {
        layout
            .padding(.horizontal, grid.inset)
            .padding(.vertical, grid.verticalPadding)
            .animation(MC.Motion.state(reduceMotion), value: isChecking)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(speaker.name)
            .accessibilityValue("\(RestrictedSpeakerWording.groupTitle). \(caption)")
            .accessibilityActions {
                if !isChecking { Button(RestrictedSpeakerWording.checkAgain, action: onCheckAgain) }
                if let onDetails { Button("Details", action: onDetails) }
            }
    }

    @ViewBuilder private var layout: some View {
        switch density {
        case .regular: deskLayout(dense: false)
        case .dense: deskLayout(dense: true)
        case .touch: touchLayout
        }
    }

    private func lock(size: CGFloat) -> some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(MC.Ink.tertiary)
            .accessibilityHidden(true)
    }

    private func glyph(size: CGFloat) -> some View {
        Image(systemName: speaker.glyph.symbolName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: speaker.glyph.weight))
            .foregroundStyle(MC.Ink.tertiary)
            .accessibilityHidden(true)
    }

    private var name: some View {
        Text(speaker.name)
            .font(MC.Font.body)
            .foregroundStyle(MC.Ink.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }

    private var captionText: some View {
        Text(caption)
            .font(MC.Font.caption)
            .foregroundStyle(MC.Ink.secondary)
            .lineLimit(1)
            .id(caption)
            .transition(reduceMotion ? .opacity : .push(from: .bottom))
    }

    private var checkAgainButton: some View {
        Button(RestrictedSpeakerWording.checkAgain, action: onCheckAgain)
            .mcLinkButtonStyle()
            .font(MC.Font.caption)
            .fixedSize()
            .disabled(isChecking)
            .opacity(isChecking ? 0 : 1)
    }

    /// The Mac window (regular) and the menu-bar panel (dense).
    private func deskLayout(dense: Bool) -> some View {
        HStack(spacing: 0) {
            lock(size: 11)
                .frame(width: grid.checkbox, alignment: .center)
                .padding(.trailing, MC.Space.s)
            glyph(size: 14)
                .frame(width: grid.glyph, height: grid.glyph)
                .padding(.trailing, MC.Space.s)
            if grid.badge > 0 {
                Color.clear
                    .frame(width: grid.badge, height: grid.badge)
                    .padding(.trailing, MC.Space.s)
            }
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                name
                if dense {
                    HStack(spacing: MC.Space.xs) {
                        captionText
                        checkAgainButton
                            .padding(.leading, MC.Space.xs)
                    }
                    .clipped()
                } else {
                    captionText.clipped()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !dense {
                checkAgainButton
                    .padding(.leading, MC.Space.m)
                accessory()
                    .frame(width: grid.accessory)
                    .padding(.leading, MC.Space.s)
            }
        }
    }

    /// The phone: the speaker rows' marks and info button, the action under the words.
    private var touchLayout: some View {
        let mark = min(max(grid.checkbox, touchMark), 30)
        let glyphSize = min(max(17, touchGlyph), 24)
        return HStack(spacing: 0) {
            lock(size: mark * 0.62)
                .frame(width: mark)
                .padding(.trailing, MC.Space.s)
            glyph(size: glyphSize)
                .frame(width: max(grid.glyph, glyphSize + 7), height: max(grid.glyph, glyphSize + 7))
                .padding(.trailing, MC.Space.s)
            // The name and caption keep the row's full width (a phone has no room for the action
            // beside them); the action sits under them on the text column.
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                name
                captionText.clipped()
                checkAgainButton
                    .frame(minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            accessory()
                .frame(width: grid.accessory, height: 44)
        }
    }
}

extension RestrictedSpeakerRow where Accessory == EmptyView {
    init(speaker: SpeakerItem, grid: MC.RowGrid = .regular, density: SpeakerRow<EmptyView>.Density = .regular,
         onCheckAgain: @escaping () -> Void) {
        self.init(speaker: speaker, grid: grid, density: density, onCheckAgain: onCheckAgain, accessory: { EmptyView() })
    }
}

/// The detail of a speaker that turned the hub away: what it means, and Check Again. Nothing
/// else: no volume, no sync trim, nothing to adjust on a speaker this person can't use.
struct RestrictedSpeakerExplanation: View {
    var speaker: SpeakerItem
    var onCheckAgain: () -> Void

    private var isChecking: Bool { speaker.state == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            Text(RestrictedSpeakerWording.explanation)
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(RestrictedSpeakerWording.checkAgainHint)
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MC.Space.s) {
                Button(RestrictedSpeakerWording.checkAgain, action: onCheckAgain)
                    .disabled(isChecking)
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text(RestrictedSpeakerWording.checking)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                }
            }
        }
    }
}
