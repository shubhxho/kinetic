//
//  MLInsightsPanel.swift
//  Kinetic Studio
//
//  The anomaly surface. A run produces tens of thousands of samples across a
//  dozen channels; nobody reads that. This panel reads it and points at the
//  three moments that were unusual, then lets you click one to put the timeline
//  exactly there.
//
//  Integration note — why the protocols below exist:
//  the real detector lives in the KineticML target, which is being written in
//  parallel with this file. Importing it now would couple two moving targets and
//  neither could compile until both landed. Instead the views depend on thin
//  local protocols that describe only what the UI reads, and a built-in heuristic
//  provider satisfies them today. When KineticML lands, integration is a handful
//  of conformances (see "Conforming KineticML" below) and one changed default
//  argument — no view code moves.
//
//  Conforming KineticML:
//      extension Anomaly: AnomalyDescribing {
//          var anomalyID: String { String(describing: id) }
//          var kindName: String { kind.rawValue }
//      }
//      extension InsightReport: InsightReporting {
//          var anomalyCount: Int { anomalies.count }
//          var contactSummary: String { ... }        // from contactStats
//      }
//      struct KineticMLInsights: InsightProviding { ... }  // wraps TelemetryInsight
//

import Combine
import Kinetic
import KineticRender
import SwiftUI

// MARK: - Integration seam

/// One detected event, reduced to what a row needs to draw.
/// `kindName` is a string rather than an enum so this file does not have to know
/// the case list — `AnomalyKind` can grow without touching the UI. `anomalyID` is
/// a string rather than `Identifiable` conformance because the real `Anomaly`
/// picks its own `ID` type, and an existential with an associated type cannot be
/// fed to `ForEach`.
protocol AnomalyDescribing {
    var anomalyID: String { get }
    var channel: String { get }
    var kindName: String { get }
    var time: Double { get }
    /// 0...1. Anything above 0.66 is drawn as an error.
    var severity: Double { get }
    var value: Double { get }
    var explanation: String { get }
}

/// The end-of-run summary. Deliberately flat: the panel renders prose, so it
/// wants numbers, not nested statistics structs.
protocol InsightReporting {
    var headline: String { get }
    var duration: Double { get }
    var stepTimeP50: Double { get }
    var stepTimeP95: Double { get }
    var stepTimeMax: Double { get }
    var energyDrift: Double { get }
    var contactSummary: String { get }
    var anomalyCount: Int { get }
}

/// A named pair of channels that move together.
struct ChannelCorrelation: Identifiable {
    var a: String
    var b: String
    var r: Double
    var id: String { "\(a)|\(b)" }
}

/// A channel's samples over the analysis window.
struct ChannelSamples: Identifiable {
    var label: String
    var times: [Double]
    var values: [Double]
    var id: String { label }
}

/// Everything the analyser is given. One input type, three outputs — an adapter
/// over KineticML only has to translate this once.
struct RunWindow {
    var duration: Double
    var stepMilliseconds: [Double]
    var contactCounts: [Double]
    var energies: [Double]
    var channels: [ChannelSamples]

    var sampleCount: Int { stepMilliseconds.count }
    var isEmpty: Bool { stepMilliseconds.isEmpty && channels.isEmpty }
}

/// The analyser itself. Value-in, value-out: no reference to the world, so it can
/// be moved off the main actor later without changing a call site.
protocol InsightProviding {
    /// Human-readable name of the engine doing the work, shown in the header.
    var engineName: String { get }
    /// Mirrors `MLRuntime.isAvailable`.
    var isAccelerated: Bool { get }
    /// Mirrors `MLRuntime.deviceDescription`.
    var deviceDescription: String { get }

    func anomalies(in window: RunWindow) -> [any AnomalyDescribing]
    func correlations(in window: RunWindow) -> [ChannelCorrelation]
    func report(for window: RunWindow, anomalies: [any AnomalyDescribing]) -> any InsightReporting
}

// MARK: - Built-in provider

/// Concrete anomaly used by the heuristic provider. `kindName` values match the
/// raw values of `AnomalyKind` so rows look identical once the real engine is in.
struct HeuristicAnomaly: AnomalyDescribing {
    let anomalyID = UUID().uuidString
    var channel: String
    var kindName: String
    var time: Double
    var severity: Double
    var value: Double
    var explanation: String
}

