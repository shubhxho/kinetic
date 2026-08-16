//
//  Tokens.swift
//  Kinetic Studio
//
//  The glass layer's half of the design system. Theme.swift owns the hues and the
//  flat-chrome metrics; this file re-exports them under one namespace and adds only
//  what glass needs (merge spacing, stroke opacities, motion curves). Re-exporting
//  rather than re-declaring keeps a single source of truth — a hue changed in
//  Palette moves both the flat and the glass chrome in the same commit.
//

import SwiftUI

// MARK: - Namespace

/// The full token surface for Studio, flat and glass alike.
enum StudioTokens {

    // Accents. Aliases, not copies: Palette is the definition.
    static let accent = Palette.accent    // #0070F3
    static let success = Palette.success  // #0CCE6B
    static let warning = Palette.warning  // #F5A623
    static let danger = Palette.danger    // #FF4D4F

    /// Neutral ramp for dark appearance, darkest to lightest.
    enum NeutralDark {
        static let base = Palette.black
        static let surface = Palette.surface
        static let elevated = Palette.surfaceElevated
        static let border = Palette.border
        static let borderSubtle = Palette.borderSubtle
        static let text = Palette.text
        static let textSecondary = Palette.textSecondary
        static let textTertiary = Palette.textTertiary
    }

    /// Neutral ramp for light appearance, lightest to darkest.
    enum NeutralLight {
        static let base = Palette.lightBackground
        static let surface = Palette.lightSurface
        static let elevated = Color.white
        static let border = Palette.lightBorder
        static let borderSubtle = Color(white: 0.95)
        static let text = Palette.lightText
        static let textSecondary = Palette.lightTextSecondary
        static let textTertiary = Color(white: 0.6)
    }

    /// Corner radii. `pill` is deliberately huge so it clamps to a capsule at any height,
    /// which is what Liquid Glass lensing expects on controls.
    enum Radius {
        static let small = Metric.radius            // 6
        static let medium: CGFloat = 8
        static let large = Metric.radiusLarge       // 10
        static let card: CGFloat = 14
        static let pill: CGFloat = 999
    }

    /// Spacing scale. `gutter` matches the flat chrome so glass panels line up with
    /// the inspector rows they sit beside.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let gutter = Metric.gutter           // 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Type scale. The six flat steps are aliases of `Typo`; the display steps below
    /// are new because glass tiles read at a larger size than inspector rows.
    enum Typography {
        static let sectionLabel = Typo.sectionLabel
        static let title = Typo.title
        static let body = Typo.body
        static let small = Typo.small
        static let mono = Typo.mono
        static let monoSmall = Typo.monoSmall

        /// Headline numerals for stat tiles. Monospaced so a value ticking from
        /// 9 to 10 does not shove the unit sideways.
        static let monoDisplay = Font.system(size: 22, weight: .semibold, design: .monospaced)
        static let monoMedium = Font.system(size: 15, weight: .semibold, design: .monospaced)

        /// Keyboard hints — small, monospaced, and never the focus of a glyph run.
        static let keycap = Font.system(size: 10, weight: .medium, design: .monospaced)
    }
}

// MARK: - Glass metrics

/// Dimensions that only exist because of glass: lensing needs more breathing room
/// than a flat border does, and the container needs to know how close is "merge".
enum GlassMetric {
    /// Distance under which sibling glass shapes fuse into one blob. Larger than the
    /// visual gap between controls, so a toolbar reads as a single pane of glass.
    static let mergeSpacing: CGFloat = 18

    static let controlHeight: CGFloat = 26
    static let barHeight = Metric.toolbarHeight   // 44
    static let chipHeight: CGFloat = 20
    static let searchHeight: CGFloat = 28

    static let hairline: CGFloat = 1

    /// Opacities for the pre-26 fallback. `.ultraThinMaterial` has no lensing or
    /// specular edge, so the tint has to carry the state read on its own.
    static let fallbackTint: Double = 0.16
    static let fallbackStroke: Double = 0.9
    static let fallbackHighlight: Double = 0.06

    /// Tint strength for a glass surface that is carrying state (selected, active).
    static let activeTint: Double = 0.30

    static let restShadow: CGFloat = 4
    static let hoverShadow: CGFloat = 14
    static let hoverLift: CGFloat = 2
}

// MARK: - Motion

/// One spring for anything that morphs between two glass shapes, one for hover.
/// Sharing them is what makes independent components look like one material.
enum GlassMotion {
    static let selection = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let hover = Animation.easeOut(duration: 0.14)
}

// MARK: - Semantic tone

/// The status vocabulary chips and stats speak in. Callers pass intent, not a hue,
/// so a future change to what "warning" means lands in exactly one place.
enum GlassTone {
    case neutral
    case accent
    case success
    case warning
    case danger

    func color(in theme: StudioTheme) -> Color {
        switch self {
        case .neutral: return theme.secondary
        case .accent: return StudioTokens.accent
        case .success: return StudioTokens.success
        case .warning: return StudioTokens.warning
        case .danger: return StudioTokens.danger
        }
    }
}

// MARK: - Theme extensions

/// Glass-specific colours hang off the existing `StudioTheme` (and therefore the
/// existing `studioTheme` environment key) rather than a second theme object —
/// two themes in the environment is two ways for the app to disagree with itself.
extension StudioTheme {
    /// Edge highlight that stands in for the specular rim glass draws for free.
    var glassStroke: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    /// Slightly stronger edge for surfaces that float above content (cards, popovers).
    var glassStrokeStrong: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    /// Fill placed behind `.ultraThinMaterial` on macOS 14 so the material has
    /// something to thin — over a bright 3D viewport it otherwise blows out.
    var glassFallbackFill: Color {
        isDark ? Color.black.opacity(0.34) : Color.white.opacity(0.52)
    }

    /// Drop shadow under floating glass. Light mode uses a softer, cooler shadow
    /// because a black shadow on white reads as dirt.
    var glassShadow: Color {
        isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.14)
    }

    /// Hover wash for controls that are not themselves glass.
    var glassHover: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
}
