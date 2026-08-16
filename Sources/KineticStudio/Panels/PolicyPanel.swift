//
//  PolicyPanel.swift
//  Kinetic Studio
//
//  Train a controller, look at the curve, run it on the live scene, and compare it
//  against the law you could have derived with a pencil. The comparison is the
//  point: a learned controller that cannot beat an analytic one is a result worth
//  seeing, not a result worth hiding.
//
//  Integration note — why the protocols below exist:
//  the trainer lives in the KineticML target, which is being written in parallel
//  with this file. Rather than import a moving target, the views depend on the
//  thin protocols below and a built-in trainer satisfies them today. When
//  KineticML lands, integration is one adapter:
//
//      extension TrainedPolicy: TrainedPolicyRepresentable {
//          var parameterCount: Int { parameters.count }
//          var specDescription: String { String(describing: spec) }
//          func encoded() throws -> Data { try JSONEncoder().encode(self) }
//          func action(observation: [Double]) -> [Double] { ... }   // via Policy
//      }
//      struct CartPoleDriver: PolicyTaskDriving { ... }  // wraps CartPoleTrainer,
//                                                        // LQRCartPole, MLRuntime
//
//  then `PolicyPanel(model: model, driver: CartPoleDriver())`.
//

import AppKit
import Foundation
import Kinetic
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Integration seam

/// Mirrors `KineticML.Policy`.
protocol PolicyActing {
    func action(observation: [Double]) -> [Double]
}

/// A policy that has been trained and can be written to disk.
protocol TrainedPolicyRepresentable: PolicyActing, Sendable {
    /// One line describing the architecture, shown under the results.
    var specDescription: String { get }
    var parameterCount: Int { get }
    func encoded() throws -> Data
}

struct PolicyEvaluation: Sendable {
    var meanSteps: Double
    var meanReward: Double
    var successRate: Double
}

/// One point on the training curve.
struct PolicyTrainingSample: Sendable, Identifiable {
    var iteration: Int
    var bestReward: Double
    var meanReward: Double
    var id: Int { iteration }
}

/// Everything the panel needs to train, score and drive one task.
///
/// `Sendable` because training runs on a detached task — the panel hands the
/// driver across, and gets progress marshalled back to the main actor.
protocol PolicyTaskDriving: Sendable {
    var taskName: String { get }
    var taskSummary: String { get }
    /// The scene this task expects; the panel offers to load it when it is missing.
    var sceneIdentifier: String { get }
    /// Mirrors `MLRuntime.isAvailable` / `.deviceDescription`.
    var isAccelerated: Bool { get }
    var deviceDescription: String { get }
    var baselineName: String { get }

    /// Blocking. Returns `nil` when `progress` asked it to stop.
    ///
    /// `progress` returns "keep going". A trainer that genuinely cannot be
    /// interrupted should train in chunks inside its adapter and honour the flag
    /// between them; the panel drops a cancelled result either way, so the UI
    /// never waits on it.
    func train(iterations: Int, population: Int, seed: UInt64,
               progress: @Sendable (PolicyTrainingSample) -> Bool) -> (any TrainedPolicyRepresentable)?

    func evaluate(_ policy: any PolicyActing, episodes: Int, seed: UInt64) -> PolicyEvaluation

    /// The hand-derived law to measure the learned one against.
    func baselinePolicy() -> any PolicyActing

    func decode(_ data: Data) throws -> any TrainedPolicyRepresentable

    /// Live-scene bridge. Separated from the task model so the panel never has to
    /// know how a scene lays out its coordinates.
    func observation(from world: World) -> [Double]?
    func apply(action: [Double], to world: World)
}

// MARK: - Built-in cart-pole driver

/// Deterministic 64-bit generator so a seed means the same run twice.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A four-weight linear controller: `force = tanh(w . observation) * limit`.
/// Small enough to read, which is the point — every parameter is on screen.
struct LinearCartPolePolicy: TrainedPolicyRepresentable, Codable {
    var weights: [Double]
    var forceLimit: Double
    var note: String

