// Training.swift
//
// Two optimisers, chosen for two genuinely different situations.
//
// `fitRegression` is gradient-based: it needs a differentiable path from parameters to
// loss, which exists when you are cloning a demonstrated trajectory or distilling a
// planner into a network.
//
// `crossEntropyMethod` is gradient-free: it treats the objective as a black box. That is
// what a Kinetic rollout actually is — stepping the C++ physics core through a thousand
// timesteps, accumulating a reward, and returning a scalar. No gradient flows back through
// contact resolution, so no amount of autodiff will help. CEM is the one that will train a
// controller.

import Foundation

import MLX
import MLXNN
import MLXOptimizers

// MARK: - Configuration

/// Hyperparameters for supervised training.
public struct TrainingConfig: Sendable {

    /// Adam step size.
    public var learningRate: Double

    /// Rows per gradient step. Clamped to the dataset size when larger.
    public var batchSize: Int

    /// Number of passes over the dataset.
    public var epochs: Int

    /// Seed for weight initialisation and mini-batch ordering.
    ///
    /// See ``MLRuntime/seed(_:)`` for what reproducibility this does and does not buy.
    public var seed: UInt64

    /// Called once per epoch with `(epochIndex, meanLoss)`.
    ///
    /// KineticML never prints. A training run is a long-lived operation inside an app that
    /// owns its own UI, so progress is reported through this callback and nowhere else.
    /// `@Sendable` because a caller may well be driving a SwiftUI progress bar from another
    /// isolation domain.
    public var progress: (@Sendable (Int, Double) -> Void)?

    public init(
        learningRate: Double = 1e-3,
        batchSize: Int = 32,
        epochs: Int = 100,
        seed: UInt64 = 0,
        progress: (@Sendable (Int, Double) -> Void)? = nil
    ) {
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.epochs = epochs
        self.seed = seed
        self.progress = progress
    }

    /// - Throws: `MLError.invalidConfiguration`.
    func validate() throws {
        guard learningRate.isFinite, learningRate > 0 else {
            throw MLError.invalidConfiguration(
                "learningRate must be finite and positive, got \(learningRate)")
        }
        guard batchSize > 0 else {
            throw MLError.invalidConfiguration("batchSize must be positive, got \(batchSize)")
        }
        guard epochs > 0 else {
            throw MLError.invalidConfiguration("epochs must be positive, got \(epochs)")
        }
    }
}

// MARK: - Deterministic RNG

