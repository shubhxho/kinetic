//
//  AxisGizmoView.swift
//  Kinetic Studio
//
//  Orientation gizmo. It reads the live camera angles out of the viewport and
//  projects the three world axes onto a flat disc, so the corner of the screen
//  always answers "which way is up, and which way am I looking from".
//
//  Kinetic is Z-up (the robotics convention), so the colour mapping is the robotics
//  one too: X red, Y green, Z blue, with Z drawn straight up whenever the camera is
//  level. Axes leaning away from the viewer are drawn first and dimmer; that
//  ordering plus the fade is the entire 3D illusion — without it the gizmo is an
//  ambiguous three-spoke star that reads the same from opposite sides.
//
//  Clicking a tip snaps the camera to the view that looks down that axis.
//

import KineticRender
import SwiftUI
import simd

// MARK: - Axes

private enum GizmoAxis: String, CaseIterable {
    case x, y, z

    var direction: SIMD3<Double> {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }

    var color: Color {
        switch self {
        case .x: return Color(red: 0.94, green: 0.27, blue: 0.34)
        case .y: return Color(red: 0.20, green: 0.80, blue: 0.45)
        case .z: return Color(red: 0.20, green: 0.55, blue: 1.00)
        }
    }

    var label: String { rawValue.uppercased() }

    /// The preset whose camera ends up *on* this axis looking back at the target.
    ///
    /// `ViewportCommands.setCamera` places the eye at azimuth/elevation around the
    /// target, so: `.side` is azimuth 0 → eye on +X; `.front` is azimuth -π/2 → eye
    /// on -Y looking along +Y; `.top` is elevation ≈ π/2 → eye on +Z.
    var preset: CameraPreset {
        switch self {
        case .x: return .side
        case .y: return .front
        case .z: return .top
        }
    }

    var snapDescription: String {
        switch self {
        case .x: return "Snap to the X axis (side view)"
        case .y: return "Snap to the Y axis (front view)"
        case .z: return "Snap to the Z axis (top view)"
        }
    }
}

/// One projected axis end: the positive tip carries a spoke and a letter, the
/// negative tip is a bare ring so the two ends of an axis never read alike.
private struct GizmoTip {
    let id: String
    let axis: GizmoAxis
    let isPositive: Bool
    let point: CGPoint
    /// Component along the camera's forward vector. Positive means the tip leans
    /// away from the viewer.
    let depth: Double
}

// MARK: - Gizmo

