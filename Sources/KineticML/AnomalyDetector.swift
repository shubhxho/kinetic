//
//  AnomalyDetector.swift
//  KineticML
//
//  Online detection of "something went wrong, and here is when" over the scalar
//  channels a running world exposes: step time, contact count, solver residual,
//  energy, joint coordinates, sensor readings.
//
//  Design constraints that shaped this file:
//
//  * The detector is called once per simulated step, at up to 2 kHz, from the
//    thread that owns the world. `observe` therefore does no allocation, no
//    string formatting and no dictionary insertion in steady state. All the
//    per-channel state is a struct in a contiguous array; explanations are only
//    built in the branch where an anomaly actually fires.
//  * Everything is single-threaded by construction. There is no lock and no
//    global mutable state: hand one detector to one stepping thread. That is
//    cheaper and less surprising than pretending an anomaly detector is a
//    concurrent data structure.
//  * Several of the tests below are heuristics, not theorems. Where a threshold
//    was picked because it behaved well on this engine's scenes rather than
//    because it falls out of a distribution, the comment says so.
//

import Foundation

// MARK: - Channel semantics

/// What a channel *is*, so the detector can be specific rather than generic.
///
/// The role travels with the anomaly, which is how `TelemetryInsight.explain`
/// can give advice about `armature` or `stiffnessTimeConstant` instead of
/// "a channel exceeded its threshold".
public enum ChannelRole: String, Codable, Sendable, CaseIterable {
    case other
    case stepTime
    case contactCount
    case constraintCount
    case solverIterations
    case solverResidual
    case energy
    case height
    case jointPosition
    case jointVelocity
    case actuatorForce
    case sensor
    /// The multi-channel reconstruction score produced by the learned mode.
    case jointPattern
}

/// Declarations about a channel that let the detector be smart.
///
/// A z-score on its own is a poor detector for most of what a physics engine
/// emits: contact counts are integers with a floor at zero, solver residuals
/// are heavy-tailed and spend most of their life near machine epsilon, and a
/// joint holding a target legitimately never changes. Each of those needs a
/// different default, and the caller is the only one who knows which is which.
public struct ChannelHint: Codable, Sendable, Equatable {

    /// Sign structure. A `nonNegative` channel that goes negative is a bug in
    /// the producer, not a statistical event, and is reported immediately.
    public enum Sign: String, Codable, Sendable {
        case any
        case nonNegative
        case positive
    }

    /// Direction the channel is contractually allowed to move.
    public enum Monotonicity: String, Codable, Sendable {
        case none
        case nonDecreasing
        case nonIncreasing
    }

    /// Used only for formatting explanations. Kinetic is metres / kilograms /
    /// seconds / radians throughout, except `StepProfile` timings, which are
    /// milliseconds.
    public enum Unit: String, Codable, Sendable {
        case dimensionless
        case milliseconds
        case seconds
        case count
        case joules
        case metres
        case newtons
        case radians
    }

    public var role: ChannelRole = .other
    public var sign: Sign = .any
    public var monotonicity: Monotonicity = .none
    public var unit: Unit = .dimensionless

    /// A hard band the channel is known to live in, when one exists (joint
    /// limits, a sensor range). Leaving this `nil` is normal.
    public var bounds: ClosedRange<Double>?

    /// Score against the median / MAD rather than the mean / standard
    /// deviation. Set this for anything with a long right tail: step time
    /// (one page fault ruins the mean), contact count, solver residual. A
    /// plain z-score on those channels cries wolf on every sample that is
    /// merely large.
    public var heavyTailed: Bool = false

    /// Whether a channel that stops changing is suspicious. False for most
    /// channels: a settled scene holding 84 contacts is the goal, not a
    /// fault. True for sensors and actuator forces, where a value frozen to
    /// the bit is usually a dead reading or a saturated actuator.
    public var expectedToVary: Bool = false

    /// Absolute magnitude below which changes are considered noise. Every
    /// scale in the detector is floored by
    /// `max(robust scale, noiseFloor, |median| * relativeNoiseFloor)`, which is
    /// what stops a perfectly smooth channel from flagging its own quantisation.
    public var noiseFloor: Double = 0
    public var relativeNoiseFloor: Double = 1e-3

    /// A step-to-step change no larger than this counts as "did not change".
    public var quiescenceTolerance: Double = 0

    /// Robust (or standard) scores above this fire a `spike`.
    public var spikeThreshold: Double = 6

    /// A `stall` needs the channel to be quiescent for this long, in seconds of
    /// simulated time.
    public var stallDuration: Double = 0.25

    /// `drift` needs the fast average to sit this many scales away from the
    /// slow baseline, in one direction, for this long.
    public var driftThreshold: Double = 4
    public var driftDuration: Double = 1.0

    /// `oscillation` needs this many baseline crossings inside a window of this
    /// length, with roughly constant amplitude and a roughly constant period.
    ///
    /// Crossings rather than sign flips of the step-to-step delta: white noise
    /// flips its delta on roughly every other sample, so a delta-based test
    /// calls every noisy channel a limit cycle. Ten crossings in half a second
    /// is a 10 Hz floor on what can be detected.
    public var oscillationFlips: Int = 10
    public var oscillationWindow: Double = 0.5

    /// `divergence` needs the magnitude to grow by at least this factor for
    /// this many consecutive samples. Geometric growth sustained over a dozen
    /// steps is the signature of an unstable integration, and unlike a fixed
    /// ceiling it does not need to know the scene's scale. Non-finite values
    /// fire immediately and bypass the warm-up.
    public var divergenceGrowth: Double = 1.08
    public var divergenceRun: Int = 12

    /// `constraintStress`: value staying above this for `elevatedDuration`.
    /// Only meaningful for residual-like channels; `nil` disables the test.
    public var elevatedThreshold: Double?
    public var elevatedDuration: Double = 0.05

    /// Minimum simulated time between two anomalies of the same kind on this
    /// channel. Without it, a 2 kHz loop turns one event into two thousand.
    public var refractory: Double = 0.5

    /// Samples required before this channel can fire anything except a
    /// non-finite divergence.
    public var warmupSamples: Int = 200

    /// EWMA gain for the "fast" average; the slow baseline uses this / 64.
    ///
    /// Per *sample*, not per second. At the 2 kHz this is tuned for, 0.02 is a
    /// 25 ms fast average against a 1.6 s baseline. A caller sampling at 60 Hz
    /// should raise it, or drift will take a minute to notice anything.
    public var smoothing: Double = 0.02

    public init() {}

    // MARK: Presets

    /// Sensible defaults for a channel nothing is known about.
    public static let generic = ChannelHint()

    /// `world.profile.total`, in milliseconds.
    ///
    /// Heavy-tailed by nature: the OS steals the core occasionally and the
    /// mean never recovers. Stall detection is off because a constant step
    /// time is the happy path.
    public static var stepTime: ChannelHint {
        var hint = ChannelHint()
        hint.role = .stepTime
        hint.sign = .nonNegative
        hint.unit = .milliseconds
        hint.heavyTailed = true
        hint.spikeThreshold = 8
        hint.noiseFloor = 0.05          // 50 us: below this nobody cares
        hint.refractory = 0.25
        return hint
    }

    /// `world.profile.contactCount`.
    ///
    /// An integer channel, so the quiescence tolerance is half a count and the
    /// noise floor is two contacts: a scene breathing between 80 and 82
    /// contacts is not news.
    public static var contactCount: ChannelHint {
        var hint = ChannelHint()
        hint.role = .contactCount
        hint.sign = .nonNegative
        hint.unit = .count
        hint.heavyTailed = true
        hint.quiescenceTolerance = 0.5
        hint.noiseFloor = 2
        hint.spikeThreshold = 8
        return hint
    }

    /// `world.profile.solverResidual`.
    ///
    /// The 1e-3 elevated threshold is the engine's own rule of thumb: the
    /// solver tuning table treats a residual that "stays high" as the symptom
    /// of an over-constrained scene or a mass ratio above 1e4. 50 ms of
    /// simulated time is long enough that a single hard step does not count.
    public static var solverResidual: ChannelHint {
        var hint = ChannelHint()
        hint.role = .solverResidual
        hint.sign = .nonNegative
        hint.heavyTailed = true
        hint.spikeThreshold = 10
        hint.noiseFloor = 1e-9
        hint.elevatedThreshold = 1e-3
        hint.elevatedDuration = 0.05
        hint.refractory = 1.0
        return hint
    }