/// SplitMix64 — a small, fully specified generator used for everything in KineticML that
/// must be reproducible independently of MLX.
///
/// Deliberately not Swift's `SystemRandomNumberGenerator` (entropy-seeded, so a run could
/// never be replayed) and deliberately not MLX's stream (device-resident, so batch order
/// would depend on the network architecture and on whether the GPU was used). The algorithm
/// is integer-only and specified bit-for-bit, so the sequence is identical on every machine
/// and every Swift version.
struct SplitMix64 {

    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`, built from the top 53 bits so every value is exactly
    /// representable as a `Double`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2⁻⁵³
    }

    /// Uniform integer in `0 ..< bound` by rejection sampling, which is unbiased where
    /// `next() % bound` is not.
    mutating func nextBelow(_ bound: Int) -> Int {
        precondition(bound > 0)
        let limit = UInt64(bound)
        let threshold = UInt64.max - (UInt64.max % limit) - (limit - 1)
        while true {
            let value = next()
            if value <= threshold { return Int(value % limit) }
        }
    }

    /// Standard normal via the Marsaglia polar method.
    ///
    /// Preferred over Box-Muller here because it needs no trigonometric function; `log` and
    /// `sqrt` are both correctly rounded on Apple platforms, so the sequence is stable.
    mutating func nextGaussian() -> Double {
        while true {
            let u = 2 * nextUnit() - 1
            let v = 2 * nextUnit() - 1
            let s = u * u + v * v
            if s > 0, s < 1 {
                return u * (-2 * Foundation.log(s) / s).squareRoot()
            }
        }
    }

    /// Fisher–Yates permutation of `0 ..< count`.
    ///
    /// Written out rather than using `shuffled(using:)` so that the batch order is pinned
    /// to this file and cannot drift with a standard-library implementation change.
    mutating func permutation(count: Int) -> [Int] {
        var indices = Array(0 ..< count)
        guard count > 1 else { return indices }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = nextBelow(i + 1)
            indices.swapAt(i, j)
        }
        return indices
    }
}

// MARK: - Trainer

/// Optimisers over ``MLP``.
public enum Trainer {

    // MARK: Supervised regression

    /// Fits `model` to `(inputs, targets)` by minimising mean squared error with Adam.
    ///
    /// Use this when a differentiable target exists: behaviour cloning from recorded
    /// trajectories, distilling a trajectory optimiser, or learning a residual dynamics
    /// model. If your objective is "run the simulation and see how it went", use
    /// ``crossEntropyMethod(spec:evaluate:parameterCount:iterations:population:eliteFraction:seed:)``
    /// instead — there is no gradient to follow through a contact solver.
    ///
    /// The model is trained in place. On a thrown error the model's parameters are left
    /// wherever the last successful step put them, which is stated here rather than
    /// silently rolled back.
    ///
    /// - Parameters:
    ///   - model: the network to train, mutated in place.
    ///   - inputs: `n` observation rows, each of width `model.spec.inputSize`.
    ///   - targets: `n` target rows, each of width `model.spec.outputSize`.
    ///   - config: hyperparameters and the per-epoch progress callback.
    /// - Returns: the mean training loss for each epoch, in order — `config.epochs` values.
    /// - Throws: `MLError.invalidConfiguration` for a bad config, `MLError.shapeMismatch`
    ///   for a dataset that does not match the model, or `MLError.backendUnavailable` /
    ///   `MLError.backend` when MLX cannot run the work.
    public static func fitRegression(
        model: MLP,
        inputs: [[Double]],
        targets: [[Double]],
        config: TrainingConfig
    ) throws -> [Double] {
        try config.validate()
        try MLRuntime.requireBackend()

        let rowCount = inputs.count
        guard rowCount > 0 else {
            throw MLError.shapeMismatch("training set is empty")
        }
        guard targets.count == rowCount else {
            throw MLError.shapeMismatch(
                "\(rowCount) input rows but \(targets.count) target rows")
        }
        let inputWidth = model.spec.inputSize
        let outputWidth = model.spec.outputSize
        for (index, row) in inputs.enumerated() where row.count != inputWidth {
            throw MLError.shapeMismatch(
                "input row \(index) has width \(row.count), expected \(inputWidth)")
        }
        for (index, row) in targets.enumerated() where row.count != outputWidth {
            throw MLError.shapeMismatch(
                "target row \(index) has width \(row.count), expected \(outputWidth)")
        }

        // Seed before anything stochastic happens. Batch order comes from our own
        // generator (below) so that it is independent of MLX's stream; this call covers
        // any MLX-side randomness the optimiser or the layers may draw on.
        MLRuntime.seed(config.seed)
        var rng = SplitMix64(seed: config.seed)

        // Narrow once, up front, into flat row-major buffers. Doing the f64 → f32
        // conversion per epoch would be pure waste, and doing it per batch would put a
        // conversion inside the hot loop. See `MLTensorBridge` for why f32 is the right
        // precision for a learning signal even though the physics core is f64.
        let flatInputs = inputs.flatMap { $0.map(Float.init) }
        let flatTargets = targets.flatMap { $0.map(Float.init) }

        let batchSize = min(config.batchSize, rowCount)
        let optimizer = Adam(learningRate: Float(config.learningRate))
        let lossAndGrad = valueAndGrad(model: model.net) {
            (network: Sequential, x: MLXArray, y: MLXArray) -> MLXArray in
            mseLoss(predictions: network(x), targets: y, reduction: .mean)
        }

        let progress = config.progress
        var history = [Double]()
        history.reserveCapacity(config.epochs)

        try MLRuntime.withCheckedDevice { errors in
            for epoch in 0 ..< config.epochs {
                let order = rng.permutation(count: rowCount)
                var weightedLoss = 0.0

                var start = 0
                while start < rowCount {
                    let end = min(start + batchSize, rowCount)
                    let rows = Array(order[start ..< end])

                    let x = MLXArray(
                        gather(flatInputs, rows: rows, width: inputWidth),
                        [rows.count, inputWidth])
                    let y = MLXArray(
                        gather(flatTargets, rows: rows, width: outputWidth),
                        [rows.count, outputWidth])

                    let (loss, gradients) = lossAndGrad(model.net, x, y)
                    optimizer.update(model: model.net, gradients: gradients)

                    // MLX is lazy; without this the graph would grow for a whole epoch
                    // before anything executed, and `loss.item` below would be the only
                    // thing forcing it. Evaluating the model and the optimiser state each
                    // step keeps peak memory proportional to one batch.
                    MLX.eval(model.net, optimizer)

                    // Surface an MLX failure before reading the loss out. `item(_:)`
                    // preconditions on the array actually having been computed, so on a
                    // backend error it would abort the process instead of throwing.
                    try errors.check()
                    guard loss.size == 1 else {
                        throw MLError.shapeMismatch(
                            "loss reduced to \(loss.size) values, expected a scalar")
                    }
                    weightedLoss += Double(loss.item(Float.self)) * Double(rows.count)
                    start = end
                }

                let meanLoss = weightedLoss / Double(rowCount)
                history.append(meanLoss)
                progress?(epoch, meanLoss)
            }
        }

        return history
    }

    /// Copies the selected rows out of a flat row-major buffer, preserving `rows` order.
    private static func gather(_ flat: [Float], rows: [Int], width: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(rows.count * width)
        for row in rows {
            let start = row * width
            out.append(contentsOf: flat[start ..< (start + width)])
        }
        return out
    }

    // MARK: Cross-entropy method

    /// A gradient-free cross-entropy-method search over a flat parameter vector.
    ///
    /// CEM maintains a diagonal Gaussian over parameter space. Each iteration it samples a
    /// population, scores every sample with `evaluate`, keeps the best `eliteFraction`, and
    /// refits the Gaussian to those elites. It needs nothing from the objective but a
    /// number, which is precisely the situation when the objective is a Kinetic rollout:
    /// stepping the rigid-body core through contact events is not differentiable, and a
    /// finite-difference gradient over thousands of parameters would cost thousands of
    /// rollouts per step where CEM costs `population`.
    ///
    /// The whole routine is plain Swift arithmetic with a specified PRNG — no MLX. That is
    /// intentional: a controller trained this way is reproducible from its seed on any
    /// machine, including one where the GPU is unavailable, and the search itself never
    /// becomes a source of the non-determinism Kinetic is built to avoid.
    ///
    /// - Parameters:
    ///   - spec: the network the parameter vector describes. `spec.parameterCount` is
    ///     authoritative for the search dimension, because it is the only length that can
    ///     be loaded back into a model.
    ///   - evaluate: scores a candidate parameter vector. **Higher is better** — return a
    ///     reward, or the negation of a cost. Called `iterations * population` times, and
    ///     called serially, so it may safely drive a single `World`.
    ///   - parameterCount: the caller's expectation of the search dimension, accepted for
    ///     call-site clarity. It must equal `spec.parameterCount`; where it does not, the
    ///     spec wins, since a vector of any other length could not be installed into a
    ///     network built from that spec.
    ///   - iterations: number of refit rounds. Values below 1 are treated as 1.
    ///   - population: samples per iteration. Values below 2 are treated as 2, since a
    ///     distribution cannot be refitted from a single point.
    ///   - eliteFraction: fraction of the population kept per round, clamped to
    ///     `(0, 1]`; at least one elite is always kept.
    ///   - seed: seeds the sampler. The same seed and the same `evaluate` give the same
    ///     answer.
    /// - Returns: the mean of the final distribution — `spec.parameterCount` values, ready
    ///   for ``load(_:into:)``.
    public static func crossEntropyMethod(
        spec: MLPSpec,
        evaluate: @escaping ([Double]) -> Double,
        parameterCount: Int,
        iterations: Int,
        population: Int,
        eliteFraction: Double,
        seed: UInt64
    ) -> [Double] {
        // The spec is the authority: see the `parameterCount` parameter documentation.
        // `_ = parameterCount` would hide the disagreement; using `dimension` everywhere
        // makes the resolution explicit and local.
        let dimension = spec.parameterCount
        guard dimension > 0 else { return [] }

        let rounds = max(1, iterations)
        let populationSize = max(2, population)
        let fraction = min(1.0, max(Double.leastNormalMagnitude, eliteFraction))
        let eliteCount = min(populationSize, max(1, Int((Double(populationSize) * fraction).rounded())))

        var rng = SplitMix64(seed: seed)

        // Start centred at zero with unit-ish spread. Zero mean matches the symmetry of a
        // freshly initialised network; a standard deviation near the scale of sensible
        // weights means the first population already contains usable controllers rather
        // than saturated ones.
        var mean = [Double](repeating: 0, count: dimension)
        var deviation = [Double](repeating: 0.5, count: dimension)

        // Floor on the standard deviation. Without it CEM collapses onto the first decent
        // elite set and then samples the same vector forever, which reads as convergence
        // but is premature termination.
        let minimumDeviation = 1e-4

        var candidate = [Double](repeating: 0, count: dimension)
        var samples = [[Double]]()
        var scores = [Double]()

        for _ in 0 ..< rounds {
            samples.removeAll(keepingCapacity: true)
            scores.removeAll(keepingCapacity: true)
            samples.reserveCapacity(populationSize)
            scores.reserveCapacity(populationSize)

            for _ in 0 ..< populationSize {
                for index in 0 ..< dimension {
                    candidate[index] = mean[index] + deviation[index] * rng.nextGaussian()
                }
                let score = evaluate(candidate)
                samples.append(candidate)
                // A non-finite score means the rollout diverged. Ranking it last is honest:
                // it is a real outcome of that parameter vector, not a missing measurement,
                // and dropping it would bias the elite set toward untested regions.
                scores.append(score.isFinite ? score : -.infinity)
            }

            // Descending by score; ties broken by index so the ordering is total and the
            // whole routine stays reproducible regardless of sort stability.
            let ranked = (0 ..< populationSize).sorted { lhs, rhs in
                scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
            }
            let elites = ranked.prefix(eliteCount)

            for index in 0 ..< dimension {
                var sum = 0.0
                for elite in elites { sum += samples[elite][index] }
                let newMean = sum / Double(eliteCount)

                var variance = 0.0
                for elite in elites {
                    let delta = samples[elite][index] - newMean
                    variance += delta * delta
                }
                // Population (biased) variance: with a handful of elites the unbiased
                // correction inflates the spread enough to stall convergence.
                variance /= Double(eliteCount)

                mean[index] = newMean
                deviation[index] = max(minimumDeviation, variance.squareRoot())
            }
        }

        return mean
    }

    // MARK: Flat parameter vectors

    /// Reads every parameter of `model` into one flat vector.
    ///
    /// The order is the canonical sorted-key order of the module tree, identical to the
    /// order ``load(_:into:)`` expects and to the order ``MLP/save(to:)`` writes. That is
    /// what lets a black-box optimiser treat the network as a point in `parameterCount`
    /// dimensions.
    ///
    /// - Returns: `model.parameterCount()` values, or an empty array if MLX failed. Use
    ///   ``flattenChecked(_:)`` for the reason.
    public static func flatten(_ model: MLP) -> [Double] {
        (try? flattenChecked(model)) ?? []
    }

    /// ``flatten(_:)`` with the failure reason preserved.
    ///
    /// - Throws: `MLError` from the backend.
    public static func flattenChecked(_ model: MLP) throws -> [Double] {
        try MLRuntime.withCheckedDevice { _ in
            var flat = [Double]()
            flat.reserveCapacity(model.parameterCount())
            for (_, array) in model.net.parameters().flattened() {
                flat.append(contentsOf: MLTensorBridge.doubles(array))
            }
            return flat
        }
    }

    /// Installs a flat parameter vector produced by ``flatten(_:)`` or by
    /// ``crossEntropyMethod(spec:evaluate:parameterCount:iterations:population:eliteFraction:seed:)``.
    ///
    /// On any mismatch the model is left **completely unmodified** — the vector is split
    /// and validated in full before a single tensor is replaced. A partially loaded network
    /// would behave like a trained one and score like noise.
    ///
    /// Use ``loadChecked(_:into:)`` when you need to know whether it took.
    public static func load(_ flat: [Double], into model: MLP) {
        try? loadChecked(flat, into: model)
    }

    /// ``load(_:into:)`` with the failure reason preserved.
    ///
    /// - Throws: `MLError.shapeMismatch` if `flat.count != model.parameterCount()`, or an
    ///   `MLError` from the backend.
    public static func loadChecked(_ flat: [Double], into model: MLP) throws {
        try MLRuntime.withCheckedDevice { _ in
            let current = model.net.parameters().flattened()
            let expected = current.reduce(0) { $0 + $1.1.size }
            guard flat.count == expected else {
                throw MLError.shapeMismatch(
                    "parameter vector has \(flat.count) values, network needs \(expected)")
            }

            var replacements = [(String, MLXArray)]()
            replacements.reserveCapacity(current.count)
            var offset = 0
            for (key, array) in current {
                let count = array.size
                let slice = flat[offset ..< (offset + count)].map(Float.init)
                replacements.append((key, MLXArray(slice, array.shape)))
                offset += count
            }

            model.net.update(parameters: ModuleParameters.unflattened(replacements))
            MLX.eval(model.net)
        }
    }
}
