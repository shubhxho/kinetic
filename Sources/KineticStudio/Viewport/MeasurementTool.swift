//
//  MeasurementTool.swift
//  Kinetic Studio
//
//  Click two points on the model to measure the straight-line distance between
//  them. The tool is a thin SwiftUI layer over the same picking maths the viewport
//  uses: unproject the click through the camera, raycast the world, keep the hit.
//
//  COORDINATE SPACES — the one thing this file has to get exactly right.
//
//  * `KineticView` is an `MTKView`, and AppKit views are not flipped by default:
//    their origin is bottom-left with +y pointing UP. That is why the viewport's own
//    `select(at:)` can write `ndc.y = y / height * 2 - 1` with no flip.
//  * SwiftUI hands gesture locations in a top-left origin space with +y pointing
//    DOWN.
//  * Normalised device coordinates are +y UP in both Metal and OpenGL conventions.
//
//  So the x mapping is copied from the viewport verbatim, and the y mapping picks up
//  exactly one negation:
//
//      ndcX =      x / width  * 2 - 1
//      ndcY = 1 -  y / height * 2            (=  -( y / height * 2 - 1 ))
//
//  Projecting back the other way (world → screen, for drawing the markers) applies
//  the same flip in reverse. Getting this wrong is not a subtle bug — the ray
//  reflects about the horizon and you pick the geometry mirrored above or below the
//  thing you clicked.
//
//  Depth uses Metal's [0, 1] clip range: z = 0 is the near plane, z = 1 the far
//  plane, matching `Matrix.perspective` in KineticRender.
//

import Kinetic
import KineticRender
import SwiftUI
import simd

// MARK: - State

/// The measurement itself, kept outside the view so the enclosing screen can own a
/// "measure" toggle, read the result, and reset the tool without reaching into it.
@MainActor
final class MeasurementState: ObservableObject {
    /// True while the tool is armed. Arming it takes the mouse away from the camera,
    /// so it is a mode the caller turns on deliberately.
    @Published var isEnabled = false
    /// Zero, one or two committed world-space points.
    @Published private(set) var points: [Vec3] = []
    /// Where the pointer is currently hovering in world space, if anywhere. Drives
    /// the live readout before the second click lands.
    @Published var preview: Vec3?

    init() {}

    /// Commits a point. A third click starts a fresh measurement rather than growing
    /// a polyline — two points is the whole contract of this tool.
    func record(_ point: Vec3) {
        if points.count >= 2 {
            points = [point]
        } else {
            points.append(point)
        }
    }

    func reset() {
        points.removeAll()
        preview = nil
    }

    /// Turns the tool off and throws the measurement away.
    func disable() {
        isEnabled = false
        reset()
    }

    var isComplete: Bool { points.count >= 2 }

    /// Per-axis separation, present only once two points are committed.
    var delta: Vec3? {
        guard points.count >= 2 else { return nil }
        return points[1] - points[0]
    }

    var distance: Double? {
        delta.map { simd_length($0) }
    }
}

// MARK: - Tool