    /// `world.profile.constraintCount`.
    public static var constraintCount: ChannelHint {
        var hint = ChannelHint()
        hint.role = .constraintCount
        hint.sign = .nonNegative
        hint.unit = .count
        hint.heavyTailed = true
        hint.quiescenceTolerance = 0.5
        hint.noiseFloor = 4
        return hint
    }

    /// `world.profile.solverIterations` - what the sweep actually did.
    public static var solverIterations: ChannelHint {
        var hint = ChannelHint()
        hint.role = .solverIterations
        hint.sign = .nonNegative
        hint.unit = .count
        hint.heavyTailed = true
        hint.quiescenceTolerance = 0.5
        hint.noiseFloor = 2
        return hint
    }

    /// `world.totalEnergy`. Drift is the interesting mode here, not spikes.
    public static var energy: ChannelHint {
        var hint = ChannelHint()
        hint.role = .energy
        hint.unit = .joules
        hint.driftThreshold = 3
        hint.driftDuration = 0.5
        hint.spikeThreshold = 9
        hint.relativeNoiseFloor = 2e-3   // 0.2% of the current level
        return hint
    }

    /// `world.centerOfMass.z`, or any other height-like channel.
    public static var height: ChannelHint {
        var hint = ChannelHint()
        hint.role = .height
        hint.unit = .metres
        hint.noiseFloor = 1e-5           // 10 um of settle is not a drift
        hint.oscillationFlips = 12
        return hint
    }

    public static var jointPosition: ChannelHint {
        var hint = ChannelHint()
        hint.role = .jointPosition
        hint.unit = .radians
        hint.noiseFloor = 1e-5
        return hint
    }

    public static var jointVelocity: ChannelHint {
        var hint = ChannelHint()
        hint.role = .jointVelocity
        hint.unit = .dimensionless
        hint.noiseFloor = 1e-4
        return hint
    }

    /// Actuator force. Expected to vary: an actuator whose force is frozen to
    /// the bit for a quarter second is either unhooked or hard against a limit.
    public static var actuatorForce: ChannelHint {
        var hint = ChannelHint()
        hint.role = .actuatorForce
        hint.unit = .newtons
        hint.expectedToVary = true
        hint.noiseFloor = 1e-4
        return hint
    }

    /// Sensor reading. Same reasoning as `actuatorForce`.
    public static var sensor: ChannelHint {
        var hint = ChannelHint()
        hint.role = .sensor
        hint.expectedToVary = true
        hint.noiseFloor = 1e-6
        return hint
    }
}

// MARK: - Statistics

/// Streaming summary of one channel.
///
/// Three estimators, because no single one covers the failure modes:
///
/// * Welford mean / variance - exact, non-catastrophic, describes the whole run.
/// * EWMA mean / variance - forgets, so it tracks the level the channel is at
///   *now* rather than the level it started at.
/// * An online median and median-absolute-deviation - robust. Solver residuals
///   and contact counts are heavy-tailed enough that one 200x sample inflates
///   the standard deviation permanently, after which nothing ever looks
///   anomalous again. The MAD does not move.
///
/// All updates are O(1) with no allocation.
public struct ChannelStatistics: Codable, Sendable {

    public private(set) var count: Int = 0
    public private(set) var mean: Double = 0
    public private(set) var minimum: Double = .greatestFiniteMagnitude
    public private(set) var maximum: Double = -.greatestFiniteMagnitude
    public private(set) var last: Double = 0
    public private(set) var lastTime: Double = 0
    public private(set) var firstTime: Double = 0

    /// Exponentially weighted mean and variance (West's incremental form).
    public private(set) var ewmaMean: Double = 0
    public private(set) var ewmaVariance: Double = 0

    /// Robust centre and spread.
    public private(set) var median: Double = 0
    public private(set) var medianAbsoluteDeviation: Double = 0

    /// Welford's M2.
    private var sumOfSquaredDeviations: Double = 0
    /// Mean |x - mean| during bootstrap, used to seed the MAD.
    private var bootstrapDeviation: Double = 0

    public var smoothing: Double
    /// Fraction of the current MAD the median moves per sample once the
    /// stochastic update takes over. 0.05 converges in a few hundred samples
    /// and is slow enough that a spike cannot drag the baseline with it -
    /// tuned by hand on this engine's scenes, not derived.
    public var medianStepGain: Double

    /// Samples spent seeding the median from the mean before the stochastic
    /// update takes over. Below this the sign-step estimator has no scale to
    /// step by.
    private static let bootstrapSamples = 32

    public init(smoothing: Double = 0.02, medianStepGain: Double = 0.05) {
        self.smoothing = smoothing
        self.medianStepGain = medianStepGain
    }

    public var variance: Double {
        count > 1 ? sumOfSquaredDeviations / Double(count - 1) : 0
    }

    public var standardDeviation: Double { variance.squareRoot() }
    public var ewmaStandardDeviation: Double { ewmaVariance.squareRoot() }

    /// MAD rescaled to a standard-deviation equivalent for a normal sample.
    /// The 1.4826 is the usual consistency constant.
    public var robustScale: Double { 1.4826 * medianAbsoluteDeviation }

    /// Signed deviation in standard deviations. Returns 0 when there is no
    /// spread to speak of, rather than an infinity.
    public func zScore(_ value: Double) -> Double {
        zScore(value, floor: 0)
    }

    /// Signed deviation in standard deviations, with the denominator floored.
    ///
    /// The floor matters more than it looks. A channel held to within a
    /// microradian has a standard deviation near zero, and any real motion
    /// then scores in the thousands - a true detection wrapped in a number no
    /// one can act on.
    public func zScore(_ value: Double, floor: Double) -> Double {
        let sigma = Swift.max(standardDeviation, floor)
        guard sigma > 0, sigma.isFinite else { return 0 }
        return (value - mean) / sigma
    }

    /// Signed deviation in robust scales.
    public func robustScore(_ value: Double, floor: Double) -> Double {
        let scale = Swift.max(robustScale, floor)
        guard scale > 0, scale.isFinite else { return 0 }
        return (value - median) / scale
    }

    public mutating func update(_ value: Double, at time: Double) {
        guard value.isFinite else { return }   // never poison the estimators

        count += 1
        if count == 1 {
            mean = value
            ewmaMean = value
            median = value
            firstTime = time
        } else {
            let delta = value - mean
            mean += delta / Double(count)
            sumOfSquaredDeviations += delta * (value - mean)

            let ewDelta = value - ewmaMean
            ewmaMean += smoothing * ewDelta
            ewmaVariance = (1 - smoothing) * (ewmaVariance + smoothing * ewDelta * ewDelta)

            if count <= ChannelStatistics.bootstrapSamples {
                // Seed phase: the mean is a fine centre and the mean absolute
                // deviation is a fine scale, and both exist from sample two.
                median = mean
                let deviation = abs(value - mean)
                bootstrapDeviation += (deviation - bootstrapDeviation) / Double(count)
                medianAbsoluteDeviation = bootstrapDeviation
            } else {
                // Stochastic median: step a fixed fraction of the current
                // spread toward the sample. This is the Ma/Muthukrishnan style
                // estimator - cheap, allocation-free, and deliberately slow, so
                // a burst of outliers cannot move the baseline. It is an
                // approximation: on a channel with a genuine step change it
                // takes a few hundred samples to catch up.
                let step = Swift.max(medianStepGain * medianAbsoluteDeviation, 0)
                if value > median {
                    median += step
                } else if value < median {
                    median -= step
                }
                let deviation = abs(value - median)
                medianAbsoluteDeviation += smoothing * (deviation - medianAbsoluteDeviation)
            }
        }

        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
        last = value
        lastTime = time
    }

    public mutating func reset() {
        let keptSmoothing = smoothing
        let keptGain = medianStepGain
        self = ChannelStatistics(smoothing: keptSmoothing, medianStepGain: keptGain)
    }
}

// MARK: - Anomalies

