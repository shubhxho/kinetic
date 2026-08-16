//
//  ViewportHUD.swift
//  Kinetic Studio
//
//  The instrument layer that floats above the Metal viewport: a telemetry cluster,
//  a strip of view toggles, the "you are reviewing history" banner, and the
//  selection callout.
//
//  Two rules govern everything in this file.
//
//  1. The viewport underneath owns the mouse. Orbit, pan, zoom and picking all live
//     in KineticView, so any overlay that is purely a readout switches hit testing
//     off — otherwise a 560pt wide stat cluster would eat the drag that was meant to
//     orbit the camera. Only real controls (buttons, toggles) opt back in.
//  2. Glass is conditional. On macOS 26 the chrome is Liquid Glass so it refracts the
//     scene moving behind it; below that the fallback is the flat Studio chrome from
//     Theme.swift over `.ultraThinMaterial` — a deliberate second design, not a
//     degraded first one.
//

import Kinetic
import KineticRender
import SwiftUI

// MARK: - Glass primitives shared by the overlay layer

/// Liquid Glass surface for viewport chrome.
///
/// `interactive` is only worth requesting on hit targets: interactive glass tracks
/// the pointer and reacts to pressure, which is wasted on a readout that has hit
/// testing disabled.
@MainActor
struct ViewportGlass: ViewModifier {
    @Environment(\.studioTheme) private var theme

    var cornerRadius: CGFloat = Metric.radiusLarge
    var tint: Color?
    var interactive: Bool = false

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value = Glass.regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
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
            // The material alone is too transparent over a bright viewport, so the
            // fallback stacks a faint surface fill under it and keeps a hairline —
            // without the border the chrome dissolves into a light scene.
            content
                .background(shape.fill(tint?.opacity(0.18) ?? Color.clear))
                .background(shape.fill(theme.surface.opacity(theme.isDark ? 0.55 : 0.35)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(theme.border.opacity(0.85), lineWidth: 1))
        }
    }
}

extension View {
    /// Sugar for `ViewportGlass`; reads better inline than `.modifier(...)`.
    func viewportGlass(cornerRadius: CGFloat = Metric.radiusLarge,
                       tint: Color? = nil,
                       interactive: Bool = false) -> some View {
        modifier(ViewportGlass(cornerRadius: cornerRadius, tint: tint,
                               interactive: interactive))
    }
}

/// Groups sibling glass shapes so they fuse as they approach each other. Outside a
/// container each shape refracts on its own and a cluster reads as loose lozenges.
/// Below macOS 26 it is a pass-through: the layout is identical, only the merging
/// is missing.
@MainActor
struct ViewportGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - HUD

/// The floating instrument cluster: simulated time, realtime factor, step cost,
/// contact count, frame rate and instance count, plus an expandable second row of
/// render-side numbers.
struct ViewportHUD: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    /// Extra detail is opt-in: the six primary numbers are what you watch while
    /// tuning a model; draw cost and solver counts are what you look at when
    /// something is already wrong.
    @State private var isExpanded = false

    init(model: StudioModel) {
        self.model = model
    }

    /// Realtime factor is the one number with a pass/fail reading, so it is the one
    /// number that carries colour. Everything else stays neutral to keep the cluster
    /// from turning into a traffic light.
    private var realtimeTone: Color {
        model.stats.realtimeFactor >= 0.95 ? Palette.success : Palette.warning
    }

    var body: some View {
        ViewportGlassGroup {
            HStack(alignment: .center, spacing: 8) {
                readouts
                    // The readout is scenery. Anything the pointer does here belongs
                    // to the camera underneath it.
                    .allowsHitTesting(false)

                disclosure
            }
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                HUDReadout(label: "time", value: format(model.displayTime, 3), unit: "s")
                HUDReadout(label: "realtime", value: format(model.stats.realtimeFactor, 2),
                           unit: "×", tone: realtimeTone)
                HUDReadout(label: "step", value: format(model.stats.stepMilliseconds, 2),
                           unit: "ms")
                HUDReadout(label: "contacts", value: "\(model.stats.contactCount)")
                HUDReadout(label: "fps", value: format(model.stats.frameRate, 0))
                HUDReadout(label: "instances", value: "\(model.stats.instanceCount)")
            }

            if isExpanded {
                Rectangle()
                    .fill(theme.border.opacity(0.6))
                    .frame(height: 1)
                HStack(spacing: 14) {
                    HUDReadout(label: "draw", value: format(model.stats.drawMilliseconds, 2),
                               unit: "ms")
                    HUDReadout(label: "constraints", value: "\(model.stats.constraintCount)")
                    HUDReadout(label: "steps/frame", value: "\(model.stats.stepsPerFrame)")
                    HUDReadout(label: "energy",
                               value: format(model.stats.kineticEnergy
                                             + model.stats.potentialEnergy, 2),
                               unit: "J")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .viewportGlass(cornerRadius: Metric.radiusLarge)
    }

    private var disclosure: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .viewportGlass(cornerRadius: Metric.radius, interactive: true)
        .help(isExpanded ? "Hide render detail" : "Show render detail")
    }

    private func format(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value.isFinite ? value : 0)
    }
}