struct AxisGizmoView: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    /// Diameter of the disc. 78pt keeps the letters legible without the gizmo
    /// competing with the model for attention.
    var size: CGFloat = 78

    @State private var hoveredID: String?

    init(model: StudioModel, size: CGFloat = 78) {
        self.model = model
        self.size = size
    }

    // The camera lives inside the Metal view and publishes nothing when it orbits.
    // The gizmo still tracks it because `model.stats` is republished every rendered
    // frame, which re-evaluates this body — so reading the angles here is always a
    // fresh read, never a cached one.
    private var azimuth: Double { Double(model.commands.camera?.azimuth ?? -0.9) }
    private var elevation: Double { Double(model.commands.camera?.elevation ?? 0.42) }

    private var centre: CGPoint { CGPoint(x: size / 2, y: size / 2) }
    private var radius: CGFloat { size * 0.30 }

    var body: some View {
        // Everything the canvas needs is resolved out here, so the drawing closure
        // touches only plain values.
        let tips = projectedTips()
        let hovered = hoveredID
        let hairline = theme.border

        Canvas { context, _ in
            draw(tips: tips, hovered: hovered, hairline: hairline, into: &context)
        }
        .frame(width: size, height: size)
        // A rounded rectangle whose radius is half its side *is* a circle, so the
        // shared glass surface gives the disc without a second code path.
        .viewportGlass(cornerRadius: size / 2, interactive: true)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoveredID = nearestTip(to: location, in: tips, within: 13)?.id
            case .ended:
                hoveredID = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            snap(at: location, tips: tips)
        }
        .help(hoveredHelp(tips: tips))
        .accessibilityLabel(Text("Orientation gizmo"))
    }

    // MARK: Projection

    /// Camera basis for a Z-up world, derived from the same azimuth/elevation the
    /// orbit camera uses for its eye position.
    ///
    ///   eye offset  d = (cos a·cos e, sin a·cos e, sin e)
    ///   forward     f = -d                      (from the eye into the scene)
    ///   right       s = normalize(f × Z) = (-sin a, cos a, 0)
    ///   up          u = s × f = (-cos a·sin e, -sin a·sin e, cos e)
    ///
    /// `elevation` is clamped to ±1.52 rad by the camera, so cos e > 0 and the right
    /// vector never degenerates at the poles.
    private func projectedTips() -> [GizmoTip] {
        let a = azimuth, e = elevation
        let forward = SIMD3<Double>(-cos(a) * cos(e), -sin(a) * cos(e), -sin(e))
        let right = SIMD3<Double>(-sin(a), cos(a), 0)
        let up = SIMD3<Double>(-cos(a) * sin(e), -sin(a) * sin(e), cos(e))

        var tips: [GizmoTip] = []
        for axis in GizmoAxis.allCases {
            for sign in [1.0, -1.0] {
                let v = axis.direction * sign
                let x = simd_dot(v, right)
                // Canvas y grows downward while the camera's up vector points up the
                // screen, so the vertical component is negated exactly once, here.
                let y = -simd_dot(v, up)
                let point = CGPoint(x: centre.x + CGFloat(x) * radius,
                                    y: centre.y + CGFloat(y) * radius)
                tips.append(GizmoTip(id: "\(axis.rawValue)\(sign > 0 ? "+" : "-")",
                                     axis: axis, isPositive: sign > 0,
                                     point: point, depth: simd_dot(v, forward)))
            }
        }
        // Furthest first: later strokes paint over earlier ones, which is what makes
        // a near spoke visibly cross in front of a far one.
        return tips.sorted { $0.depth > $1.depth }
    }

    /// Depth in [-1, 1] mapped to opacity. A tip pointing straight at the viewer is
    /// solid; one pointing straight away keeps just enough presence to be clickable.
    private func opacity(for depth: Double) -> Double {
        let t = (depth + 1) / 2          // 0 = toward the viewer, 1 = away
        return 1.0 - 0.62 * t
    }

    // MARK: Drawing

    private func draw(tips: [GizmoTip], hovered: String?, hairline: Color,
                      into context: inout GraphicsContext) {
        // Hub: the neutral "reset to isometric" target, and a visual anchor for the
        // spokes so they do not appear to float.
        context.fill(Path(ellipseIn: CGRect(x: centre.x - 2.5, y: centre.y - 2.5,
                                            width: 5, height: 5)),
                     with: .color(hairline.opacity(0.9)))

        for tip in tips {
            let isHovered = tip.id == hovered
            let alpha = isHovered ? 1.0 : opacity(for: tip.depth)
            let color = tip.axis.color.opacity(alpha)
            let ballRadius: CGFloat = isHovered ? 7.5 : (tip.isPositive ? 6.5 : 5)

            if tip.isPositive {
                var spoke = Path()
                spoke.move(to: centre)
                spoke.addLine(to: tip.point)
                context.stroke(spoke, with: .color(color),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            let box = CGRect(x: tip.point.x - ballRadius, y: tip.point.y - ballRadius,
                             width: ballRadius * 2, height: ballRadius * 2)
            if tip.isPositive {
                context.fill(Path(ellipseIn: box), with: .color(color))
                context.draw(Text(tip.axis.label)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white),
                             at: tip.point, anchor: .center)
            } else {
                // Hollow ring: the negative end reads as "the far side of this axis"
                // rather than as a fourth, fifth and sixth axis.
                context.stroke(Path(ellipseIn: box), with: .color(color),
                               lineWidth: 1.5)
                if isHovered {
                    context.draw(Text("-" + tip.axis.label)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(color),
                                 at: CGPoint(x: tip.point.x, y: tip.point.y - 11),
                                 anchor: .center)
                }
            }
        }
    }

    // MARK: Interaction

    private func nearestTip(to location: CGPoint, in tips: [GizmoTip],
                            within threshold: CGFloat) -> GizmoTip? {
        var best: GizmoTip?
        var bestDistance = threshold
        // Iterate in reverse so the nearest-to-camera tip wins an overlap, matching
        // what the user sees on top.
        for tip in tips.reversed() {
            let distance = hypot(tip.point.x - location.x, tip.point.y - location.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = tip
            }
        }
        return best
    }

    private func snap(at location: CGPoint, tips: [GizmoTip]) {
        if let tip = nearestTip(to: location, in: tips, within: 15) {
            model.commands.setCamera(tip.axis.preset)
            return
        }
        // A click on the hub means "give me the neutral three-quarter view again".
        if hypot(location.x - centre.x, location.y - centre.y) <= radius * 0.5 {
            model.commands.setCamera(.isometric)
        }
    }

    private func hoveredHelp(tips: [GizmoTip]) -> String {
        guard let id = hoveredID, let tip = tips.first(where: { $0.id == id }) else {
            return "Orientation gizmo — click an axis to snap the camera, "
                + "the centre for isometric"
        }
        return tip.axis.snapDescription
    }
}
