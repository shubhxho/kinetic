// MLRuntime.swift
//
// The bottom layer of KineticML: device discovery, determinism control, and the
// conversion boundary between Kinetic's double-precision physics state and MLX's
// float32 tensors.
//
// Everything above this file (Networks, Training, and any policy that ships with a
// robot description) assumes the guarantees established here and nowhere else.

import Foundation
import Metal

import MLX
import MLXRandom

// MARK: - Errors

/// Failures that KineticML reports instead of returning degenerate values.
///
/// MLX's own C++ layer defaults to `fatalError` on an internal error. Every entry
/// point in KineticML that touches MLX runs inside `MLX.withError { ... }`, which
/// converts those into Swift errors, so a malformed shape aborts the caller's
/// training run rather than the whole simulator.
public enum MLError: Error, LocalizedError, Sendable, Equatable {

    /// No usable MLX device could be initialised on this machine.
    case backendUnavailable(String)

    /// A tensor, parameter vector, or dataset had the wrong shape.
    case shapeMismatch(String)

    /// An `MLPSpec` described a network that cannot be built.
    case invalidSpec(String)

    /// A checkpoint on disk could not be read, or did not match the network.
    case checkpoint(String)

    /// A `TrainingConfig` or dataset was not usable.
    case invalidConfiguration(String)

    /// An error raised by MLX itself and captured at the KineticML boundary.
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable(let message):
            return "KineticML: MLX backend unavailable — \(message)"
        case .shapeMismatch(let message):
            return "KineticML: shape mismatch — \(message)"
        case .invalidSpec(let message):
            return "KineticML: invalid network spec — \(message)"
        case .checkpoint(let message):
            return "KineticML: checkpoint error — \(message)"
        case .invalidConfiguration(let message):
            return "KineticML: invalid configuration — \(message)"
        case .backend(let message):
            return "KineticML: MLX error — \(message)"
        }
    }
}

// MARK: - Runtime

/// Device discovery and determinism control for KineticML.
///
/// `MLRuntime` is the only place that decides *where* tensor work runs. Callers ask for
/// availability, they are never told to assume it. Three outcomes are distinguished, and
/// they are genuinely different situations:
///
/// - **GPU** — `isAvailable == true`. The normal case on Apple silicon.
/// - **CPU** — `isAvailable == false`, `isUsable == true`. MLX works but Metal does not.
///   This is the state of a SwiftPM command-line build, which cannot compile MLX's Metal
///   kernel library; training still runs, just slower. Reporting this as "unavailable"
///   would be a lie, and reporting it as GPU would be a worse one.
/// - **Neither** — `isUsable == false`. Every entry point throws
///   `MLError.backendUnavailable` with the reason MLX gave.
public enum MLRuntime {

    // MARK: Availability

    /// Which device the probe settled on.
    enum Backend: Sendable {
        case gpu
        case cpu
    }

    /// Result of the one-time device probe. Computed lazily on first access and cached,
    /// because the probe allocates a device and runs a real kernel.
    ///
    /// The probe is deliberately an *actual computation* rather than a capability query.
    /// `MTLCreateSystemDefaultDevice()` returning non-nil does not prove that MLX can
    /// dispatch its Metal kernels — a missing `default.metallib` (every SwiftPM CLI build)
    /// and a sandbox that forbids GPU access both pass that check and then fail on first
    /// use. Multiplying two numbers and reading the answer back proves the whole path.
    private static let probeResult: Result<Backend, MLError> = {
        var gpuFailure = "no default Metal device on this system"
        if MTLCreateSystemDefaultDevice() != nil {
            switch probe(.gpu, label: "GPU") {
            case .success:
                return .success(.gpu)
            case .failure(let error):
                gpuFailure = error.errorDescription ?? String(describing: error)
            }
        }
        switch probe(.cpu, label: "CPU") {
        case .success:
            return .success(.cpu)
        case .failure(let error):
            return .failure(
                .backendUnavailable(
                    "GPU: \(gpuFailure); CPU: \(error.errorDescription ?? "\(error)")"))
        }
    }()

