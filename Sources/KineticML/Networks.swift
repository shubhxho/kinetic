// Networks.swift
//
// The one network topology KineticML ships: a plain multi-layer perceptron, described by a
// value type, and serialised as JSON.
//
// A robotics simulator's policies are small — tens of thousands of parameters, not billions.
// That changes the engineering trade-off completely: a trained controller should be a text
// file you can open, diff, and commit next to the URDF it drives. Hence JSON rather than
// safetensors, and hence a `Codable` spec rather than a builder DSL.

import Foundation

import MLX
import MLXNN

// MARK: - Spec

/// Hidden-layer activation.
public enum MLActivation: String, Codable, Sendable, CaseIterable {
    case relu
    case tanh
    case gelu

    /// The corresponding stateless MLX layer.
    func layer() -> UnaryLayer {
        switch self {
        case .relu: return ReLU()
        case .tanh: return Tanh()
        case .gelu: return GELU()
        }
    }
}

/// Optional squashing applied to the network's output.
///
/// Robot actuators have limits. A policy whose raw linear output is fed to a joint can and
/// will command a torque outside the actuator's range early in training, which in a rigid
/// body simulator manifests as an explosion rather than a bad reward. Squashing the output
/// into the actuator range makes every sample the optimiser draws physically admissible.
public enum MLOutputSquash: Codable, Sendable, Equatable {

    /// The final linear layer's output is used directly.
    case none

    /// `tanh` rescaled from its natural `[-1, 1]` onto `[low, high]`.
    ///
    /// The gradient is largest at the centre of the range, so a policy initialised near
    /// zero starts in the responsive part of the curve rather than saturated.
    case tanh(low: Double, high: Double)
}

/// A declarative description of a multi-layer perceptron.
///
/// This is the unit of persistence: a checkpoint is a spec plus its weights, so loading a
/// trained policy never requires the code that built it to still exist in the same shape.
public struct MLPSpec: Codable, Sendable, Equatable {

    /// Width of the observation vector, e.g. `World.saveState().count` or a hand-picked
    /// slice of it.
    public var inputSize: Int

    /// Widths of the hidden layers, outermost first. Empty means a single linear map.
    public var hiddenSizes: [Int]

    /// Width of the action vector.
    public var outputSize: Int

    /// Activation between hidden layers. Never applied after the output layer.
    public var activation: MLActivation

    /// Squashing applied after the output layer.
    public var outputSquash: MLOutputSquash

    public init(
        inputSize: Int,
        hiddenSizes: [Int],
        outputSize: Int,
        activation: MLActivation = .tanh,
        outputSquash: MLOutputSquash = .none
    ) {
        self.inputSize = inputSize
        self.hiddenSizes = hiddenSizes
        self.outputSize = outputSize
        self.activation = activation
        self.outputSquash = outputSquash
    }

    /// The number of trainable scalars a network built from this spec will contain.
    ///
    /// Computed arithmetically, without instantiating anything, so `Trainer` can size a
    /// gradient-free search over a flat parameter vector on a machine where MLX has not
    /// been touched yet.
    public var parameterCount: Int {
        var total = 0
        var previous = inputSize
        for width in hiddenSizes {
            total += previous * width + width  // weight + bias
            previous = width
        }
        total += previous * outputSize + outputSize
        return total
    }

    /// Rejects specs that cannot describe a network.
    ///
    /// - Throws: `MLError.invalidSpec`.
    public func validate() throws {
        guard inputSize > 0 else {
            throw MLError.invalidSpec("inputSize must be positive, got \(inputSize)")
        }
        guard outputSize > 0 else {
            throw MLError.invalidSpec("outputSize must be positive, got \(outputSize)")
        }
        for (index, width) in hiddenSizes.enumerated() where width <= 0 {
            throw MLError.invalidSpec(
                "hidden layer \(index) has non-positive width \(width)")
        }
        if case .tanh(let low, let high) = outputSquash {
            guard low.isFinite, high.isFinite else {
                throw MLError.invalidSpec("output squash bounds must be finite")
            }
            guard low < high else {
                throw MLError.invalidSpec(
                    "output squash requires low < high, got low=\(low) high=\(high)")
            }
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case inputSize, hiddenSizes, outputSize, activation, outputSquash
    }

    /// Hand-written so that a human editing a checkpoint by hand can omit the fields that
    /// have obvious defaults and still get a loadable file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputSize = try container.decode(Int.self, forKey: .inputSize)
        hiddenSizes = try container.decodeIfPresent([Int].self, forKey: .hiddenSizes) ?? []
        outputSize = try container.decode(Int.self, forKey: .outputSize)
        activation =
            try container.decodeIfPresent(MLActivation.self, forKey: .activation) ?? .tanh
        outputSquash =
            try container.decodeIfPresent(MLOutputSquash.self, forKey: .outputSquash) ?? .none
    }
}