struct HeuristicReport: InsightReporting {
    var headline: String
    var duration: Double
    var stepTimeP50: Double
    var stepTimeP95: Double
    var stepTimeMax: Double
    var energyDrift: Double
    var contactSummary: String
    var anomalyCount: Int
}

/// Statistics, not learning. It finds outliers with medians and absolute
/// deviations, which is cheap, explainable, and completely honest about what it
/// is — the header says "heuristic" until a real engine is attached.
struct HeuristicInsightProvider: InsightProviding {
    var engineName: String { "Built-in heuristics" }
    var isAccelerated: Bool { false }
    var deviceDescription: String { "CPU, single thread" }

    /// Fewer than this and every statistic is noise.
    private let minimumSamples = 48

    // MARK: Anomalies

    func anomalies(in window: RunWindow) -> [any AnomalyDescribing] {
        var found: [HeuristicAnomaly] = []
        let movingChannels = window.channels.filter { spread($0.values) > 0 }.count

        for channel in window.channels where channel.values.count >= minimumSamples {
            found.append(contentsOf: scan(channel, movingChannels: movingChannels))
        }
        // Newest first: the thing that just went wrong is the thing being watched.
        return found.sorted { $0.time > $1.time }.prefix(80).map { $0 as any AnomalyDescribing }
    }

    private func scan(_ channel: ChannelSamples, movingChannels: Int) -> [HeuristicAnomaly] {
        let values = channel.values
        let times = channel.times
        var out: [HeuristicAnomaly] = []

        // A non-finite sample is not an outlier, it is a broken run. Report and stop.
        if let index = values.firstIndex(where: { !$0.isFinite }) {
            return [HeuristicAnomaly(
                channel: channel.label, kindName: "divergence",
                time: times[index], severity: 1.0, value: values[index],
                explanation: "\(channel.label) became non-finite. Everything after this point "
                    + "in the run is meaningless.")]
        }

        let centre = median(values)
        let deviation = medianAbsoluteDeviation(values, centre: centre)
        let scale = max(deviation, 1e-12)

        // Spikes: isolated samples far from the median. MAD rather than standard
        // deviation because one large spike inflates the standard deviation enough
        // to hide itself.
        if deviation > 0 {
            var lastReported = -Double.greatestFiniteMagnitude
            var spikes: [(index: Int, score: Double)] = []
            for (index, value) in values.enumerated() {
                let score = abs(value - centre) / scale
                if score > 6 { spikes.append((index, score)) }
            }
            for spike in spikes.sorted(by: { $0.score > $1.score }) {
                let time = times[spike.index]
                // One report per excursion, not one per sample inside it.
                guard abs(time - lastReported) > 0.05 else { continue }
                lastReported = time
                out.append(HeuristicAnomaly(
                    channel: channel.label, kindName: "spike",
                    time: time, severity: severity(from: spike.score, saturatingAt: 24),
                    value: values[spike.index],
                    explanation: String(
                        format: "%@ jumped to %.4g, about %.0f deviations from its typical %.4g.",
                        channel.label, values[spike.index], spike.score, centre)))
                if out.count >= 6 { break }
            }
        }

        // Stall: this channel stopped moving while the rest of the run did not.
        // Alone it means nothing — a paused scene stalls every channel.
        if deviation == 0, movingChannels > 1, let last = times.last {
            out.append(HeuristicAnomaly(
                channel: channel.label, kindName: "stall",
                time: last, severity: 0.4, value: centre,
                explanation: String(
                    format: "%@ held %.4g for the whole window while other channels kept moving.",
                    channel.label, centre)))
        }

        // Drift: a trend large enough that the channel is not returning to where
        // it started. Reported against the channel's own noise floor.
        if deviation > 0, let trend = linearTrend(times: times, values: values) {
            let travel = abs(trend.slope) * max(times.count > 1 ? times[times.count - 1] - times[0] : 0, 0)
            let ratio = travel / (scale * 6)
            if ratio > 1, let last = times.last {
                out.append(HeuristicAnomaly(
                    channel: channel.label, kindName: "drift",
                    time: last, severity: severity(from: ratio, saturatingAt: 8),
                    value: values[values.count - 1],
                    explanation: String(
                        format: "%@ moved %.4g over the window in one direction — a trend, not noise.",
                        channel.label, trend.slope * max(times[times.count - 1] - times[0], 0))))
            }
        }

        // Oscillation: the first difference keeps changing sign at high rate and
        // the amplitude is not small. Ringing in a solver looks exactly like this.
        if deviation > 0, values.count > 8 {
            var changes = 0
            var previous = values[1] - values[0]
            for index in 2..<values.count {
                let delta = values[index] - values[index - 1]
                if delta != 0, previous != 0, (delta < 0) != (previous < 0) { changes += 1 }
                if delta != 0 { previous = delta }
            }
            let rate = Double(changes) / Double(values.count - 2)
            if rate > 0.45, spread(values) > scale * 4, let last = times.last {
                out.append(HeuristicAnomaly(
                    channel: channel.label, kindName: "oscillation",
                    time: last, severity: severity(from: rate * 2, saturatingAt: 2),
                    value: values[values.count - 1],
                    explanation: String(
                        format: "%@ reversed direction on %.0f%% of steps with a swing of %.4g — ringing.",
                        channel.label, rate * 100, spread(values))))
            }
        }

        // Divergence: magnitude growing without bound.
        if let first = values.first, let last = values.last,
           abs(first) > 1e-9, abs(last) > abs(first) * 20, let time = times.last {
            out.append(HeuristicAnomaly(
                channel: channel.label, kindName: "divergence",
                time: time, severity: 0.95, value: last,
                explanation: String(
                    format: "%@ grew from %.4g to %.4g across the window. Check the timestep "
                        + "and the solver iteration count.", channel.label, first, last)))
        }

        // Constraint stress is a named channel rather than a shape: the solver
        // residual is the only signal here that has an absolute meaning.
        if channel.label.localizedCaseInsensitiveContains("residual"),
           let peak = values.max(), peak > 1e-4,
           let index = values.firstIndex(of: peak) {
            out.append(HeuristicAnomaly(
                channel: channel.label, kindName: "constraintStress",
                time: times[index], severity: severity(from: peak / 1e-4, saturatingAt: 100),
                value: peak,
                explanation: String(
                    format: "Solver residual reached %.3g — the constraint set did not fully "
                        + "converge on that step.", peak)))
        }

        return out
    }

