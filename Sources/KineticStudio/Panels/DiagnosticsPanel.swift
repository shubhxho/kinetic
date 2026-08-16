//
//  DiagnosticsPanel.swift
//  Kinetic Studio
//
//  Foxglove's Diagnostics panel is a board of named checks, each with a status
//  and a message. This is the simulator's version: the numbers that tell you
//  whether the step you are watching can be believed.
//
//  Every threshold below is justified where it is written, and every remedy
//  names a knob that actually exists — the ones documented under "Tuning" in
//  docs/src/physics/solver.md: armature, stiffnessTimeConstant, solverIterations,
//  warmStart, and the scene's mass ratio.
//
//  Sparklines come from a local 10 Hz sampler rather than from `model.history`,
//  which only records contact count, step time and energy. Ten samples a second
//  over the last ~10 seconds is plenty to see a trend and costs one dictionary
//  append per metric per tick.
//

import Kinetic
import SwiftUI

// MARK: - Status

enum DiagnosticStatus {
    case ok, warn, bad

    var color: Color {
        switch self {
        case .ok: return Palette.success
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }

    var label: String {
        switch self {
        case .ok: return "ok"
        case .warn: return "warn"
        case .bad: return "bad"
        }
    }

    /// Ordering for "worst status wins" in the panel header.
    var severity: Int {
        switch self {
        case .ok: return 0
        case .warn: return 1
        case .bad: return 2
        }
    }
}

private struct DiagnosticEntry: Identifiable {
    let id: String
    let title: String
    let value: String
    let unit: String?
    let status: DiagnosticStatus
    /// One line, shown only when the row is not ok.
    let diagnosis: String?
    let trend: [Double]
}

// MARK: - Panel

struct DiagnosticsPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @EnvironmentObject private var live: LiveStats

    /// Rolling sample buffers, one per metric id.
    @State private var trends: [String: [Double]] = [:]
    /// Total energy at the last reset, the reference for drift.
    @State private var energyBaseline: Double?
    @State private var lastSampledTime: Double = 0

    /// ~10 seconds of history at the sampler's 10 Hz.
    private static let trendCapacity = 96