/// One column of the cluster: caption above, monospaced value below. Values are
/// monospaced so the cluster does not reflow every frame as digits change width.
private struct HUDReadout: View {
    @Environment(\.studioTheme) private var theme

    let label: String
    let value: String
    var unit: String?
    var tone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(Typo.sectionLabel)
                .kerning(0.5)
                .foregroundStyle(theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typo.monoLarge)
                    .foregroundStyle(tone ?? theme.text)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
        }
        .fixedSize()
    }
}

// MARK: - View toggles

/// One entry in the floating toggle strip. The binding is handed in rather than a
/// key path so the strip never needs to know it is talking to `RenderSettings`.
private struct ViewToggleSpec: Identifiable {
    let id: String
    let systemImage: String
    let title: String
    /// The single-key shortcut KineticView already listens for, if there is one.
    let shortcut: String?
    let binding: Binding<Bool>

    /// Tooltip text. The shortcut lives in the tooltip because the strip is
    /// icon-only — there is nowhere else to teach it.
    var help: String {
        guard let shortcut else { return title }
        return "\(title)  ·  \(shortcut)"
    }
}

/// Floating vertical strip of render toggles. Icons only: the strip sits over the
/// scene and labels would cover more of the model than they explain.
struct ViewportToolbar: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    init(model: StudioModel) {
        self.model = model
    }

    private var toggles: [ViewToggleSpec] {
        [
            ViewToggleSpec(id: "grid", systemImage: "grid", title: "Ground grid",
                           shortcut: "G", binding: $model.settings.showGrid),
            ViewToggleSpec(id: "contacts", systemImage: "smallcircle.filled.circle",
                           title: "Contact points", shortcut: "C",
                           binding: $model.settings.showContacts),
            ViewToggleSpec(id: "forces", systemImage: "arrow.up.right",
                           title: "Contact forces", shortcut: nil,
                           binding: $model.settings.showContactForces),
            ViewToggleSpec(id: "collision", systemImage: "square.on.square.dashed",
                           title: "Collision shapes", shortcut: "K",
                           binding: $model.settings.showCollisionGeometry),
            ViewToggleSpec(id: "frames", systemImage: "move.3d", title: "Link frames",
                           shortcut: nil, binding: $model.settings.showLinkFrames),
            ViewToggleSpec(id: "com", systemImage: "scalemass", title: "Centre of mass",
                           shortcut: nil, binding: $model.settings.showCenterOfMass),
            ViewToggleSpec(id: "trails", systemImage: "scribble", title: "Motion trails",
                           shortcut: "T", binding: $model.settings.showTrails),
            ViewToggleSpec(id: "wireframe", systemImage: "grid.circle", title: "Wireframe",
                           shortcut: "W", binding: $model.settings.wireframe),
        ]
    }

    var body: some View {
        ViewportGlassGroup {
            VStack(spacing: 2) {
                ForEach(toggles) { spec in
                    ViewToggleButton(spec: spec)
                    if spec.id == "forces" || spec.id == "com" {
                        Rectangle()
                            .fill(theme.border.opacity(0.5))
                            .frame(width: 16, height: 1)
                            .padding(.vertical, 2)
                    }
                }
            }
            .padding(4)
            .viewportGlass(cornerRadius: Metric.radiusLarge + 2, interactive: true)
        }
    }
}

