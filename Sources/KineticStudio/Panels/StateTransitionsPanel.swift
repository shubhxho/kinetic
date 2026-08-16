//
//  StateTransitionsPanel.swift
//  Kinetic Studio
//
//  Foxglove's State Transitions panel draws a discrete signal as coloured bands
//  along a shared time axis, so you can see *when* something was in a state
//  rather than reading a plot and inferring it. The simulator's discrete signals
//  come from the recorded history: whether anything was touching, whether the
//  step blew its budget, and how many contacts the solver was carrying.
//
//  Drawing is per-pixel-column rather than per-frame. The history holds up to
//  `windowSeconds / timestep` frames — 10 000 at the defaults — and a band edge
//  is only ever a pixel wide, so aggregating each column over the frames that
//  land in it costs one pass and never produces geometry finer than the display.
//  The aggregation is a max, not a sample, so a single over-budget step in a
//  hundred still paints its column red instead of being skipped.
//

import Kinetic
import SwiftUI

// MARK: - Track model

private struct TransitionSegment {
    let x0: CGFloat
    let x1: CGFloat
    let value: Double
}

private enum TransitionStyle {
    /// Painted when the value is non-zero, left empty otherwise.
    case boolean(Color)
    /// Painted in a colour per distinct value, the way Foxglove bands an enum.
    case bands
}

private struct TransitionTrack: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let style: TransitionStyle
    /// Reduced with `max` across every frame that falls in a pixel column.
    let value: (HistoryFrame) -> Double
    /// How the hover readout renders this track's value.
    let readout: (Double) -> String
}

/// Colour for a contact-count band. Zero reads as "empty", then the categorical
/// ramp so adjacent counts stay distinguishable.
private func transitionBandColor(_ value: Double) -> Color? {
    let count = Int(value.rounded())
    guard count > 0 else { return nil }
    return Palette.series[(count - 1) % Palette.series.count]
}

/// Collapses the history into runs of equal value, one pixel column at a time.
private func transitionSegments(count: Int, width: CGFloat, originX: CGFloat,
                                sample: (Int) -> Double) -> [TransitionSegment] {
    guard count > 0, width >= 1 else { return [] }
    let columns = max(1, Int(width))
    var segments: [TransitionSegment] = []
    segments.reserveCapacity(32)

    func x(_ column: Int) -> CGFloat {
        originX + CGFloat(column) / CGFloat(columns) * width
    }

    var runStart = 0
    var runValue = 0.0
    var started = false

    for column in 0..<columns {
        let lower = Int(Double(column) / Double(columns) * Double(count))
        let upper = max(lower + 1, Int(Double(column + 1) / Double(columns) * Double(count)))
        var peak = 0.0
        var seen = false
        for index in lower..<min(upper, count) {
            let candidate = sample(index)
            peak = seen ? max(peak, candidate) : candidate
            seen = true
        }
        if !started {
            started = true
            runStart = column
            runValue = peak
        } else if peak != runValue {
            segments.append(TransitionSegment(x0: x(runStart), x1: x(column), value: runValue))
            runStart = column
            runValue = peak
        }
    }
    if started {
        segments.append(TransitionSegment(x0: x(runStart), x1: x(columns), value: runValue))
    }
    return segments
}

// MARK: - Panel

