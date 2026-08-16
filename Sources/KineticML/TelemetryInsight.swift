//
//  TelemetryInsight.swift
//  KineticML
//
//  Turns a run's samples and detections into something a person can read: a
//  summary, a headline, correlations between channels, and advice phrased in
//  terms of the knobs this engine actually has.
//
//  Everything here is off the hot path. It runs when a run finishes, or when a
//  UI asks for a report, and it is allowed to sort, allocate and interpolate.
//

import Foundation

// MARK: - Report pieces

/// Order statistics for one channel over a run.
public struct SampleDistribution: Codable, Sendable, Equatable {
    public var count: Int
    public var minimum: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var maximum: Double
    public var mean: Double
    public var standardDeviation: Double

    public init(count: Int = 0, minimum: Double = 0, p50: Double = 0, p95: Double = 0,
                p99: Double = 0, maximum: Double = 0, mean: Double = 0,
                standardDeviation: Double = 0) {
        self.count = count
        self.minimum = minimum
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.maximum = maximum
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    /// Percentiles by nearest rank on a sorted copy. Exact rather than
    /// streaming, because this is not the hot path and an approximate p99 in a
    /// report is a false economy.
    public static func make(from values: [Double]) -> SampleDistribution {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return SampleDistribution() }
        let sorted = finite.sorted()

        func percentile(_ fraction: Double) -> Double {
            let rank = Int((fraction * Double(sorted.count - 1)).rounded())
            return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
        }

        let mean = sorted.reduce(0, +) / Double(sorted.count)
        var sumSquares = 0.0
        for value in sorted { sumSquares += (value - mean) * (value - mean) }
        let deviation = sorted.count > 1 ? (sumSquares / Double(sorted.count - 1)).squareRoot() : 0

        return SampleDistribution(count: sorted.count,
                                  minimum: sorted[0],
                                  p50: percentile(0.50),
                                  p95: percentile(0.95),
                                  p99: percentile(0.99),
                                  maximum: sorted[sorted.count - 1],
                                  mean: mean,
                                  standardDeviation: deviation)
    }
}

/// What the collision and constraint side of the run looked like.
public struct ContactSummary: Codable, Sendable, Equatable {
    public var mean: Double
    public var p95: Double
    public var peak: Double
    /// Fraction of samples with at least one contact.
    public var touchingFraction: Double
    /// Fraction of samples where the count changed from the previous sample -
    /// a settled scene sits near zero, a churning one near one.
    public var churnFraction: Double

    public init(mean: Double = 0, p95: Double = 0, peak: Double = 0,
                touchingFraction: Double = 0, churnFraction: Double = 0) {
        self.mean = mean
        self.p95 = p95
        self.peak = peak
        self.touchingFraction = touchingFraction
        self.churnFraction = churnFraction
    }
}

/// Energy bookkeeping. Kinetic's semi-implicit integrator dissipates slightly
/// and contacts dissipate a lot, so a small negative drift is healthy; a
/// positive drift is not.
public struct EnergySummary: Codable, Sendable, Equatable {
    public var initial: Double
    public var final: Double
    public var absoluteDrift: Double
    /// Drift as a fraction of the initial magnitude. Zero when the run starts
    /// at zero energy, where a relative figure is meaningless.
    public var relativeDrift: Double
    public var peakDeviation: Double
    public var driftPerSecond: Double

    public init(initial: Double = 0, final: Double = 0, absoluteDrift: Double = 0,
                relativeDrift: Double = 0, peakDeviation: Double = 0,
                driftPerSecond: Double = 0) {
        self.initial = initial
        self.final = final
        self.absoluteDrift = absoluteDrift
        self.relativeDrift = relativeDrift
        self.peakDeviation = peakDeviation
        self.driftPerSecond = driftPerSecond
    }
}

/// One correlation, in a form that survives a round trip through JSON.
public struct ChannelCorrelation: Codable, Sendable, Equatable {
    public var a: String
    public var b: String
    /// Pearson r over the aligned pair, in -1...1.
    public var r: Double
    public var sampleCount: Int

