//
//  PlotView.swift
//  Kinetic Studio
//
//  Canvas-drawn time-series plot. Sized for a telemetry strip: readable at 90 pt
//  tall, no chrome that does not carry information, and a shared time axis so
//  several stacked plots line up.
//

import SwiftUI

struct TimeSeriesPlot: View {
    @Environment(\.studioTheme) private var theme

    let series: PlotSeries
    let windowSeconds: Double
    let currentTime: Double
    var showAxis: Bool = true
    var onRemove: (() -> Void)? = nil

    private var samples: [(t: Double, v: Double)] {
        let cutoff = currentTime - windowSeconds
        return series.ordered.filter { $0.t >= cutoff }
    }

    var body: some View {
        let points = samples
        let bounds = valueBounds(points)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(series.color)
                    .frame(width: 6, height: 6)
                Text(series.channel.label)
                    .font(Typo.small.weight(.medium))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 4)
                Text(format(points.last?.v ?? 0))
                    .font(Typo.mono)
                    .foregroundStyle(series.color)
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Canvas { context, size in
                let insetLeft: CGFloat = showAxis ? 44 : 6
                let plotRect = CGRect(x: insetLeft, y: 4,
                                      width: max(size.width - insetLeft - 8, 1),
                                      height: max(size.height - 16, 1))

                // Horizontal reference lines at min / mid / max.
                var gridPath = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    let y = plotRect.maxY - CGFloat(fraction) * plotRect.height
                    gridPath.move(to: CGPoint(x: plotRect.minX, y: y))
                    gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                }
                context.stroke(gridPath, with: .color(theme.borderSubtle), lineWidth: 1)

                if showAxis {
                    for (fraction, value) in [(1.0, bounds.upper), (0.0, bounds.lower)] {
                        let y = plotRect.maxY - CGFloat(fraction) * plotRect.height
                        let text = Text(format(value))
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                        context.draw(text, at: CGPoint(x: insetLeft - 6, y: y),
                                     anchor: fraction > 0.5 ? .trailing : .trailing)
                    }
                }

                guard points.count > 1, bounds.upper > bounds.lower else { return }
                let tMin = max(currentTime - windowSeconds, points.first!.t)
                let tSpan = max(currentTime - tMin, 1e-6)

                func project(_ sample: (t: Double, v: Double)) -> CGPoint {
                    let x = plotRect.minX + CGFloat((sample.t - tMin) / tSpan) * plotRect.width
                    let normalized = (sample.v - bounds.lower) / (bounds.upper - bounds.lower)
                    let y = plotRect.maxY - CGFloat(normalized) * plotRect.height
                    return CGPoint(x: x, y: y)
                }

                var line = Path()
                var fill = Path()
                line.move(to: project(points[0]))
                fill.move(to: CGPoint(x: project(points[0]).x, y: plotRect.maxY))
                fill.addLine(to: project(points[0]))
                for sample in points.dropFirst() {
                    let p = project(sample)
                    line.addLine(to: p)
                    fill.addLine(to: p)
                }
                fill.addLine(to: CGPoint(x: project(points.last!).x, y: plotRect.maxY))
                fill.closeSubpath()

                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [series.color.opacity(0.22), series.color.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: plotRect.minY),
                    endPoint: CGPoint(x: 0, y: plotRect.maxY)))
                context.stroke(line, with: .color(series.color),
                               style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

                if let last = points.last {
                    let p = project(last)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5,
                                                        width: 5, height: 5)),
                                 with: .color(series.color))
                }
            }
            .frame(minHeight: 52)
            .padding(.bottom, 4)
        }
        .background(theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
    }

    private func valueBounds(_ points: [(t: Double, v: Double)]) -> (lower: Double, upper: Double) {
        guard !points.isEmpty else { return (0, 1) }
        var lower = points[0].v
        var upper = points[0].v
        for p in points {
            lower = min(lower, p.v)
            upper = max(upper, p.v)
        }
        if upper - lower < 1e-9 {
            let pad = max(abs(upper) * 0.1, 0.5)
            return (lower - pad, upper + pad)
        }
        let pad = (upper - lower) * 0.12
        return (lower - pad, upper + pad)
    }

    private func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        if magnitude < 0.001 || magnitude >= 100_000 { return String(format: "%.2e", value) }
        if magnitude < 1 { return String(format: "%.4f", value) }
        if magnitude < 100 { return String(format: "%.3f", value) }
        return String(format: "%.1f", value)
    }
}
