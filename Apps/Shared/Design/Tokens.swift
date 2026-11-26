import SwiftUI

/// Multicast's design tokens. One neutral family, five inks, one accent (the system accent),
/// two status colours. Shared by the Mac hub and the iOS remote, so no AppKit or UIKit here.
enum MC {}

// MARK: - Colour

/// A colour that resolves per appearance. Pure SwiftUI so it works on both platforms.
struct Adaptive: ShapeStyle {
    let light: Color
    let dark: Color
    /// Used under Increase Contrast; falls back to the normal pair.
    var lightHigh: Color?
    var darkHigh: Color?

    func resolve(in environment: EnvironmentValues) -> Color {
        let high = environment.colorSchemeContrast == .increased
        switch environment.colorScheme {
        case .dark: return high ? (darkHigh ?? dark) : dark
        default: return high ? (lightHigh ?? light) : light
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension MC {
    /// Five inks, strongest first. Contrast is checked against `Surface.group` and
    /// `Surface.canvas`: ink1–3 clear 4.5:1 for text, ink4 clears 3:1 for glyphs.
    enum Ink {
        /// Titles, names, values.
        static let primary = Adaptive(light: Color(hex: 0x1D1D1F), dark: Color(hex: 0xF5F5F7))
        /// Body copy that isn't a name.
        static let body = Adaptive(light: Color(hex: 0x3A3A3D), dark: Color(hex: 0xD6D6DB))
        /// Subtitles, captions, secondary values.
        static let secondary = Adaptive(light: Color(hex: 0x66666B), dark: Color(hex: 0xA6A6AB),
                                        lightHigh: Color(hex: 0x48484C), darkHigh: Color(hex: 0xC7C7CC))
        /// Glyphs and quiet controls.
        static let tertiary = Adaptive(light: Color(hex: 0x86868B), dark: Color(hex: 0x86868B),
                                       lightHigh: Color(hex: 0x5E5E63), darkHigh: Color(hex: 0xAEAEB2))
        /// Hairlines and tracks. Never for glyphs: a disabled glyph is `tertiary` at half opacity.
        static let faint = Adaptive(light: Color(hex: 0xDCDCE0), dark: Color(hex: 0x3D3D41),
                                    lightHigh: Color(hex: 0xB8B8BD), darkHigh: Color(hex: 0x5A5A5F))
        /// Hairlines on `Surface.groupOnRaised`, one step up to stay visible on the lighter fill.
        static let faintOnRaised = Adaptive(light: Color(hex: 0xDCDCE0), dark: Color(hex: 0x4C4C50),
                                            lightHigh: Color(hex: 0xB8B8BD), darkHigh: Color(hex: 0x66666B))
    }

    enum Surface {
        /// The pane behind content.
        static let canvas = Adaptive(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1E1E20))
        /// Grouped containers on the canvas. Dark gets depth from a lighter step, not a shadow.
        static let group = Adaptive(light: Color(hex: 0xF4F4F6), dark: Color(hex: 0x2A2A2D))
        /// Popovers and the menu-bar panel.
        static let raised = Adaptive(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x2C2C2F))
        /// Grouped containers inside a raised surface: one step lighter again in dark, so a
        /// nested surface is never darker than its parent.
        static let groupOnRaised = Adaptive(light: Color(hex: 0xF4F4F6), dark: Color(hex: 0x3A3A3D))
        /// Empty artwork and placeholders.
        static let well = Adaptive(light: Color(hex: 0xE8E8EC), dark: Color(hex: 0x38383B))
    }

    /// Status colours mean status, nothing else.
    enum Status {
        static let playing = Adaptive(light: Color(hex: 0x1E9E46), dark: Color(hex: 0x32D158))
        static let failed = Adaptive(light: Color(hex: 0xC8001A), dark: Color(hex: 0xFF5A50))
    }

    static let accent = Color.accentColor
}

// MARK: - Surface level

extension EnvironmentValues {
    /// True inside a popover or the menu-bar panel, so grouped sections step up from the
    /// raised surface instead of the canvas.
    @Entry var mcOnRaisedSurface = false
}

extension View {
    /// Marks the content as sitting on `MC.Surface.raised`.
    func onRaisedSurface() -> some View { environment(\.mcOnRaisedSurface, true) }