    // MARK: Correlations

    func correlations(in window: RunWindow) -> [ChannelCorrelation] {
        let usable = window.channels.filter { $0.values.count >= minimumSamples }
        guard usable.count > 1 else { return [] }

        var out: [ChannelCorrelation] = []
        for i in 0..<(usable.count - 1) {
            for j in (i + 1)..<usable.count {
                // Series are sampled once per step, so aligning from the newest
                // sample backwards lines them up without interpolating.
                let count = min(usable[i].values.count, usable[j].values.count)
                let left = Array(usable[i].values.suffix(count))
                let right = Array(usable[j].values.suffix(count))
                guard let r = pearson(left, right), abs(r) >= 0.35 else { continue }
                out.append(ChannelCorrelation(a: usable[i].label, b: usable[j].label, r: r))
            }
        }
        return out.sorted { abs($0.r) > abs($1.r) }
    }

    // MARK: Report

    func report(for window: RunWindow,
                anomalies: [any AnomalyDescribing]) -> any InsightReporting {
        let steps = window.stepMilliseconds
        let p50 = percentile(steps, 0.50)
        let p95 = percentile(steps, 0.95)
        let peak = steps.max() ?? 0
        let drift = (window.energies.last ?? 0) - (window.energies.first ?? 0)

        let meanContacts = window.contactCounts.isEmpty
            ? 0
            : window.contactCounts.reduce(0, +) / Double(window.contactCounts.count)
        let peakContacts = window.contactCounts.max() ?? 0
        let contacts = String(format: "%.1f contacts on average, peaking at %.0f",
                              meanContacts, peakContacts)

        let worst = anomalies.max { $0.severity < $1.severity }
        let headline: String
        if let worst {
            headline = String(
                format: "%.1f s analysed. The strongest signal is a %@ on %@ at t = %.3f s.",
                window.duration, readableKind(worst.kindName), worst.channel, worst.time)
        } else if window.sampleCount < minimumSamples {
            headline = String(format: "%.1f s analysed — too short to say anything yet.",
                              window.duration)
        } else {
            headline = String(format: "%.1f s analysed. Nothing in the window looks unusual.",
                              window.duration)
        }

        return HeuristicReport(headline: headline, duration: window.duration,
                               stepTimeP50: p50, stepTimeP95: p95, stepTimeMax: peak,
                               energyDrift: drift, contactSummary: contacts,
                               anomalyCount: anomalies.count)
    }

