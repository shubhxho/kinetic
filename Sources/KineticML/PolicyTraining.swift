// PolicyTraining.swift
//
// Training and evaluation for the cart-pole task, plus the analytic controller the learned
// one is measured against.
//
// Three things live here, in dependency order: a seeded generator (nothing in this package is
// allowed to draw from the system RNG), a hand-derived LQR law that balances the pole with no
// learning and no MLX, and a cross-entropy-method trainer that searches a small network's
// parameters against exactly the same task definition. Having the analytic law in the same
// file as the trainer is the point — it is the number the learned policy has to beat, and it
// is what the feature falls back to on a machine where MLX will not run.

import Foundation
import Kinetic

// MARK: - Seeded randomness

/// xoshiro256\*\* — a small, fast, well-distributed generator, seeded by SplitMix64.
///
/// Written out here rather than using `SystemRandomNumberGenerator` because every number that
/// influences a training run has to be reproducible from an integer. Two runs with the same
/// seed must produce byte-identical parameters, or none of the metrics in a `TrainedPolicy`
/// mean anything.
public struct PolicyRandom: RandomNumberGenerator {

    private var state: (UInt64, UInt64, UInt64, UInt64)
    private var spareGaussian: Double?

    /// Seeds all four words from SplitMix64, so even a seed of `0` gives a well-mixed state.
    public init(seed: UInt64) {
        var z = seed
        func splitMix() -> UInt64 {
            z = z &+ 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        state = (splitMix(), splitMix(), splitMix(), splitMix())
        spareGaussian = nil
    }

    public mutating func next() -> UInt64 {
        let result = PolicyRandom.rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = PolicyRandom.rotl(state.3, 45)
        return result
    }

    /// Uniform in `[0, 1)`. Uses the top 53 bits, which is exactly the mantissa width of a
    /// `Double`, so every representable value in the interval is reachable and none is
    /// favoured by rounding.
    public mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Uniform in `range`.
    public mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }

    /// Standard normal, by Box–Muller. The second variate of each pair is kept rather than
    /// discarded, so a sequence of draws consumes the generator at a predictable rate.
    public mutating func gaussian() -> Double {
        if let spare = spareGaussian {
            spareGaussian = nil
            return spare
        }
        // `uniform()` can return exactly zero, and log(0) is -inf; nudge into (0, 1].
        let u1 = max(uniform(), Double.leastNormalMagnitude)
        let u2 = uniform()
        let radius = (-2 * Foundation.log(u1)).squareRoot()
        let angle = 2 * Double.pi * u2
        spareGaussian = radius * Foundation.sin(angle)
        return radius * Foundation.cos(angle)
    }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}

// MARK: - Analytic baseline

/// A linear-quadratic-regulator feedback law for `SceneLibrary.cartPole()`.
///
/// `u = clamp(kₓ·x + k_ẋ·ẋ + k_θ·θ + k_ω·ω, -1, 1)`
///
/// Why this exists: it makes the learned controller falsifiable. "The network balances the
/// pole" is not an interesting claim on a system that a four-number linear law solves; the
/// interesting claim is that the learned policy matches or beats these numbers. It also means
/// the app has a working controller on a Mac where MLX cannot start, since nothing here
/// touches the ML runtime.
///
/// **Derivation.** The gains are the solution of the continuous-time algebraic Riccati
/// equation for the plant linearised about the upright equilibrium, with parameters read out
/// of `SceneLibrary.cartPole()` rather than assumed:
///
///     cart mass M      = 8·0.12·0.07·0.05 · 800 + 0.01 (slide armature) = 2.698 kg
///     pole mass m      = 0.4 kg,  pivot→com l = 0.3 m
///     pole inertia I   = I_com(capsule r=0.018, L=0.6) + m l² + 0.001 (armature) = 0.05002 kg·m²
///     joint damping    = 0.1 N·s/m (slide), 0.002 N·m·s (hinge)
///     actuator         = motor, gear 50, so F = 50·u newtons
///
/// giving, for the state `[x, ẋ, θ, ω]`,
///
///     ẍ = -0.0356 ẋ -  1.005 θ + 0.0017 ω + 17.79 u
///     ω̇ =  0.0854 ẋ + 25.946 θ - 0.0441 ω - 42.69 u
///
/// with `Q = diag(1, 1, 10, 1)`, `R = 1`. The closed-loop poles are -46.6, -2.80 ± 0.77j and
/// -1.07, i.e. the pole is caught in a fraction of a second and the cart returns to the origin
/// over a couple of seconds.
///
/// **Honest limits.** These gains come from the *linearised* model, so they are only
/// guaranteed near upright; they cannot swing the pole up from hanging, and with `|u| ≤ 1` the
/// recoverable set is bounded. Against the nonlinear model they recover from |θ₀| up to about
/// 0.55 rad — past this task's own 0.7 rad failure threshold — and tolerate a doubled cart
/// mass, a ±50% pole mass error, a 30% loss of actuator gear, and 5× the joint damping, which
/// is the margin that matters given that the linearisation neglects the solver's discrete-time
/// behaviour.
public struct LQRCartPole: Policy {