    /// Held in `@State` so the subscription survives re-renders. A plain stored
    /// property would hand `onReceive` a brand-new publisher on every frame the
    /// model publishes, and the timer would be resubscribed before it ever fired.
    @State private var sampler = Timer.publish(every: 0.1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        let entries = buildEntries()
        let worst = entries.map(\.status).max(by: { $0.severity < $1.severity }) ?? .ok

        return VStack(spacing: 0) {
            header(worst: worst, entries: entries)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        DiagnosticRow(entry: entry)
                        Divider().opacity(0.5)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(theme.background)
        .onReceive(sampler) { _ in sample() }
    }

    // MARK: Chrome

    private func header(worst: DiagnosticStatus, entries: [DiagnosticEntry]) -> some View {
        let failing = entries.filter { $0.status != .ok }.count
        return HStack(spacing: 8) {
            Circle()
                .fill(worst.color)
                .frame(width: 7, height: 7)
            Text("DIAGNOSTICS")
                .font(Typo.sectionLabel)
                .kerning(0.6)
                .foregroundStyle(theme.tertiary)
            Chip(text: failing == 0 ? "all clear" : "\(failing) needing attention",
                 tone: worst.color)
            Spacer(minLength: 0)
            Text(String(format: "%.3f ms/step", model.world.profile.total))
                .font(Typo.monoSmall)
                .monospacedDigit()
                .foregroundStyle(theme.tertiary)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 34)
        .modifier(DiagnosticsChrome())
    }

    // MARK: Sampling

    private func sample() {
        let world = model.world
        let profile = world.profile
        let energy = world.totalEnergy

        // A time that went backwards means `reset()` or a scrub. Either way the
        // pre-jump energy is no longer a meaningful reference, so rebase.
        if energyBaseline == nil || world.time < lastSampledTime {
            energyBaseline = energy
        }
        lastSampledTime = world.time

        record("residual", profile.solverResidual)
        record("iterations", Double(profile.solverIterations))
        record("contacts", Double(profile.contactCount))
        record("constraints", Double(profile.constraintCount))
        record("broadphase", Double(profile.broadphasePairs))
        record("energy", energy)
        record("realtime", live.value.realtimeFactor)
        record("telemetry", Double(model.bridgeConnections))
    }

    private func record(_ key: String, _ value: Double) {
        var samples = trends[key] ?? []
        samples.append(value.isFinite ? value : 0)
        if samples.count > Self.trendCapacity {
            samples.removeFirst(samples.count - Self.trendCapacity)
        }
        trends[key] = samples
    }

    private func trend(_ key: String) -> [Double] { trends[key] ?? [] }

    // MARK: Entries

    private func buildEntries() -> [DiagnosticEntry] {
        let world = model.world
        let profile = world.profile
        let options = world.options

        return [
            residualEntry(profile: profile, options: options),
            iterationsEntry(profile: profile, options: options),
            contactsEntry(profile: profile),
            constraintsEntry(profile: profile),
            broadphaseEntry(profile: profile),
            energyEntry(world: world),
            realtimeEntry(options: options),
            telemetryEntry(),
        ]
    }

    private func residualEntry(profile: StepProfile,
                               options: SimulationOptions) -> DiagnosticEntry {
        let residual = profile.solverResidual
        // The residual is the constraint-velocity error left after the sweep, in
        // metres per second. 1e-6 m/s is a micron a second: invisible over any
        // run length. 1e-3 m/s is a millimetre a second of slip, which reads as a
        // stack that visibly settles within a few seconds. `solverTolerance`
        // (1e-10 by default) is the solver's own exit test, far tighter than what
        // a scene needs to look right, so it is reported rather than used here.
        let status: DiagnosticStatus = residual < 1e-6 ? .ok : (residual < 1e-3 ? .warn : .bad)
        let diagnosis: String?
        switch status {
        case .ok:
            diagnosis = nil
        case .warn:
            diagnosis = "Residual is drifting above 1e-6 m/s. Raising solverIterations from "
                + "\(options.solverIterations) usually absorbs it."
        case .bad:
            diagnosis = "Residual is above 1e-3 m/s: the scene is over-constrained, or its "
                + "masses differ by more than 10⁴. Raise solverIterations from "
                + "\(options.solverIterations), and give the light links a non-zero armature "
                + "so their effective inertia is not swamped by the heavy ones."
        }
        return DiagnosticEntry(id: "residual", title: "Solver residual",
                               value: String(format: "%.2e", residual), unit: "m/s",
                               status: status, diagnosis: diagnosis, trend: trend("residual"))
    }

    private func iterationsEntry(profile: StepProfile,
                                 options: SimulationOptions) -> DiagnosticEntry {
        let used = profile.solverIterations
        let configured = max(options.solverIterations, 1)
        // Hitting the configured count means the sweep exited on its budget and
        // not on tolerance: it stopped because it ran out, not because it was
        // done. Above 80% of the budget there is still convergence but no
        // headroom for a heavier moment — a landing, a stack collapsing.
        let ratio = Double(used) / Double(configured)
        let status: DiagnosticStatus = used >= configured ? .bad : (ratio >= 0.8 ? .warn : .ok)
        let diagnosis: String?
        switch status {
        case .ok:
            diagnosis = nil
        case .warn:
            diagnosis = "Only \(configured - used) iterations of headroom left before the "
                + "sweep exits on the cap rather than on tolerance."
        case .bad:
            diagnosis = "The sweep spent its whole solverIterations budget, so it exited on "
                + "the cap. Raise solverIterations, and check armature is non-zero — a light "
                + "link with no armature needs far more sweeps to settle."
        }
        return DiagnosticEntry(id: "iterations", title: "Solver iterations",
                               value: "\(used) / \(configured)", unit: nil,
                               status: status, diagnosis: diagnosis, trend: trend("iterations"))
    }

    private func contactsEntry(profile: StepProfile) -> DiagnosticEntry {
        let count = profile.contactCount
        // Each contact is its own 3×3 or 4×4 Delassus block, resolved once per
        // solver iteration, so step cost is roughly (contacts × iterations). 256
        // blocks is a busy but comfortable scene; past ~1024 the sweep dominates
        // the step no matter how well it converges.
        let status: DiagnosticStatus = count <= 256 ? .ok : (count <= 1024 ? .warn : .bad)
        let diagnosis: String? = status == .ok ? nil
            : "\(count) contact blocks are resolved \(profile.solverIterations)× per step. "
              + "Step cost scales with the product, so trimming solverIterations is the only "
              + "lever that does not change the scene."
        return DiagnosticEntry(id: "contacts", title: "Contacts", value: "\(count)", unit: nil,
                               status: status, diagnosis: diagnosis, trend: trend("contacts"))
    }

    private func constraintsEntry(profile: StepProfile) -> DiagnosticEntry {
        let count = profile.constraintCount
        // Constraints are contacts plus joint limits plus equalities, so the
        // comfortable band sits above the contact band — roughly two rows per
        // contact once limits and welds are counted.
        let status: DiagnosticStatus = count <= 512 ? .ok : (count <= 2048 ? .warn : .bad)
        let diagnosis: String? = status == .ok ? nil
            : "\(count) constraint rows against \(profile.contactCount) contacts. A row count "
              + "far above the contact count means joint limits and equalities are carrying "
              + "the scene, which is where an over-constrained model shows up first."
        return DiagnosticEntry(id: "constraints", title: "Constraint rows", value: "\(count)",
                               unit: nil, status: status, diagnosis: diagnosis,
                               trend: trend("constraints"))
    }

    private func broadphaseEntry(profile: StepProfile) -> DiagnosticEntry {
        let pairs = profile.broadphasePairs
        let contacts = max(profile.contactCount, 1)
        let ratio = Double(pairs) / Double(contacts)
        // Pairs are proposals; contacts are what survived narrowphase. The ratio
        // is what matters: a broadphase handing narrowphase 20× more pairs than
        // it turns into contacts is spending the collision stage on boxes that
        // are nowhere near each other. Below 32 pairs the ratio is noise, so it
        // is not judged at all.
        let status: DiagnosticStatus
        if pairs <= 32 || ratio < 8 {
            status = .ok
        } else if ratio < 24 {
            status = .warn
        } else {
            status = .bad
        }
        let share = profile.total > 0 ? profile.collision / profile.total * 100 : 0
        let diagnosis: String? = status == .ok ? nil
            : "\(pairs) pairs produced \(profile.contactCount) contacts ("
              + String(format: "%.0f×", ratio) + " rejected) and collision is "
              + String(format: "%.0f%%", share)
              + " of the step — the broadphase is proposing far more work than it resolves."
        return DiagnosticEntry(id: "broadphase", title: "Broadphase pairs", value: "\(pairs)",
                               unit: nil, status: status, diagnosis: diagnosis,
                               trend: trend("broadphase"))
    }

    private func energyEntry(world: World) -> DiagnosticEntry {
        let energy = world.totalEnergy
        let baseline = energyBaseline ?? energy
        // Normalised so a 1 J scene and a 1 kJ scene are judged the same, with a
        // 1 J floor so a scene that starts near zero energy does not report
        // infinite drift. Semi-implicit Euler is not symplectic, so a slow bleed
        // is expected physics: 1% is that bleed, 5% is the solver putting energy
        // in rather than letting it out.
        let drift = abs(energy - baseline) / max(abs(baseline), 1)
        let status: DiagnosticStatus = drift < 0.01 ? .ok : (drift < 0.05 ? .warn : .bad)
        let gaining = energy > baseline
        let diagnosis: String?
        if status == .ok {
            diagnosis = nil
        } else if gaining {
            diagnosis = String(format: "Energy is %.1f%% above the reset state. Gain comes from "
                               + "contacts driven too stiffly: keep stiffnessTimeConstant at or "
                               + "above 2 × timestep, and give light links a non-zero armature "
                               + "so a contact impulse cannot overwhelm their inertia.",
                               drift * 100)
        } else {
            diagnosis = String(format: "Energy is %.1f%% below the reset state. Losing it this "
                               + "fast usually means the sweep is not converging — raise "
                               + "solverIterations and confirm warmStart is on.", drift * 100)
        }
        return DiagnosticEntry(id: "energy", title: "Energy drift since reset",
                               value: String(format: "%+.2f", energy - baseline), unit: "J",
                               status: status, diagnosis: diagnosis, trend: trend("energy"))
    }

    private func realtimeEntry(options: SimulationOptions) -> DiagnosticEntry {
        let factor = live.value.realtimeFactor
        // 1.0 is one simulated second per wall-clock second. Below 0.95 the
        // viewport is already behind the clock; below 0.5 nothing about the run
        // feels live any more.
        let status: DiagnosticStatus = factor >= 0.95 ? .ok : (factor >= 0.5 ? .warn : .bad)
        let diagnosis: String? = status == .ok ? nil
            : "Running at " + String(format: "%.2f×", factor) + " realtime. solverIterations "
              + "(currently \(options.solverIterations)) is the largest single lever on step "
              + "cost, and warmStart is \(options.warmStart ? "on" : "off") — with it off every "
              + "sweep restarts from zero impulse and needs more iterations to reach the same "
              + "result."
        return DiagnosticEntry(id: "realtime", title: "Realtime factor",
                               value: String(format: "%.2f", factor), unit: "×",
                               status: status, diagnosis: diagnosis, trend: trend("realtime"))
    }

    private func telemetryEntry() -> DiagnosticEntry {
        // Three honest states. Serving at least one client is ok. Listening with
        // nobody attached is a warning, because a run being published to nobody
        // is nearly always an oversight. Stopped is also a warning rather than an
        // error: the simulation itself is fine, only the outside view of it is
        // missing.
        let running = model.bridgeIsRunning
        let clients = model.bridgeConnections
        let status: DiagnosticStatus = running && clients > 0 ? .ok : .warn
        let value: String
        let diagnosis: String?
        if !running {
            value = "stopped"
            diagnosis = "The Foxglove-compatible server is not listening; nothing outside "
                + "Studio can see this run."
        } else if clients == 0 {
            value = "listening"
            diagnosis = "Serving on ws://localhost:\(model.bridgePort) with no clients attached."
        } else {
            value = "\(clients) client\(clients == 1 ? "" : "s")"
            diagnosis = nil
        }
        return DiagnosticEntry(id: "telemetry", title: "Telemetry server", value: value,
                               unit: nil, status: status, diagnosis: diagnosis,
                               trend: trend("telemetry"))
    }
}

// MARK: - Row

private struct DiagnosticRow: View {
    @Environment(\.studioTheme) private var theme
    let entry: DiagnosticEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(entry.status.color.opacity(0.35), lineWidth: 3)
                            .opacity(entry.status == .ok ? 0 : 1))
                Text(entry.title)
                    .font(Typo.small)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Spacer(minLength: 8)