private struct ViewToggleButton: View {
    @Environment(\.studioTheme) private var theme
    let spec: ViewToggleSpec

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
    }

    var body: some View {
        let isOn = spec.binding.wrappedValue
        Button {
            spec.binding.wrappedValue.toggle()
        } label: {
            Image(systemName: spec.systemImage)
                .font(.system(size: 12, weight: .semibold))
                // Active state tints rather than fills: a solid fill inside glass
                // punches an opaque hole in the material.
                .foregroundStyle(isOn ? theme.accent : theme.secondary)
                .frame(width: 28, height: 26)
                .background(shape.fill(isOn ? theme.accent.opacity(0.18)
                                            : (hovering ? theme.border.opacity(0.45)
                                                        : Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(spec.help)
        .accessibilityLabel(Text(spec.title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Scrubbing banner

/// Shown while the playhead is inside the recorded window. The affordance matters:
/// without it a paused, rewound simulation looks like a hung one.
struct ScrubbingBanner: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    init(model: StudioModel) {
        self.model = model
    }

    var body: some View {
        if model.isScrubbing {
            ViewportGlassGroup {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.warning)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reviewing history — the simulation is paused")
                            .font(Typo.small.weight(.medium))
                            .foregroundStyle(theme.text)
                        Text(String(format: "playhead at %.3f s", model.displayTime))
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }

                    Button {
                        model.resumeLive()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("Jump to live")
                                .font(Typo.small.weight(.semibold))
                        }
                        .foregroundStyle(Palette.warning)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .viewportGlass(cornerRadius: Metric.radius,
                                   tint: Palette.warning, interactive: true)
                    .help("Return to the newest state and resume stepping")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .viewportGlass(cornerRadius: Metric.radiusLarge, tint: Palette.warning)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Selection callout

/// Small card describing whatever the last viewport click hit. It duplicates a
/// little of the inspector on purpose: the point of a callout is that your eyes
/// never leave the model.
struct SelectionCallout: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    init(model: StudioModel) {
        self.model = model
    }

    var body: some View {
        if let index = model.selectedGeom, model.world.geomInfo.indices.contains(index) {
            card(for: index)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        }
    }

    private func card(for index: Int) -> some View {
        let geom = model.world.geomInfo[index]
        let poses = model.world.geomPoses()
        let position = index < poses.count ? poses[index].position : Vec3.zero
        let mass = model.world.mass(articulation: geom.articulation, link: geom.link)

        return ViewportGlassGroup {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text(geom.name.isEmpty ? "geom \(index)" : geom.name)
                        .font(Typo.title)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Button {
                        model.selectedGeom = nil
                        model.settings.selection = []
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.tertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the selection")
                }
                .padding(.bottom, 6)

                calloutRow("link",
                           model.world.name(articulation: geom.articulation, link: geom.link))
                calloutRow("shape", describe(geom.shape))
                calloutRow("mass", String(format: "%.4f kg", mass))
                calloutRow("position", String(format: "%.3f  %.3f  %.3f",
                                              position.x, position.y, position.z))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 244, alignment: .leading)
            .viewportGlass(cornerRadius: Metric.radiusLarge, interactive: true)
        }
    }

    private func calloutRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Typo.mono)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 18)
    }

    /// `Kinetic.Shape` is spelled out because SwiftUI has a `Shape` of its own and
    /// this file imports both modules.
    private func describe(_ shape: Kinetic.Shape) -> String {
        switch shape {
        case .sphere(let r): return String(format: "sphere r=%.3f", r)
        case .box(let h): return String(format: "box %.2f×%.2f×%.2f", h.x * 2, h.y * 2, h.z * 2)
        case .capsule(let r, let l): return String(format: "capsule r=%.3f l=%.3f", r, l * 2)
        case .cylinder(let r, let l): return String(format: "cylinder r=%.3f l=%.3f", r, l * 2)
        case .plane: return "plane"
        case .convexHull(let mesh, _): return "hull #\(mesh)"
        }
    }
}
