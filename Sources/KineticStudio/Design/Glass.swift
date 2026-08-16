//
//  Glass.swift
//  Kinetic Studio
//
//  The Liquid Glass chrome. Every component here has two appearances: real glass on
//  macOS 26, and a material-plus-hairline stand-in below it. The stand-in is not a
//  degraded glass — it is the flat Studio chrome from Theme.swift with the same
//  geometry, so an app running on macOS 14 looks intentional rather than unfinished.
//
//  Anything that should visually fuse (toolbar buttons, a segmented track, a row of
//  stats) is wrapped in a GlassEffectContainer. Outside a container each shape
//  refracts on its own and the chrome reads as scattered lozenges.
//

import SwiftUI

// Shared across every segmented control instance; the namespaces are per-instance,
// so a constant id is enough to pair "the pill" with "the pill".
private let glassSelectionID = "glass.selection.pill"

// MARK: - Surface

/// Applies glass (or its stand-in) with a tint and corner radius.
@MainActor
struct GlassSurface: ViewModifier {
    @Environment(\.studioTheme) private var theme

    var tint: Color?
    var cornerRadius: CGFloat = StudioTokens.Radius.large
    /// Interactive glass reacts to pointer pressure; only worth it on hit targets.
    var interactive: Bool = false

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value = Glass.regular
        if let tint {
            value = value.tint(tint)
        }
        if interactive {
            value = value.interactive()
        }
        return value
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(tint?.opacity(GlassMetric.fallbackTint) ?? Color.clear))
                .background(shape.fill(theme.glassFallbackFill))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(theme.glassStroke, lineWidth: GlassMetric.hairline))
        }
    }
}

extension View {
    /// Sugar for `GlassSurface`; reads better inline than `.modifier(...)`.
    func glassSurface(tint: Color? = nil,
                      cornerRadius: CGFloat = StudioTokens.Radius.large,
                      interactive: Bool = false) -> some View {
        modifier(GlassSurface(tint: tint, cornerRadius: cornerRadius, interactive: interactive))
    }
}

// MARK: - Cluster

/// Groups sibling glass views so they merge as they approach each other.
/// Below macOS 26 it is a plain `HStack` — the layout is identical, only the
/// fusing is missing.
@MainActor
struct GlassCluster<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = StudioTokens.Space.md, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: GlassMetric.mergeSpacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

// MARK: - Bar

/// Horizontal toolbar chrome: one pane of glass with a hairline bottom border.
/// The border survives on macOS 26 because glass alone does not separate the bar
/// from a bright viewport underneath it.
@MainActor
struct GlassBar<Content: View>: View {
    @Environment(\.studioTheme) private var theme

    private let height: CGFloat
    private let spacing: CGFloat
    private let content: Content

    init(height: CGFloat = GlassMetric.barHeight,
         spacing: CGFloat = StudioTokens.Space.md,
         @ViewBuilder content: () -> Content) {
        self.height = height
        self.spacing = spacing
        self.content = content()
    }

    private var row: some View {
        HStack(spacing: spacing) { content }
            .padding(.horizontal, StudioTokens.Space.gutter)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: GlassMetric.mergeSpacing) { row }
                    .glassEffect(.regular, in: Rectangle())
            } else {
                row
                    .background(theme.glassFallbackFill)
                    .background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: GlassMetric.hairline)
        }
    }
}

// MARK: - Panel

/// Titled panel chrome with an optional trailing accessory (a menu, a count, a
/// close button). Content is left un-inset so panels can host full-bleed lists.
@MainActor
struct GlassPanel<Content: View, Accessory: View>: View {
    @Environment(\.studioTheme) private var theme

    private let title: String
    private let cornerRadius: CGFloat
    private let content: Content
    private let accessory: Accessory

    init(_ title: String,
         cornerRadius: CGFloat = StudioTokens.Radius.card,
         @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.cornerRadius = cornerRadius
        self.content = content()
        self.accessory = accessory()
    }