struct MeasurementTool: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @ObservedObject var state: MeasurementState

    init(model: StudioModel, state: MeasurementState) {
        self.model = model
        self.state = state
    }

    /// The pair currently being measured: two committed points, or the first point
    /// paired with the live hover so the readout updates before the second click.
    private var span: (a: Vec3, b: Vec3)? {
        guard let first = state.points.first else { return nil }
        if state.points.count >= 2 { return (first, state.points[1]) }
        if state.isEnabled, let preview = state.preview { return (first, preview) }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if state.isEnabled {
                    captureLayer(in: size)
                }

                canvas(in: size)
                    .allowsHitTesting(false)

                if let span, let midpoint = midpointOnScreen(span, in: size) {
                    readout(for: span)
                        .position(midpoint)
                }

                if state.isEnabled || !state.points.isEmpty {
                    escapeCatcher
                }
            }
        }
    }

    // MARK: Input

    private func captureLayer(in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let hit = pick(at: location, in: size) {
                    state.record(hit)
                }
                // A click into empty space records nothing on purpose: inventing a
                // point on an imaginary plane would give a confident wrong number.
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    state.preview = pick(at: location, in: size)
                case .ended:
                    state.preview = nil
                }
            }
    }

    /// Escape clears the measurement. It is a real (invisible) button rather than an
    /// `onExitCommand` so it works without the overlay having taken focus.
    private var escapeCatcher: some View {
        Button {
            state.reset()
        } label: {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Picking

    /// View coordinates → world ray → first hit. Mirrors `KineticView.select(at:)`
    /// apart from the y flip documented at the top of this file.
    private func pick(at location: CGPoint, in size: CGSize) -> Vec3? {
        guard let ray = worldRay(at: location, in: size) else { return nil }
        return model.world.raycast(origin: ray.origin, direction: ray.direction,
                                   maxDistance: 500)?.point
    }

    private func worldRay(at location: CGPoint, in size: CGSize)
        -> (origin: Vec3, direction: Vec3)?
    {
        guard let camera = model.commands.camera,
              size.width > 1, size.height > 1 else { return nil }

        // x matches the viewport; y is negated once because SwiftUI's origin is
        // top-left while NDC (and the unflipped MTKView) put +y upward.
        let ndcX = Float(location.x / size.width) * 2 - 1
        let ndcY = 1 - Float(location.y / size.height) * 2

        // The overlay is laid out in points and the drawable is in pixels, but the
        // aspect ratio is identical and NDC is a ratio, so the backing scale cancels.
        let aspect = Float(size.width / size.height)
        let inverse = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix).inverse

        let nearPoint = inverse * SIMD4<Float>(ndcX, ndcY, 0, 1)
        let farPoint = inverse * SIMD4<Float>(ndcX, ndcY, 1, 1)
        guard abs(nearPoint.w) > 1e-6, abs(farPoint.w) > 1e-6 else { return nil }

        let origin = SIMD3<Float>(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w
        let target = SIMD3<Float>(farPoint.x, farPoint.y, farPoint.z) / farPoint.w
        let direction = simd_normalize(target - origin)
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else {
            return nil
        }

        return (Vec3(Double(origin.x), Double(origin.y), Double(origin.z)),
                Vec3(Double(direction.x), Double(direction.y), Double(direction.z)))
    }

    /// World → view. The exact inverse of `worldRay`, including the single y flip.
    /// Returns nil for points behind the eye, where the perspective divide would
    /// fold them back into the frame.
    private func project(_ point: Vec3, in size: CGSize) -> CGPoint? {
        guard let camera = model.commands.camera,
              size.width > 1, size.height > 1 else { return nil }

        let aspect = Float(size.width / size.height)
        let matrix = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
        let clip = matrix * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
        // The projection's w column is -z_view, so w > 0 means "in front of the eye".
        guard clip.w > 1e-6 else { return nil }

        let ndcX = Double(clip.x / clip.w)
        let ndcY = Double(clip.y / clip.w)
        return CGPoint(x: (ndcX * 0.5 + 0.5) * size.width,
                       y: (1 - (ndcY * 0.5 + 0.5)) * size.height)
    }

    private func midpointOnScreen(_ span: (a: Vec3, b: Vec3), in size: CGSize) -> CGPoint? {
        guard let a = project(span.a, in: size), let b = project(span.b, in: size) else {
            return nil
        }
        // Lifted above the segment so the label never sits on the line it annotates.
        return CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 34)
    }

    // MARK: Drawing

    private func canvas(in size: CGSize) -> some View {
        // Resolved before the closure so the drawing code sees plain geometry and
        // never reaches back into the world or the camera mid-render.
        let a = state.points.first.flatMap { project($0, in: size) }
        let b = span.flatMap { project($0.b, in: size) }
        let corners = staircase(in: size)
        let hover = (state.isEnabled && !state.isComplete)
            ? state.preview.flatMap { project($0, in: size) } : nil
        let accent = theme.accent
        let ink = theme.text

        return Canvas { context, _ in
            if let a, let b {
                // Faint per-axis staircase: it turns the three Δ numbers in the label
                // into something you can see in the scene.
                if corners.count == 4 {
                    var stairs = Path()
                    stairs.move(to: corners[0])
                    for corner in corners.dropFirst() { stairs.addLine(to: corner) }
                    context.stroke(stairs, with: .color(accent.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round,
                                                      dash: [3, 3]))
                }

                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                context.stroke(line, with: .color(accent),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }

            if let a { marker(at: a, label: "A", color: accent, ink: ink, into: &context) }
            if let b, state.isComplete {
                marker(at: b, label: "B", color: accent, ink: ink, into: &context)
            }

            if let hover {
                // Live crosshair for the point that has not been committed yet.
                context.stroke(Path(ellipseIn: CGRect(x: hover.x - 5, y: hover.y - 5,
                                                      width: 10, height: 10)),
                               with: .color(accent.opacity(0.8)), lineWidth: 1.2)
                var cross = Path()
                cross.move(to: CGPoint(x: hover.x - 9, y: hover.y))
                cross.addLine(to: CGPoint(x: hover.x + 9, y: hover.y))
                cross.move(to: CGPoint(x: hover.x, y: hover.y - 9))
                cross.addLine(to: CGPoint(x: hover.x, y: hover.y + 9))
                context.stroke(cross, with: .color(accent.opacity(0.45)), lineWidth: 1)
            }
        }
    }

    private func marker(at point: CGPoint, label: String, color: Color, ink: Color,
                        into context: inout GraphicsContext) {
        let box = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: box), with: .color(color))
        context.stroke(Path(ellipseIn: box.insetBy(dx: -2.5, dy: -2.5)),
                       with: .color(color.opacity(0.35)), lineWidth: 1)
        context.draw(Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(ink),
                     at: CGPoint(x: point.x + 12, y: point.y - 10), anchor: .center)
    }

    /// The four projected corners of the axis-aligned path A → Δx → Δy → Δz → B.
    private func staircase(in size: CGSize) -> [CGPoint] {
        guard let span else { return [] }
        let stops: [Vec3] = [
            span.a,
            Vec3(span.b.x, span.a.y, span.a.z),
            Vec3(span.b.x, span.b.y, span.a.z),
            span.b,
        ]
        let projected = stops.compactMap { project($0, in: size) }
        // All four or none: a partially projected staircase would draw a chord
        // through the scene that means nothing.
        return projected.count == stops.count ? projected : []
    }

    // MARK: Readout

    private func readout(for span: (a: Vec3, b: Vec3)) -> some View {
        let delta = span.b - span.a
        let distance = simd_length(delta)

        return ViewportGlassGroup {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lengthText(distance))
                        .font(Typo.monoLarge)
                        .foregroundStyle(theme.text)
                        .monospacedDigit()
                    if !state.isComplete {
                        Text("live")
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        state.reset()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the measurement  ·  esc")
                }

                HStack(spacing: 8) {
                    deltaLabel("Δx", delta.x)
                    deltaLabel("Δy", delta.y)
                    deltaLabel("Δz", delta.z)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .fixedSize()
            .viewportGlass(cornerRadius: Metric.radius, interactive: true)
        }
    }

    private func deltaLabel(_ name: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
            Text(String(format: "%+.3f", value))
                .font(Typo.monoSmall)
                .foregroundStyle(theme.secondary)
                .monospacedDigit()
        }
    }

    /// Metres, except under 10 cm where millimetres are the unit an engineer would
    /// actually say out loud.
    private func lengthText(_ metres: Double) -> String {
        metres < 0.1 ? String(format: "%.1f mm", metres * 1000)
                     : String(format: "%.3f m", metres)
    }
}