                DiagnosticSparkline(samples: entry.trend, tone: entry.status.color)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(entry.value)
                        .font(Typo.mono)
                        .monospacedDigit()
                        .foregroundStyle(entry.status == .ok ? theme.text : entry.status.color)
                    if let unit = entry.unit {
                        Text(unit)
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }
                }
                .frame(width: 96, alignment: .trailing)
            }

            if let diagnosis = entry.diagnosis {
                Text(diagnosis)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 8)
    }
}

// MARK: - Sparkline

private struct DiagnosticSparkline: View {
    @Environment(\.studioTheme) private var theme
    let samples: [Double]
    let tone: Color

    var body: some View {
        let points = samples
        let border = theme.borderSubtle

        return Canvas { context, size in
            guard points.count > 1 else { return }
            var lower = points[0]
            var upper = points[0]
            for value in points {
                lower = min(lower, value)
                upper = max(upper, value)
            }
            // A flat trace should sit on the mid-line rather than snapping to an
            // edge, so a degenerate range is padded symmetrically.
            if upper - lower < 1e-12 {
                let pad = max(abs(upper) * 0.1, 0.5)
                lower -= pad
                upper += pad
            }
            let span = upper - lower

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 1))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            context.stroke(baseline, with: .color(border), lineWidth: 1)

            var path = Path()
            for (index, value) in points.enumerated() {
                let x = CGFloat(index) / CGFloat(points.count - 1) * size.width
                let normalized = (value - lower) / span
                let y = size.height - 2 - CGFloat(normalized) * (size.height - 4)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(tone),
                           style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(width: 76, height: 18)
    }
}

// MARK: - Chrome background

/// Inline glass so this panel does not depend on the shared design system's
/// glass components while they are still being written.
private struct DiagnosticsChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