public enum AnomalyKind: String, Codable, Sendable, CaseIterable {
    /// A single sample far outside the channel's robust band.
    case spike
    /// A channel that stopped changing when the hint says it should not have.
    case stall
    /// Slow, one-directional departure of the fast average from the baseline.
    case drift
    /// Sustained sign flips of the step-to-step delta at roughly constant
    /// amplitude - jitter, limit cycling, a controller fighting itself.
    case oscillation
    /// Magnitude growing geometrically, or a value that is no longer finite.
    case divergence
    /// A residual-like channel holding above its threshold.
    case constraintStress
    /// The channel left the band its hint promised: a negative count, a value
    /// outside declared bounds, a monotone channel going backwards.
    case rangeViolation
    /// Learned mode only: the *combination* of channels is unlike anything
    /// seen during training, while no single channel left its own band.
    case jointPattern

    /// Short human label, used in headlines.
    public var label: String {
        switch self {
        case .spike: return "spike"
        case .stall: return "stall"
        case .drift: return "drift"
        case .oscillation: return "oscillation"
        case .divergence: return "divergence"
        case .constraintStress: return "solver stress"
        case .rangeViolation: return "range violation"
        case .jointPattern: return "joint pattern"
        }
    }

    /// True for detections produced by the learned model rather than by the
    /// per-channel statistics.
    public var isLearned: Bool { self == .jointPattern }
}

/// One detection, with everything a human needs to act on it.
public struct Anomaly: Identifiable, Codable, Sendable, Equatable {

    public let id: UUID
    public let channel: String
    public let role: ChannelRole
    public let kind: AnomalyKind
    /// Simulated time at which the detection fired.
    public let time: Double
    /// How long the condition had been true when it fired, in simulated
    /// seconds. Zero for instantaneous detections such as a spike.
    public let duration: Double
    /// 0...1. Comparable within a kind; only roughly comparable across kinds.
    public let severity: Double
    public let value: Double
    /// Where the detector expected the value to be.
    public let expectedLower: Double
    public let expectedUpper: Double
    /// Written at fire time, in words, with the numbers in it.
    public let explanation: String
    /// Whatever other channels were worth quoting, by name.
    public let context: [String: Double]

    public var expectedBand: ClosedRange<Double> {
        expectedLower <= expectedUpper ? expectedLower...expectedUpper : expectedUpper...expectedLower
    }

    public init(id: UUID = UUID(),
                channel: String,
                role: ChannelRole,
                kind: AnomalyKind,
                time: Double,
                duration: Double = 0,
                severity: Double,
                value: Double,
                expectedLower: Double,
                expectedUpper: Double,
                explanation: String,
                context: [String: Double] = [:]) {
        self.id = id
        self.channel = channel
        self.role = role
        self.kind = kind
        self.time = time
        self.duration = duration
        self.severity = Swift.min(1, Swift.max(0, severity))
        self.value = value
        self.expectedLower = expectedLower
        self.expectedUpper = expectedUpper
        self.explanation = explanation
        self.context = context
    }
}

// MARK: - Learned mode

/// The learned half of the detector, kept behind a protocol so the model
/// implementation can move without this file moving.
///
/// An implementation backed by `MLPSpec` / `MLP` / `Trainer.fitRegression`
/// trains an autoencoder - input dimension in, small bottleneck, input
/// dimension out - and returns the squared reconstruction error.
public protocol JointPatternModel: AnyObject {
    /// Flattened window length the model expects: channels * windowSteps.
    var inputDimension: Int { get }
    /// Called once, off the hot path, with the windows collected during
    /// warm-up. Throwing leaves the detector in its statistical-only mode.
    func fit(windows: [[Double]]) throws
    /// Reconstruction error for one flattened window. Must not allocate.
    func reconstructionError(_ window: UnsafeBufferPointer<Double>) -> Double
}

/// Why the learned mode is or is not running. Worth surfacing in the UI: a
/// silent fallback looks identical to "nothing is wrong".
public enum LearnedModeStatus: String, Codable, Sendable {
    case disabled
    case runtimeUnavailable
    case modelUnavailable
    case collecting
    case active
    case trainingFailed
}

/// Configuration for the multi-channel reconstruction detector.
///
/// This catches the case no per-channel test can: contact count normal, step
/// time normal, but that step time *at that contact count* has never been seen
/// before. The window gives it a little history, so a transient combination
/// that only makes sense as a sequence is also visible.
public struct LearnedModeConfiguration {

    public var isEnabled: Bool = false
    /// Channels forming the vector, in a fixed order. All must be registered.
    public var channels: [String] = []
    /// How many consecutive steps go into one window.
    public var windowSteps: Int = 16
    /// Windows collected before fitting. Collection allocates; scoring does not.
    public var trainingWindows: Int = 512
    /// Score every Nth step. The window moves by one step at a time, so
    /// consecutive scores are almost identical and scoring all of them is
    /// mostly wasted work.
    public var evaluationStride: Int = 8
    /// Robust scores of the reconstruction error above this fire.
    public var threshold: Double = 8
    public var refractory: Double = 1.0

    /// The single point of contact with the ML runtime. Swap it in tests, and
    /// reconcile it here if the runtime's spelling differs.
    public var isRuntimeAvailable: () -> Bool = { MLRuntime.isAvailable }

    /// Builds the model for a given flattened input dimension. Returning `nil`
    /// - which is the default - leaves the detector purely statistical.
    public var makeModel: (Int) -> JointPatternModel? = { _ in nil }

    public init() {}
}

// MARK: - Step statistics

/// The solver statistics `observeStep` needs.
///
/// Deliberately a protocol rather than a dependency on the physics module:
/// `Kinetic.StepProfile` already has every one of these members with these
/// names, so integration is the one line
/// `extension StepProfile: SolverStepStatistics {}`.
public protocol SolverStepStatistics {
    /// Total step time, in milliseconds.
    var total: Double { get }
    /// Broadphase plus narrowphase time, in milliseconds.
    var collision: Double { get }
    /// Constraint sweep time, in milliseconds.
    var solve: Double { get }
    var contactCount: Int { get }
    var constraintCount: Int { get }
    /// Iterations the sweep actually ran before hitting tolerance.
    var solverIterations: Int { get }
    var solverResidual: Double { get }
}

/// A plain value conforming to `SolverStepStatistics`, for callers that do not
/// have a `StepProfile` to hand (replayed logs, tests).
public struct StepStatistics: SolverStepStatistics, Sendable, Codable, Equatable {
    public var total: Double
    public var collision: Double
    public var solve: Double
    public var contactCount: Int
    public var constraintCount: Int
    public var solverIterations: Int
    public var solverResidual: Double

    public init(total: Double = 0, collision: Double = 0, solve: Double = 0,
                contactCount: Int = 0, constraintCount: Int = 0,
                solverIterations: Int = 0, solverResidual: Double = 0) {
        self.total = total
        self.collision = collision
        self.solve = solve
        self.contactCount = contactCount
        self.constraintCount = constraintCount
        self.solverIterations = solverIterations
        self.solverResidual = solverResidual
    }
}

/// Canonical channel names. These match the labels Studio already plots, so an
/// anomaly and a plot line refer to the same string.
public enum TelemetryChannelName {
    public static let stepTime = "step time (ms)"
    public static let collisionTime = "collision time (ms)"
    public static let solveTime = "solve time (ms)"
    public static let contactCount = "contacts"
    public static let constraintCount = "constraints"
    public static let solverIterations = "solver iterations"
    public static let solverResidual = "solver residual"
    public static let totalEnergy = "total energy (J)"
    public static let comHeight = "com height (m)"
    /// Synthetic channel the learned mode reports against.
    public static let jointPattern = "channel vector"
}

// MARK: - Detector

/// Watches named scalar channels and reports, in words, when one of them - or
/// the combination of several - stops making sense.
///
/// Threading: not internally synchronised, and deliberately so. Every field is
/// a value type owned by this instance; give one detector to the thread that
/// steps the world and read the results from `drainAnomalies()`.
public final class AnomalyDetector {

