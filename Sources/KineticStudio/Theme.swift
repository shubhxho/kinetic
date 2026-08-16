//
//  Theme.swift
//  Kinetic Studio
//
//  Design tokens and the thin layer that dresses SwiftUI's own controls.
//
//  Everything here composes native views — `Button`, `Toggle`, `Slider`,
//  `LabeledContent`, `GroupBox`, `Divider` — rather than reimplementing them.
//  A hand-drawn checkbox looks the same until someone tabs to it, right-clicks
//  it, turns on Increase Contrast or runs VoiceOver; the native control already
//  does all of that, and styling it through `ButtonStyle` / `ToggleStyle` is how
//  SwiftUI is meant to be extended.
//

import SwiftUI

enum Palette {
    // Neutrals — dark
    static let black = Color(red: 0, green: 0, blue: 0)
    static let surface = Color(white: 0.039)          // #0A0A0A
    static let surfaceElevated = Color(white: 0.067)  // #111111
    static let border = Color(white: 0.149)           // #262626
    static let borderSubtle = Color(white: 0.102)     // #1A1A1A
    static let text = Color(white: 0.929)             // #EDEDED
    static let textSecondary = Color(white: 0.631)    // #A1A1A1
    static let textTertiary = Color(white: 0.400)     // #666666

    // Neutrals — light
    static let lightBackground = Color(white: 1.0)
    static let lightSurface = Color(white: 0.980)     // #FAFAFA
    static let lightBorder = Color(white: 0.918)      // #EAEAEA
    static let lightText = Color(white: 0.090)        // #171717
    static let lightTextSecondary = Color(white: 0.400)

    // Accents
    static let accent = Color(red: 0.0, green: 0.439, blue: 0.953)     // #0070F3
    static let success = Color(red: 0.047, green: 0.808, blue: 0.420)  // #0CCE6B
    static let warning = Color(red: 0.961, green: 0.651, blue: 0.137)  // #F5A623
    static let danger = Color(red: 1.0, green: 0.302, blue: 0.310)     // #FF4D4F
    static let violet = Color(red: 0.494, green: 0.298, blue: 1.0)     // #7E4CFF
    static let cyan = Color(red: 0.31, green: 0.85, blue: 0.95)

    /// Categorical series colours for plots, ordered for maximum separation.
    static let series: [Color] = [
        accent, success, warning, violet, cyan, danger,
        Color(red: 0.98, green: 0.45, blue: 0.72),
        Color(red: 0.60, green: 0.80, blue: 0.30),
    ]
}

struct StudioTheme {
    var isDark: Bool

    var background: Color { isDark ? Palette.black : Palette.lightBackground }
    var surface: Color { isDark ? Palette.surface : Palette.lightSurface }
    var elevated: Color { isDark ? Palette.surfaceElevated : Color.white }
    var border: Color { isDark ? Palette.border : Palette.lightBorder }
    var borderSubtle: Color { isDark ? Palette.borderSubtle : Color(white: 0.95) }
    var text: Color { isDark ? Palette.text : Palette.lightText }
    var secondary: Color { isDark ? Palette.textSecondary : Palette.lightTextSecondary }
    var tertiary: Color { isDark ? Palette.textTertiary : Color(white: 0.6) }
    var accent: Color { Palette.accent }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = StudioTheme(isDark: true)
}