    public let observationSize = CartPole.observationSize
    public let actionSize = CartPole.actionSize

    /// Cart position gain, N per metre of control units.
    public let positionGain: Double

    /// Cart velocity gain.
    public let velocityGain: Double

    /// Pole angle gain. By far the largest: the angle is the unstable mode, and a positive θ
    /// (tip leaning toward `+x`) is corrected by driving the cart toward `+x`, hence the
    /// positive sign on all four terms.
    public let angleGain: Double

    /// Pole angular-rate gain.
    public let angularRateGain: Double

    /// The actuator's control range.
    public let controlRange: ClosedRange<Double>

    /// The gains derived above. Overridable so the same structure can be re-tuned if the
    /// scene's masses change, without a second type.
    public init(
        positionGain: Double = 1.0000,
        velocityGain: Double = 1.6280,
        angleGain: Double = 8.6712,
        angularRateGain: Double = 1.9254,
        controlRange: ClosedRange<Double> = CartPole.controlRange
    ) {
        self.positionGain = positionGain
        self.velocityGain = velocityGain
        self.angleGain = angleGain
        self.angularRateGain = angularRateGain
        self.controlRange = controlRange
    }

    /// `[kₓ, k_ẋ, k_θ, k_ω]`, in the observation's order.
    public var gains: [Double] { [positionGain, velocityGain, angleGain, angularRateGain] }

    public func action(observation: [Double]) -> [Double] {
        guard observation.count >= CartPole.observationSize else { return [0] }
        let u =
            positionGain * observation[0]
            + velocityGain * observation[1]
            + angleGain * observation[2]
            + angularRateGain * observation[3]
        guard u.isFinite else { return [0] }
        return [min(max(u, controlRange.lowerBound), controlRange.upperBound)]
    }
}

// MARK: - Optimiser seam

/// Everything `CartPoleTrainer` asks of a gradient-free optimiser.
///
/// A protocol rather than a direct call so that the trainer's logic — the rollouts, the fixed
/// perturbation set, the metrics — can be exercised with a stub, and so that all of the
/// coupling to `Trainer` sits in one adapter below.
public protocol PolicyOptimizer {

    /// Maximises `objective` over a flat parameter vector of length `parameterCount`.
    func optimize(
        parameterCount: Int,
        settings: PolicyOptimizerSettings,
        objective: @escaping ([Double]) -> Double
    ) throws -> [Double]
}

/// Search budget and shape.
public struct PolicyOptimizerSettings: Sendable, Equatable {

    /// Generations.
    public var iterations: Int

    /// Candidates sampled per generation. Cross-entropy needs this to be comfortably larger
    /// than the dimension of the search space; see `CartPoleTrainer.defaultSpec`.
    public var population: Int

    /// Fraction of each generation kept to refit the sampling distribution.
    public var eliteFraction: Double

    /// Seeds both the optimiser's sampling and the network's initialisation.
    public var seed: UInt64

    public init(iterations: Int, population: Int, eliteFraction: Double, seed: UInt64) {
        self.iterations = iterations
        self.population = population
        self.eliteFraction = eliteFraction
        self.seed = seed
    }
}

/// Adapter onto `Trainer.crossEntropyMethod`. The whole of KineticML's ML backend enters this
/// file through this one function body.
public struct CrossEntropyOptimizer: PolicyOptimizer {

    /// The topology whose parameters are being searched.
    public let spec: MLPSpec

    public init(spec: MLPSpec) {
        self.spec = spec
    }

    public func optimize(
        parameterCount: Int,
        settings: PolicyOptimizerSettings,
        objective: @escaping ([Double]) -> Double
    ) throws -> [Double] {
        try Trainer.crossEntropyMethod(
            spec: spec,
            evaluate: objective,
            parameterCount: parameterCount,
            iterations: settings.iterations,
            population: settings.population,
            eliteFraction: settings.eliteFraction,
            seed: settings.seed)
    }
}