    // MARK: Statistics

    private func spread(_ values: [Double]) -> Double {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func medianAbsoluteDeviation(_ values: [Double], centre: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        // 1.4826 makes MAD comparable to a standard deviation for normal data.
        return median(values.map { abs($0 - centre) }) * 1.4826
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let blend = position - Double(lower)
        return sorted[lower] * (1 - blend) + sorted[upper] * blend
    }

    private func linearTrend(times: [Double],
                             values: [Double]) -> (slope: Double, intercept: Double)? {
        let count = min(times.count, values.count)
        guard count > 2 else { return nil }
        let n = Double(count)
        var sumT = 0.0, sumV = 0.0, sumTT = 0.0, sumTV = 0.0
        for index in 0..<count {
            sumT += times[index]
            sumV += values[index]
            sumTT += times[index] * times[index]
            sumTV += times[index] * values[index]
        }
        let denominator = n * sumTT - sumT * sumT
        guard abs(denominator) > 1e-15 else { return nil }
        let slope = (n * sumTV - sumT * sumV) / denominator
        return (slope, (sumV - slope * sumT) / n)
    }

    private func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let count = min(a.count, b.count)
        guard count > 3 else { return nil }
        let meanA = a.reduce(0, +) / Double(count)
        let meanB = b.reduce(0, +) / Double(count)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in 0..<count {
            let da = a[index] - meanA
            let db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 1e-18, varianceB > 1e-18 else { return nil }
        let r = covariance / (varianceA.squareRoot() * varianceB.squareRoot())
        return r.isFinite ? r : nil
    }

    private func severity(from score: Double, saturatingAt limit: Double) -> Double {
        min(max(score / limit, 0), 1)
    }
}

/// Shared by the provider and the rows so both spell the kinds the same way.
private func readableKind(_ kindName: String) -> String {
    switch kindName {
    case "constraintStress": return "constraint stress"
    default: return kindName
    }
}

// MARK: - Panel

/// Anomalies, correlations and a run summary over the recorded window.
///
/// `MLInsightsPanel(model: model)` uses the built-in heuristics. Pass a provider
/// to swap in the KineticML engine: `MLInsightsPanel(model: model, provider: ...)`.
struct MLInsightsPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    private let provider: any InsightProviding

    init(model: StudioModel, provider: any InsightProviding = HeuristicInsightProvider()) {
        self.model = model
        self.provider = provider
    }