    public init(a: String, b: String, r: Double, sampleCount: Int) {
        self.a = a
        self.b = b
        self.r = r
        self.sampleCount = sampleCount
    }
}

/// Everything worth knowing about a finished run, in one value.
public struct InsightReport: Codable, Sendable {
    /// Simulated seconds covered by the samples.
    public var duration: Double
    /// Number of samples on the densest channel - one per step, in practice.
    public var sampleCount: Int
    public var channelCount: Int

    public var stepTime: SampleDistribution?
    public var solverResidual: SampleDistribution?
    public var contacts: ContactSummary?
    public var energy: EnergySummary?

    public var anomalies: [Anomaly]
    public var correlations: [ChannelCorrelation]

    /// One sentence a person can read without knowing any of the above.
    public var headline: String
    /// Advice for the most severe distinct problems, worst first.
    public var advice: [String]

    public init(duration: Double = 0, sampleCount: Int = 0, channelCount: Int = 0,
                stepTime: SampleDistribution? = nil, solverResidual: SampleDistribution? = nil,
                contacts: ContactSummary? = nil, energy: EnergySummary? = nil,
                anomalies: [Anomaly] = [], correlations: [ChannelCorrelation] = [],
                headline: String = "", advice: [String] = []) {
        self.duration = duration
        self.sampleCount = sampleCount
        self.channelCount = channelCount
        self.stepTime = stepTime
        self.solverResidual = solverResidual
        self.contacts = contacts
        self.energy = energy
        self.anomalies = anomalies
        self.correlations = correlations
        self.headline = headline
        self.advice = advice
    }
}

// MARK: - Insight

public enum TelemetryInsight {

    public typealias Series = [(time: Double, value: Double)]
    public typealias SampleSet = [String: Series]

    /// Correlations weaker than this are noise on any realistic sample count
    /// and only clutter the report.
    private static let correlationFloor = 0.5
    /// Guard against an O(n^2) sweep over a Studio session with a channel per
    /// degree of freedom. The densest channels are the interesting ones.
    private static let maximumCorrelatedChannels = 24

    // MARK: Summary

    /// Builds the run summary. Samples do not have to be sorted or aligned;
    /// each series is sorted defensively and channels are matched by name with
    /// a tolerant comparison, so "step time (ms)", "stepTime" and "step_time"
    /// all resolve to the same thing.
    public static func summarise(anomalies: [Anomaly], samples: SampleSet) -> InsightReport {
        var report = InsightReport()
        report.anomalies = anomalies.sorted { $0.time < $1.time }
        report.channelCount = samples.count

        var lowestTime = Double.greatestFiniteMagnitude
        var highestTime = -Double.greatestFiniteMagnitude
        for series in samples.values {
            for sample in series where sample.time.isFinite {
                lowestTime = Swift.min(lowestTime, sample.time)
                highestTime = Swift.max(highestTime, sample.time)
            }
            report.sampleCount = Swift.max(report.sampleCount, series.count)
        }
        report.duration = highestTime > lowestTime ? highestTime - lowestTime : 0

        if let stepTime = series(in: samples, role: .stepTime) {
            report.stepTime = SampleDistribution.make(from: stepTime.map(\.value))
        }
        if let residual = series(in: samples, role: .solverResidual) {
            report.solverResidual = SampleDistribution.make(from: residual.map(\.value))
        }
        if let contacts = series(in: samples, role: .contactCount) {
            report.contacts = contactSummary(contacts.map(\.value))
        }
        if let energy = series(in: samples, role: .energy) {
            report.energy = energySummary(sortedByTime(energy))
        }

        report.correlations = correlate(samples).map {
            ChannelCorrelation(a: $0.a, b: $0.b, r: $0.r,
                               sampleCount: Swift.min(samples[$0.a]?.count ?? 0,
                                                      samples[$0.b]?.count ?? 0))
        }
        report.headline = headline(for: report)
        report.advice = advice(for: report.anomalies)
        return report
    }