// MARK: - Trained artefact

/// A trained controller, reduced to something that can be committed next to the scene it
/// drives: the topology, the numbers, and the score it actually achieved.
///
/// The metrics are stored rather than recomputed because they are a claim about a specific
/// build of the physics engine. If a change to the solver makes the committed policy worse, a
/// re-evaluation that disagrees with `meanSteps` is exactly the signal that should be noticed.
public struct TrainedPolicy: Codable, Sendable, Equatable {

    /// Network topology. Enough to rebuild the policy without the training code.
    public var spec: MLPSpec

    /// Flat parameter vector, in `Trainer`'s layout.
    public var parameters: [Double]

    /// Mean steps survived at evaluation, out of `CartPole.episodeLength`.
    public var meanSteps: Double

    /// Mean accumulated reward per evaluation episode.
    public var meanReward: Double

    /// Fraction of evaluation episodes that survived the full episode.
    public var successRate: Double

    /// Search budget that produced this, kept so a result can be reproduced.
    public var iterations: Int
    public var population: Int
    public var seed: UInt64

    /// Where the search ran, e.g. the Metal device. Recorded because a policy trained on a
    /// different backend is worth re-checking, not because it changes how it is loaded.
    public var device: String

    public init(
        spec: MLPSpec,
        parameters: [Double],
        meanSteps: Double,
        meanReward: Double,
        successRate: Double,
        iterations: Int,
        population: Int,
        seed: UInt64,
        device: String
    ) {
        self.spec = spec
        self.parameters = parameters
        self.meanSteps = meanSteps
        self.meanReward = meanReward
        self.successRate = successRate
        self.iterations = iterations
        self.population = population
        self.seed = seed
        self.device = device
    }

    /// Rebuilds the runnable policy.
    ///
    /// - Throws: `MLError` if the spec is unbuildable or MLX is unavailable. Callers that
    ///   must not fail should fall back to `LQRCartPole()`.
    public func makePolicy(controlRange: ClosedRange<Double> = CartPole.controlRange) throws
        -> NeuralPolicy
    {
        let network = try MLP(spec: spec)
        try Trainer.load(parameters, into: network)
        return NeuralPolicy(
            network: network,
            observationSize: spec.inputSize,
            actionSize: spec.outputSize,
            controlRange: controlRange)
    }

    /// JSON with sorted keys, so a committed checkpoint produces a stable diff.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TrainedPolicy {
        try JSONDecoder().decode(TrainedPolicy.self, from: data)
    }

    public func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    public static func load(contentsOf url: URL) throws -> TrainedPolicy {
        try decode(Data(contentsOf: url))
    }
}

// MARK: - Trainer

/// Trains and scores cart-pole controllers.
public enum CartPoleTrainer {

    /// One seeded initial condition. Held as a value so the same set can be replayed for
    /// every candidate in a search and again at evaluation time.
    public struct Perturbation: Sendable, Equatable {

        /// Initial pole angle, radians.
        public var angle: Double

        /// Initial pole angular rate, rad/s.
        public var angularRate: Double

        /// Initial cart offset, metres.
        public var position: Double

        public init(angle: Double, angularRate: Double = 0, position: Double = 0) {
            self.angle = angle
            self.angularRate = angularRate
            self.position = position
        }
    }

    /// The topology searched by `train`.
    ///
    /// Deliberately tiny: 4 → 8 → 1 is 49 parameters. Cross-entropy fits a diagonal Gaussian
    /// over the whole parameter vector from a handful of elites, so its sample requirement
    /// grows with the dimension — a two-hidden-layer network of width 16 is 369 parameters and
    /// would need a population in the hundreds before the elite statistics mean anything. A
    /// smaller network that the search can actually solve is worth more than a larger one it
    /// cannot. `tanh` squashing puts every sampled action inside the actuator's range from the
    /// first generation, so no candidate can blow the integrator up.
    public static let defaultSpec = MLPSpec(
        inputSize: CartPole.observationSize,
        hiddenSizes: [8],
        outputSize: CartPole.actionSize,
        activation: .tanh,
        outputSquash: .tanh(low: CartPole.controlRange.lowerBound,
                            high: CartPole.controlRange.upperBound))

    /// Initial conditions used to score every training candidate. Four is a compromise: more
    /// makes the objective less noisy, and every one of them multiplies the cost of a
    /// generation by a full rollout.
    public static let trainingEpisodes = 4