    /// Runs `3² + 4² == 25` on `deviceType` and reports whether the whole path worked.
    ///
    /// Takes a `DeviceType` rather than a `Device` so that constructing the device happens
    /// *inside* the error scope: `Device.init` eagerly creates the device's default stream,
    /// and that is already enough to fail on a build with no Metal library. Evaluating
    /// `Device.gpu` as an argument would raise the error outside `withError`, where MLX's
    /// default handler aborts the process.
    private static func probe(_ deviceType: DeviceType, label: String) -> Result<Void, MLError> {
        do {
            try MLX.withError { (errors: ErrorBox) in
                let device = Device(deviceType)
                try errors.check()
                try Device.withDefaultDevice(device) {
                    let a = MLXArray(converting: [3.0, 4.0])
                    let sumOfSquares = (a * a).sum()
                    MLX.eval(sumOfSquares)

                    // Check before touching the result. MLX's error handler records the
                    // failure but execution continues, and reading a value out of an array
                    // that was never computed trips a `precondition` inside MLX — a hard
                    // crash where a thrown error is what we owe the caller.
                    try errors.check()

                    guard sumOfSquares.size == 1 else {
                        throw MLError.backendUnavailable(
                            "\(label) probe produced a \(sumOfSquares.size)-element result")
                    }
                    let value = sumOfSquares.item(Float.self)
                    try errors.check()
                    guard value == 25 else {
                        throw MLError.backendUnavailable(
                            "\(label) probe returned \(value) where 25 was expected")
                    }
                }
            }
            return .success(())
        } catch let error as MLError {
            return .failure(error)
        } catch {
            return .failure(.backendUnavailable("\(label): \(error)"))
        }
    }

    /// Whether an MLX **GPU** device is usable on this machine, determined by running a
    /// real kernel once at first access rather than by assuming Apple silicon implies Metal.
    ///
    /// `false` does not mean KineticML cannot train — see ``isUsable``.
    public static var isAvailable: Bool {
        if case .success(.gpu) = probeResult { return true }
        return false
    }

    /// Whether MLX can execute at all, on any device.
    ///
    /// This is the flag that decides whether training is possible. `isAvailable == false &&
    /// isUsable == true` means CPU-only: correct results, materially slower.
    public static var isUsable: Bool {
        if case .success = probeResult { return true }
        return false
    }

    /// Throws a descriptive `MLError.backendUnavailable` when MLX cannot run at all.
    ///
    /// Every constructor and training entry point calls this first. KineticML never
    /// substitutes a zero-filled tensor or an untrained network for a missing backend:
    /// a controller that silently outputs zeros looks like a working controller that has
    /// learned to do nothing, which is the worst possible failure mode for a robotics
    /// simulator.
    public static func requireBackend() throws {
        if case .failure(let error) = probeResult {
            throw error
        }
    }

    /// A short human-readable description of the compute device, suitable for a status bar
    /// or an About panel.
    ///
    /// Examples: `"Apple GPU (Apple M3 Max), 64 GB unified memory"`, `"CPU (Metal
    /// unavailable)"`, `"unavailable"`.
    public static var deviceDescription: String {
        switch probeResult {
        case .failure:
            return "unavailable"
        case .success(.cpu):
            return "CPU (Metal unavailable)"
        case .success(.gpu):
            let info = GPU.deviceInfo()
            let gigabytes = Double(info.memorySize) / 1_073_741_824.0
            let memory = gigabytes >= 1
                ? String(format: "%.0f GB unified memory", gigabytes.rounded())
                : "unified memory"
            if info.architecture.isEmpty || info.architecture == "Unknown" {
                return "Apple GPU, \(memory)"
            }
            return "Apple GPU (\(info.architecture)), \(memory)"
        }
    }

    // MARK: Determinism

    /// Seeds MLX's global random stream.
    ///
    /// Kinetic's physics core is bit-deterministic: the same world, the same inputs, and
    /// the same step count produce byte-identical state on every run, which is what makes
    /// recorded trajectories comparable and regression tests meaningful. Machine learning
    /// must not undermine that guarantee, so every source of randomness in KineticML is
    /// explicitly seeded and none of them read the system entropy pool:
    ///
    /// 1. Network weight initialisation draws from MLX's global stream, seeded here.
    /// 2. Mini-batch ordering in `Trainer.fitRegression` uses a SplitMix64 generator
    ///    seeded from `TrainingConfig.seed` — deliberately *not* MLX's stream, so that
    ///    changing the network architecture does not change the batch order.
    /// 3. The CEM sampler in `Trainer.crossEntropyMethod` uses its own SplitMix64 seeded
    ///    from its `seed` argument, so a gradient-free training run is reproducible even
    ///    on a machine where MLX is not used at all.
    ///
    /// What this does *not* promise: bit-identical results across different MLX versions,
    /// across GPU and CPU execution, or across machines with different GPU architectures.
    /// Floating-point reduction order on a GPU depends on the dispatch geometry. Seeding
    /// makes a run reproducible on a given machine and build; it does not make float32
    /// GPU arithmetic associative. Trajectories replayed through the physics core remain
    /// bit-exact regardless, because a trained policy is loaded from fixed weights.
    public static func seed(_ value: UInt64) {
        MLXRandom.seed(value)
    }