    public struct Configuration {
        /// Simulated seconds during which nothing fires. The first steps of a
        /// run are dominated by settling and by cold caches, and firing on
        /// them teaches users to ignore the detector.
        public var warmupDuration: Double = 0.25
        /// Samples required in addition to the warm-up duration.
        public var minimumSamples: Int = 100
        /// Cap on the retained history. Detections are cheap to make and
        /// expensive to scroll.
        public var maximumRetainedAnomalies: Int = 512
        public var learned = LearnedModeConfiguration()

        public init() {}
    }

    public private(set) var configuration: Configuration

    // MARK: Per-channel state

    /// Refractory clocks, one per kind, held inline. An array here would be an
    /// allocation per channel and a bounds check per sample; there are eight
    /// kinds and they are not going to multiply.
    private struct RefractoryClocks {
        var spike = -Double.greatestFiniteMagnitude
        var stall = -Double.greatestFiniteMagnitude
        var drift = -Double.greatestFiniteMagnitude
        var oscillation = -Double.greatestFiniteMagnitude
        var divergence = -Double.greatestFiniteMagnitude
        var constraintStress = -Double.greatestFiniteMagnitude
        var rangeViolation = -Double.greatestFiniteMagnitude
        var jointPattern = -Double.greatestFiniteMagnitude

        func last(_ kind: AnomalyKind) -> Double {
            switch kind {
            case .spike: return spike
            case .stall: return stall
            case .drift: return drift
            case .oscillation: return oscillation
            case .divergence: return divergence
            case .constraintStress: return constraintStress
            case .rangeViolation: return rangeViolation
            case .jointPattern: return jointPattern
            }
        }

        mutating func mark(_ kind: AnomalyKind, at time: Double) {
            switch kind {
            case .spike: spike = time
            case .stall: stall = time
            case .drift: drift = time
            case .oscillation: oscillation = time
            case .divergence: divergence = time
            case .constraintStress: constraintStress = time
            case .rangeViolation: rangeViolation = time
            case .jointPattern: jointPattern = time
            }
        }
    }

    private struct ChannelState {
        let name: String
        var hint: ChannelHint
        var stats: ChannelStatistics

        var previous: Double = 0
        var hasPrevious = false

        // Slow baseline for drift, deliberately much slower than the EWMA in
        // `stats` so the two can separate.
        var slowMean: Double = 0

        // stall
        var quietSince: Double = 0
        var isQuiet = false

        // drift
        var driftSince: Double = 0
        var driftSign: Int = 0

        // oscillation: half cycles of the deviation from the slow baseline
        var crossingSign: Int = 0
        var halfCyclePeak: Double = 0
        var halfCycleStart: Double = 0
        var crossingCount: Int = 0
        var flipWindowStart: Double = 0
        var amplitudeMin: Double = .greatestFiniteMagnitude
        var amplitudeMax: Double = 0
        var amplitudeSum: Double = 0
        var halfCycleMin: Double = .greatestFiniteMagnitude
        var halfCycleMax: Double = 0

        // divergence
        var growthRun: Int = 0

        // constraint stress
        var elevatedSince: Double = 0
        var isElevated = false

        /// Mean interval between samples, so the oscillation test can reject
        /// half cycles that are only a sample or two long.
        var sampleInterval: Double = 0

        // Escalation memory: how bad it was the last time each of the
        // continuous conditions was reported. A condition that persists is
        // re-reported only when it gets materially worse, which is what stops
        // one ongoing problem from filling the panel.
        var lastDriftScore: Double = 0
        var lastStressHold: Double = 0
        var lastStallHold: Double = 0
        var lastOscillationAmplitude: Double = 0

        var refractory = RefractoryClocks()

        init(name: String, hint: ChannelHint) {
            self.name = name
            self.hint = hint
            self.stats = ChannelStatistics(smoothing: hint.smoothing)
        }
    }

    private var states: [ChannelState] = []
    /// Name to index. Written by `register`, read in the hot path. Callers that
    /// care about the last nanosecond should cache `index(of:)` and use the
    /// index-based `observe`.
    private var indexByName: [String: Int] = [:]
    /// Fast lookups for cross-channel context in explanations.
    private var indexByRole: [ChannelRole: Int] = [:]

    private var history: [Anomaly] = []

    /// Resolved indices for the `observeStep` channels. Resolved once, so the
    /// per-step path does no hashing at all. Not assumed to be 0...8: the
    /// caller may have registered channels of their own first.
    private struct StepChannelIndices {
        var total = 0
        var collision = 0
        var solve = 0
        var contacts = 0
        var constraints = 0
        var iterations = 0
        var residual = 0
        var energy = 0
        var height = 0
    }
    private var stepIndices: StepChannelIndices?

    // MARK: Learned mode state

    private var learnedModel: JointPatternModel?
    private var learnedChannelIndices: [Int] = []
    /// Ring of normalised channel vectors, `windowSteps * channels` doubles.
    private var learnedRing: [Double] = []
    private var learnedRingHead = 0
    private var learnedRingFilled = 0
    /// Contiguous, chronologically ordered copy handed to the model. Allocated
    /// once so scoring never touches the allocator.
    private var learnedScratch: [Double] = []
    private var learnedTraining: [[Double]] = []
    private var learnedErrorStats = ChannelStatistics(smoothing: 0.01)
    private var learnedStepCounter = 0
    private var learnedRefractory = -Double.greatestFiniteMagnitude
    public private(set) var learnedModeStatus: LearnedModeStatus = .disabled