    private static func contactSummary(_ values: [Double]) -> ContactSummary {
        guard !values.isEmpty else { return ContactSummary() }
        let distribution = SampleDistribution.make(from: values)
        var touching = 0
        var changes = 0
        var previous = values[0]
        for (index, value) in values.enumerated() {
            if value > 0 { touching += 1 }
            if index > 0, value != previous { changes += 1 }
            previous = value
        }
        return ContactSummary(mean: distribution.mean,
                              p95: distribution.p95,
                              peak: distribution.maximum,
                              touchingFraction: Double(touching) / Double(values.count),
                              churnFraction: values.count > 1
                                  ? Double(changes) / Double(values.count - 1) : 0)
    }

    private static func energySummary(_ series: Series) -> EnergySummary {
        guard let first = series.first, let last = series.last else { return EnergySummary() }
        let initial = first.value
        let drift = last.value - initial
        var peak = 0.0
        for sample in series { peak = Swift.max(peak, abs(sample.value - initial)) }
        let span = last.time - first.time
        return EnergySummary(initial: initial,
                             final: last.value,
                             absoluteDrift: drift,
                             relativeDrift: abs(initial) > 1e-9 ? drift / abs(initial) : 0,
                             peakDeviation: peak,
                             driftPerSecond: span > 0 ? drift / span : 0)
    }

    // MARK: Headline