struct StateTransitionsPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    @State private var hoverFraction: Double?

    private let gutter: CGFloat = 138
    private let trackHeight: CGFloat = 26
    private let trackSpacing: CGFloat = 8
    private let axisHeight: CGFloat = 18

    private var history: StateHistory { model.history }

    var body: some View {
        let tracks = buildTracks()
        let frameCount = history.count

        return VStack(spacing: 0) {
            header(tracks: tracks, frameCount: frameCount)
            Divider()
            if frameCount < 2 {
                emptyState
            } else {
                GeometryReader { proxy in
                    canvas(tracks: tracks, frameCount: frameCount)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    scrub(x: value.location.x, width: proxy.size.width)
                                })
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hoverFraction = fraction(x: point.x, width: proxy.size.width)
                            case .ended:
                                hoverFraction = nil
                            }
                        }
                }
                .frame(height: canvasHeight(trackCount: tracks.count))
                .padding(.vertical, 8)
                Spacer(minLength: 0)
                legend
            }
        }
        .background(theme.background)
    }

    private func canvasHeight(trackCount: Int) -> CGFloat {
        CGFloat(trackCount) * trackHeight + CGFloat(max(trackCount - 1, 0)) * trackSpacing
            + axisHeight
    }

    // MARK: Tracks

    private func buildTracks() -> [TransitionTrack] {
        // The budget is one real-time timestep: a step that takes longer than the
        // interval it simulates cannot keep up, whatever the wall clock says.
        let budgetMilliseconds = model.world.options.timestep * 1000

        return [
            TransitionTrack(
                id: "contact",
                title: "in contact",
                subtitle: "contacts > 0",
                style: .boolean(Palette.success),
                value: { $0.contactCount > 0 ? 1 : 0 },
                readout: { $0 > 0 ? "touching" : "free" }),
            TransitionTrack(
                id: "budget",
                title: "step over budget",
                subtitle: String(format: "> %.2f ms", budgetMilliseconds),
                style: .boolean(Palette.danger),
                value: { $0.stepMilliseconds > budgetMilliseconds ? 1 : 0 },
                readout: { $0 > 0 ? "over" : "within" }),
            TransitionTrack(
                id: "count",
                title: "contact count",
                subtitle: "bands per value",
                style: .bands,
                value: { Double($0.contactCount) },
                readout: { String(Int($0.rounded())) }),
        ]
    }

    // MARK: Chrome

    private func header(tracks: [TransitionTrack], frameCount: Int) -> some View {
        HStack(spacing: 10) {
            Text("STATE TRANSITIONS")
                .font(Typo.sectionLabel)
                .kerning(0.6)
                .foregroundStyle(theme.tertiary)
            Chip(text: "\(frameCount) frames")

            Spacer(minLength: 8)

            if let readout = hoverReadout(tracks: tracks, frameCount: frameCount) {
                Text(readout)
                    .font(Typo.mono)
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            } else if frameCount > 1 {
                Text(String(format: "%.2f – %.2f s", history.startTime, history.endTime))
                    .font(Typo.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiary)
            }

            if model.isScrubbing {
                ToolbarButton(systemImage: "forward.end", label: "Live") {
                    model.resumeLive()
                }
            }
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 34)
        .modifier(StateTransitionsChrome())
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Run the simulation to record a history.")
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendSwatch(color: Palette.success, label: "in contact")
            legendSwatch(color: Palette.danger, label: "over budget")
            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 10)
            ForEach(1...5, id: \.self) { count in
                legendSwatch(color: Palette.series[(count - 1) % Palette.series.count],
                             label: count == 5 ? "5+" : "\(count)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.bottom, 10)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 8)
            Text(label)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
        }
    }

    // MARK: Readout

    private func hoverReadout(tracks: [TransitionTrack], frameCount: Int) -> String? {
        guard let hoverFraction, frameCount > 1 else { return nil }
        let index = max(0, min(frameCount - 1, Int((Double(frameCount - 1) * hoverFraction)
                                                    .rounded())))
        let frame = history.frame(at: index)
        let parts = tracks.map { "\($0.title): \($0.readout($0.value(frame)))" }
        return String(format: "t %.3f s  ·  ", frame.time) + parts.joined(separator: "  ·  ")
    }

    // MARK: Interaction

    private func fraction(x: CGFloat, width: CGFloat) -> Double? {
        let span = width - gutter
        guard span > 1 else { return nil }
        let value = Double((x - gutter) / span)
        guard value >= -0.02, value <= 1.02 else { return nil }
        return min(max(value, 0), 1)
    }

    /// Clicking or dragging the timeline moves the playhead. This is the one
    /// place the panel touches simulation state, and it goes through the model's
    /// own scrub path so the world is restored from history rather than stepped.
    private func scrub(x: CGFloat, width: CGFloat) {
        guard let value = fraction(x: x, width: width) else { return }
        model.scrub(toFraction: value)
    }

    // MARK: Canvas

    private func canvas(tracks: [TransitionTrack], frameCount: Int) -> some View {
        let gutterWidth = gutter
        let trackH = trackHeight
        let spacing = trackSpacing
        let axis = axisHeight
        let playhead = playheadFraction(frameCount: frameCount)
        let hover = hoverFraction
        let startTime = history.startTime
        let endTime = history.endTime
        let store = history
        let border = theme.border
        let subtle = theme.borderSubtle
        let tertiary = theme.tertiary
        let surface = theme.surface
        let text = theme.text
        let accent = theme.accent

        return Canvas { context, canvasSize in
            let plotX = gutterWidth
            let plotWidth = max(canvasSize.width - gutterWidth - 8, 1)

            for (row, track) in tracks.enumerated() {
                let y = CGFloat(row) * (trackH + spacing)
                let laneRect = CGRect(x: plotX, y: y, width: plotWidth, height: trackH)

                // Lane background and label gutter.
                context.fill(Path(roundedRect: laneRect, cornerRadius: 3),
                             with: .color(surface))
                context.stroke(Path(roundedRect: laneRect, cornerRadius: 3),
                               with: .color(subtle), lineWidth: 1)

                context.draw(
                    Text(track.title).font(Typo.small.weight(.medium)).foregroundStyle(text),
                    at: CGPoint(x: gutterWidth - 12, y: y + trackH / 2 - 6), anchor: .trailing)
                context.draw(
                    Text(track.subtitle).font(Typo.monoSmall).foregroundStyle(tertiary),
                    at: CGPoint(x: gutterWidth - 12, y: y + trackH / 2 + 7), anchor: .trailing)

                let segments = transitionSegments(count: frameCount, width: plotWidth,
                                                  originX: plotX) { index in
                    track.value(store.frame(at: index))
                }

                for segment in segments {
                    let color: Color?
                    switch track.style {
                    case .boolean(let tone):
                        color = segment.value > 0 ? tone : nil
                    case .bands:
                        color = transitionBandColor(segment.value)
                    }
                    guard let color else { continue }
                    let rect = CGRect(x: segment.x0, y: y + 3,
                                      width: max(segment.x1 - segment.x0, 1),
                                      height: trackH - 6)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                 with: .color(color.opacity(0.85)))

                    // Only label a band that is comfortably wider than the text.
                    if case .bands = track.style, rect.width > 22 {
                        context.draw(
                            Text(String(Int(segment.value.rounded())))
                                .font(Typo.monoSmall)
                                .foregroundStyle(Color.black.opacity(0.75)),
                            at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                    }
                }
            }

            let tracksBottom = CGFloat(tracks.count) * (trackH + spacing) - spacing

            // Time axis.
            var axisPath = Path()
            axisPath.move(to: CGPoint(x: plotX, y: tracksBottom + 6))
            axisPath.addLine(to: CGPoint(x: plotX + plotWidth, y: tracksBottom + 6))
            context.stroke(axisPath, with: .color(border), lineWidth: 1)
            context.draw(
                Text(String(format: "%.2f s", startTime))
                    .font(Typo.monoSmall).foregroundStyle(tertiary),
                at: CGPoint(x: plotX, y: tracksBottom + axis - 2), anchor: .leading)
            context.draw(
                Text(String(format: "%.2f s", endTime))
                    .font(Typo.monoSmall).foregroundStyle(tertiary),
                at: CGPoint(x: plotX + plotWidth, y: tracksBottom + axis - 2), anchor: .trailing)

            // Playhead, then hover crosshair on top of it.
            var playheadPath = Path()
            let playheadX = plotX + CGFloat(playhead) * plotWidth
            playheadPath.move(to: CGPoint(x: playheadX, y: 0))
            playheadPath.addLine(to: CGPoint(x: playheadX, y: tracksBottom + 6))
            context.stroke(playheadPath, with: .color(accent), lineWidth: 1.5)

            if let hover {
                var hoverPath = Path()
                let hoverX = plotX + CGFloat(hover) * plotWidth
                hoverPath.move(to: CGPoint(x: hoverX, y: 0))
                hoverPath.addLine(to: CGPoint(x: hoverX, y: tracksBottom + 6))
                context.stroke(hoverPath, with: .color(text.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }

    private func playheadFraction(frameCount: Int) -> Double {
        guard frameCount > 1 else { return 1 }
        guard model.isScrubbing else { return 1 }
        return Double(model.scrubIndex) / Double(frameCount - 1)
    }
}

// MARK: - Chrome background

/// Inline glass, kept free of the shared design system's glass components so the
/// panel compiles on its own.
private struct StateTransitionsChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
