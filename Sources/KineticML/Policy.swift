// Policy.swift
//
// The seam between a controller and a simulation.
//
// A "policy" here is deliberately the smallest possible thing: observations in, actions out,
// no state, no simulator reference, no knowledge of what it is driving. Everything that ties
// a policy to a particular robot — which coordinates to read, which actuators to write, what
// counts as reward — lives in the closures a `PolicyRunner` is built with, or in a task
// definition like `CartPole`. That split is what lets one harness score a hand-derived linear
// law, a learned network, and a scripted baseline against each other without special cases.

import Foundation
import Kinetic

// MARK: - Policy

/// A deterministic mapping from an observation vector to an action vector.
///
/// `Sendable` because policies are read-only after construction and get evaluated from
/// whatever thread the optimiser or the render loop happens to be on. Implementations must
/// therefore not accumulate state across calls: a policy that remembers is a policy whose
/// score depends on the order candidates were evaluated in, which would destroy the
/// reproducibility the rest of this package is built on.
public protocol Policy: Sendable {

    /// Width of the vector `action(observation:)` expects.
    var observationSize: Int { get }

    /// Width of the vector `action(observation:)` returns.
    var actionSize: Int { get }

    /// Maps one observation to one action.
    ///
    /// Implementations must tolerate a wrong-width observation rather than trap. A policy is
    /// evaluated thousands of times per training run, sometimes on a diverging simulation
    /// that produces `NaN`; killing the process there would lose the whole run.
    func action(observation: [Double]) -> [Double]
}

// MARK: - Network seam

/// The only thing `NeuralPolicy` needs from a neural network.
///
/// Kept as a one-method protocol so that this file has no compile-time dependency on MLX or
/// on the shape of `MLP`. Swapping in a different backend, or a stub in a test, is a matter
/// of conforming a type to this and nothing else.
public protocol PolicyNetwork: AnyObject {

    /// Forward pass. Returns an empty array if the input was unusable — see `MLP.predict(_:)`.
    func predict(_ input: [Double]) -> [Double]
}

/// The single line of coupling to the MLX-backed network. `MLP.predict(_:)` already has the
/// required shape, including the empty-array-on-failure contract.
extension MLP: PolicyNetwork {}

// MARK: - Linear policy

/// An affine map `action = clamp(W · observation + b)`.
///
/// Two jobs. First, it is the honest baseline: if a network cannot beat a linear map on a
/// task, the network is not earning its keep. Second, it is the harness's own sanity check —
/// it has no dependencies at all, so a failure while running one localises the bug to the
/// runner or the task definition rather than to the learner.
public struct LinearPolicy: Policy {

    public let observationSize: Int
    public let actionSize: Int

    /// Row-major `actionSize × observationSize`. Flat rather than nested because this is also
    /// the layout a gradient-free optimiser searches over.
    public let weights: [Double]

    /// One bias per action.
    public let biases: [Double]

    /// Applied to every output. `nil` leaves the raw affine value alone.
    public let outputRange: ClosedRange<Double>?

    /// Builds a policy, resizing `weights` and `biases` to the shape implied by
    /// `observationSize` and `actionSize`: short arrays are zero-padded, long ones truncated.
    ///
    /// Resizing rather than trapping is deliberate. The caller is often an optimiser handing
    /// over a candidate vector whose length came from a spec that may have been edited on
    /// disk; a wrong length should degrade into a well-defined (bad-scoring) policy, not a
    /// crash in the middle of a search.
    public init(
        observationSize: Int,
        actionSize: Int,
        weights: [Double],
        biases: [Double] = [],
        outputRange: ClosedRange<Double>? = -1...1
    ) {
        let inputs = max(observationSize, 0)
        let outputs = max(actionSize, 0)
        self.observationSize = inputs
        self.actionSize = outputs
        self.weights = LinearPolicy.resized(weights, to: inputs * outputs)
        self.biases = LinearPolicy.resized(biases, to: outputs)
        self.outputRange = outputRange
    }

    /// Number of scalars a search over this topology has to optimise.
    public static func parameterCount(observationSize: Int, actionSize: Int) -> Int {
        max(observationSize, 0) * max(actionSize, 0) + max(actionSize, 0)
    }

    /// Builds a policy from one flat vector: all weights row-major, then all biases.
    ///
    /// This is the layout `CartPoleTrainer` hands to the optimiser, so the same
    /// `[Double]` can describe either a linear baseline or a network's parameters.
    public init(
        parameters: [Double],
        observationSize: Int,
        actionSize: Int,
        outputRange: ClosedRange<Double>? = -1...1
    ) {
        let inputs = max(observationSize, 0)
        let outputs = max(actionSize, 0)
        let split = inputs * outputs
        let padded = LinearPolicy.resized(parameters, to: split + outputs)
        self.init(
            observationSize: inputs,
            actionSize: outputs,
            weights: Array(padded[0..<split]),
            biases: Array(padded[split...]),
            outputRange: outputRange)
    }

    /// The flat vector form, matching `init(parameters:observationSize:actionSize:)`.
    public var parameters: [Double] { weights + biases }