    /// Draws a reproducible set of initial conditions.
    ///
    /// Ranges are a little inside the failure thresholds. Starting a candidate at 0.6 rad
    /// would mostly measure whether the *initial* state is recoverable at all rather than
    /// whether the policy is any good.
    public static func perturbations(count: Int, seed: UInt64) -> [Perturbation] {
        var rng = PolicyRandom(seed: seed)
        return (0..<max(count, 0)).map { _ in
            Perturbation(
                angle: rng.uniform(in: -0.20...0.20),
                angularRate: rng.uniform(in: -0.25...0.25),
                position: rng.uniform(in: -0.15...0.15))
        }
    }

    /// Trains a network policy with the cross-entropy method.
    ///
    /// Each candidate is scored by replaying the *same* seeded set of initial conditions, so
    /// the objective is a deterministic function of the parameter vector and two candidates
    /// are always compared on identical work. Each rollout resets the world, applies its
    /// perturbation, runs up to `CartPole.episodeLength` steps, accumulates `CartPole.reward`,
    /// and stops the moment `CartPole.isTerminated` fires — which is also what makes the
    /// search affordable, since a bad candidate falls within a fraction of a second and costs
    /// a fraction of a full rollout.
    ///
    /// What this method can and cannot do, plainly. CEM is a distribution-fitting search: it
    /// samples parameter vectors, keeps the best fraction, and refits a Gaussian to them. It
    /// needs no gradients and no differentiable simulator, which is why it fits here. It has
    /// no notion of *which step* earned the reward, so it cannot do the credit assignment a
    /// policy-gradient method would; it optimises the mean over this fixed perturbation set,
    /// so a policy that is excellent on three initial conditions and hopeless on the fourth
    /// can outscore a uniformly competent one; and it will happily overfit those four
    /// conditions, which is exactly why `evaluate` re-scores on a different seed.
    ///
    /// - Parameter progress: called at most once per generation with `(generation, best score
    ///   in that generation)`. Generation boundaries are inferred from the evaluation count,
    ///   because the optimiser exposes no callback of its own.
    /// - Throws: `MLError` if MLX cannot build or run the network.
    public static func train(
        iterations: Int = 60,
        population: Int = 64,
        seed: UInt64 = 0x5EED_CA11,
        progress: ((Int, Double) -> Void)? = nil
    ) throws -> TrainedPolicy {
        try train(
            spec: defaultSpec,
            optimizer: CrossEntropyOptimizer(spec: defaultSpec),
            iterations: iterations,
            population: population,
            seed: seed,
            progress: progress)
    }

    /// `train(iterations:population:seed:progress:)` with the topology and the optimiser
    /// injected. The default path calls straight into this.
    public static func train(
        spec: MLPSpec,
        optimizer: any PolicyOptimizer,
        iterations: Int = 60,
        population: Int = 64,
        seed: UInt64 = 0x5EED_CA11,
        progress: ((Int, Double) -> Void)? = nil
    ) throws -> TrainedPolicy {
        try spec.validate()

        // Pin the ML backend's own stream before anything allocates weights, so a rerun with
        // the same seed produces the same initial distribution.
        MLRuntime.seed(seed)

        let episodes = perturbations(count: trainingEpisodes, seed: seed &+ 0x9E37)
        let monitor = GenerationMonitor(population: population, progress: progress)
        let settings = PolicyOptimizerSettings(
            iterations: iterations,
            population: population,
            eliteFraction: 0.2,
            seed: seed)

        let best = try optimizer.optimize(
            parameterCount: spec.parameterCount,
            settings: settings
        ) { parameters in
            let score = objective(parameters: parameters, spec: spec, episodes: episodes)
            monitor.record(score)
            return score
        }

        // Score the winner on initial conditions it was never trained against. These are the
        // numbers that get committed, so they have to be the out-of-sample ones.
        let network = try MLP(spec: spec)
        try Trainer.load(best, into: network)
        let policy = NeuralPolicy(
            network: network,
            observationSize: spec.inputSize,
            actionSize: spec.outputSize,
            controlRange: CartPole.controlRange)
        let metrics = evaluate(policy, episodes: 25, seed: seed &+ 0xA5A5)

        return TrainedPolicy(
            spec: spec,
            parameters: best,
            meanSteps: metrics.meanSteps,
            meanReward: metrics.meanReward,
            successRate: metrics.successRate,
            iterations: iterations,
            population: population,
            seed: seed,
            device: MLRuntime.isAvailable ? MLRuntime.deviceDescription : "unavailable")
    }