    // MARK: Init

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        history.reserveCapacity(32)
    }

    // MARK: Registration

    /// Declares a channel and what is known about it. Registering the same
    /// name twice replaces the hint and keeps the statistics.
    public func register(channel: String, hint: ChannelHint) {
        if let index = indexByName[channel] {
            states[index].hint = hint
            states[index].stats.smoothing = hint.smoothing
            if hint.role != .other { indexByRole[hint.role] = index }
            return
        }
        let index = states.count
        states.append(ChannelState(name: channel, hint: hint))
        indexByName[channel] = index
        if hint.role != .other { indexByRole[hint.role] = index }
    }

    /// Stable index for a channel, for callers that want to skip the string
    /// hash on every sample.
    public func index(of channel: String) -> Int? { indexByName[channel] }

    public var channelNames: [String] { states.map(\.name) }

    public func statistics(for channel: String) -> ChannelStatistics? {
        guard let index = indexByName[channel] else { return nil }
        return states[index].stats
    }

    public func hint(for channel: String) -> ChannelHint? {
        guard let index = indexByName[channel] else { return nil }
        return states[index].hint
    }

    // MARK: Observation

    /// Feeds one sample. Returns at most one anomaly - the most severe kind
    /// that fired on this sample - or `nil`, which is the overwhelmingly
    /// common case.
    ///
    /// An unregistered channel is registered with `ChannelHint.generic` on
    /// first sight. That one call allocates; every later call on the same name
    /// does not.
    @discardableResult
    public func observe(channel: String, value: Double, time: Double) -> Anomaly? {
        let index: Int
        if let known = indexByName[channel] {
            index = known
        } else {
            register(channel: channel, hint: .generic)
            guard let created = indexByName[channel] else { return nil }
            index = created
        }
        return observe(channelIndex: index, value: value, time: time)
    }

    /// Index-based hot path. No hashing, no allocation unless something fires.
    @discardableResult
    public func observe(channelIndex: Int, value: Double, time: Double) -> Anomaly? {
        guard channelIndex >= 0, channelIndex < states.count else { return nil }
        let fired = evaluate(channelIndex: channelIndex, value: value, time: time)
        if let anomaly = fired { record(anomaly) }
        return fired
    }

    /// Convenience for the solver statistics, which are the channels most worth
    /// watching and the ones every caller has to hand.
    ///
    /// Registers its channels on first use. Returns an empty array when nothing
    /// fired - an empty `Array` is a shared singleton and costs no allocation.
    @discardableResult
    public func observeStep(time: Double,
                            profile: some SolverStepStatistics,
                            energy: Double? = nil,
                            comHeight: Double? = nil) -> [Anomaly] {
        var fired: [Anomaly] = []
        observeStep(time: time, profile: profile, energy: energy, comHeight: comHeight,
                    into: { fired.append($0) })
        return fired
    }

    /// Sink form: strictly allocation-free while nothing fires.
    public func observeStep(time: Double,
                            profile: some SolverStepStatistics,
                            energy: Double? = nil,
                            comHeight: Double? = nil,
                            into sink: (Anomaly) -> Void) {
        let indices = stepIndices ?? registerStepChannels()

        if let a = observe(channelIndex: indices.total, value: profile.total, time: time) { sink(a) }
        if let a = observe(channelIndex: indices.collision,
                           value: profile.collision, time: time) { sink(a) }
        if let a = observe(channelIndex: indices.solve, value: profile.solve, time: time) { sink(a) }
        if let a = observe(channelIndex: indices.contacts,
                           value: Double(profile.contactCount), time: time) { sink(a) }
        if let a = observe(channelIndex: indices.constraints,
                           value: Double(profile.constraintCount), time: time) { sink(a) }
        if let a = observe(channelIndex: indices.iterations,
                           value: Double(profile.solverIterations), time: time) { sink(a) }
        if let a = observe(channelIndex: indices.residual,
                           value: profile.solverResidual, time: time) { sink(a) }
        if let energy, let a = observe(channelIndex: indices.energy, value: energy, time: time) {
            sink(a)
        }
        if let comHeight,
           let a = observe(channelIndex: indices.height, value: comHeight, time: time) {
            sink(a)
        }

        if let a = endStep(time: time) { sink(a) }
    }

    /// Closes the step for the learned mode. `observeStep` calls this; callers
    /// driving `observe` directly must call it once per step for the joint
    /// detector to see anything.
    @discardableResult
    public func endStep(time: Double) -> Anomaly? {
        guard configuration.learned.isEnabled else { return nil }
        let fired = evaluateLearned(time: time)
        if let anomaly = fired { record(anomaly) }
        return fired
    }

    /// Registers the solver channels and caches their indices, so the per-step
    /// path never touches the name dictionary again.
    @discardableResult
    private func registerStepChannels() -> StepChannelIndices {
        register(channel: TelemetryChannelName.stepTime, hint: .stepTime)

        // Collision and solve time share the step-time statistics but not its
        // role: only one channel may claim `.stepTime` for context lookups.
        var collision = ChannelHint.stepTime
        collision.role = .other
        register(channel: TelemetryChannelName.collisionTime, hint: collision)

        var solve = ChannelHint.stepTime
        solve.role = .other
        register(channel: TelemetryChannelName.solveTime, hint: solve)

        register(channel: TelemetryChannelName.contactCount, hint: .contactCount)
        register(channel: TelemetryChannelName.constraintCount, hint: .constraintCount)
        register(channel: TelemetryChannelName.solverIterations, hint: .solverIterations)
        register(channel: TelemetryChannelName.solverResidual, hint: .solverResidual)
        register(channel: TelemetryChannelName.totalEnergy, hint: .energy)
        register(channel: TelemetryChannelName.comHeight, hint: .height)

        var indices = StepChannelIndices()
        indices.total = indexByName[TelemetryChannelName.stepTime] ?? 0
        indices.collision = indexByName[TelemetryChannelName.collisionTime] ?? 0
        indices.solve = indexByName[TelemetryChannelName.solveTime] ?? 0
        indices.contacts = indexByName[TelemetryChannelName.contactCount] ?? 0
        indices.constraints = indexByName[TelemetryChannelName.constraintCount] ?? 0
        indices.iterations = indexByName[TelemetryChannelName.solverIterations] ?? 0
        indices.residual = indexByName[TelemetryChannelName.solverResidual] ?? 0
        indices.energy = indexByName[TelemetryChannelName.totalEnergy] ?? 0
        indices.height = indexByName[TelemetryChannelName.comHeight] ?? 0
        stepIndices = indices
        return indices
    }

    // MARK: Results

    /// Detections so far, oldest first.
    public var anomalies: [Anomaly] { history }

    /// Takes the detections and clears the buffer, so a UI can poll without
    /// growing it forever.
    public func drainAnomalies() -> [Anomaly] {
        let out = history
        history.removeAll(keepingCapacity: true)
        return out
    }

    /// Clears statistics and detections; keeps registrations, hints and the
    /// fitted model, so a re-run starts cold but not blind.
    public func reset() {
        for index in states.indices {
            let hint = states[index].hint
            var fresh = ChannelState(name: states[index].name, hint: hint)
            fresh.stats = ChannelStatistics(smoothing: hint.smoothing)
            states[index] = fresh
        }
        history.removeAll(keepingCapacity: true)
        learnedRingHead = 0
        learnedRingFilled = 0
        learnedStepCounter = 0
        learnedRefractory = -Double.greatestFiniteMagnitude
        learnedErrorStats.reset()
    }

    private func record(_ anomaly: Anomaly) {
        if history.count >= configuration.maximumRetainedAnomalies {
            history.removeFirst(history.count - configuration.maximumRetainedAnomalies + 1)
        }
        history.append(anomaly)
    }

    // MARK: - Detection

    /// The whole hot path. Reads the baseline built from previous samples,
    /// updates the bookkeeping, then decides. Scoring against the pre-update
    /// baseline matters: a large sample that is included in its own baseline
    /// partly hides itself.
    private func evaluate(channelIndex: Int, value: Double, time: Double) -> Anomaly? {
        let hint = states[channelIndex].hint

        // --- Non-finite: fires immediately, bypasses warm-up, never enters the
        // estimators. A NaN in a channel is not a statistical event.
        if !value.isFinite {
            guard allow(.divergence, channelIndex: channelIndex, at: time, hint: hint) else { return nil }
            return fire(.divergence, channelIndex: channelIndex, value: value, time: time,
                        duration: 0, severity: 1,
                        lower: hint.bounds?.lowerBound ?? -Double.greatestFiniteMagnitude,
                        upper: hint.bounds?.upperBound ?? Double.greatestFiniteMagnitude)
        }

        // One local copy of the channel's state for the whole update.
        // Every `states[i].field = x` on a class property is an exclusivity
        // check; there are thirty of them below, and doing the arithmetic on a
        // local value and writing back once measurably beats paying for each.
        var state = states[channelIndex]

        // --- Baseline captured before the update.
        let baseline = state.stats
        let hadPrevious = state.hasPrevious
        let previous = state.previous
        // Two scales, and the difference matters. `floorScale` is what the
        // caller says is too small to care about; `scale` also follows what the
        // channel is actually doing. Tests that ask "is this bigger than the
        // usual variation" use `scale`; the oscillation test uses `floorScale`,
        // because a sustained oscillation inflates the robust scale until it
        // is the size of its own amplitude and hides itself.
        let floorScale = Swift.max(hint.noiseFloor,
                                   abs(baseline.median) * hint.relativeNoiseFloor)
        let scale = Swift.max(baseline.robustScale, floorScale)
        let slowBefore = state.slowMean
        let elapsed = baseline.count > 0 ? time - baseline.firstTime : 0

        // --- Bookkeeping.
        let delta = hadPrevious ? value - previous : 0
        state.stats.update(value, at: time)
        if baseline.count == 0 {
            state.slowMean = value
            state.flipWindowStart = time
            state.quietSince = time
            state.driftSince = time
        } else {
            // Slow baseline: 64 times slower than the fast EWMA. The gap
            // between two EWMAs following a ramp is proportional to the
            // difference of their time constants, so a baseline only a little
            // slower than the fast average never separates far enough from it
            // to clear the drift threshold.
            let slowGain = hint.smoothing / 64
            state.slowMean += slowGain * (value - slowBefore)
        }

        // Quiescence.
        let tolerance = Swift.max(hint.quiescenceTolerance, 0)
        if hadPrevious && abs(delta) <= tolerance {
            if !state.isQuiet {
                state.isQuiet = true
                state.quietSince = time
            }
        } else {
            state.isQuiet = false
            state.quietSince = time
            state.lastStallHold = 0
        }

        // Oscillation bookkeeping: half cycles of the deviation from the slow
        // baseline, counted through a hysteresis band. Noise wanders across its
        // baseline constantly, so a bare crossing count is useless; what the
        // band, the peak and the half-cycle duration together buy is the
        // ability to ask afterwards whether the crossings had a rhythm.
        if hadPrevious {
            let interval = time - baseline.lastTime
            if interval > 0 {
                if state.sampleInterval <= 0 {
                    state.sampleInterval = interval
                } else {
                    state.sampleInterval +=
                        0.05 * (interval - state.sampleInterval)
                }
            }

            let deviation = value - slowBefore
            // Wide enough to ignore the noise floor, but never so wide that a
            // real cycle cannot cross it - hence the 0.75, not 2, on the
            // adaptive term.
            let hysteresis = Swift.max(2 * floorScale, 0.75 * baseline.robustScale)
            state.halfCyclePeak =
                Swift.max(state.halfCyclePeak, abs(deviation))
            let side = deviation > hysteresis ? 1 : (deviation < -hysteresis ? -1 : 0)
            if side != 0 && side != state.crossingSign {
                if state.crossingSign != 0 {
                    let peak = state.halfCyclePeak
                    let span = time - state.halfCycleStart
                    state.crossingCount += 1
                    state.amplitudeMin =
                        Swift.min(state.amplitudeMin, peak)
                    state.amplitudeMax =
                        Swift.max(state.amplitudeMax, peak)
                    state.amplitudeSum += peak
                    state.halfCycleMin =
                        Swift.min(state.halfCycleMin, span)
                    state.halfCycleMax =
                        Swift.max(state.halfCycleMax, span)
                }
                state.crossingSign = side
                state.halfCycleStart = time
                state.halfCyclePeak = 0
            }
        }

        // Divergence run: geometric growth of the magnitude.
        if hadPrevious {
            let magnitude = abs(value)
            let previousMagnitude = abs(previous)
            if previousMagnitude > scale && magnitude > previousMagnitude * hint.divergenceGrowth {
                state.growthRun += 1
            } else {
                state.growthRun = 0
            }
        }

        // Elevated run, for residual-like channels.
        if let threshold = hint.elevatedThreshold {
            if value > threshold {
                if !state.isElevated {
                    state.isElevated = true
                    state.elevatedSince = time
                }
            } else {
                state.isElevated = false
                state.elevatedSince = time
                state.lastStressHold = 0
            }
        }

        // Drift run: fast average sitting off the slow baseline, one direction.
        let fast = state.stats.ewmaMean
        let slow = state.slowMean
        let departure = fast - slow
        let driftScore = scale > 0 ? departure / scale : 0
        let sign = driftScore > hint.driftThreshold ? 1 : (driftScore < -hint.driftThreshold ? -1 : 0)
        if sign == 0 || sign != state.driftSign {
            state.driftSign = sign
            state.driftSince = time
            if sign == 0 { state.lastDriftScore = 0 }
        }

        state.previous = value
        state.hasPrevious = true

        // Feed the learned window with the normalised value, if this channel is
        // part of the vector. Cheap and unconditional beats a lookup.
        captureLearnedSample(channelIndex: channelIndex, value: value,
                             centre: baseline.median, scale: scale)

        states[channelIndex] = state

        // --- Range and monotonicity: contractual, checked outside the warm-up
        // because a violation is a violation on sample one.
        if hadPrevious {
            var violated = false
            var lower = -Double.greatestFiniteMagnitude
            var upper = Double.greatestFiniteMagnitude
            switch hint.sign {
            case .nonNegative where value < 0:
                violated = true; lower = 0
            case .positive where value <= 0:
                violated = true; lower = 0
            default:
                break
            }
            if let bounds = hint.bounds, !violated, value < bounds.lowerBound || value > bounds.upperBound {
                violated = true
                lower = bounds.lowerBound
                upper = bounds.upperBound
            }
            if !violated {
                switch hint.monotonicity {
                case .nonDecreasing where delta < -tolerance:
                    violated = true; lower = previous
                case .nonIncreasing where delta > tolerance:
                    violated = true; upper = previous
                default:
                    break
                }
            }
            if violated, allow(.rangeViolation, channelIndex: channelIndex, at: time, hint: hint) {
                return fire(.rangeViolation, channelIndex: channelIndex, value: value, time: time,
                            duration: 0, severity: 1, lower: lower, upper: upper)
            }
        }

        // --- Warm-up gate for everything statistical.
        guard baseline.count >= Swift.max(hint.warmupSamples, configuration.minimumSamples),
              elapsed >= configuration.warmupDuration else { return nil }

        // --- Divergence by sustained geometric growth.
        if state.growthRun >= hint.divergenceRun,
           allow(.divergence, channelIndex: channelIndex, at: time, hint: hint) {
            let run = state.growthRun
            let severity = Swift.min(1, 0.6 + Double(run - hint.divergenceRun) * 0.02)
            return fire(.divergence, channelIndex: channelIndex, value: value, time: time,
                        duration: 0, severity: severity,
                        lower: baseline.median - hint.driftThreshold * scale,
                        upper: baseline.median + hint.driftThreshold * scale,
                        runLength: run)
        }

        // --- Constraint stress.
        if let threshold = hint.elevatedThreshold, state.isElevated {
            let held = time - state.elevatedSince
            // Escalation: after the first report, say it again only once it has
            // held three times as long. An ongoing problem then gets reported
            // at a decreasing rate instead of every refractory period.
            let required = Swift.max(hint.elevatedDuration, state.lastStressHold * 3)
            if held >= required,
               allow(.constraintStress, channelIndex: channelIndex, at: time, hint: hint) {
                states[channelIndex].lastStressHold = held
                // Severity blends how long it has held with how far above the
                // threshold it sits; both matter and neither alone is enough.
                let overshoot = threshold > 0 ? Swift.min(1, log10(Swift.max(value / threshold, 1)) / 3) : 1
                let persistence = Swift.min(1, held / (hint.elevatedDuration * 8))
                return fire(.constraintStress, channelIndex: channelIndex, value: value, time: time,
                            duration: held, severity: 0.4 + 0.3 * overshoot + 0.3 * persistence,
                            lower: 0, upper: threshold)
            }
        }

        // --- Spike.
        let score = hint.heavyTailed
            ? baseline.robustScore(value, floor: scale)
            : baseline.zScore(value, floor: scale)
        if abs(score) > hint.spikeThreshold,
           abs(value - baseline.median) > scale,
           allow(.spike, channelIndex: channelIndex, at: time, hint: hint) {
            let severity = Swift.min(1, (abs(score) - hint.spikeThreshold) / (2 * hint.spikeThreshold) + 0.4)
            return fire(.spike, channelIndex: channelIndex, value: value, time: time,
                        duration: 0, severity: severity,
                        lower: baseline.median - hint.spikeThreshold * scale,
                        upper: baseline.median + hint.spikeThreshold * scale,
                        score: score)
        }

        // --- Oscillation. Evaluated at the end of each window, not per sample.
        if time - state.flipWindowStart >= hint.oscillationWindow {
            let window = time - state.flipWindowStart
            let crossings = state.crossingCount
            let amplitudeMin = state.amplitudeMin
            let amplitudeMax = state.amplitudeMax
            let meanAmplitude = crossings > 0
                ? state.amplitudeSum / Double(crossings) : 0
            // Two ratios, both needed. Constant amplitude alone does not
            // separate a limit cycle from noise that happens to be wide; a
            // constant *period* does, because noise has no period. A decaying
            // ring-down fails the amplitude ratio, which is intended - a scene
            // that is settling is not a fault.
            let steadyAmplitude = amplitudeMin < .greatestFiniteMagnitude
                && amplitudeMax <= amplitudeMin * 6
            let halfCycleMin = state.halfCycleMin
            let steadyPeriod = halfCycleMin < .greatestFiniteMagnitude
                && state.halfCycleMax <= halfCycleMin * 4
            // Half cycles a sample or two long are either noise crossing its
            // own band or chatter at the step rate, and the two are not
            // separable from a single channel - so this test declines to try,
            // and only reports cycles it can actually resolve.
            let resolved = state.sampleInterval > 0
                && halfCycleMin >= 3 * state.sampleInterval
            states[channelIndex].crossingCount = 0
            states[channelIndex].flipWindowStart = time
            states[channelIndex].amplitudeMin = .greatestFiniteMagnitude
            states[channelIndex].amplitudeMax = 0
            states[channelIndex].amplitudeSum = 0
            states[channelIndex].halfCycleMin = .greatestFiniteMagnitude
            states[channelIndex].halfCycleMax = 0

            let qualifies = crossings >= hint.oscillationFlips && steadyAmplitude
                && steadyPeriod && resolved && meanAmplitude > 2 * floorScale
            // A limit cycle that just keeps going is one event, not one per
            // window. Say it again only if it grows by half.
            if !qualifies { states[channelIndex].lastOscillationAmplitude = 0 }
            if qualifies, meanAmplitude >= state.lastOscillationAmplitude * 1.5,
               allow(.oscillation, channelIndex: channelIndex, at: time, hint: hint) {
                states[channelIndex].lastOscillationAmplitude = meanAmplitude
                let severity = Swift.min(1, 0.35 + Double(crossings - hint.oscillationFlips) * 0.01
                                            + Swift.min(0.3, meanAmplitude / (8 * Swift.max(floorScale, 1e-12))))
                // Two crossings per period, so this is the fundamental.
                let frequency = window > 0 ? Double(crossings) / (2 * window) : 0
                return fire(.oscillation, channelIndex: channelIndex, value: value, time: time,
                            duration: window, severity: severity,
                            lower: slow - meanAmplitude, upper: slow + meanAmplitude,
                            flips: crossings, amplitude: meanAmplitude, frequency: frequency)
            }
        }

        // --- Drift. Never on a channel that is sitting still: a frozen channel
        // is a stall, and reporting the baseline catching up to it as a drift
        // is the same event told twice.
        if state.driftSign != 0, !state.isQuiet {
            let held = time - state.driftSince
            // Same escalation rule as constraint stress, on the departure
            // rather than the duration: a ramp that keeps ramping is worth
            // hearing about again only once it has gone half again as far.
            let required = Swift.max(hint.driftThreshold, state.lastDriftScore * 1.5)
            if held >= hint.driftDuration, abs(driftScore) >= required,
               allow(.drift, channelIndex: channelIndex, at: time, hint: hint) {
                states[channelIndex].lastDriftScore = abs(driftScore)
                let severity = Swift.min(1, 0.3 + abs(driftScore) / (4 * hint.driftThreshold)
                                            + Swift.min(0.3, held / (8 * hint.driftDuration)))
                return fire(.drift, channelIndex: channelIndex, value: value, time: time,
                            duration: held, severity: severity,
                            lower: slow - hint.driftThreshold * scale,
                            upper: slow + hint.driftThreshold * scale,
                            score: driftScore, reference: slow)
            }
        }

        // --- Stall. Last, because it is the least urgent of the lot.
        if hint.expectedToVary, state.isQuiet {
            let held = time - state.quietSince
            // Only meaningful if the channel used to move: a channel that has
            // been flat since the first sample was probably never wired up, and
            // saying so once at the end of the run is kinder than saying it now.
            let required = Swift.max(hint.stallDuration, state.lastStallHold * 3)
            if held >= required, baseline.robustScale > hint.noiseFloor,
               allow(.stall, channelIndex: channelIndex, at: time, hint: hint) {
                states[channelIndex].lastStallHold = held
                let severity = Swift.min(1, 0.3 + held / (6 * Swift.max(hint.stallDuration, 1e-6)) * 0.3)
                return fire(.stall, channelIndex: channelIndex, value: value, time: time,
                            duration: held, severity: severity,
                            lower: baseline.median - scale, upper: baseline.median + scale)
            }
        }

        return nil
    }

    /// Refractory check. Called before any string is built, which is the point.
    private func allow(_ kind: AnomalyKind, channelIndex: Int, at time: Double,
                       hint: ChannelHint) -> Bool {
        time - states[channelIndex].refractory.last(kind) >= hint.refractory
    }

    // MARK: - Explanation (only reached when something fires)

    private func fire(_ kind: AnomalyKind,
                      channelIndex: Int,
                      value: Double,
                      time: Double,
                      duration: Double,
                      severity: Double,
                      lower: Double,
                      upper: Double,
                      score: Double = 0,
                      reference: Double = 0,
                      runLength: Int = 0,
                      flips: Int = 0,
                      amplitude: Double = 0,
                      frequency: Double = 0) -> Anomaly {
        states[channelIndex].refractory.mark(kind, at: time)

        let state = states[channelIndex]
        let hint = state.hint
        let unit = hint.unit
        let name = state.name

        var context: [String: Double] = [:]
        // Quote the other solver channels when the anomaly is about the solver:
        // "residual high" is much more useful next to "at 282 contacts".
        if hint.role == .solverResidual || hint.role == .stepTime || kind == .constraintStress {
            if let contactIndex = indexByRole[.contactCount] {
                context[TelemetryChannelName.contactCount] = states[contactIndex].stats.last
            }
            if let constraintIndex = indexByRole[.constraintCount] {
                context[TelemetryChannelName.constraintCount] = states[constraintIndex].stats.last
            }
            if let iterationIndex = indexByRole[.solverIterations] {
                context[TelemetryChannelName.solverIterations] = states[iterationIndex].stats.last
            }
        }

        let text: String
        switch kind {
        case .divergence where !value.isFinite:
            text = "\(name) became \(value.isNaN ? "NaN" : "infinite") at "
                + TelemetryFormat.time(time)
                + ". The state is no longer a number, so everything downstream of this step is meaningless."
        case .divergence:
            text = "\(name) grew for \(runLength) consecutive steps, reaching "
                + TelemetryFormat.value(value, unit: unit)
                + " from a typical " + TelemetryFormat.value(state.stats.median, unit: unit)
                + " - faster than linear, so it is not settling, it is running away."
        case .constraintStress:
            var sentence = "\(name) held above "
                + TelemetryFormat.value(upper, unit: unit)
                + " for " + TelemetryFormat.duration(duration)
                + " (now " + TelemetryFormat.value(value, unit: unit) + ")"
            if let contacts = context[TelemetryChannelName.contactCount] {
                sentence += " while contact count was " + TelemetryFormat.count(contacts)
            }
            if let iterations = context[TelemetryChannelName.solverIterations] {
                sentence += " and the sweep ran " + TelemetryFormat.count(iterations) + " iterations"
            }
            sentence += " - the scene is over-constrained or the mass ratio is extreme."
            text = sentence
        case .spike:
            // Past about fifty scales the number stops meaning anything to a
            // reader - "97266 standard deviations" is noise dressed as
            // precision - so say it in words and quote the values instead.
            let distance = abs(score) >= 50
                ? "far outside its usual band"
                : TelemetryFormat.number(abs(score), precision: 1)
                    + (hint.heavyTailed ? " robust scales" : " standard deviations")
                    + " out"
            text = "\(name) jumped to " + TelemetryFormat.value(value, unit: unit)
                + " at " + TelemetryFormat.time(time) + ", " + distance
                + ", from a usual " + TelemetryFormat.value(state.stats.median, unit: unit)
                + " (band " + TelemetryFormat.value(lower, unit: unit)
                + " to " + TelemetryFormat.value(upper, unit: unit) + ")."
        case .stall:
            text = "\(name) has not moved from "
                + TelemetryFormat.value(value, unit: unit)
                + " for " + TelemetryFormat.duration(duration)
                + ", after varying by about "
                + TelemetryFormat.value(state.stats.robustScale, unit: unit)
                + " before that - the channel looks frozen rather than settled."
        case .drift:
            let direction = score > 0 ? "up" : "down"
            text = "\(name) has drifted \(direction) from "
                + TelemetryFormat.value(reference, unit: unit)
                + " to " + TelemetryFormat.value(value, unit: unit)
                + " over " + TelemetryFormat.duration(duration)
                + " without coming back - a one-way departure of "
                + TelemetryFormat.number(abs(score), precision: 1) + " scales."
        case .oscillation:
            text = "\(name) crossed its baseline \(flips) times in "
                + TelemetryFormat.duration(duration)
                + " - about " + TelemetryFormat.number(frequency, precision: 1)
                + " Hz at a steady amplitude of "
                + TelemetryFormat.value(amplitude, unit: unit)
                + ", holding rather than decaying. That is a limit cycle, not convergence."
        case .rangeViolation:
            text = "\(name) reached " + TelemetryFormat.value(value, unit: unit)
                + ", outside the range it was declared to live in ("
                + TelemetryFormat.value(lower, unit: unit) + " to "
                + TelemetryFormat.value(upper, unit: unit) + ")."
        case .jointPattern:
            text = "The combination of channels is unlike anything seen during warm-up: "
                + "reconstruction error " + TelemetryFormat.number(value, precision: 3)
                + " against a learned typical " + TelemetryFormat.number(state.stats.median, precision: 3)
                + ". No single channel left its own band."
        }

        return Anomaly(channel: name,
                       role: hint.role,
                       kind: kind,
                       time: time,
                       duration: duration,
                       severity: severity,
                       value: value,
                       expectedLower: lower,
                       expectedUpper: upper,
                       explanation: text,
                       context: context)
    }

    // MARK: - Learned mode

    /// Enables the reconstruction detector. Returns the resulting status, which
    /// is `.collecting` on success and says why on failure - the caller should
    /// surface that rather than assume the model is running.
    @discardableResult
    public func enableLearnedMode(_ configurationUpdate: LearnedModeConfiguration) -> LearnedModeStatus {
        configuration.learned = configurationUpdate
        configuration.learned.isEnabled = true

        guard configurationUpdate.isRuntimeAvailable() else {
            configuration.learned.isEnabled = false
            learnedModeStatus = .runtimeUnavailable
            return learnedModeStatus
        }

        // Every channel must already be registered; resolving the indices once
        // is what keeps the per-step capture free of dictionary work.
        var indices: [Int] = []
        indices.reserveCapacity(configurationUpdate.channels.count)
        for name in configurationUpdate.channels {
            guard let index = indexByName[name] else {
                configuration.learned.isEnabled = false
                learnedModeStatus = .modelUnavailable
                return learnedModeStatus
            }
            indices.append(index)
        }
        guard !indices.isEmpty, configurationUpdate.windowSteps > 0 else {
            configuration.learned.isEnabled = false
            learnedModeStatus = .modelUnavailable
            return learnedModeStatus
        }

        let dimension = indices.count * configurationUpdate.windowSteps
        guard let model = configurationUpdate.makeModel(dimension) else {
            configuration.learned.isEnabled = false
            learnedModeStatus = .modelUnavailable
            return learnedModeStatus
        }

        learnedModel = model
        learnedChannelIndices = indices
        learnedRing = [Double](repeating: 0, count: dimension)
        learnedScratch = [Double](repeating: 0, count: dimension)
        learnedRingHead = 0
        learnedRingFilled = 0
        learnedTraining.removeAll(keepingCapacity: false)
        learnedTraining.reserveCapacity(configurationUpdate.trainingWindows)
        learnedErrorStats.reset()
        register(channel: TelemetryChannelName.jointPattern, hint: learnedHint())
        learnedModeStatus = .collecting
        return learnedModeStatus
    }

    public func disableLearnedMode() {
        configuration.learned.isEnabled = false
        learnedModeStatus = .disabled
    }

    private func learnedHint() -> ChannelHint {
        var hint = ChannelHint()
        hint.role = .jointPattern
        hint.sign = .nonNegative
        hint.heavyTailed = true
        hint.warmupSamples = Int.max        // never scored by the scalar tests
        hint.refractory = configuration.learned.refractory
        return hint
    }

    /// Writes one channel's normalised value into the current window slot.
    /// Normalising here - rather than in the model - means the model sees a
    /// scene-independent vector and a fitted model survives a scale change.
    private func captureLearnedSample(channelIndex: Int, value: Double,
                                      centre: Double, scale: Double) {
        guard configuration.learned.isEnabled, !learnedRing.isEmpty else { return }
        // Linear scan over a handful of indices beats a dictionary here.
        var slot = -1
        for (offset, index) in learnedChannelIndices.enumerated() where index == channelIndex {
            slot = offset
            break
        }
        guard slot >= 0 else { return }
        let normalised = scale > 0 ? (value - centre) / scale : 0
        learnedRing[learnedRingHead * learnedChannelIndices.count + slot] = normalised
    }

    private func evaluateLearned(time: Double) -> Anomaly? {
        guard let model = learnedModel, !learnedRing.isEmpty else { return nil }
        let width = learnedChannelIndices.count
        let steps = configuration.learned.windowSteps

        learnedRingHead = (learnedRingHead + 1) % steps
        learnedRingFilled = Swift.min(learnedRingFilled + 1, steps)
        learnedStepCounter += 1
        guard learnedRingFilled >= steps else { return nil }

        // Copy the ring out in chronological order. Fixed-size, pre-allocated.
        let oldest = learnedRingHead
        for step in 0..<steps {
            let source = ((oldest + step) % steps) * width
            let destination = step * width
            for channel in 0..<width {
                learnedScratch[destination + channel] = learnedRing[source + channel]
            }
        }

        if learnedModeStatus == .collecting {
            if learnedTraining.count < configuration.learned.trainingWindows {
                // Allocates, but only during warm-up and only every stride.
                if learnedStepCounter % configuration.learned.evaluationStride == 0 {
                    learnedTraining.append(learnedScratch)
                }
                return nil
            }
            do {
                try model.fit(windows: learnedTraining)
                learnedTraining.removeAll(keepingCapacity: false)
                learnedModeStatus = .active
            } catch {
                learnedTraining.removeAll(keepingCapacity: false)
                learnedModeStatus = .trainingFailed
                configuration.learned.isEnabled = false
                return nil
            }
        }

        guard learnedModeStatus == .active,
              learnedStepCounter % configuration.learned.evaluationStride == 0 else { return nil }

        let error = learnedScratch.withUnsafeBufferPointer { model.reconstructionError($0) }
        guard error.isFinite else { return nil }

        let floor = Swift.max(learnedErrorStats.robustScale, 1e-9)
        let score = learnedErrorStats.robustScore(error, floor: floor)
        learnedErrorStats.update(error, at: time)
        guard let channelIndex = indexByName[TelemetryChannelName.jointPattern] else { return nil }
        states[channelIndex].stats.update(error, at: time)

        // The error distribution needs its own warm-up: the first errors after
        // fitting are on data the model just saw and are unrepresentatively low.
        guard learnedErrorStats.count > 128 else { return nil }
        guard score > configuration.learned.threshold,
              time - learnedRefractory >= configuration.learned.refractory else { return nil }
        learnedRefractory = time

        let severity = Swift.min(1, 0.4 + (score - configuration.learned.threshold)
                                    / (3 * configuration.learned.threshold))
        return fire(.jointPattern, channelIndex: channelIndex, value: error, time: time,
                    duration: 0, severity: severity,
                    lower: 0,
                    upper: learnedErrorStats.median + configuration.learned.threshold * floor)
    }
}