    public func action(observation: [Double]) -> [Double] {
        guard actionSize > 0 else { return [] }
        let shared = min(observationSize, observation.count)
        var result = [Double](repeating: 0, count: actionSize)
        for row in 0..<actionSize {
            var sum = biases[row]
            let base = row * observationSize
            for column in 0..<shared {
                sum += weights[base + column] * observation[column]
            }
            result[row] = clamped(sum)
        }
        return result
    }

    private func clamped(_ value: Double) -> Double {
        // A diverged simulation feeds NaN in; commanding zero is the safe reading of "no
        // information", and it keeps the actuator inside its range no matter what.
        guard value.isFinite else { return 0 }
        guard let range = outputRange else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func resized(_ values: [Double], to count: Int) -> [Double] {
        if values.count == count { return values }
        if values.count > count { return Array(values[0..<count]) }
        return values + [Double](repeating: 0, count: count - values.count)
    }
}

// MARK: - Neural policy

/// A `Policy` backed by a neural network, clamped to an actuator's control range.
///
/// The clamp is not cosmetic. A network's output layer is unbounded unless the spec squashes
/// it, and the physics core applies `gear × ctrl` as a generalised force without checking the
/// actuator's range — an untrained network can therefore command a force large enough to blow
/// the integrator up in one step. Clamping here means every action a policy can emit, at any
/// point in training, is one the real robot could have been asked for.
public final class NeuralPolicy: Policy, @unchecked Sendable {

    /// The network. `@unchecked Sendable` on the class covers this: the network's parameters
    /// are written once, before the policy is constructed, and `predict(_:)` only reads them.
    /// Conforming `MLP` itself to `Sendable` would be a stronger claim than is true — it is
    /// mutable during training — so the narrower claim is made here, where it holds.
    private let network: any PolicyNetwork

    public let observationSize: Int
    public let actionSize: Int

    /// The actuator control range every output is clamped into.
    public let controlRange: ClosedRange<Double>

    public init(
        network: any PolicyNetwork,
        observationSize: Int,
        actionSize: Int,
        controlRange: ClosedRange<Double> = -1...1
    ) {
        self.network = network
        self.observationSize = max(observationSize, 0)
        self.actionSize = max(actionSize, 0)
        self.controlRange = controlRange
    }

    public func action(observation: [Double]) -> [Double] {
        let input = NeuralPolicy.resized(observation, to: observationSize)
        let raw = network.predict(input)
        var result = [Double](repeating: 0, count: actionSize)
        for index in 0..<actionSize {
            // `predict` returns an empty array when the backend refuses the call. Zero is the
            // only defensible action then: it is inside every actuator range and it does not
            // masquerade as a decision the network made.
            let value = index < raw.count ? raw[index] : 0
            result[index] = value.isFinite
                ? min(max(value, controlRange.lowerBound), controlRange.upperBound)
                : 0
        }
        return result
    }

    private static func resized(_ values: [Double], to count: Int) -> [Double] {
        if values.count == count { return values }
        if values.count > count { return Array(values[0..<count]) }
        return values + [Double](repeating: 0, count: count - values.count)
    }
}

// MARK: - Runner

/// Binds a `Policy` to a `World`.
///
/// Everything task-specific is a closure, so this type never learns what a cart-pole is. The
/// same runner drives a quadruped's 12 actuators from a 40-value observation given different
/// closures, and — importantly for training — the closures are the only thing that has to
/// change when the observation is re-scaled or the reward re-shaped.
public struct PolicyRunner {

    /// The simulation being driven. A reference: stepping mutates it in place.
    public let world: World

    /// The controller.
    public let policy: any Policy

    /// Reads the observation vector out of the world.
    private let observation: (World) -> [Double]

    /// Writes an action into the world's control buffer.
    private let apply: (World, [Double]) -> Void

    public init(
        world: World,
        policy: any Policy,
        observation: @escaping (World) -> [Double],
        apply: @escaping (World, [Double]) -> Void
    ) {
        self.world = world
        self.policy = policy
        self.observation = observation
        self.apply = apply
    }

    /// Observe, act, write the control, advance one timestep.
    ///
    /// One policy evaluation per physics step. Real controllers run slower than the physics
    /// (500 Hz here is far above any sensible control rate), but decimating the policy is a
    /// property of a specific task, so a caller who wants it holds the action themselves and
    /// calls `world.step()` in between.
    public func step() {
        apply(world, policy.action(observation: observation(world)))
        world.step()
    }

    /// Runs up to `steps` steps and returns the accumulated reward.
    ///
    /// - Parameters:
    ///   - steps: maximum number of physics steps.
    ///   - reward: scored after each step. `nil` counts one point per surviving step.
    @discardableResult
    public func run(steps: Int, reward: ((World) -> Double)? = nil) -> Double {
        rollout(steps: steps, reward: reward).reward
    }