    /// A text-only action in the accent, as a link button on the Mac and a borderless one on iOS.
    func mcLinkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless).foregroundStyle(MC.accent)
        #endif
    }
}

// MARK: - Type

extension MC {
    /// System text styles, chosen for their macOS sizes (15 / 13 / 11) so they scale with
    /// Dynamic Type on iOS. Hierarchy is one weight step: regular and semibold.
    enum Font {
        /// 15pt semibold: the now-playing title, pane titles.
        static let title = SwiftUI.Font.title3.weight(.semibold)
        /// 13pt: names, list rows.
        static let body = SwiftUI.Font.body
        static let bodyEmphasis = SwiftUI.Font.body.weight(.semibold)
        /// 11pt: subtitles, section headers, captions.
        static let caption = SwiftUI.Font.subheadline
        static let captionEmphasis = SwiftUI.Font.subheadline.weight(.semibold)
        /// The one big number: master volume.
        static let bigNumber = SwiftUI.Font.largeTitle.weight(.regular).monospacedDigit()
        /// Values that change: time, %, ms.
        static let value = SwiftUI.Font.body.monospacedDigit()
        static let captionValue = SwiftUI.Font.subheadline.monospacedDigit()
    }
}

// MARK: - Space, radius, size

extension MC {
    /// A 4pt scale. Words keep `m` from any container edge.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    /// Nested shapes: outer = inner + padding.
    enum Radius {
        /// List artwork, small tiles.
        static let small: CGFloat = 4
        /// Now-playing artwork, buttons.
        static let medium: CGFloat = 8
        /// Grouped containers (inner 8 + 4 inset).
        static let large: CGFloat = 12
    }

    /// Fixed tracks shared by every speaker row and the master row, so columns line up.
    struct RowGrid: Sendable {
        var checkbox: CGFloat = 16
        var glyph: CGFloat = 20
        /// A fixed slot for the state badge in front of the name (dense rows), so the dots,
        /// spinners and triangles form one column. Zero where the badge leads the status line.
        var badge: CGFloat = 0
        var slider: CGFloat
        var value: CGFloat = 30
        var accessory: CGFloat = 20
        var inset: CGFloat = MC.Space.m
        var verticalPadding: CGFloat = MC.Space.m

        /// Where a row's words start; dividers begin here.
        var textLeading: CGFloat {
            inset + checkbox + MC.Space.s + glyph + MC.Space.s + (badge > 0 ? badge + MC.Space.s : 0)
        }

        static let regular = RowGrid(slider: 200)
        static let dense = RowGrid(badge: 10, slider: 112, verticalPadding: MC.Space.s)
        /// The phone: a 22pt on/off mark, the slider on its own line under the words (so its
        /// width is the row's, not a track), a 36pt value and a 44pt accessory button.
        static let touch = RowGrid(checkbox: 22, glyph: 24, slider: 0, value: 36, accessory: 44,
                                   verticalPadding: MC.Space.s)
    }
}

// MARK: - Motion

extension MC {
    /// Every motion has a cause; these are the two curves. Reduce Motion swaps travel for a
    /// short cross-fade, and nothing loops for decoration.
    enum Motion {
        /// State changes in place: a row's status, a value rolling.
        static func state(_ reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.45, 0, 0.1, 1, duration: 0.32)
        }
        /// Things that arrive: a retry button opening its room, a row appearing.
        static func arrive(_ reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.5)
        }
        /// UI feedback stays as quick as the platform's.
        static let feedback: Animation = .easeOut(duration: 0.15)
        /// Meters follow data, smoothed just enough to not flicker.
        static let meter: Animation = .linear(duration: 0.08)
    }
}

// MARK: - Formatting

extension MC {
    enum Format {
        static func time(_ t: TimeInterval) -> String {
            let s = max(0, Int(t.rounded(.down)))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
        static func trim(_ ms: Int) -> String {
            ms == 0 ? "0 ms" : (ms > 0 ? "+\(ms) ms" : "\u{2212}\(-ms) ms")
        }
    }
}