// MARK: - Formatting

/// Number formatting for explanations. Deliberately not `NumberFormatter`:
/// this runs off the hot path but still inside a step loop, and locale-aware
/// grouping in a diagnostic string helps nobody.
public enum TelemetryFormat {

    public static func number(_ value: Double, precision: Int = 3) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-inf" : "inf") }
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        if magnitude >= 1e6 || magnitude < 1e-3 { return String(format: "%.2e", value) }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 10 { return String(format: "%.\(Swift.max(precision - 1, 0))f", value) }
        return String(format: "%.\(precision)f", value)
    }

    public static func count(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        return String(format: "%.0f", value.rounded())
    }

    public static func value(_ value: Double, unit: ChannelHint.Unit) -> String {
        switch unit {
        case .dimensionless: return number(value)
        case .milliseconds: return number(value) + " ms"
        case .seconds: return number(value) + " s"
        case .count: return count(value)
        case .joules: return number(value) + " J"
        case .metres: return number(value) + " m"
        case .newtons: return number(value) + " N"
        case .radians: return number(value) + " rad"
        }
    }

    /// A span of simulated time, in the unit a human would use for it.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "?" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }

    /// An instant on the simulated clock.
    public static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "t = ?" }
        return String(format: "t = %.3f s", seconds)
    }

    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "?" }
        let value = fraction * 100
        if abs(value) >= 10 { return String(format: "%.0f%%", value) }
        if abs(value) >= 1 { return String(format: "%.1f%%", value) }
        return String(format: "%.2f%%", value)
    }
}