extension EnvironmentValues {
    var studioTheme: StudioTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

enum Typo {
    static let sectionLabel = Font.system(size: 10, weight: .semibold).width(.expanded)
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let small = Font.system(size: 11, weight: .regular)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoLarge = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
}

enum Metric {
    static let radius: CGFloat = 6
    static let radiusLarge: CGFloat = 10
    static let gutter: CGFloat = 12
    static let rowHeight: CGFloat = 24
    static let toolbarHeight: CGFloat = 44
    static let sidebarWidth: CGFloat = 248
    static let inspectorWidth: CGFloat = 288
}

// MARK: - Button styling

/// Styling for the compact controls that live in bars and panel headers.
///
/// A `ButtonStyle` rather than a bespoke `Button` clone: SwiftUI keeps ownership
/// of hit testing, the pressed state, keyboard activation, focus rings and
/// accessibility, and this only decides how the label is dressed.
struct KineticButtonStyle: ButtonStyle {
    @Environment(\.studioTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var isActive: Bool = false
    var tone: Color? = nil
    var showsBorder: Bool = true

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = isActive ? theme.accent
            : (configuration.isPressed ? theme.border
               : (hovering ? theme.border.opacity(0.55) : .clear))

        configuration.label
            .font(Typo.small.weight(.medium))
            .foregroundStyle(isActive ? Color.white : (tone ?? theme.text))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: Metric.radius))
            .overlay {
                if showsBorder && !isActive {
                    RoundedRectangle(cornerRadius: Metric.radius)
                        .stroke(theme.border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == KineticButtonStyle {
    static var kinetic: KineticButtonStyle { KineticButtonStyle() }
    static func kinetic(active: Bool, tone: Color? = nil) -> KineticButtonStyle {
        KineticButtonStyle(isActive: active, tone: tone)
    }
}

// MARK: - Small shared pieces

/// Section heading. Used where a `Form`'s own `Section` header is not available
/// because the content is a plain stack rather than a form.
struct SectionLabel: View {
    @Environment(\.studioTheme) private var theme
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Typo.sectionLabel)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(theme.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Typo.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiary)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Label on the left, monospaced value on the right — `LabeledContent`, which
/// also gives the pair the right VoiceOver reading without extra work.
struct FieldRow: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    let value: String
    var accent: Color? = nil

    var body: some View {
        LabeledContent {
            Text(value)
                .font(Typo.mono)
                .monospacedDigit()
                .foregroundStyle(accent ?? theme.text)
                .lineLimit(1)
        } label: {
            Text(label)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: Metric.rowHeight)
    }
}

/// A metric tile, built on `GroupBox` so it picks up the platform's own
/// grouping treatment.
struct StatTile: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    let value: String
    var unit: String? = nil
    var tone: Color? = nil

    var body: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typo.monoLarge)
                    .monospacedDigit()
                    .foregroundStyle(tone ?? theme.text)
                if let unit {
                    Text(unit)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
                Spacer(minLength: 0)
            }
        } label: {
            Text(label)
                .font(Typo.sectionLabel)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.tertiary)
        }
        .groupBoxStyle(.automatic)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit ?? "")")
    }
}

/// Compact status pill.
struct Chip: View {
    @Environment(\.studioTheme) private var theme
    let text: String
    var tone: Color? = nil

    var body: some View {
        Text(text)
            .font(Typo.monoSmall)
            .monospacedDigit()
            .foregroundStyle(tone ?? theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tone ?? theme.secondary).opacity(0.12), in: Capsule())
    }
}

/// A real `Toggle` with the checkbox style, plus an optional shortcut hint.
struct ToggleRow: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    @Binding var value: Bool
    var shortcut: String? = nil

    var body: some View {
        Toggle(isOn: $value) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Typo.small)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 4)
                if let shortcut {
                    Text(shortcut)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, Metric.gutter)
        .frame(height: Metric.rowHeight)
    }
}

/// A real `Slider` with its value label, laid out by `LabeledContent`.
struct ParameterSlider: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.3f"
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            LabeledContent {
                Text(String(format: format, value))
                    .font(Typo.mono)
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
            } label: {
                Text(label)
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onChange?() }
            }
            .controlSize(.mini)
            .tint(theme.accent)
            .accessibilityLabel(label)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 4)
    }
}

/// A `Button` dressed for bars and panel headers.
///
/// This is a real `Button` with a `ButtonStyle` applied, not a reimplementation:
/// it inherits activation by keyboard, the pressed state, focus, and the
/// accessibility traits of a button, and adds only a `help` tooltip.
struct ToolbarButton: View {
    let systemImage: String
    var label: String? = nil
    var isActive: Bool = false
    var tone: Color? = nil
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let label {
                Label(label, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            } else {
                Label(label ?? "", systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.kinetic(active: isActive, tone: tone))
        .help(help ?? label ?? systemImage)
    }
}
