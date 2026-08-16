//
//  Theme.swift
//  Kinetic Studio
//
//  Design tokens. The system is deliberately narrow: one accent, a four-step
//  neutral ramp, one radius scale, one type scale. Numbers are always monospaced
//  so columns of telemetry stay aligned as values change.
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

// MARK: - Shared building blocks

/// Small uppercase section header used at the top of every panel.
struct SectionLabel: View {
    @Environment(\.studioTheme) private var theme
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(Typo.sectionLabel)
                .kerning(0.6)
                .foregroundStyle(theme.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// A key/value row: label left, monospaced value right.
struct FieldRow: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    let value: String
    var accent: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Typo.mono)
                .foregroundStyle(accent ?? theme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: Metric.rowHeight)
    }
}

struct StatTile: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    let value: String
    var unit: String? = nil
    var tone: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Typo.sectionLabel)
                .kerning(0.5)
                .foregroundStyle(theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typo.monoLarge)
                    .foregroundStyle(tone ?? theme.text)
                if let unit {
                    Text(unit)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radius)
                .stroke(theme.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
    }
}

struct ToolbarButton: View {
    @Environment(\.studioTheme) private var theme
    let systemImage: String
    var label: String? = nil
    var isActive: Bool = false
    var tone: Color? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                if let label {
                    Text(label)
                        .font(Typo.small.weight(.medium))
                }
            }
            .foregroundStyle(isActive ? Color.white : (tone ?? theme.text))
            .padding(.horizontal, label == nil ? 8 : 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Metric.radius)
                    .fill(isActive ? theme.accent
                                   : (hovering ? theme.border.opacity(0.55) : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radius)
                    .stroke(isActive ? Color.clear : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Chip: View {
    @Environment(\.studioTheme) private var theme
    let text: String
    var tone: Color? = nil

    var body: some View {
        Text(text)
            .font(Typo.monoSmall)
            .foregroundStyle(tone ?? theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tone ?? theme.secondary).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct ToggleRow: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    @Binding var value: Bool
    var shortcut: String? = nil

    var body: some View {
        Button {
            value.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(value ? theme.accent : Color.clear)
                    .frame(width: 13, height: 13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(value ? theme.accent : theme.border, lineWidth: 1))
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(value ? 1 : 0))
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
            .padding(.horizontal, Metric.gutter)
            .frame(height: Metric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact labelled slider with a monospaced readout.
struct ParameterSlider: View {
    @Environment(\.studioTheme) private var theme
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.3f"
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
            }
            Slider(value: $value, in: range) { _ in onChange?() }
                .controlSize(.mini)
                .tint(theme.accent)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 4)
    }
}

struct PanelDivider: View {
    @Environment(\.studioTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
    }
}

struct VerticalDivider: View {
    @Environment(\.studioTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1)
    }
}