    @State private var isAnalysing = false
    @State private var anomalies: [any AnomalyDescribing] = []
    @State private var correlations: [ChannelCorrelation] = []
    @State private var report: (any InsightReporting)?
    @State private var lastAnalysisTime: Double?
    @State private var selectedAnomaly: String?
    @State private var ticker = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    /// At most this many samples per channel reach the analyser. The window can
    /// hold 10,000 steps; nothing here gets more truthful past a couple thousand,
    /// and the analysis runs on the main actor.
    private let analysisBudget = 2000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if anomalies.isEmpty && report == nil {
                emptyState
            } else {
                content
            }
        }
        .background(theme.background)
        .onReceive(ticker) { _ in
            guard isAnalysing, !model.isScrubbing else { return }
            analyse(includeReport: false)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isAnalysing ? theme.accent : theme.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("INSIGHTS")
                    .font(Typo.sectionLabel)
                    .kerning(0.6)
                    .foregroundStyle(theme.tertiary)
                Text(subtitle)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Chip(text: provider.isAccelerated ? "accelerated" : "cpu",
                 tone: provider.isAccelerated ? Palette.success : nil)

            ToolbarButton(systemImage: isAnalysing ? "stop.fill" : "play.fill",
                          label: isAnalysing ? "Stop" : "Analyse",
                          isActive: isAnalysing) {
                isAnalysing.toggle()
                if isAnalysing {
                    analyse(includeReport: false)
                    model.log("live analysis on — \(provider.engineName)", .info)
                } else {
                    model.log("live analysis off", .info)
                }
            }

            ToolbarButton(systemImage: "text.alignleft", label: "Summarise") {
                analyse(includeReport: true)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 8)
        .background(headerChrome)
    }

    /// Engine, device, and how stale the numbers below are — a reading taken ten
    /// seconds ago is not a reading of what is on screen now.
    private var subtitle: String {
        let engine = "\(provider.engineName) · \(provider.deviceDescription)"
        guard let lastAnalysisTime else { return engine }
        return engine + String(format: " · read at t=%.2fs", lastAnalysisTime)
    }

    /// Liquid Glass on the panel's floating header, material below macOS 26.
    /// Kept inline so this panel carries no dependency on the shared chrome.
    @ViewBuilder
    private var headerChrome: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing analysed yet")
                .font(Typo.title)
                .foregroundStyle(theme.text)
            Text("Press Analyse to watch the recorded window. Anomalies appear here as soon as "
                 + "a channel does something its own history does not explain — a spike, a stall, "
                 + "a one-way drift, ringing, or a solver residual that failed to converge.")
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It needs roughly fifty samples per channel before it will claim anything, so "
                 + "run the simulation for a second or two first. Plotted channels are analysed "
                 + "alongside step time, contact count and total energy.")
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !provider.isAccelerated {
                Text("This is statistics, not a model: medians, deviations and correlations. "
                     + "It finds outliers. It does not know why they happened.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metric.gutter)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let report {
                    SectionLabel(text: "Run summary")
                    summaryParagraph(report)
                    Divider()
                }

                SectionLabel(text: "Anomalies",
                             trailing: anomalies.isEmpty ? "none" : "\(anomalies.count)")
                if anomalies.isEmpty {
                    Text("No outliers in the window.")
                        .font(Typo.small)
                        .foregroundStyle(theme.tertiary)
                        .padding(.horizontal, Metric.gutter)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 1) {
                        ForEach(anomalies, id: \.anomalyID) { anomaly in
                            anomalyRow(anomaly)
                        }
                    }
                    .padding(.bottom, 8)
                }

                Divider()
                SectionLabel(text: "Correlations",
                             trailing: correlations.isEmpty ? nil : "top \(min(correlations.count, 8))")
                if correlations.isEmpty {
                    Text("Plot two or more channels to see what moves together.")
                        .font(Typo.small)
                        .foregroundStyle(theme.tertiary)
                        .padding(.horizontal, Metric.gutter)
                        .padding(.bottom, 10)
                } else {
                    VStack(spacing: 2) {
                        ForEach(correlations.prefix(8)) { pair in
                            correlationRow(pair)
                        }
                    }
                    .padding(.bottom, 4)
                    Text("Correlation is not cause. Two channels can track each other because "
                         + "both follow a third.")
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                        .padding(.horizontal, Metric.gutter)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func anomalyRow(_ anomaly: any AnomalyDescribing) -> some View {
        let tone = severityColor(anomaly.severity)
        let key = anomaly.anomalyID
        return Button {
            scrub(to: anomaly.time)
            selectedAnomaly = key
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Severity reads as a bar rather than a number: the eye ranks bars
                // faster than it ranks decimals.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tone)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .opacity(0.35 + 0.65 * min(max(anomaly.severity, 0), 1))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Chip(text: readableKind(anomaly.kindName), tone: tone)
                        Text(anomaly.channel)
                            .font(Typo.small.weight(.medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: "t=%.3fs", anomaly.time))
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }
                    Text(anomaly.explanation)
                        .font(Typo.small)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 6)
            }
            .padding(.horizontal, Metric.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedAnomaly == key ? theme.accent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Move the timeline to t = \(String(format: "%.3f", anomaly.time)) s")
    }

    private func correlationRow(_ pair: ChannelCorrelation) -> some View {
        let magnitude = min(abs(pair.r), 1)
        let tone = pair.r >= 0 ? theme.accent : Palette.warning
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(pair.r >= 0
                     ? "\(pair.a) tracks \(pair.b)"
                     : "\(pair.a) moves against \(pair.b)")
                    .font(Typo.small)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(String(format: "r = %+.2f", pair.r))
                    .font(Typo.mono)
                    .foregroundStyle(tone)
            }
            // A bar for |r| so the ranking survives a glance.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.borderSubtle)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tone.opacity(0.75))
                        .frame(width: max(geometry.size.width * magnitude, 1))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 3)
    }

    private func summaryParagraph(_ report: any InsightReporting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.headline)
                .font(Typo.body.weight(.medium))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(distributionSentence(report))
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                StatTile(label: "step p50", value: String(format: "%.2f", report.stepTimeP50),
                         unit: "ms")
                StatTile(label: "step p95", value: String(format: "%.2f", report.stepTimeP95),
                         unit: "ms")
                StatTile(label: "anomalies", value: "\(report.anomalyCount)",
                         tone: report.anomalyCount > 0 ? Palette.warning : nil)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.bottom, 10)
    }

    private func distributionSentence(_ report: any InsightReporting) -> String {
        var parts: [String] = []
        parts.append(String(
            format: "Half of the steps finished inside %.2f ms; one in twenty took longer than "
                + "%.2f ms, and the slowest took %.2f ms.",
            report.stepTimeP50, report.stepTimeP95, report.stepTimeMax))
        parts.append("The window held \(report.contactSummary).")
        let drift = report.energyDrift
        if abs(drift) < 1e-9 {
            parts.append("Total energy did not measurably change.")
        } else {
            parts.append(String(
                format: "Total energy %@ by %.4g J over %.1f s — expected for a damped or "
                    + "actuated scene, worth a look for a passive one.",
                drift > 0 ? "rose" : "fell", abs(drift), report.duration))
        }
        return parts.joined(separator: " ")
    }

    private func severityColor(_ severity: Double) -> Color {
        if severity >= 0.66 { return Palette.danger }
        if severity >= 0.33 { return Palette.warning }
        return theme.accent
    }

    // MARK: Actions

    /// Puts the playhead on the anomaly. History times are absolute simulation
    /// seconds, so the fraction is measured against the window's own bounds.
    private func scrub(to time: Double) {
        let start = model.history.startTime
        let end = model.history.endTime
        guard end > start else {
            model.log("no recorded window to scrub into", .warning)
            return
        }
        let fraction = min(max((time - start) / (end - start), 0), 1)
        model.scrub(toFraction: fraction)
    }

    private func analyse(includeReport: Bool) {
        let window = makeWindow()
        guard !window.isEmpty else {
            if includeReport { model.log("nothing recorded to summarise yet", .warning) }
            return
        }
        let found = provider.anomalies(in: window)
        anomalies = found
        correlations = provider.correlations(in: window)
        lastAnalysisTime = model.stats.simulationTime
        if includeReport {
            let summary = provider.report(for: window, anomalies: found)
            report = summary
            model.log(summary.headline, found.isEmpty ? .info : .warning)
        }
    }

    /// Builds the analyser's input from the recorded window plus whatever the user
    /// has chosen to plot. Step time, contacts and energy are always included
    /// because they are the three channels that explain most bad runs.
    private func makeWindow() -> RunWindow {
        let history = model.history
        let count = history.count
        var times: [Double] = []
        var steps: [Double] = []
        var contacts: [Double] = []
        var energies: [Double] = []

        if count > 0 {
            let stride = max(1, count / analysisBudget)
            var index = 0
            while index < count {
                let frame = history.frame(at: index)
                times.append(frame.time)
                steps.append(frame.stepMilliseconds)
                contacts.append(Double(frame.contactCount))
                energies.append(frame.totalEnergy)
                index += stride
            }
        }

        var channels: [ChannelSamples] = []
        if times.count >= 4 {
            channels.append(ChannelSamples(label: "step time (ms)", times: times, values: steps))
            channels.append(ChannelSamples(label: "contacts", times: times, values: contacts))
            channels.append(ChannelSamples(label: "total energy (J)", times: times, values: energies))
        }

        for series in model.series {
            // The three above are already covered; a duplicate would correlate
            // perfectly with itself and crowd out real pairs.
            guard !channels.contains(where: { $0.label == series.channel.label }) else { continue }
            let ordered = series.ordered
            guard ordered.count >= 4 else { continue }
            let stride = max(1, ordered.count / analysisBudget)
            var sampleTimes: [Double] = []
            var sampleValues: [Double] = []
            var index = 0
            while index < ordered.count {
                sampleTimes.append(ordered[index].t)
                sampleValues.append(ordered[index].v)
                index += stride
            }
            channels.append(ChannelSamples(label: series.channel.label,
                                           times: sampleTimes, values: sampleValues))
        }

        let duration = max(history.endTime - history.startTime, 0)
        return RunWindow(duration: duration, stepMilliseconds: steps, contactCounts: contacts,
                         energies: energies, channels: channels)
    }
}