    /// One sentence, numbers included, written so it can go straight into a
    /// status bar without further processing.
    public static func headline(for report: InsightReport) -> String {
        var parts: [String] = []

        let duration = TelemetryFormat.duration(report.duration)
        if let worst = report.anomalies.max(by: { $0.severity < $1.severity }) {
            let others = report.anomalies.count - 1
            var opening = "\(report.anomalies.count) "
                + (report.anomalies.count == 1 ? "anomaly" : "anomalies")
                + " in \(duration) of simulation"
            if others > 0 { opening += ", worst" } else { opening += ":" }
            parts.append(opening + " \(worst.kind.label) on \(worst.channel) at "
                         + TelemetryFormat.time(worst.time) + ".")
        } else {
            parts.append("\(duration) simulated with nothing out of band.")
        }

        if let stepTime = report.stepTime, stepTime.count > 0 {
            parts.append("Step time p50 " + TelemetryFormat.number(stepTime.p50)
                         + " ms, p95 " + TelemetryFormat.number(stepTime.p95)
                         + " ms, max " + TelemetryFormat.number(stepTime.maximum) + " ms.")
        }
        if let contacts = report.contacts, contacts.peak > 0 {
            parts.append("Contacts averaged " + TelemetryFormat.count(contacts.mean)
                         + ", peaking at " + TelemetryFormat.count(contacts.peak) + ".")
        }
        if let energy = report.energy, energy.initial != 0 || energy.final != 0 {
            let direction = energy.absoluteDrift >= 0 ? "gained" : "lost"
            parts.append("Energy \(direction) "
                         + TelemetryFormat.percent(abs(energy.relativeDrift))
                         + " over the run.")
        }
        if let strongest = report.correlations.first, abs(strongest.r) >= 0.8 {
            parts.append("\(strongest.a) tracks \(strongest.b) at r = "
                         + String(format: "%.3f", strongest.r) + ".")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Advice

    /// Advice for the worst distinct problems in a run, worst first, one entry
    /// per (kind, role) pair so a hundred spikes on one channel do not fill the
    /// panel.
    public static func advice(for anomalies: [Anomaly], limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var advised = Set<String>()
        var out: [String] = []
        for anomaly in anomalies.sorted(by: { $0.severity > $1.severity }) {
            let key = anomaly.kind.rawValue + "/" + anomaly.role.rawValue
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let text = explain(anomaly)
            // Different roles can share advice - contact count and constraint
            // count lead to the same paragraph - so dedupe on the advice too,
            // not only on the pair that produced it.
            let tail = String(text.suffix(160))
            guard !advised.contains(tail) else { continue }
            advised.insert(tail)
            out.append(text)
            if out.count >= limit { break }
        }
        return out
    }

    /// Maps one detection to advice grounded in this engine's tuning knobs.
    ///
    /// Everything suggested here exists: `solverIterations`,
    /// `relaxationIterations`, `stiffnessTimeConstant`, `dampingRatio`,
    /// `armature`, `warmStart`, `friction`, `torsionalFriction`,
    /// `maxCorrectionVelocity`, `penetrationSlop`, `timestep`, `integrator`,
    /// `restitution`, `linearDamping` / `angularDamping`. The guidance follows
    /// the solver chapter's tuning table and the troubleshooting reference.
    public static func explain(_ anomaly: Anomaly) -> String {
        let when = TelemetryFormat.time(anomaly.time)

        switch (anomaly.kind, anomaly.role) {

        // --- Solver not converging -------------------------------------------------
        case (.constraintStress, _), (.spike, .solverResidual), (.drift, .solverResidual):
            var text = anomaly.explanation + " "
            text += "The sweep is not converging. In order: raise `solverIterations` "
            text += "(default 30) and `relaxationIterations` (default 6) and watch whether "
            text += "`world.profile.solverResidual` comes down - if it does not, iterations "
            text += "are not the problem. "
            if let contacts = anomaly.context[TelemetryChannelName.contactCount], contacts > 64 {
                text += "At " + TelemetryFormat.count(contacts) + " contacts the scene is "
                text += "probably over-constrained: look for redundant welds and loop "
                text += "closures, and for stacks where every body contacts every neighbour. "
            }
            text += "Then check mass ratios: above roughly 1e4 between contacting bodies every "
            text += "impulse solver goes compliant, and no iteration count rescues it. "
            text += "Confirm `warmStart` is on, since it is what carries impulses between steps."
            return text

        case (.spike, .stepTime), (.drift, .stepTime):
            var text = anomaly.explanation + " "
            text += "Step time is an output, not a cause - correlate it before tuning it. "
            text += "If contact count moved with it, the cost is collision and constraint "
            text += "setup: reduce geometry overlap, or split a large concave mesh into convex "
            text += "parts so the hulls are smaller. If contact count did not move, the cost is "
            text += "the sweep: `solverIterations` bounds it directly, and `torsionalFriction` "
            text += "adds a fourth row to every contact - roughly 30% of solver time in a "
            text += "contact-heavy scene - so enable it per material rather than globally."
            return text

        // --- Jitter and limit cycles ------------------------------------------------
        case (.oscillation, .jointPosition), (.oscillation, .jointVelocity),
             (.oscillation, .actuatorForce), (.oscillation, .height), (.oscillation, .sensor):
            var text = anomaly.explanation + " "
            text += "This is the classic jitter-at-rest signature. Add `armature` to the joints "
            text += "first: it is the single most effective fix for a jittering articulated "
            text += "robot, and a stack that wobbles usually has `armature` at zero. Then raise "
            text += "`stiffnessTimeConstant` (softer contacts settle more quietly) and push "
            text += "`dampingRatio` above 1. Confirm `warmStart` is on. If an actuator is "
            text += "driving the oscillation, its `kp` is too high for the step - lower it or "
            text += "raise `kd` before touching the solver."
            return text

        case (.oscillation, _):
            return anomaly.explanation
                + " Sustained sign flips at constant amplitude mean something is fighting"
                + " something else. Add `armature` to the joints, raise `dampingRatio` above 1,"
                + " and check whether an actuator gain is set for a larger timestep than the"
                + " one in use."

        // --- Blowing up --------------------------------------------------------------
        case (.divergence, _):
            var text = anomaly.explanation + " "
            text += "If this happened in the first steps, the cause is almost always "
            text += "overlapping geometry in the initial pose: deep overlap produces a large "
            text += "corrective impulse. Open the scene paused in Studio and look at the rest "
            text += "pose, lower `maxCorrectionVelocity` (default 3 m/s) so recovery is "
            text += "gentler, and remember that joint-adjacent pairs are filtered but "
            text += "grandparent/grandchild pairs are not - turn self-collision off for that "
            text += "articulation or set group masks. If it happened mid-run, the timestep is "
            text += "past the stable range for semi-implicit Euler: halve `timestep`, and for "
            text += "contact-free rotating bodies switch the integrator to `.rungeKutta4`."
            return text

        // --- Energy -------------------------------------------------------------------
        case (.drift, .energy), (.spike, .energy):
            let growing = anomaly.value > (anomaly.expectedLower + anomaly.expectedUpper) / 2
            if growing {
                var text = anomaly.explanation + " "
                text += "Energy should not grow. Check `restitution` first - a value above 1 is "
                text += "not physical and injects energy at every bounce. Then the timestep: "
                text += "very large steps push semi-implicit Euler past its stable range. For "
                text += "contact-free rotating bodies `.rungeKutta4` conserves noticeably "
                text += "better. If the growth coincides with contacts appearing, it is the "
                text += "contact solver, and lowering `stiffnessTimeConstant` toward "
                text += "`2 * timestep` will make the contacts stiffer and less springy."
                return text
            }
            return anomaly.explanation
                + " Energy falling is usually correct - contacts and dry friction dissipate,"
                + " and `linearDamping` / `angularDamping` remove more if they are non-zero."
                + " Worth a look only if the scene was meant to be conservative: check those"
                + " two damping options are zero and that `restitution` is what you intended."

        // --- Sinking / settling ---------------------------------------------------------
        case (.drift, .height):
            var text = anomaly.explanation + " "
            text += "A body that keeps sinking is a stack that has not converged, not a "
            text += "collision miss - speculative contacts mean a resting sphere sits at "
            text += "exactly its radius. Raise `solverIterations`, check `armature` is "
            text += "non-zero, and if the contacts feel spongy lower `stiffnessTimeConstant` "
            text += "toward `2 * timestep`. If the bodies differ in mass by more than about "
            text += "1e4, that compliance is expected and no amount of tuning removes it."
            return text

        case (.drift, .jointPosition), (.drift, .jointVelocity):
            var text = anomaly.explanation + " "
            text += "A joint walking away from its target usually means the load is winning. "
            text += "If it is sliding contact, raise `friction` and add `torsionalFriction` to "
            text += "the material where bodies pivot in place - point friction cannot stop a "
            text += "sphere or a foot spinning. If it is the actuator, check its `forceRange` "
            text += "and the joint's `effortLimit` are not clamping the command."
            return text

        // --- Frozen channels ---------------------------------------------------------------
        case (.stall, .jointPosition), (.stall, .jointVelocity), (.stall, .actuatorForce):
            var text = anomaly.explanation + " "
            text += "Work down the list: is the joint's `kind` `.fixed`? Are its limits equal "
            text += "(`lower == upper`)? Is `damping` very large - implicit damping is stable, "
            text += "so a large value silently freezes a joint instead of making it oscillate? "
            text += "Is an actuator holding it at a target? Position actuators default to a "
            text += "control input of zero, so seed `world.control` after `compile()` rather "
            text += "than relying on the default pose. The Joints tab in Studio will drag it "
            text += "directly and show you what stops it."
            return text

        case (.stall, .sensor):
            return anomaly.explanation
                + " A sensor pinned to one value is usually a sensor reading a link that is not"
                + " moving, or one whose `cutoff` is clamping it. Check the sensor's `link` and"
                + " `cutoff`, and plot the joint it is attached to alongside it - if the joint"
                + " moves and the sensor does not, the specification is pointing at the wrong"
                + " body."

        case (.stall, _):
            return anomaly.explanation
                + " Confirm whoever writes this channel is still running: a channel frozen to"
                + " the bit is more often a stalled producer than a stalled simulation."

        // --- Contract violations ------------------------------------------------------------
        case (.rangeViolation, .contactCount), (.rangeViolation, .constraintCount),
             (.rangeViolation, .solverIterations), (.rangeViolation, .solverResidual):
            return anomaly.explanation
                + " These come straight from `world.profile` and cannot legitimately go"
                + " negative or non-finite. Treat it as a defect in the step that produced it"
                + " and file the scene - `kinetic validate` checks the solver's invariants on"
                + " every run."

        case (.rangeViolation, .jointPosition):
            return anomaly.explanation
                + " A joint outside its declared limits means the limit constraint was dropped"
                + " or overpowered. Limits activate within 30 mrad of the bound, so an"
                + " overshoot this large points at `enableJointLimits` being off, at a"
                + " conflicting equality constraint, or at an actuator whose `effortLimit`"
                + " exceeds what the limit row can resist - raise `solverIterations` and check"
                + " the joint is actually `limited`."

        case (.rangeViolation, _):
            return anomaly.explanation
                + " The channel left the range it was registered with. Either the hint is"
                + " wrong or the producer is; check the hint first, since it is the cheaper of"
                + " the two to be wrong about."

        // --- Contacts -------------------------------------------------------------------------
        case (.spike, .contactCount), (.drift, .contactCount), (.spike, .constraintCount):
            var text = anomaly.explanation + " "
            text += "A jump in contact count is either new geometry arriving or existing "
            text += "geometry interpenetrating. Check the pair with the Contacts panel at "
            text += when + ". Remember a concave mesh collides as its convex hull, so a "
            text += "concave part can generate contacts where the visual mesh has a hole - "
            text += "decompose it into convex parts upstream and attach one geom per part. If "
            text += "the count jumped without anything moving, `contactMargin` may be wide "
            text += "enough to be generating speculative contacts you did not expect."
            return text

        // --- Learned ---------------------------------------------------------------------------
        case (.jointPattern, _):
            return anomaly.explanation
                + " Nothing here is out of band on its own, so start with the correlations:"
                + " the pair whose usual relationship broke is the lead. In practice this fires"
                + " when step time and contact count decouple - the solver is doing more work"
                + " per contact than it used to, which is what an over-constrained island or a"
                + " newly extreme mass ratio looks like from the outside."

        // --- Fallback ---------------------------------------------------------------------------
        case (.spike, _), (.drift, _):
            return anomaly.explanation
                + " Plot this channel against contact count and solver residual around "
                + when + "; on this engine those two explain most of what surprises people."
        }
    }

    // MARK: Correlation

    /// Pearson correlation between every pair of channels, strongest first.
    ///
    /// Channels are sampled at the same steps in practice, but not necessarily
    /// at the same instants, so each pair is aligned by linear interpolation
    /// onto the sparser channel's timestamps over the overlapping interval.
    /// Constant channels are skipped - r is undefined there, not zero.
    public static func correlate(_ samples: SampleSet) -> [(a: String, b: String, r: Double)] {
        // Densest channels first, then capped: the pair sweep is quadratic and
        // a Studio session can have a channel per degree of freedom.
        let names = samples.keys
            .filter { (samples[$0]?.count ?? 0) >= 8 }
            .sorted { lhs, rhs in
                let left = samples[lhs]?.count ?? 0
                let right = samples[rhs]?.count ?? 0
                return left == right ? lhs < rhs : left > right
            }
            .prefix(maximumCorrelatedChannels)

        var prepared: [String: Series] = [:]
        for name in names {
            if let series = samples[name] { prepared[name] = sortedByTime(series) }
        }

        let ordered = Array(names)
        var out: [(a: String, b: String, r: Double)] = []
        for i in 0..<ordered.count {
            for j in (i + 1)..<ordered.count {
                guard let left = prepared[ordered[i]], let right = prepared[ordered[j]] else {
                    continue
                }
                guard let r = pearson(left, right), abs(r) >= correlationFloor else { continue }
                out.append((a: ordered[i], b: ordered[j], r: r))
            }
        }
        out.sort { abs($0.r) > abs($1.r) }
        return out
    }

    /// Pearson r for two time series, or `nil` when the pair does not overlap
    /// enough or one of them never moves.
    private static func pearson(_ first: Series, _ second: Series) -> Double? {
        guard first.count >= 8, second.count >= 8 else { return nil }
        // Align onto whichever series is sparser: interpolating the dense one is
        // information-preserving, inventing samples for the sparse one is not.
        let (grid, other) = first.count <= second.count ? (first, second) : (second, first)
        guard let lowest = other.first?.time, let highest = other.last?.time else { return nil }

        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(grid.count)
        ys.reserveCapacity(grid.count)

        var cursor = 0
        for sample in grid {
            guard sample.time >= lowest, sample.time <= highest, sample.value.isFinite else {
                continue
            }
            while cursor + 1 < other.count && other[cursor + 1].time < sample.time { cursor += 1 }
            let lower = other[cursor]
            let upper = cursor + 1 < other.count ? other[cursor + 1] : other[cursor]
            let span = upper.time - lower.time
            let interpolated: Double
            if span > 0 {
                let t = (sample.time - lower.time) / span
                interpolated = lower.value + t * (upper.value - lower.value)
            } else {
                interpolated = lower.value
            }
            guard interpolated.isFinite else { continue }
            xs.append(sample.value)
            ys.append(interpolated)
        }

        guard xs.count >= 8 else { return nil }
        let n = Double(xs.count)
        var meanX = 0.0
        var meanY = 0.0
        for index in 0..<xs.count {
            meanX += xs[index]
            meanY += ys[index]
        }
        meanX /= n
        meanY /= n

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for index in 0..<xs.count {
            let dx = xs[index] - meanX
            let dy = ys[index] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        let denominator = (varianceX * varianceY).squareRoot()
        guard denominator > 0, denominator.isFinite else { return nil }
        let r = covariance / denominator
        guard r.isFinite else { return nil }
        return Swift.min(1, Swift.max(-1, r))
    }

    // MARK: Channel lookup

    /// Finds the series for a well-known role, tolerating naming differences
    /// between producers. Studio's labels are the canonical spelling; anything
    /// that normalises to the same token set matches.
    public static func series(in samples: SampleSet, role: ChannelRole) -> Series? {
        let candidates: [String]
        switch role {
        case .stepTime: candidates = ["steptimems", "steptime", "step", "totalsteptime"]
        case .contactCount: candidates = ["contacts", "contactcount"]
        case .constraintCount: candidates = ["constraints", "constraintcount"]
        case .solverIterations: candidates = ["solveriterations", "iterations"]
        case .solverResidual: candidates = ["solverresidual", "residual"]
        case .energy: candidates = ["totalenergyj", "totalenergy", "energy"]
        case .height: candidates = ["comheightm", "comheight", "height"]
        default: return nil
        }
        for name in samples.keys.sorted() where candidates.contains(normalise(name)) {
            return samples[name]
        }
        return nil
    }

    /// Lowercase, letters and digits only: "step time (ms)" -> "steptimems".
    private static func normalise(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for character in name.lowercased() where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    private static func sortedByTime(_ series: Series) -> Series {
        var isSorted = true
        for index in 1..<Swift.max(series.count, 1) where series[index].time < series[index - 1].time {
            isSorted = false
            break
        }
        return isSorted ? series : series.sorted { $0.time < $1.time }
    }

    // MARK: Encoding

    /// A JSON encoder that survives a report containing a divergence.
    /// `Anomaly.value` is deliberately left as it was observed, and the
    /// observed value of a divergence is sometimes infinite or NaN, which the
    /// default encoder refuses to write.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy =
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy =
            .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}