// MARK: - Scaled tanh layer

/// `tanh` rescaled onto `[low, high]`, as a parameterless MLX layer.
///
/// Implemented as a layer rather than as post-processing so that it sits inside the
/// `Sequential` and therefore inside `valueAndGrad`'s trace: supervised training sees the
/// squashing when it computes gradients, which is the only way the loss can teach the
/// network to stay off the saturated tails.
final class ScaledTanh: Module, UnaryLayer {

    let center: Float
    let halfRange: Float

    init(low: Float, high: Float) {
        self.center = (high + low) / 2
        self.halfRange = (high - low) / 2
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        center + halfRange * MLX.tanh(x)
    }
}

// MARK: - Network

/// A multi-layer perceptron built from an ``MLPSpec``.
///
/// Reference type because it owns MLX parameter buffers that the optimiser mutates in
/// place; copying one would silently fork a training run.
public final class MLP {

    /// The description this network was built from. Persisted alongside the weights.
    public let spec: MLPSpec

    /// The underlying MLX module. Package-internal: `Trainer` needs it for `valueAndGrad`
    /// and for the optimiser, but exposing an `MLXNN.Sequential` publicly would leak MLX
    /// into every caller's type signatures.
    let net: Sequential

    /// Builds and initialises the network.
    ///
    /// Weight initialisation draws from MLX's global random stream. Call
    /// ``MLRuntime/seed(_:)`` first if you need the initial weights to be reproducible —
    /// `Trainer` does this for you.
    ///
    /// - Throws: `MLError.invalidSpec` for an unbuildable spec, or
    ///   `MLError.backendUnavailable` if MLX cannot run on this machine. It never returns
    ///   a placeholder network.
    public init(spec: MLPSpec) throws {
        try spec.validate()
        self.spec = spec
        self.net = try MLRuntime.withCheckedDevice { _ in MLP.makeNetwork(spec) }
        // Realise the freshly initialised parameters now, so that a later failure is
        // attributable to training rather than to lazy construction.
        try MLRuntime.withCheckedDevice { _ in MLX.eval(self.net) }
    }

    private static func makeNetwork(_ spec: MLPSpec) -> Sequential {
        var layers = [UnaryLayer]()
        var previous = spec.inputSize
        for width in spec.hiddenSizes {
            layers.append(Linear(previous, width))
            layers.append(spec.activation.layer())
            previous = width
        }
        layers.append(Linear(previous, spec.outputSize))
        if case .tanh(let low, let high) = spec.outputSquash {
            layers.append(ScaledTanh(low: Float(low), high: Float(high)))
        }
        return Sequential(layers: layers)
    }

    // MARK: Evaluation