    /// `run(steps:reward:)` with early termination and the surviving step count.
    ///
    /// Training needs both numbers: reward is what the optimiser maximises, steps is what a
    /// human reads. Reward is credited only for states that pass `isTerminated`, so a policy
    /// cannot bank points for the step on which it fell over.
    public func rollout(
        steps: Int,
        reward: ((World) -> Double)? = nil,
        isTerminated: ((World) -> Bool)? = nil
    ) -> (steps: Int, reward: Double) {
        var total = 0.0
        var completed = 0
        for _ in 0..<max(steps, 0) {
            step()
            if isTerminated?(world) == true { break }
            completed += 1
            total += reward?(world) ?? 1
        }
        return (completed, total)
    }
}

// MARK: - Cart-pole task

/// The cart-pole task: what to observe, how to act, what is worth points, and when it is over.
///
/// One place, so that the trainer, the evaluator, the analytic controller and the app all
/// agree. A policy trained against a reward defined here and then run against a differently
/// shaped reward elsewhere would silently look worse than it is.
public enum CartPole {

    /// `[x, ẋ, θ, ω]`.
    public static let observationSize = 4

    /// One actuator: the motor on the cart's prismatic joint, `ctrl ∈ [-1, 1]`.
    public static let actionSize = 1

    /// The actuator's control range, from `SceneLibrary.cartPole()`.
    public static let controlRange: ClosedRange<Double> = -1...1

    /// Failure threshold on cart position, in metres. Inside the joint's own ±2.4 limit, so
    /// an episode ends because the task was failed and not because the cart hit a hard stop —
    /// the constraint force from a limit would make the reward signal discontinuous.
    public static let positionLimit = 2.2

    /// Failure threshold on pole angle, in radians (≈40°). Beyond this the linearisation the
    /// analytic controller is derived from stops being meaningful.
    public static let angleLimit = 0.7

    /// Steps in a full episode: 1000 at the default 1/500 s timestep, i.e. two seconds.
    public static let episodeLength = 1000

    /// `[x, ẋ, θ, ω]` — cart position and velocity, pole angle and angular rate.
    ///
    /// θ is the revolute joint's coordinate about `+y`, so a positive θ tips the pole's tip
    /// toward `+x`, and pushing the cart toward `+x` is the corrective action.
    public static func observation(_ world: World) -> [Double] {
        let q = world.positions
        let v = world.velocities
        guard q.count >= 2, v.count >= 2 else {
            return [Double](repeating: 0, count: observationSize)
        }
        return [q[0], v[0], q[1], v[1]]
    }

    /// Writes the first action value into the cart motor, clamped to its control range.
    public static func apply(_ world: World, _ action: [Double]) {
        guard world.actuatorCount > 0 else { return }
        let raw = action.first ?? 0
        world.control[0] = raw.isFinite
            ? min(max(raw, controlRange.lowerBound), controlRange.upperBound)
            : 0
    }

    /// Reward for the current state, in `[0.2, 1]` while alive.
    ///
    /// Shaping rationale. A pure alive bonus (1 per surviving step) is the honest objective,
    /// but it is nearly flat: early in a cross-entropy search almost every candidate falls at
    /// roughly the same time, so the elite set is chosen from a tie and the search wanders.
    /// Every term below is normalised by the value at which the episode *ends*, so the weights
    /// are directly comparable and the total can never go negative while alive:
    ///
    /// - `1` — alive bonus, still the dominant term. Surviving beats posing.
    /// - `0.50 (θ/θₘₐₓ)²` — the actual task. Quadratic, so it separates "nearly upright" from
    ///   "leaning but not yet failed", which is exactly the distinction a tie-broken elite set
    ///   needs.
    /// - `0.25 (x/xₘₐₓ)²` — stay near the origin. Without it, drifting off at constant speed
    ///   scores the same as balancing in place until the moment the cart runs out of track.
    /// - `0.05 u²` — effort. Small on purpose: it discourages the full-scale chatter that a
    ///   gradient-free search finds attractive (bang-bang balances fine and costs nothing
    ///   otherwise), without ever making it preferable to fall over quietly.
    ///
    /// The control term reads the value applied on the step just taken, which is what
    /// `PolicyRunner` leaves in the buffer when it scores.
    public static func reward(_ world: World) -> Double {
        let state = observation(world)
        let angle = state[2] / angleLimit
        let position = state[0] / positionLimit
        let effort = world.actuatorCount > 0 ? world.control[0] : 0
        let value = 1.0 - 0.5 * angle * angle - 0.25 * position * position - 0.05 * effort * effort
        return value.isFinite ? value : 0
    }

    /// True once the cart has left the track or the pole has fallen past `angleLimit`.
    ///
    /// A non-finite state also terminates: a diverged simulation is a failed episode, and
    /// letting `NaN` propagate into the reward would poison the optimiser's mean.
    public static func isTerminated(_ world: World) -> Bool {
        let state = observation(world)
        guard state[0].isFinite, state[2].isFinite else { return true }
        return abs(state[0]) > positionLimit || abs(state[2]) > angleLimit
    }

    /// A runner wired to this task.
    public static func runner(world: World, policy: any Policy) -> PolicyRunner {
        PolicyRunner(world: world, policy: policy, observation: observation, apply: apply)
    }
}