    var specDescription: String {
        "linear, tanh-squashed, \(weights.count) weights, force limit \(String(format: "%.1f", forceLimit)) N"
    }
    var parameterCount: Int { weights.count }

    func action(observation: [Double]) -> [Double] {
        var sum = 0.0
        for index in 0..<min(weights.count, observation.count) {
            sum += weights[index] * observation[index]
        }
        return [tanh(sum) * forceLimit]
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Random-search hill climbing on the textbook cart-pole. Not deep learning, and
/// the header says so — but it is a real optimiser producing a real curve, and it
/// swaps out for `CartPoleTrainer` at one call site.
///
/// Honest caveat surfaced in the UI: training happens against this analytic model,
/// not against the rigid-body engine. A policy that balances here can still fail
/// on the live scene when the two models disagree.
struct CartPoleHillClimb: PolicyTaskDriving {
    var taskName: String { "Cart-pole balance" }
    var taskSummary: String {
        "Keep the pole upright and the cart inside the track. Observation is "
            + "[cart position, cart velocity, pole angle, pole rate]; the action is a "
            + "single horizontal force."
    }
    var sceneIdentifier: String { "cartpole" }
    var isAccelerated: Bool { false }
    var deviceDescription: String { "CPU, single thread" }
    var baselineName: String { "hand-tuned linear law" }

    private let forceLimit = 10.0
    private let maximumSteps = 500

    // MARK: Training

    func train(iterations: Int, population: Int, seed: UInt64,
               progress: @Sendable (PolicyTrainingSample) -> Bool) -> (any TrainedPolicyRepresentable)? {
        var generator = SeededGenerator(seed: seed)
        var best = [Double](repeating: 0, count: 4)
        var bestScore = score(weights: best, episodes: 3, generator: &generator)
        // Start wide and narrow down: early iterations explore, late ones polish.
        var stepSize = 1.0

        for iteration in 0..<max(iterations, 1) {
            var iterationTotal = 0.0
            var iterationBest = -Double.greatestFiniteMagnitude

            for _ in 0..<max(population, 1) {
                var candidate = best
                for index in candidate.indices {
                    candidate[index] += Double.random(in: -stepSize...stepSize, using: &generator)
                }
                let candidateScore = score(weights: candidate, episodes: 3, generator: &generator)
                iterationTotal += candidateScore
                iterationBest = max(iterationBest, candidateScore)
                if candidateScore > bestScore {
                    bestScore = candidateScore
                    best = candidate
                }
            }

            stepSize = max(stepSize * 0.985, 0.05)
            let sample = PolicyTrainingSample(
                iteration: iteration + 1,
                bestReward: bestScore,
                meanReward: iterationTotal / Double(max(population, 1)))
            if !progress(sample) { return nil }
        }

        return LinearCartPolePolicy(
            weights: best, forceLimit: forceLimit,
            note: "trained by random-search hill climbing on the analytic cart-pole model")
    }

    private func score(weights: [Double], episodes: Int,
                       generator: inout SeededGenerator) -> Double {
        let policy = LinearCartPolePolicy(weights: weights, forceLimit: forceLimit, note: "")
        var total = 0.0
        for _ in 0..<max(episodes, 1) {
            total += rollout(policy, generator: &generator).reward
        }
        return total / Double(max(episodes, 1))
    }

    // MARK: Evaluation

    func evaluate(_ policy: any PolicyActing, episodes: Int, seed: UInt64) -> PolicyEvaluation {
        var generator = SeededGenerator(seed: seed)
        var steps = 0.0
        var reward = 0.0
        var successes = 0
        let count = max(episodes, 1)
        for _ in 0..<count {
            let result = rollout(policy, generator: &generator)
            steps += Double(result.steps)
            reward += result.reward
            // "Success" is the classic bar: survive the whole episode.
            if result.steps >= maximumSteps { successes += 1 }
        }
        return PolicyEvaluation(meanSteps: steps / Double(count),
                                meanReward: reward / Double(count),
                                successRate: Double(successes) / Double(count))
    }

    func baselinePolicy() -> any PolicyActing {
        // Gains in the shape an LQR solution takes for this plant: position and
        // velocity terms small, angle and angle-rate terms dominant.
        LinearCartPolePolicy(weights: [0.12, 0.35, 2.60, 0.55], forceLimit: forceLimit,
                             note: "hand-tuned stand-in for the analytic law")
    }

    func decode(_ data: Data) throws -> any TrainedPolicyRepresentable {
        try JSONDecoder().decode(LinearCartPolePolicy.self, from: data)
    }

    // MARK: Analytic model

    /// Textbook cart-pole: cart mass 1 kg, pole 0.1 kg over 1 m, 20 ms control tick.
    private func rollout(_ policy: any PolicyActing,
                         generator: inout SeededGenerator) -> (steps: Int, reward: Double) {
        var x = Double.random(in: -0.05...0.05, using: &generator)
        var xDot = Double.random(in: -0.05...0.05, using: &generator)
        var theta = Double.random(in: -0.05...0.05, using: &generator)
        var thetaDot = Double.random(in: -0.05...0.05, using: &generator)

        let gravity = 9.81
        let cartMass = 1.0
        let poleMass = 0.1
        let totalMass = cartMass + poleMass
        let halfLength = 0.5
        let poleMoment = poleMass * halfLength
        let tau = 0.02
        let angleLimit = 12.0 * Double.pi / 180.0
        let trackLimit = 2.4

        var reward = 0.0
        for step in 0..<maximumSteps {
            let force = min(max(policy.action(observation: [x, xDot, theta, thetaDot]).first ?? 0,
                                -forceLimit), forceLimit)
            let cosTheta = cos(theta)
            let sinTheta = sin(theta)
            let temp = (force + poleMoment * thetaDot * thetaDot * sinTheta) / totalMass
            let thetaAcceleration = (gravity * sinTheta - cosTheta * temp)
                / (halfLength * (4.0 / 3.0 - poleMass * cosTheta * cosTheta / totalMass))
            let xAcceleration = temp - poleMoment * thetaAcceleration * cosTheta / totalMass

            x += tau * xDot
            xDot += tau * xAcceleration
            theta += tau * thetaDot
            thetaDot += tau * thetaAcceleration

            // Reward staying alive, and prefer being centred and upright over
            // merely surviving — otherwise the optimiser is happy drifting.
            reward += 1.0 - 0.25 * abs(theta) / angleLimit - 0.10 * abs(x) / trackLimit

            if abs(x) > trackLimit || abs(theta) > angleLimit || !x.isFinite || !theta.isFinite {
                return (step + 1, reward)
            }
        }
        return (maximumSteps, reward)
    }

    // MARK: Live-scene bridge

    /// The cart-pole scene is one articulation: a prismatic slider then a hinge.
    /// If the loaded model is not that, there is no honest mapping, so return nil
    /// rather than feed the policy noise.
    func observation(from world: World) -> [Double]? {
        guard world.coordinateCount >= 2, world.dofCount >= 2 else { return nil }
        return [world.positions[0], world.velocities[0],
                world.positions[1], world.velocities[1]]
    }

    func apply(action: [Double], to world: World) {
        guard world.actuatorCount > 0, let force = action.first else { return }
        world.control[0] = min(max(force, -forceLimit), forceLimit)
    }
}

// MARK: - Session

/// Owns the training task and the control loop. It exists so the detached task
/// never captures the view: progress lands here on the main actor, and SwiftUI
/// reads it as ordinary published state.
@MainActor
final class PolicyTrainingSession: ObservableObject {
    @Published private(set) var isTraining = false
    @Published private(set) var progressFraction = 0.0
    @Published private(set) var curve: [PolicyTrainingSample] = []
    @Published private(set) var trained: (any TrainedPolicyRepresentable)?
    @Published private(set) var evaluation: PolicyEvaluation?
    @Published private(set) var baseline: PolicyEvaluation?
    @Published private(set) var trainingSeconds: Double?
    @Published private(set) var isAttached = false
    @Published private(set) var status = ""

    private var task: Task<Void, Never>?
    private var controlTimer: Timer?

    /// Control refresh rate for a policy driving the live scene. The engine steps
    /// faster than this, so the last action is held between refreshes — a real
    /// zero-order hold, and the reason the panel says so out loud.
    private let controlHz = 120.0

    var isRunningLive: Bool { controlTimer != nil }

    // MARK: Training

    func train(using driver: any PolicyTaskDriving, iterations: Int, population: Int,
               seed: UInt64) {
        guard !isTraining else { return }
        cancel()
        curve = []
        progressFraction = 0
        trainingSeconds = nil
        isTraining = true
        status = "training \(iterations) iterations, population \(population), seed \(seed)"

        // Report at most ~120 points back to the UI: a 2000-iteration run does not
        // need 2000 main-actor hops to draw a curve 300 points wide.
        let reportEvery = max(1, iterations / 120)
        let started = Date()

        // Captured strongly: a main-actor class is Sendable, and the session has to
        // outlive the task anyway to receive the result. Cancellation, not a weak
        // reference, is what stops the work.
        task = Task.detached(priority: .userInitiated) { [session = self] in
            let result = driver.train(iterations: iterations, population: population,
                                      seed: seed) { sample in
                if Task.isCancelled { return false }
                if sample.iteration % reportEvery == 0 || sample.iteration == iterations {
                    // Progress crosses back to the main actor here and nowhere else.
                    Task { @MainActor in
                        session.record(sample, of: iterations)
                    }
                }
                return true
            }
            let elapsed = Date().timeIntervalSince(started)
            let scored = result.map { driver.evaluate($0, episodes: 24, seed: seed &+ 1) }
            await MainActor.run {
                session.finish(result, evaluation: scored, seconds: elapsed)
            }
        }
    }

    private func record(_ sample: PolicyTrainingSample, of iterations: Int) {
        guard isTraining else { return }
        curve.append(sample)
        progressFraction = min(Double(sample.iteration) / Double(max(iterations, 1)), 1)
    }

    private func finish(_ policy: (any TrainedPolicyRepresentable)?,
                        evaluation: PolicyEvaluation?, seconds: Double) {
        isTraining = false
        task = nil
        guard let policy else {
            status = "training cancelled"
            return
        }
        trained = policy
        self.evaluation = evaluation
        trainingSeconds = seconds
        progressFraction = 1
        status = "trained in \(String(format: "%.2f", seconds)) s"
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isTraining {
            isTraining = false
            status = "training cancelled"
        }
    }

    func measureBaseline(using driver: any PolicyTaskDriving, seed: UInt64) {
        baseline = driver.evaluate(driver.baselinePolicy(), episodes: 24, seed: seed &+ 1)
    }

    func adopt(_ policy: any TrainedPolicyRepresentable, using driver: any PolicyTaskDriving,
               seed: UInt64) {
        trained = policy
        evaluation = driver.evaluate(policy, episodes: 24, seed: seed &+ 1)
        curve = []
        trainingSeconds = nil
        progressFraction = 0
        status = "loaded a policy from disk"
    }

    // MARK: Live control

    func attach(driver: any PolicyTaskDriving, model: StudioModel) {
        guard let policy = trained, controlTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / controlHz, repeats: true) {
            [weak model] _ in
            Task { @MainActor in
                guard let model, !model.isScrubbing else { return }
                guard let observation = driver.observation(from: model.world) else { return }
                driver.apply(action: policy.action(observation: observation), to: model.world)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        controlTimer = timer
        isAttached = true
        model.log("policy attached to the live scene at \(Int(controlHz)) Hz", .success)
    }

    func detach(model: StudioModel?) {
        controlTimer?.invalidate()
        controlTimer = nil
        guard isAttached else { return }
        isAttached = false
        // Leave the actuators where they were rather than snapping to zero: a
        // sudden release is its own disturbance.
        model?.log("policy detached", .info)
    }
}

// MARK: - Panel

/// Train a controller, watch the curve, run it, and compare it with the analytic law.
///
/// `PolicyPanel(model: model)` uses the built-in cart-pole trainer. Pass a driver
/// to use the KineticML one: `PolicyPanel(model: model, driver: CartPoleDriver())`.
@MainActor
struct PolicyPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @StateObject private var session = PolicyTrainingSession()

    private let driver: any PolicyTaskDriving

    init(model: StudioModel, driver: any PolicyTaskDriving = CartPoleHillClimb()) {
        self.model = model
        self.driver = driver
    }

    @State private var iterations = 150
    @State private var population = 32
    @State private var seedText = "1"

    private var seed: UInt64 { UInt64(seedText.trimmingCharacters(in: .whitespaces)) ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    taskSection
                    Divider()
                    trainingSection
                    Divider()
                    curveSection
                    Divider()
                    resultsSection
                    Divider()
                    runSection
                }
            }
        }
        .background(theme.background)
        .onDisappear {
            session.detach(model: model)
            session.cancel()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.isTraining ? theme.accent : theme.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("POLICY")
                    .font(Typo.sectionLabel)
                    .kerning(0.6)
                    .foregroundStyle(theme.tertiary)
                Text(driver.deviceDescription)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Chip(text: driver.isAccelerated ? "accelerated" : "cpu",
                 tone: driver.isAccelerated ? Palette.success : nil)
            if session.isAttached {
                Chip(text: "driving scene", tone: Palette.success)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 8)
        .background(headerChrome)
    }