    /// Forward pass. Accepts either a rank-1 vector of width `spec.inputSize` or a rank-2
    /// batch of shape `[n, spec.inputSize]`.
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        net(x)
    }

    /// Total number of trainable scalars, read from the live parameters.
    ///
    /// Agrees with `spec.parameterCount`; this variant is the ground truth because it
    /// reflects what was actually built.
    public func parameterCount() -> Int {
        net.parameters().flattenedValues().reduce(0) { $0 + $1.size }
    }

    /// Runs one observation through the network, for callers that never want to see an
    /// `MLXArray`.
    ///
    /// - Returns: `spec.outputSize` values, or an **empty array** if the input was the
    ///   wrong width or MLX failed. Empty is unambiguous — a successful call always
    ///   returns at least one value, because `outputSize` is validated to be positive —
    ///   and it is deliberately not a vector of zeros, which would be indistinguishable
    ///   from a policy that has learned to do nothing. Use ``predictChecked(_:)`` when you
    ///   want the reason.
    public func predict(_ input: [Double]) -> [Double] {
        (try? predictChecked(input)) ?? []
    }

    /// ``predict(_:)`` with the failure reason preserved.
    ///
    /// - Throws: `MLError.shapeMismatch` if `input.count != spec.inputSize`, or an
    ///   `MLError` from the backend.
    public func predictChecked(_ input: [Double]) throws -> [Double] {
        guard input.count == spec.inputSize else {
            throw MLError.shapeMismatch(
                "network expects \(spec.inputSize) inputs, got \(input.count)")
        }
        return try MLRuntime.withCheckedDevice { _ in
            let x = MLTensorBridge.vector(input)
            let y = net(x.reshaped([1, spec.inputSize]))
            return MLTensorBridge.doubles(y)
        }
    }

    /// Runs a batch of observations in one dispatch. Much faster than looping
    /// ``predict(_:)`` when scoring a population of rollouts.
    ///
    /// - Throws: `MLError.shapeMismatch` for an empty, ragged, or wrong-width batch.
    public func predictBatch(_ inputs: [[Double]]) throws -> [[Double]] {
        for (index, row) in inputs.enumerated() where row.count != spec.inputSize {
            throw MLError.shapeMismatch(
                "row \(index) has width \(row.count), expected \(spec.inputSize)")
        }
        return try MLRuntime.withCheckedDevice { _ in
            let x = try MLTensorBridge.matrix(inputs)
            return try MLTensorBridge.doubleRows(net(x))
        }
    }

    // MARK: Persistence

    /// On-disk representation: the spec plus every parameter tensor, keyed by its path in
    /// the module tree.
    ///
    /// Values are stored as `Double`. Every `Float` is exactly representable as a `Double`,
    /// so the round trip is lossless, and JSON has no float type to distinguish them
    /// anyway — this only affects how many digits a human sees.
    private struct Checkpoint: Codable {
        struct Parameter: Codable {
            var key: String
            var shape: [Int]
            var values: [Double]
        }
        var format: String
        var spec: MLPSpec
        var parameters: [Parameter]
    }

    /// The format tag written into every checkpoint, so a future reader can refuse a file
    /// it does not understand rather than misinterpret it.
    private static let checkpointFormat = "kinetic.mlp.v1"

    /// Writes the spec and weights to `url` as JSON.
    ///
    /// Pretty-printed with sorted keys: the file is meant to be committed next to the robot
    /// description it drives, and a stable key order keeps diffs meaningful across retrains.
    ///
    /// - Throws: `MLError` from the backend, or any error raised by `Data.write`.
    public func save(to url: URL) throws {
        let parameters: [Checkpoint.Parameter] = try MLRuntime.withCheckedDevice { _ in
            // `flattened()` emits dictionary keys in sorted order, so the parameter list is
            // canonical and byte-stable across runs.
            net.parameters().flattened().map { key, array in
                Checkpoint.Parameter(
                    key: key,
                    shape: array.shape,
                    values: MLTensorBridge.doubles(array))
            }
        }
        let checkpoint = Checkpoint(
            format: MLP.checkpointFormat, spec: spec, parameters: parameters)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(checkpoint).write(to: url, options: .atomic)
    }

    /// Reads a checkpoint written by ``save(to:)``.
    ///
    /// Rebuilds the network from the stored spec, then installs the stored weights. Every
    /// key and shape is checked: a checkpoint that does not match the spec it carries is
    /// rejected rather than partially applied, because a half-loaded policy is a policy
    /// that looks trained and is not.
    ///
    /// - Throws: `MLError.checkpoint` on any mismatch, `MLError.invalidSpec` for an
    ///   unbuildable spec, or `MLError.backendUnavailable`.
    public static func load(from url: URL) throws -> MLP {
        let data = try Data(contentsOf: url)
        let checkpoint: Checkpoint
        do {
            checkpoint = try JSONDecoder().decode(Checkpoint.self, from: data)
        } catch {
            throw MLError.checkpoint(
                "could not decode \(url.lastPathComponent): \(error)")
        }
        guard checkpoint.format == checkpointFormat else {
            throw MLError.checkpoint(
                "unsupported format '\(checkpoint.format)', expected '\(checkpointFormat)'")
        }

        let model = try MLP(spec: checkpoint.spec)

        let stored = Dictionary(
            checkpoint.parameters.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        guard stored.count == checkpoint.parameters.count else {
            throw MLError.checkpoint("checkpoint contains duplicate parameter keys")
        }

        let expected = try MLRuntime.withCheckedDevice { _ in model.net.parameters().flattened() }
        guard expected.count == checkpoint.parameters.count else {
            throw MLError.checkpoint(
                "checkpoint has \(checkpoint.parameters.count) tensors, "
                    + "the spec builds a network with \(expected.count)")
        }

        var replacements = [(String, MLXArray)]()
        replacements.reserveCapacity(expected.count)
        for (key, current) in expected {
            guard let parameter = stored[key] else {
                throw MLError.checkpoint("checkpoint is missing parameter '\(key)'")
            }
            guard parameter.shape == current.shape else {
                throw MLError.checkpoint(
                    "parameter '\(key)' has shape \(parameter.shape) in the checkpoint "
                        + "but \(current.shape) in the network")
            }
            let count = parameter.shape.reduce(1, *)
            guard parameter.values.count == count else {
                throw MLError.checkpoint(
                    "parameter '\(key)' declares shape \(parameter.shape) (\(count) values) "
                        + "but carries \(parameter.values.count)")
            }
            replacements.append(
                (key, MLXArray(parameter.values.map(Float.init), parameter.shape)))
        }

        try MLRuntime.withCheckedDevice { _ in
            model.net.update(parameters: ModuleParameters.unflattened(replacements))
            MLX.eval(model.net)
        }
        return model
    }
}