    private var header: some View {
        HStack(spacing: StudioTokens.Space.sm) {
            Text(title.uppercased())
                .font(StudioTokens.Typography.sectionLabel)
                .kerning(0.6)
                .foregroundStyle(theme.tertiary)
            Spacer(minLength: StudioTokens.Space.md)
            accessory
        }
        .padding(.horizontal, StudioTokens.Space.gutter)
        .padding(.top, 10)
        .padding(.bottom, StudioTokens.Space.sm)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.borderSubtle)
                .frame(height: GlassMetric.hairline)
            content
        }
        .glassSurface(cornerRadius: cornerRadius)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension GlassPanel where Accessory == EmptyView {
    init(_ title: String,
         cornerRadius: CGFloat = StudioTokens.Radius.card,
         @ViewBuilder content: () -> Content) {
        self.init(title, cornerRadius: cornerRadius, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Button

/// Label plus optional glyph. Active buttons tint rather than fill, because a solid
/// fill inside a glass bar punches a hole in the material.
@MainActor
struct GlassButton: View {
    @Environment(\.studioTheme) private var theme

    private let title: String?
    private let systemImage: String?
    private let isActive: Bool
    private let tone: Color?
    private let action: () -> Void

    @State private var hovering = false

    init(_ title: String? = nil,
         systemImage: String? = nil,
         isActive: Bool = false,
         tone: Color? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
        self.tone = tone
        self.action = action
    }

    private var effectiveTone: Color { tone ?? StudioTokens.accent }

    private var label: some View {
        HStack(spacing: StudioTokens.Space.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            if let title {
                Text(title).font(StudioTokens.Typography.small.weight(.medium))
            }
        }
        .foregroundStyle(isActive ? effectiveTone : theme.text)
        .padding(.horizontal, title == nil ? StudioTokens.Space.md : 10)
        .frame(height: GlassMetric.controlHeight)
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .tint(isActive ? effectiveTone : Color.clear)
        } else {
            Button(action: action) {
                label
                    .background(fallbackFill)
                    .overlay(fallbackBorder)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(GlassMotion.hover, value: hovering)
        }
    }

    private var fallbackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StudioTokens.Radius.medium, style: .continuous)
    }

    private var fallbackFill: some View {
        fallbackShape.fill(
            isActive ? effectiveTone.opacity(GlassMetric.fallbackTint)
                     : (hovering ? theme.glassHover : Color.clear))
    }

    private var fallbackBorder: some View {
        fallbackShape.strokeBorder(
            isActive ? effectiveTone.opacity(0.6) : theme.border,
            lineWidth: GlassMetric.hairline)
    }
}

// MARK: - Segmented control

/// Segmented picker whose selection is a single glass pill that travels between
/// segments. `matchedGeometryEffect` moves the frame; `glassEffectID` lets the
/// material itself stretch and re-form across the gap instead of cross-fading.
@MainActor
struct GlassSegmentedControl<T: Hashable>: View {
    @Environment(\.studioTheme) private var theme

    private let items: [T]
    @Binding private var selection: T
    private let title: (T) -> String
    private let icon: (T) -> String?

    @Namespace private var geometry
    @Namespace private var glassNamespace

    init(_ items: [T],
         selection: Binding<T>,
         title: @escaping (T) -> String,
         icon: @escaping (T) -> String? = { _ in nil }) {
        self.items = items
        self._selection = selection
        self.title = title
        self.icon = icon
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: GlassMetric.mergeSpacing) { track }
        } else {
            track
        }
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StudioTokens.Radius.medium + 2, style: .continuous)
    }

    private var track: some View {
        HStack(spacing: StudioTokens.Space.hair) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(StudioTokens.Space.hair)
        // The track stays flat even on macOS 26: glass inside glass double-refracts
        // and the pill loses its edge against its own container.
        .background(trackShape.fill(theme.surface.opacity(0.7)))
        .overlay(trackShape.strokeBorder(theme.border, lineWidth: GlassMetric.hairline))
    }

    private func segment(_ item: T) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(GlassMotion.selection) { selection = item }
        } label: {
            HStack(spacing: StudioTokens.Space.xs) {
                if let name = icon(item) {
                    Image(systemName: name).font(.system(size: 10, weight: .semibold))
                }
                Text(title(item))
                    .font(StudioTokens.Typography.small.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? theme.text : theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: GlassMetric.controlHeight)
            .background { if isSelected { pill } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StudioTokens.Radius.medium, style: .continuous)
    }

    @ViewBuilder
    private var pill: some View {
        if #available(macOS 26.0, *) {
            pillShape
                .fill(Color.clear)
                .glassEffect(
                    .regular.tint(theme.accent.opacity(GlassMetric.activeTint)).interactive(),
                    in: pillShape)
                .glassEffectID(glassSelectionID, in: glassNamespace)
                .matchedGeometryEffect(id: glassSelectionID, in: geometry)
        } else {
            pillShape
                .fill(theme.accent.opacity(GlassMetric.fallbackTint))
                .overlay(pillShape.strokeBorder(theme.accent.opacity(0.45),
                                                lineWidth: GlassMetric.hairline))
                .matchedGeometryEffect(id: glassSelectionID, in: geometry)
        }
    }
}

// MARK: - Chip

/// Compact status pill. Sized for a table cell, so it never grows past `chipHeight`.
@MainActor
struct GlassChip: View {
    @Environment(\.studioTheme) private var theme

    private let text: String
    private let tone: GlassTone
    private let systemImage: String?