    /// Liquid Glass on the floating header, `.ultraThinMaterial` below macOS 26.
    /// Inline on purpose: this panel owns its own chrome.
    @ViewBuilder
    private var headerChrome: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    // MARK: Task

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Task")
            HStack(spacing: 6) {
                // One task exists. It is still a picker, because the shape of the
                // panel should not change when the second one arrives.
                Text(driver.taskName)
                    .font(Typo.small.weight(.medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Metric.radius).fill(theme.accent))
                Text("more tasks land with the trainer")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.gutter)

            Text(driver.taskSummary)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.gutter)
                .padding(.top, 6)
                .padding(.bottom, 8)

            if model.sceneIdentifier != driver.sceneIdentifier {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.warning)
                    Text("The loaded scene is not the one this task was trained for.")
                        .font(Typo.small)
                        .foregroundStyle(theme.secondary)
                    Spacer(minLength: 4)
                    ToolbarButton(systemImage: "cube.transparent", label: "Load") {
                        model.load(sceneIdentifier: driver.sceneIdentifier)
                    }
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: Training controls

    private var trainingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Train", trailing: session.status.isEmpty ? nil : session.status)

            stepperRow(label: "iterations", value: $iterations, step: 25, range: 25...2000)
            stepperRow(label: "population", value: $population, step: 8, range: 8...256)

            HStack(spacing: 8) {
                Text("seed")
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
                Spacer(minLength: 8)
                TextField("1", text: $seedText)
                    .textFieldStyle(.plain)
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.borderSubtle, lineWidth: 1))
            }
            .padding(.horizontal, Metric.gutter)
            .frame(height: Metric.rowHeight)

            HStack(spacing: 6) {
                ToolbarButton(systemImage: session.isTraining ? "stop.fill" : "play.fill",
                              label: session.isTraining ? "Cancel" : "Train",
                              isActive: session.isTraining,
                              tone: session.isTraining ? Palette.danger : nil) {
                    if session.isTraining {
                        session.cancel()
                        model.log("training cancelled", .warning)
                    } else {
                        session.train(using: driver, iterations: iterations,
                                      population: population, seed: seed)
                        model.log("training \(driver.taskName) — \(iterations) iterations, "
                                  + "population \(population), seed \(seed)", .info)
                    }
                }
                ToolbarButton(systemImage: "ruler", label: "Baseline") {
                    session.measureBaseline(using: driver, seed: seed)
                }
                Spacer(minLength: 0)
                ToolbarButton(systemImage: "square.and.arrow.down", label: "Save") { savePolicy() }
                ToolbarButton(systemImage: "square.and.arrow.up", label: "Load") { loadPolicy() }
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 4)

            if session.isTraining {
                progressBar
            }

            Text("Training runs on a detached task; the interface keeps stepping the scene "
                 + "while it works, and Cancel stops it.")
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.gutter)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
    }

    private func stepperRow(label: String, value: Binding<Int>, step: Int,
                            range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 8)
            Text("\(value.wrappedValue)")
                .font(Typo.mono)
                .foregroundStyle(theme.text)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: Metric.rowHeight)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(theme.borderSubtle)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent)
                    .frame(width: max(geometry.size.width * session.progressFraction, 2))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
    }

    // MARK: Curve

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Training curve",
                         trailing: session.curve.isEmpty ? nil : "\(session.curve.count) points")
            if session.curve.isEmpty {
                Text("The best and mean episode reward per iteration appear here while training.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 10)
            } else {
                curveCanvas
                    .frame(height: 110)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 4)
                HStack(spacing: 10) {
                    legend(color: theme.accent, label: "best so far")
                    legend(color: Palette.violet, label: "population mean")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 10)
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
        }
    }

    private var curveCanvas: some View {
        let points = session.curve
        let rewards = points.flatMap { [$0.bestReward, $0.meanReward] }
        let lower = rewards.min() ?? 0
        let upper = rewards.max() ?? 1
        let span = max(upper - lower, 1e-9)

        return Canvas { context, size in
            let rect = CGRect(x: 40, y: 6, width: max(size.width - 48, 1),
                              height: max(size.height - 22, 1))

            var grid = Path()
            for fraction in [0.0, 0.5, 1.0] {
                let y = rect.maxY - CGFloat(fraction) * rect.height
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(theme.borderSubtle), lineWidth: 1)

            for (fraction, value) in [(1.0, upper), (0.0, lower)] {
                let y = rect.maxY - CGFloat(fraction) * rect.height
                context.draw(Text(String(format: "%.0f", value))
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary),
                    at: CGPoint(x: rect.minX - 6, y: y), anchor: .trailing)
            }

            guard points.count > 1 else { return }
            let lastIteration = Double(points[points.count - 1].iteration)
            let firstIteration = Double(points[0].iteration)
            let iterationSpan = max(lastIteration - firstIteration, 1)

            func path(_ value: @escaping (PolicyTrainingSample) -> Double) -> Path {
                var line = Path()
                for (index, sample) in points.enumerated() {
                    let x = rect.minX
                        + CGFloat((Double(sample.iteration) - firstIteration) / iterationSpan)
                        * rect.width
                    let y = rect.maxY - CGFloat((value(sample) - lower) / span) * rect.height
                    let point = CGPoint(x: x, y: y)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                return line
            }

            context.stroke(path { $0.meanReward }, with: .color(Palette.violet.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            context.stroke(path { $0.bestReward }, with: .color(theme.accent),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

            context.draw(Text("iteration \(points[points.count - 1].iteration)")
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary),
                at: CGPoint(x: rect.maxX, y: rect.maxY + 9), anchor: .trailing)
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Results")
            if let evaluation = session.evaluation, let policy = session.trained {
                HStack(spacing: 6) {
                    StatTile(label: "mean steps",
                             value: String(format: "%.0f", evaluation.meanSteps))
                    StatTile(label: "success",
                             value: String(format: "%.0f", evaluation.successRate * 100),
                             unit: "%",
                             tone: evaluation.successRate > 0.8 ? Palette.success : Palette.warning)
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 6)

                HStack(spacing: 6) {
                    StatTile(label: "parameters", value: "\(policy.parameterCount)")
                    StatTile(label: "train time",
                             value: session.trainingSeconds.map { String(format: "%.2f", $0) } ?? "—",
                             unit: session.trainingSeconds == nil ? nil : "s")
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 6)

                FieldRow(label: "architecture", value: policy.specDescription)
                FieldRow(label: "mean reward",
                         value: String(format: "%.1f", evaluation.meanReward))

                comparisonRow(evaluation)
            } else {
                Text("No policy yet. Train one, or load a saved policy from disk.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 10)
            }
        }
    }

    /// The row that keeps everyone honest.
    @ViewBuilder
    private func comparisonRow(_ evaluation: PolicyEvaluation) -> some View {
        if let baseline = session.baseline {
            let delta = evaluation.meanSteps - baseline.meanSteps
            let wins = delta >= 0
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Chip(text: wins ? "beats baseline" : "loses to baseline",
                         tone: wins ? Palette.success : Palette.warning)
                    Text(String(format: "%.0f vs %.0f steps", evaluation.meanSteps,
                                baseline.meanSteps))
                        .font(Typo.mono)
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                }
                Text(wins
                     ? String(format: "The learned controller lasts %.0f steps longer than the "
                              + "%@ on the same seeds.", delta, driver.baselineName)
                     : String(format: "The %@ lasts %.0f steps longer. On this task the learned "
                              + "controller is not yet worth its parameters.",
                              driver.baselineName, -delta))
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 6)
            .padding(.bottom, 10)
        } else {
            HStack(spacing: 8) {
                Text("No baseline measured — press Baseline to score the \(driver.baselineName) "
                     + "on the same seeds.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    // MARK: Run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Run on the live scene")
            HStack(spacing: 6) {
                ToolbarButton(systemImage: session.isAttached ? "stop.circle" : "play.circle",
                              label: session.isAttached ? "Detach" : "Attach",
                              isActive: session.isAttached) {
                    if session.isAttached {
                        session.detach(model: model)
                    } else {
                        session.attach(driver: driver, model: model)
                    }
                }
                .disabled(session.trained == nil)
                ToolbarButton(systemImage: "arrow.counterclockwise", label: "Reset scene") {
                    model.reset()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.gutter)

            Text(runNote)
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.gutter)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
    }

    private var runNote: String {
        if session.trained == nil {
            return "Attach becomes available once a policy exists."
        }
        return "The policy writes actuator commands at 120 Hz while the engine steps faster, "
            + "so each action is held for a few steps. It was trained against an analytic "
            + "cart-pole, not against this solver — expect the live scene to be the harder of "
            + "the two."
    }

    // MARK: Persistence

    private func savePolicy() {
        guard let policy = session.trained else {
            model.log("no trained policy to save", .warning)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(driver.sceneIdentifier)-policy.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Where should the trained policy be written?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try policy.encoded().write(to: url)
            model.log("policy saved to \(url.lastPathComponent)", .success)
        } catch {
            model.log("could not save the policy: \(error)", .error)
        }
    }

    private func loadPolicy() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a policy written by Kinetic Studio"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let policy = try driver.decode(Data(contentsOf: url))
            session.adopt(policy, using: driver, seed: seed)
            model.log("loaded policy \(url.lastPathComponent) — \(policy.specDescription)",
                      .success)
        } catch {
            model.log("could not load the policy: \(error)", .error)
        }
    }
}