    // MARK: Device scoping

    /// Runs `body` with the best available device installed as MLX's default.
    ///
    /// The device is chosen once per call from the cached probe, so a long training loop
    /// pays for the decision once. Scoping is task-local, which means concurrent Kinetic
    /// worlds training in parallel do not fight over a global setting.
    public static func withDevice<T>(_ body: () throws -> T) rethrows -> T {
        let device = isAvailable ? Device.gpu : Device.cpu
        return try Device.withDefaultDevice(device, body)
    }

    /// Runs `body` on the best available device and converts any MLX-internal failure into
    /// a thrown `MLError` instead of letting MLX call `fatalError`.
    ///
    /// This is the wrapper the rest of KineticML uses; `withDevice` alone is offered for
    /// callers that want to compose their own error handling.
    ///
    /// The `ErrorBox` handed to `body` lets it check for MLX errors *mid-flight*. That
    /// matters because MLX's error handler is not an exception: after it fires, execution
    /// continues with an uncomputed array, and reading a scalar out of one trips a
    /// `precondition` inside MLX. Any code that calls `.item(_:)` must check the box first.
    /// Errors are also collected on block exit, so bodies that only build and evaluate
    /// arrays need not check at all.
    static func withCheckedDevice<T>(_ body: (ErrorBox) throws -> T) throws -> T {
        try requireBackend()
        do {
            return try MLX.withError { (errors: ErrorBox) -> T in
                try withDevice { try body(errors) }
            }
        } catch let error as MLError {
            throw error
        } catch let error as MLXError {
            throw MLError.backend(error.errorDescription ?? String(describing: error))
        }
    }
}

// MARK: - Tensor bridge

/// Conversions between Kinetic's `[Double]` / `[Float]` state vectors and `MLXArray`.
///
/// ## The precision boundary
///
/// Kinetic's physics core is double precision throughout — `World.saveState()` hands back
/// `[Double]`, mass matrices and Jacobians are `[Double]`, and the integrator's
/// determinism guarantee rests on f64 arithmetic. MLX, like every practical GPU ML stack,
/// works in float32.
///
/// KineticML makes that conversion explicit and one-directional in intent: **f64 is the
/// simulation's truth, f32 is the learning signal's working precision.** Narrowing happens
/// at exactly two points — `MLTensorBridge` on the way in, and `asArray(Float.self)` on the
/// way out — and never inside a physics step.
///
/// This is safe for the same reason it is standard practice:
///
/// - Observations fed to a policy are sensor-like quantities (joint angles, velocities,
///   contact forces). f32 carries ~7 decimal digits, far more than any real encoder or
///   force sensor resolves, and far more than the noise a robust controller must tolerate.
/// - Gradients are a *search direction*, not a physical quantity. Their f32 rounding error
///   is orders of magnitude below the stochasticity already present in mini-batching,
///   weight initialisation, and — for CEM — the sampling distribution itself.
/// - The values that must stay f64 never make this trip. Integration, constraint solving,
///   and contact resolution all stay inside the C++ core in double precision; the network
///   only ever sees a copy of the state and only ever returns a control target, which the
///   core immediately widens back to f64.
///
/// What is *not* safe, and is therefore not offered here: round-tripping simulation state
/// through MLX and writing it back with `World.loadState(_:)`. That would silently truncate
/// 53 bits of mantissa to 24 and break bit-determinism. Nothing in this type produces a
/// state vector intended for `loadState`.
public struct MLTensorBridge {

    /// The dtype every tensor crossing this boundary is stored in.
    ///
    /// Exposed so that callers can assert on it rather than rediscover it, and so the
    /// f64 → f32 narrowing described above is a named constant instead of a convention.
    public static let storageDType: DType = .float32

    private init() {}

    // MARK: Swift → MLX (1-D)

    /// Builds a rank-1 `MLXArray` of shape `[values.count]` from a physics state vector.
    ///
    /// Each `Double` is narrowed to `Float`. See the type documentation for why that is
    /// the correct boundary for a learning signal.
    public static func vector(_ values: [Double]) -> MLXArray {
        MLXArray(converting: values)
    }

