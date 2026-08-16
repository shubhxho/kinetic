//
//  PlotView.swift
//  Kinetic Studio
//
//  Telemetry plots, drawn with Swift Charts rather than by hand.
//
//  The previous version rendered into a `Canvas` and computed its own axes,
//  gradients and tick labels. Charts does all of that natively, and gets the
//  things hand-rolled plotting usually gets wrong for free: accessible values,
//  correct dark-mode axis contrast, sensible tick counts as the frame resizes,
//  and interpolation that does not alias when the sample rate exceeds the pixel
//  rate.
//

import Charts
import SwiftUI

/// One sample, in the shape Charts wants: a value type it can identify.
struct PlotSample: Identifiable {
    let id: Int
    let time: Double
    let value: Double
}

struct TimeSeriesPlot: View {
    @Environment(\.studioTheme) private var theme

    let series: PlotSeries
    let windowSeconds: Double
    let currentTime: Double
    var showAxis: Bool = true
    var onRemove: (() -> Void)? = nil

    /// Charts materialises one mark per data point, so a 2 kHz channel over a
    /// 30-second window would hand it 60,000 marks for a plot a few hundred
    /// points wide. Decimating to roughly two samples per point costs nothing
    /// visible and is the difference between an idle app and a busy core.
    private static let maximumMarks = 90

    private var samples: [PlotSample] {
        let cutoff = currentTime - windowSeconds
        let window = series.ordered.drop { $0.t < cutoff }
        guard !window.isEmpty else { return [] }

        let stride = max(1, window.count / Self.maximumMarks)
        var out: [PlotSample] = []
        out.reserveCapacity(window.count / stride + 1)
        for (offset, sample) in window.enumerated() where offset % stride == 0 {
            out.append(PlotSample(id: offset, time: sample.t, value: sample.v))
        }
        // Always keep the newest sample: the readout beside the title reads from
        // it, and dropping it would make the trace lag the number.
        if let last = window.last, out.last?.time != last.t {
            out.append(PlotSample(id: window.count, time: last.t, value: last.v))
        }
        return out
    }

    var body: some View {
        let points = samples
        let domain = valueDomain(points)

        VStack(alignment: .leading, spacing: 4) {
            header(latest: points.last?.value ?? 0)

            Chart(points) { sample in
                AreaMark(
                    x: .value("Time", sample.time),
                    y: .value(series.channel.label, sample.value))
                    .foregroundStyle(
                        .linearGradient(colors: [series.color.opacity(0.28),
                                                 series.color.opacity(0.02)],
                                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.time),
                    y: .value(series.channel.label, sample.value))
                    .foregroundStyle(series.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: xDomain(points))
            .chartYAxis {
                if showAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(theme.borderSubtle)
                        AxisValueLabel()
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(theme.borderSubtle.opacity(0.6))
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>()
                        .precision(.fractionLength(1)))
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
            .chartLegend(.hidden)
            .frame(minHeight: 56)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(series.channel.label)
        .accessibilityValue(format(points.last?.value ?? 0))
    }

    @ViewBuilder
    private func header(latest: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(series.color)
                .frame(width: 6, height: 6)
            Text(series.channel.label)
                .font(Typo.small.weight(.medium))
                .foregroundStyle(theme.text)
            Spacer(minLength: 4)
            Text(format(latest))
                .font(Typo.mono)
                .monospacedDigit()
                .foregroundStyle(series.color)
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Remove \(series.channel.label)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// Charts will happily pick a domain, but a live plot needs a stable one or
    /// the trace jumps every time a new extreme arrives.
    private func valueDomain(_ points: [PlotSample]) -> ClosedRange<Double> {
        guard !points.isEmpty else { return 0...1 }
        var lower = points[0].value
        var upper = points[0].value
        for p in points {
            lower = min(lower, p.value)
            upper = max(upper, p.value)
        }
        if upper - lower < 1e-9 {
            let pad = max(abs(upper) * 0.1, 0.5)
            return (lower - pad)...(upper + pad)
        }
        let pad = (upper - lower) * 0.12
        return (lower - pad)...(upper + pad)
    }

    private func xDomain(_ points: [PlotSample]) -> ClosedRange<Double> {
        let end = max(currentTime, points.last?.time ?? 0)
        let start = min(end - windowSeconds, points.first?.time ?? end - windowSeconds)
        return start...(max(end, start + 1e-6))
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

/// A compact inline trend, for table cells and diagnostic rows.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.accent

    private var samples: [PlotSample] {
        values.enumerated().map { PlotSample(id: $0.offset, time: Double($0.offset),
                                             value: $0.element) }
    }

    var body: some View {
        Chart(samples) { sample in
            LineMark(x: .value("Sample", sample.time), y: .value("Value", sample.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.clear) }
        .accessibilityHidden(true)
    }
}