    /// Scores a policy over `episodes` seeded initial conditions.
    ///
    /// - Returns: mean steps survived, mean accumulated reward, and the fraction of episodes
    ///   that lasted the full `CartPole.episodeLength`.
    public static func evaluate(
        _ policy: any Policy,
        episodes: Int = 25,
        seed: UInt64 = 0xE1A4_0000
    ) -> (meanSteps: Double, meanReward: Double, successRate: Double) {
        let conditions = perturbations(count: episodes, seed: seed)
        guard !conditions.isEmpty else { return (0, 0, 0) }

        let world = SceneLibrary.cartPole()
        let runner = CartPole.runner(world: world, policy: policy)
        var totalSteps = 0.0
        var totalReward = 0.0
        var successes = 0

        for condition in conditions {
            prepare(world, condition)
            let result = runner.rollout(
                steps: CartPole.episodeLength,
                reward: CartPole.reward,
                isTerminated: CartPole.isTerminated)
            totalSteps += Double(result.steps)
            totalReward += result.reward
            if result.steps >= CartPole.episodeLength { successes += 1 }
        }

        let count = Double(conditions.count)
        return (totalSteps / count, totalReward / count, Double(successes) / count)
    }

    // MARK: Internals

    /// Mean reward of one candidate over the shared perturbation set.
    ///
    /// A fresh `World` per call rather than a shared one: the optimiser is free to evaluate
    /// candidates concurrently, and a `World` is a handle to mutable C++ state that would be
    /// corrupted by two rollouts at once. Building the scene is a few thousand
    /// floating-point operations against rollouts that are millions, so the cost is noise.
    private static func objective(
        parameters: [Double],
        spec: MLPSpec,
        episodes: [Perturbation]
    ) -> Double {
        guard !episodes.isEmpty else { return 0 }
        guard let network = try? MLP(spec: spec), (try? Trainer.load(parameters, into: network)) != nil
        else {
            // An unbuildable candidate scores the worst possible value rather than throwing:
            // one bad sample must not abort a search that is otherwise making progress.
            return -Double(CartPole.episodeLength)
        }

        let policy = NeuralPolicy(
            network: network,
            observationSize: spec.inputSize,
            actionSize: spec.outputSize,
            controlRange: CartPole.controlRange)
        let world = SceneLibrary.cartPole()
        let runner = CartPole.runner(world: world, policy: policy)

        var total = 0.0
        for condition in episodes {
            prepare(world, condition)
            total += runner.rollout(
                steps: CartPole.episodeLength,
                reward: CartPole.reward,
                isTerminated: CartPole.isTerminated
            ).reward
        }
        return total / Double(episodes.count)
    }

    /// Resets the world and installs one initial condition.
    ///
    /// Simulation options are left exactly as `SceneLibrary.cartPole()` set them. Training
    /// against a modified timestep or solver would produce a policy tuned to a simulation the
    /// app never runs.
    private static func prepare(_ world: World, _ condition: Perturbation) {
        world.reset()
        let q = world.positions
        let v = world.velocities
        guard q.count >= 2, v.count >= 2 else { return }
        q[0] = condition.position
        q[1] = condition.angle          // overrides the scene's 0.08 rad default lean
        v[0] = 0
        v[1] = condition.angularRate
        if world.actuatorCount > 0 { world.control[0] = 0 }
        // Refresh derived quantities so the first observation matches the state just written.
        world.forward()
    }

    /// Turns a stream of candidate scores into per-generation progress reports.
    ///
    /// A reference type behind a lock because the optimiser may score candidates from several
    /// threads; the counting has to be exact for the generation boundaries to line up, and
    /// the callback fires outside the lock so a slow UI update cannot serialise the search.
    private final class GenerationMonitor: @unchecked Sendable {

        private let lock = NSLock()
        private let population: Int
        private let progress: ((Int, Double) -> Void)?
        private var evaluations = 0
        private var generation = 0
        private var best = -Double.infinity

        init(population: Int, progress: ((Int, Double) -> Void)?) {
            self.population = max(population, 1)
            self.progress = progress
        }

        func record(_ score: Double) {
            guard progress != nil else { return }
            var report: (Int, Double)?
            lock.lock()
            evaluations += 1
            if score > best { best = score }
            if evaluations % population == 0 {
                generation += 1
                report = (generation, best)
                best = -.infinity
            }
            lock.unlock()
            if let report { progress?(report.0, report.1) }
        }
    }
}