    /// Builds a rank-1 `MLXArray` of shape `[values.count]`. No precision is lost here —
    /// `Float` is already MLX's working type.
    public static func vector(_ values: [Float]) -> MLXArray {
        MLXArray(values)
    }

    // MARK: Swift → MLX (2-D batches)

    /// Builds a rank-2 `MLXArray` of shape `[rows.count, width]` from a batch of state
    /// vectors, narrowing f64 → f32.
    ///
    /// - Throws: `MLError.shapeMismatch` if the batch is empty or ragged. A ragged batch
    ///   is always a caller bug — padding it would produce a network that trains on
    ///   fabricated observations.
    public static func matrix(_ rows: [[Double]]) throws -> MLXArray {
        let width = try uniformWidth(of: rows.map(\.count), label: "double batch")
        var flat = [Float]()
        flat.reserveCapacity(rows.count * width)
        for row in rows {
            for value in row { flat.append(Float(value)) }
        }
        return MLXArray(flat, [rows.count, width])
    }

    /// Builds a rank-2 `MLXArray` of shape `[rows.count, width]` from a batch of `Float`
    /// vectors.
    ///
    /// - Throws: `MLError.shapeMismatch` if the batch is empty or ragged.
    public static func matrix(_ rows: [[Float]]) throws -> MLXArray {
        let width = try uniformWidth(of: rows.map(\.count), label: "float batch")
        var flat = [Float]()
        flat.reserveCapacity(rows.count * width)
        for row in rows { flat.append(contentsOf: row) }
        return MLXArray(flat, [rows.count, width])
    }

    // MARK: MLX → Swift (1-D)

    /// Reads an `MLXArray` back as `[Double]`, flattening any shape in row-major order.
    ///
    /// The widening f32 → f64 is exact — every `Float` is representable as a `Double` —
    /// so this direction never loses information. It also does not *recover* the precision
    /// that was dropped on the way in; the extra digits are zeros, not measurements.
    public static func doubles(_ array: MLXArray) -> [Double] {
        floats(array).map(Double.init)
    }

    /// Reads an `MLXArray` back as `[Float]`, flattening any shape in row-major order.
    public static func floats(_ array: MLXArray) -> [Float] {
        // MLX is lazy: without an explicit eval the buffer behind `asArray` may not have
        // been materialised yet.
        MLX.eval(array)
        return array.asArray(Float.self)
    }

    // MARK: MLX → Swift (2-D batches)

    /// Reads a rank-2 `MLXArray` back as a batch of `[Double]` rows.
    ///
    /// - Throws: `MLError.shapeMismatch` if `array` is not rank-2.
    public static func doubleRows(_ array: MLXArray) throws -> [[Double]] {
        try floatRows(array).map { $0.map(Double.init) }
    }

    /// Reads a rank-2 `MLXArray` back as a batch of `[Float]` rows.
    ///
    /// - Throws: `MLError.shapeMismatch` if `array` is not rank-2.
    public static func floatRows(_ array: MLXArray) throws -> [[Float]] {
        let shape = array.shape
        guard shape.count == 2 else {
            throw MLError.shapeMismatch(
                "expected a rank-2 batch, got shape \(shape)")
        }
        let (rowCount, width) = (shape[0], shape[1])
        let flat = floats(array)
        guard flat.count == rowCount * width else {
            throw MLError.shapeMismatch(
                "tensor of shape \(shape) yielded \(flat.count) elements")
        }
        var rows = [[Float]]()
        rows.reserveCapacity(rowCount)
        for index in 0 ..< rowCount {
            let start = index * width
            rows.append(Array(flat[start ..< (start + width)]))
        }
        return rows
    }

    // MARK: Helpers

    /// Validates that a batch is non-empty and rectangular, returning its width.
    private static func uniformWidth(of widths: [Int], label: String) throws -> Int {
        guard let first = widths.first else {
            throw MLError.shapeMismatch("\(label) is empty; a batch needs at least one row")
        }
        guard first > 0 else {
            throw MLError.shapeMismatch("\(label) has zero-width rows")
        }
        for (index, width) in widths.enumerated() where width != first {
            throw MLError.shapeMismatch(
                "\(label) is ragged: row 0 has width \(first) but row \(index) has width \(width)")
        }
        return first
    }
}