    init(_ text: String, tone: GlassTone = .neutral, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        let color = tone.color(in: theme)
        HStack(spacing: StudioTokens.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(StudioTokens.Typography.monoSmall)
        }
        .foregroundStyle(color)
        .padding(.horizontal, StudioTokens.Space.sm)
        .frame(height: GlassMetric.chipHeight)
        .glassSurface(tint: color.opacity(GlassMetric.activeTint),
                      cornerRadius: StudioTokens.Radius.small)
    }
}

// MARK: - Search field

/// Search input with a leading glyph and a trailing shortcut hint. The hint is a
/// keycap rather than plain text so it does not read as an editable value.
@MainActor
struct GlassSearchField: View {
    @Environment(\.studioTheme) private var theme

    @Binding private var text: String
    private let placeholder: String
    private let shortcut: String?

    @FocusState private var focused: Bool

    init(text: Binding<String>, placeholder: String = "Search", shortcut: String? = "⌘K") {
        self._text = text
        self.placeholder = placeholder
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: StudioTokens.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(StudioTokens.Typography.body)
                .foregroundStyle(theme.text)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiary)
                }
                .buttonStyle(.plain)
            } else if let shortcut {
                Text(shortcut)
                    .font(StudioTokens.Typography.keycap)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, StudioTokens.Space.xs)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: StudioTokens.Radius.small - 2,
                                         style: .continuous)
                            .fill(theme.glassHover))
            }
        }
        .padding(.horizontal, StudioTokens.Space.md)
        .frame(height: GlassMetric.searchHeight)
        .glassSurface(tint: focused ? theme.accent.opacity(0.18) : nil,
                      cornerRadius: StudioTokens.Radius.medium,
                      interactive: true)
        .animation(GlassMotion.hover, value: focused)
        .onTapGesture { focused = true }
    }
}

// MARK: - Card

/// Tappable card. Hover lifts it rather than tinting it — on glass a tint change is
/// nearly invisible over a busy viewport, but a shadow change is not.
@MainActor
struct GlassCard: View {
    @Environment(\.studioTheme) private var theme

    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tone: GlassTone
    private let action: () -> Void

    @State private var hovering = false

    init(_ title: String,
         subtitle: String? = nil,
         systemImage: String? = nil,
         tone: GlassTone = .neutral,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.action = action
    }

    var body: some View {
        let color = tone.color(in: theme)
        Button(action: action) {
            HStack(spacing: StudioTokens.Space.gutter) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(color)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: StudioTokens.Space.hair) {
                    Text(title)
                        .font(StudioTokens.Typography.title)
                        .foregroundStyle(theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(StudioTokens.Typography.small)
                            .foregroundStyle(theme.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: StudioTokens.Space.md)
            }
            .padding(StudioTokens.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(tint: hovering ? color.opacity(0.12) : nil,
                          cornerRadius: StudioTokens.Radius.card,
                          interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: StudioTokens.Radius.card,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: theme.glassShadow,
                radius: hovering ? GlassMetric.hoverShadow : GlassMetric.restShadow,
                y: hovering ? GlassMetric.hoverLift : 1)
        .offset(y: hovering ? -GlassMetric.hoverLift : 0)
        .onHover { hovering = $0 }
        .animation(GlassMotion.hover, value: hovering)
    }
}

// MARK: - Stat

/// Metric tile: uppercase label over a large monospaced value. Value and unit sit on
/// a shared baseline so a column of tiles aligns even when units differ in length.
@MainActor
struct GlassStat: View {
    @Environment(\.studioTheme) private var theme

    private let label: String
    private let value: String
    private let unit: String?
    private let tone: GlassTone

    init(_ label: String, value: String, unit: String? = nil, tone: GlassTone = .neutral) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tone = tone
    }

    var body: some View {
        let color = tone.color(in: theme)
        VStack(alignment: .leading, spacing: StudioTokens.Space.hair) {
            Text(label.uppercased())
                .font(StudioTokens.Typography.sectionLabel)
                .kerning(0.5)
                .foregroundStyle(theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: StudioTokens.Space.hair) {
                Text(value)
                    .font(StudioTokens.Typography.monoDisplay)
                    .foregroundStyle(tone == .neutral ? theme.text : color)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(StudioTokens.Typography.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudioTokens.Space.gutter)
        .padding(.vertical, 10)
        .glassSurface(tint: tone == .neutral ? nil : color.opacity(0.14),
                      cornerRadius: StudioTokens.Radius.large)
    }
}

/// A row of stats that fuse into one continuous readout — the case the container
/// exists for. Falls back to an evenly spaced `HStack`.
@MainActor
struct GlassStatRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: GlassMetric.mergeSpacing) {
                HStack(spacing: StudioTokens.Space.md) { content }
            }
        } else {
            HStack(spacing: StudioTokens.Space.md) { content }
        }
    }
}
