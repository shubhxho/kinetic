//
//  SceneIntent.swift
//  KineticML
//
//  A typed, serialisable command language for mutating a `World`.
//
//  Natural language is the front door (see IntentParser.swift) but it is never
//  the thing that touches the simulator. Text is compiled into a `ScenePlan` --
//  an ordered list of `SceneOperation` values -- which is inspectable, diffable,
//  storable in an undo stack, and safe to show the user before anything runs.
//  Every operation is `Codable`, so a plan produced today reproduces the same
//  scene tomorrow: that is the whole point of a deterministic simulator.
//

import Foundation
import Kinetic

// MARK: - Seeded randomness

/// xoshiro256** -- small, fast, and, critically, ours.
///
/// The system generator is seeded per process, so `Double.random` would make
/// "drop five boxes" produce a different pile on every launch. A scene built
/// from a plan has to be bit-identical across runs and machines, so every
/// stochastic decision in this file draws from a generator seeded by the plan
/// itself.
public struct Xoshiro256: RandomNumberGenerator, Sendable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    public init(seed: UInt64) {
        // SplitMix64 expansion. xoshiro is badly behaved if the state is all
        // zeroes or has very few set bits, and callers will pass seeds like 0
        // and 1, so the seed is stirred before it becomes state.
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        func mix() -> UInt64 {
            z = z &+ 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        s0 = mix()
        s1 = mix()
        s2 = mix()
        s3 = mix()
        if s0 | s1 | s2 | s3 == 0 { s0 = 0x853C_49E6_748F_EA9B }
    }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 &- k))
    }

    public mutating func next() -> UInt64 {
        let result = Xoshiro256.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Xoshiro256.rotl(s3, 45)
        return result
    }

    /// Uniform in [0, 1). Built from the top 53 bits, which is the only part of
    /// the word with full equidistribution in xoshiro's low-order tail.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform in [-magnitude, magnitude].
    public mutating func symmetric(_ magnitude: Double) -> Double {
        (unit() * 2 - 1) * magnitude
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}

/// Fixed-point number formatting for logs and readbacks. Kept in one place so
/// every surface prints the same way.
func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(max(digits, 0))f", value)
}

/// FNV-1a over UTF-8. `String.hashValue` is salted per process, so it cannot be
/// used to derive a seed that survives a relaunch.
public func stableSeed(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

// MARK: - Value types

/// Plain Codable vector. `Vec3` is `SIMD3<Double>`, whose JSON form is an
/// unlabelled array; a model backend emitting `{"x":0,"y":0,"z":-1.62}` is far
/// easier to prompt for and to eyeball in a saved plan.
public struct Vector3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.init(x: x, y: y, z: z)
    }

    public init(_ v: Vec3) {
        self.init(x: v.x, y: v.y, z: v.z)
    }

    public var vec3: Vec3 { Vec3(x, y, z) }

    public static let zero = Vector3(0, 0, 0)
}

/// A body shape described the way a person says it: a kind plus one spoken
/// size. `size` is the *extent* -- a box edge, a sphere or capsule diameter --
/// because "10 cm box" means a box you could hold, not one with a 10 cm
/// half-extent.
public struct ShapeSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case box
        case sphere
        case capsule
        case cylinder

        public var noun: String { rawValue }
        public var plural: String { self == .box ? "boxes" : rawValue + "s" }
    }

    public var kind: Kind
    /// Diameter / edge length in metres.
    public var size: Double
    /// Total length along the local Z axis for capsules and cylinders.
    /// Ignored by boxes and spheres.
    public var length: Double?

    public init(kind: Kind, size: Double = 0.2, length: Double? = nil) {
        self.kind = kind
        self.size = max(size, 1e-4)
        self.length = length
    }

    public static func box(_ size: Double) -> ShapeSpec { ShapeSpec(kind: .box, size: size) }
    public static func sphere(_ size: Double) -> ShapeSpec { ShapeSpec(kind: .sphere, size: size) }

    /// Longest dimension, used for stack pitch and grid spacing.
    public var verticalExtent: Double {
        switch kind {
        case .box, .sphere: return size
        case .capsule: return length ?? (size * 3)
        case .cylinder: return length ?? size
        }
    }

    /// Bridge into the engine's geometry description.
    public var shape: Shape {
        let radius = size * 0.5
        switch kind {
        case .box:
            return .box(halfExtents: Vec3(radius, radius, radius))
        case .sphere:
            return .sphere(radius: radius)
        case .capsule:
            // Kinetic capsules measure total length as 2 * halfLength + 2 * radius,
            // so the spoken length has to have both caps subtracted from it.
            let total = max(length ?? (size * 3), size * 1.05)
            return .capsule(radius: radius, halfLength: max((total - size) * 0.5, 1e-4))
        case .cylinder:
            let total = max(length ?? size, 1e-3)
            return .cylinder(radius: radius, halfLength: total * 0.5)
        }
    }

    /// "10 cm", "1.20 m" -- the size as a person would say it back.
    public var spokenSize: String {
        let centimetres = size * 100
        return centimetres < 100
            ? String(format: "%.0f cm", centimetres)
            : String(format: "%.2f m", size)
    }

    public func describedSize(count: Int) -> String {
        "\(spokenSize) \(count == 1 ? kind.noun : kind.plural)"
    }
}

/// Contact properties, with the spoken name kept alongside the numbers so the
/// readback can say "ice" instead of "friction 0.05".
public struct MaterialSpec: Codable, Hashable, Sendable {
    public var name: String
    public var friction: Double
    public var restitution: Double
    public var torsionalFriction: Double

    public init(name: String = "custom", friction: Double = 1.0,
                restitution: Double = 0, torsionalFriction: Double = 0) {
        self.name = name
        self.friction = max(friction, 0)
        self.restitution = min(max(restitution, 0), 0.99)
        self.torsionalFriction = max(torsionalFriction, 0)
    }

    public var surface: SurfaceMaterial {
        SurfaceMaterial(friction: friction, restitution: restitution,
                        torsionalFriction: torsionalFriction)
    }

    public static let `default` = MaterialSpec(name: "default", friction: 1.0)
    public static let ice = MaterialSpec(name: "ice", friction: 0.05)
    public static let frictionless = MaterialSpec(name: "frictionless", friction: 0.0)
    public static let slippery = MaterialSpec(name: "slippery", friction: 0.1)
    public static let bouncy = MaterialSpec(name: "bouncy", friction: 1.2, restitution: 0.75)
    public static let sticky = MaterialSpec(name: "sticky", friction: 2.5)
    public static let rubber = MaterialSpec(name: "rubber", friction: 1.4, restitution: 0.6,
                                            torsionalFriction: 0.01)
    public static let steel = MaterialSpec(name: "steel", friction: 0.4, restitution: 0.2)
    public static let rough = MaterialSpec(name: "rough", friction: 1.3)

    /// True when the engine's `addGround` convenience -- which only forwards
    /// friction -- would lose information.
    public var needsFullSurface: Bool {
        restitution > 0 || torsionalFriction > 0
    }
}

/// Where a batch of bodies goes. Every arrangement is jittered by a seeded
/// generator so a pile looks natural without becoming irreproducible.
public struct PlacementSpec: Codable, Hashable, Sendable {
    public enum Arrangement: Codable, Hashable, Sendable {
        /// All bodies at one height, spread over a loose square footprint.
        case height(Double)
        /// Row-major grid on the XY plane. `spacing` nil means "derive from body size".
        case grid(columns: Int, spacing: Double?, height: Double)
        /// Vertical tower. `spacing` nil means "one body extent plus a hair".
        case stack(spacing: Double?, base: Double)
        /// Evenly spaced around a circle at a fixed height.
        case ring(radius: Double, height: Double)
        /// Uniform inside an axis-aligned box whose floor sits at `height`.
        case scattered(size: Vector3, height: Double)
    }

    public var arrangement: Arrangement
    public var center: Vector3
    /// Lateral jitter half-width, in metres.
    public var jitter: Double
    /// Base yaw about +Z applied to every body, in radians. Spoken as
    /// "rotated 45 degrees"; the parser converts degrees for us.
    public var yaw: Double
    /// Yaw jitter half-angle, in radians, added on top of `yaw`.
    public var yawJitter: Double
    public var seed: UInt64

    public init(arrangement: Arrangement, center: Vector3 = .zero,
                jitter: Double = 0.02, yaw: Double = 0, yawJitter: Double = 0,
                seed: UInt64 = 0x5EED) {
        self.arrangement = arrangement
        self.center = center
        self.jitter = max(jitter, 0)
        self.yaw = yaw
        self.yawJitter = max(yawJitter, 0)
        self.seed = seed
    }

    public static func dropped(from height: Double, seed: UInt64 = 0x5EED) -> PlacementSpec {
        PlacementSpec(arrangement: .height(height), jitter: 0.02, yawJitter: .pi, seed: seed)
    }

    /// Resting height of the first body if it were sitting on the ground.
    public var nominalHeight: Double {
        switch arrangement {
        case .height(let h): return h
        case .grid(_, _, let h): return h
        case .stack(_, let base): return base
        case .ring(_, let h): return h
        case .scattered(_, let h): return h
        }
    }

    /// Deterministic body poses. Calling this twice with the same arguments
    /// always yields the same array: the generator is local and seeded here.
    public func poses(count: Int, extent: Double) -> [Pose] {
        guard count > 0 else { return [] }
        var rng = Xoshiro256(seed: seed)
        let e = max(extent, 1e-4)
        let origin = center.vec3
        var result: [Pose] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            // Four draws per body, always in the same order, so that changing
            // the arrangement does not desynchronise the jitter stream.
            let jx = rng.symmetric(jitter)
            let jy = rng.symmetric(jitter)
            let spin = yaw + rng.symmetric(yawJitter)
            let extra = rng.unit()

            var p: Vec3
            switch arrangement {
            case .height(let h):
                let columns = max(Int(Double(count).squareRoot().rounded(.up)), 1)
                p = PlacementSpec.gridPoint(index: i, count: count, columns: columns,
                                            pitch: e * 1.6, height: h)
            case .grid(let requested, let spacing, let h):
                let columns = max(requested, 1)
                let pitch = spacing.flatMap { $0 > 0 ? $0 : nil } ?? e * 1.6
                p = PlacementSpec.gridPoint(index: i, count: count, columns: columns,
                                            pitch: pitch, height: h)
            case .stack(let spacing, let base):
                // A hair more than one extent per layer keeps the initial state
                // penetration-free; the solver hates starting inside a contact.
                let pitch = spacing.flatMap { $0 > 0 ? $0 : nil } ?? e * 1.0025
                p = Vec3(0, 0, base + e * 0.5 + pitch * Double(i))
            case .ring(let radius, let h):
                let angle = 2 * Double.pi * Double(i) / Double(count)
                p = Vec3(cos(angle) * radius, sin(angle) * radius, h)
            case .scattered(let size, let h):
                let v = size.vec3
                p = Vec3(rng.symmetric(v.x * 0.5), rng.symmetric(v.y * 0.5),
                         h + extra * max(v.z, 0))
            }

            p += origin
            p.x += jx
            p.y += jy
            result.append(Pose(position: p, orientation: Quat(axis: .up, angle: spin)))
        }
        return result
    }

    private static func gridPoint(index: Int, count: Int, columns: Int,
                                  pitch: Double, height: Double) -> Vec3 {
        let cols = max(columns, 1)
        let rows = (count + cols - 1) / cols
        let col = index % cols
        let row = index / cols
        let width = Double(cols - 1) * pitch
        let depth = Double(max(rows - 1, 0)) * pitch
        return Vec3(Double(col) * pitch - width * 0.5,
                    Double(row) * pitch - depth * 0.5,
                    height)
    }

    public var described: String {
        let spin = abs(yaw) > 1e-9
            ? ", rotated " + fixed(yaw * 180 / Double.pi, 0) + " degrees"
            : ""
        return describedArrangement + spin
    }

    private var describedArrangement: String {
        switch arrangement {
        case .height(let h):
            return String(format: "from %.2f m", h)
        case .grid(let c, let s, let h):
            let spacing = s.map { " spaced " + fixed($0, 2) + " m" } ?? ""
            return "in a \(c)-column grid at " + fixed(h, 2) + " m" + spacing
        case .stack(_, let base):
            return base > 1e-6 ? String(format: "in a stack from %.2f m", base) : "in a stack"
        case .ring(let r, let h):
            return String(format: "in a ring of radius %.2f m at %.2f m", r, h)
        case .scattered(let size, let h):
            return String(format: "scattered in a %.1f x %.1f m box at %.2f m",
                          size.x, size.y, h)
        }
    }
}

/// Which bodies an operation addresses.
public enum TargetSpec: Codable, Hashable, Sendable {
    /// Every free body the plan created, or every free body in the world if the
    /// plan created none.
    case all
    case ground
    /// Exact articulation name.
    case named(String)
    /// Any articulation whose name contains this fragment ("box" hits box0..box9).
    case matching(String)
    /// The last `count` bodies the plan added.
    case lastAdded(count: Int)
    case shape(ShapeSpec.Kind)

    public var described: String {
        switch self {
        case .all: return "every body"
        case .ground: return "the ground"
        case .named(let n): return "\"\(n)\""
        case .matching(let f): return "bodies named like \"\(f)\""
        case .lastAdded(let c): return "the last \(c) bodies"
        case .shape(let k): return "the \(k.plural)"
        }
    }
}

// MARK: - Operations

/// When an operation may be applied relative to `World.compile()`.
public enum OperationPhase: String, Codable, Hashable, Sendable {
    /// Adds or edits bodies and geoms. Must run before `compile()`.
    case topology
    /// Solver settings. The engine accepts these at any point.
    case settings
    /// Reads or writes simulation state. Requires a compiled world.
    case state
}

public enum SceneOperation: Codable, Hashable, Sendable {
    case addBodies(count: Int, shape: ShapeSpec, at: PlacementSpec, material: MaterialSpec,
                   density: Double)
    case addGround(friction: Double)
    case setGravity(Vector3)
    case setTimestep(Double)
    case setSolverIterations(Int)
    case setMaterial(target: TargetSpec, material: MaterialSpec)
    case applyImpulse(target: TargetSpec, direction: [Double], magnitude: Double)
    /// One of `SceneLibrary.all`'s ids.
    case loadScene(String)
    case run(seconds: Double)
    case reset
    case setIntegrator(String)

    public var phase: OperationPhase {
        switch self {
        case .addBodies, .addGround, .setMaterial, .loadScene:
            return .topology
        case .setGravity, .setTimestep, .setSolverIterations, .setIntegrator:
            return .settings
        case .applyImpulse, .run, .reset:
            return .state
        }
    }

    /// Stable ordering rank. A plan assembled out of order -- "run it, oh and
    /// add some boxes" -- is sorted into a legal sequence rather than rejected,
    /// but only within these buckets, so the author's relative order survives.
    public var sortRank: Int {
        switch self {
        case .loadScene: return 0
        case .setMaterial: return 1
        case .addGround: return 2
        case .addBodies: return 3
        case .setGravity, .setTimestep, .setSolverIterations, .setIntegrator: return 4
        case .reset: return 5
        case .applyImpulse: return 6
        case .run: return 7
        }
    }

    public var label: String {
        switch self {
        case .addBodies: return "addBodies"
        case .addGround: return "addGround"
        case .setGravity: return "setGravity"
        case .setTimestep: return "setTimestep"
        case .setSolverIterations: return "setSolverIterations"
        case .setMaterial: return "setMaterial"
        case .applyImpulse: return "applyImpulse"
        case .loadScene: return "loadScene"
        case .run: return "run"
        case .reset: return "reset"
        case .setIntegrator: return "setIntegrator"
        }
    }

    /// One clause of English, used for both the plan summary and the readback.
    public var described: String {
        switch self {
        case .addBodies(let count, let shape, let at, let material, let density):
            let noun = "\(count) \(shape.describedSize(count: count))"
            let mat = material.name == "default" ? "" : " of \(material.name)"
            let rho = abs(density - 500) < 1e-9 ? "" : String(format: " at %.0f kg/m3", density)
            return "add \(noun)\(mat) \(at.described)\(rho)"
        case .addGround(let friction):
            return String(format: "add a ground plane with friction %.2f", friction)
        case .setGravity(let g):
            return String(format: "set gravity to (%.2f, %.2f, %.2f) m/s2", g.x, g.y, g.z)
        case .setTimestep(let dt):
            return String(format: "set the timestep to %.4g s (%.0f Hz)", dt, dt > 0 ? 1 / dt : 0)
        case .setSolverIterations(let n):
            return "use \(n) solver iterations"
        case .setMaterial(let target, let material):
            return "make \(target.described) \(material.name)"
        case .applyImpulse(let target, let direction, let magnitude):
            let d = direction.count == 3 ? direction : [0, 0, 0]
            return "push \(target.described) along (" + fixed(d[0], 1) + ", "
                + fixed(d[1], 1) + ", " + fixed(d[2], 1) + ") with "
                + fixed(magnitude, 2) + " N s"
        case .loadScene(let id):
            let title = SceneLibrary.all.first(where: { $0.id == id })?.title ?? id
            return "load the \(title) scene"
        case .run(let seconds):
            return String(format: "run for %.2f s", seconds)
        case .reset:
            return "reset the simulation"
        case .setIntegrator(let name):
            return "switch the integrator to \(name)"
        }
    }
}

// MARK: - Plan

/// An ordered, reviewable script. The UI is expected to show `summary` and wait
/// for a confirmation before anything is applied -- a scene edit is destructive
/// and there is no undo inside the engine.
public struct ScenePlan: Codable, Hashable, Sendable {
    public var operations: [SceneOperation]
    public var summary: String

    public init(operations: [SceneOperation], summary: String = "") {
        self.operations = operations
        self.summary = summary.isEmpty ? ScenePlan.makeSummary(operations) : summary
    }

    public var isEmpty: Bool { operations.isEmpty }

    /// True when the plan changes topology, so the host must start from an
    /// uncompiled world (or rebuild the one it has).
    public var requiresRebuild: Bool {
        operations.contains { $0.phase == .topology }
    }

    /// Scene id the plan wants to start from, if any.
    public var baseScene: String? {
        for op in operations {
            if case .loadScene(let id) = op { return id }
        }
        return nil
    }

    /// A copy whose operations are in a legal phase order.
    public var ordered: ScenePlan {
        let sorted = operations.enumerated()
            .sorted { lhs, rhs in
                lhs.element.sortRank == rhs.element.sortRank
                    ? lhs.offset < rhs.offset
                    : lhs.element.sortRank < rhs.element.sortRank
            }
            .map(\.element)
        return ScenePlan(operations: sorted, summary: summary)
    }

    /// Phase-order check that touches no world, so a UI can validate before it
    /// commits to mutating anything.
    public func validate() throws {
        var lastState: SceneOperation?
        for op in operations {
            if op.phase == .state {
                lastState = op
            } else if op.phase == .topology, let previous = lastState {
                throw SceneOperationError.topologyAfterStateChange(operation: op.label,
                                                                  previous: previous.label)
            }
        }
    }

    public var describedSteps: [String] { operations.map(\.described) }

    static func makeSummary(_ operations: [SceneOperation]) -> String {
        guard !operations.isEmpty else { return "Do nothing." }
        let clauses = operations.map(\.described)
        let joined: String
        if clauses.count == 1 {
            joined = clauses[0]
        } else {
            joined = clauses.dropLast().joined(separator: ", ") + ", then " + (clauses.last ?? "")
        }
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    // MARK: JSON

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(json: Data) throws -> ScenePlan {
        try JSONDecoder().decode(ScenePlan.self, from: json)
    }
}

// MARK: - Errors

public enum SceneOperationError: Error, Hashable, Sendable, CustomStringConvertible {
    case topologyAfterCompile(operation: String)
    case topologyAfterStateChange(operation: String, previous: String)
    case requiresFreshWorld(scene: String)
    case unknownScene(String)
    case unknownIntegrator(String)
    case invalidCount(Int)
    case invalidValue(operation: String, value: Double)
    case noMatchingTarget(String)

    public var description: String {
        switch self {
        case .topologyAfterCompile(let op):
            return """
            \(op) adds or edits geometry, which the engine only accepts before \
            World.compile(). This world is already compiled -- rebuild it from \
            an empty World and re-apply the plan.
            """
        case .topologyAfterStateChange(let op, let previous):
            return """
            \(op) changes topology but is ordered after \(previous), which \
            forced the world to compile. Reorder the plan (ScenePlan.ordered \
            does this) so every topology operation precedes every state one.
            """
        case .requiresFreshWorld(let scene):
            return """
            loadScene(\"\(scene)\") builds a brand new World and cannot be \
            applied to an existing one. Use SceneOperationApplier.makeWorld(from:) \
            and swap the result in.
            """
        case .unknownScene(let id):
            let known = SceneLibrary.all.map(\.id).joined(separator: ", ")
            return "No scene with id \"\(id)\". Known scenes: \(known)."
        case .unknownIntegrator(let name):
            return "No integrator called \"\(name)\". Try euler, rk4 or implicit."
        case .invalidCount(let n):
            return "Body count \(n) is out of range; expected 1...4096."
        case .invalidValue(let op, let value):
            return "\(op) rejected the value \(value)."
        case .noMatchingTarget(let target):
            return "Nothing in the world matches \(target)."
        }
    }
}

// MARK: - Integrator naming

public enum IntegratorNaming {
    /// Spoken names to engine integrators. Kept here rather than in the parser
    /// so that a plan decoded from JSON validates the same way.
    public static func resolve(_ name: String) -> Integrator? {
        let key = name.lowercased().filter { !" -_".contains($0) }
        switch key {
        case "euler", "semiimpliciteuler", "semiimplicit", "symplectic", "symplecticeuler",
             "default", "explicit":
            return .semiImplicitEuler
        case "rk4", "rungekutta", "rungekutta4", "runge", "fourthorder":
            return .rungeKutta4
        case "implicit", "implicitfast", "fastimplicit", "implicitdamping":
            return .implicitFast
        default:
            return nil
        }
    }

    public static func name(_ integrator: Integrator) -> String {
        switch integrator {
        case .semiImplicitEuler: return "semi-implicit Euler"
        case .rungeKutta4: return "RK4"
        case .implicitFast: return "implicit-fast"
        }
    }
}

// MARK: - Applier

/// Executes a `ScenePlan` against a `World`.
///
/// The engine has two lifecycle halves: before `compile()` you may add
/// articulations, links and geoms; afterwards the model is sealed and only
/// state -- positions, velocities, options -- may move. The applier enforces
/// that boundary explicitly, compiling exactly once at the topology/state
/// transition and refusing (loudly) to run a topology operation against a world
/// that has already been sealed.
public enum SceneOperationApplier {

    /// Applies `plan` in order, returning one log line per operation plus a line
    /// for the implicit `compile()`.
    @discardableResult
    public static func apply(_ plan: ScenePlan, to world: World) throws -> [String] {
        try plan.validate()
        var session = Session(world: world)
        var log: [String] = []
        for operation in plan.operations {
            log.append(contentsOf: try session.run(operation))
        }
        return log
    }

    /// Builds a world from scratch. This is the only path that can honour
    /// `loadScene`, because `SceneLibrary` entries construct and compile their
    /// own `World` and there is no engine call that empties an existing one.
    public static func makeWorld(from plan: ScenePlan) throws -> (world: World, log: [String]) {
        try plan.validate()
        var log: [String] = []
        var remaining = plan.operations
        let world: World

        if case .loadScene(let id)? = remaining.first {
            guard let built = SceneLibrary.build(id) else {
                throw SceneOperationError.unknownScene(id)
            }
            world = built
            remaining.removeFirst()
            log.append("loadScene(\(id)) -> \(world.geomCount) geoms, compiled")
        } else if let id = plan.baseScene {
            // A load buried mid-plan cannot be honoured: everything before it
            // would be thrown away.
            throw SceneOperationError.requiresFreshWorld(scene: id)
        } else {
            world = World()
        }

        var session = Session(world: world)
        for operation in remaining {
            log.append(contentsOf: try session.run(operation))
        }
        return (world, log)
    }

    // MARK: Session

    /// Mutable bookkeeping for one application pass: which bodies this plan
    /// created (so `TargetSpec` can resolve without name lookups), which
    /// material rules are pending, and whether the world has been sealed.
    private struct Session {
        struct Created {
            var name: String
            var articulation: Int
            var link: Int
            var kind: ShapeSpec.Kind?
        }

        let world: World
        var created: [Created] = []
        var groundRule: MaterialSpec?
        var bodyRules: [(target: TargetSpec, material: MaterialSpec)] = []
        var nameCounters: [String: Int] = [:]
        var sealedByOperation: String?

        init(world: World) {
            self.world = world
        }

        mutating func run(_ operation: SceneOperation) throws -> [String] {
            switch operation {
            case .addBodies(let count, let shape, let at, let material, let density):
                return [try addBodies(count: count, shape: shape, placement: at,
                                      material: material, density: density)]
            case .addGround(let friction):
                return [try addGround(friction: friction)]
            case .setGravity(let g):
                var options = world.options
                options.gravity = g.vec3
                world.options = options
                return [String(format: "setGravity -> (%.3f, %.3f, %.3f)", g.x, g.y, g.z)]
            case .setTimestep(let dt):
                guard dt > 0, dt <= 1 else {
                    throw SceneOperationError.invalidValue(operation: "setTimestep", value: dt)
                }
                var options = world.options
                options.timestep = dt
                world.options = options
                return [String(format: "setTimestep -> %.6f s (%.1f Hz)", dt, 1 / dt)]
            case .setSolverIterations(let n):
                guard n >= 1, n <= 1000 else {
                    throw SceneOperationError.invalidValue(operation: "setSolverIterations",
                                                           value: Double(n))
                }
                var options = world.options
                options.solverIterations = n
                world.options = options
                return ["setSolverIterations -> \(n)"]
            case .setIntegrator(let name):
                guard let integrator = IntegratorNaming.resolve(name) else {
                    throw SceneOperationError.unknownIntegrator(name)
                }
                var options = world.options
                options.integrator = integrator
                world.options = options
                return ["setIntegrator -> \(IntegratorNaming.name(integrator))"]
            case .setMaterial(let target, let material):
                return [try setMaterial(target: target, material: material)]
            case .applyImpulse(let target, let direction, let magnitude):
                var log = ensureCompiled(for: "applyImpulse")
                log.append(try applyImpulse(target: target, direction: direction,
                                            magnitude: magnitude))
                return log
            case .loadScene(let id):
                guard SceneLibrary.all.contains(where: { $0.id == id }) else {
                    throw SceneOperationError.unknownScene(id)
                }
                throw SceneOperationError.requiresFreshWorld(scene: id)
            case .run(let seconds):
                guard seconds >= 0, seconds <= 3600 else {
                    throw SceneOperationError.invalidValue(operation: "run", value: seconds)
                }
                var log = ensureCompiled(for: "run")
                let dt = max(world.options.timestep, 1e-9)
                let steps = max(Int((seconds / dt).rounded()), 0)
                world.step(steps)
                log.append("run -> \(steps) steps ("
                    + fixed(seconds, 3) + " s, now t=" + fixed(world.time, 3) + ")")
                return log
            case .reset:
                var log = ensureCompiled(for: "reset")
                world.reset()
                log.append("reset -> t=0, default pose restored")
                return log
            }
        }

        // MARK: Phase control

        /// Rejects a topology operation that can no longer take effect. This is
        /// the failure the whole applier exists to make visible: adding a geom
        /// to a compiled world is silently ignored by the engine, which would
        /// leave the user staring at an unchanged scene.
        private func requireOpenTopology(_ label: String) throws {
            if let sealer = sealedByOperation {
                throw SceneOperationError.topologyAfterStateChange(operation: label,
                                                                   previous: sealer)
            }
            if world.isCompiled {
                throw SceneOperationError.topologyAfterCompile(operation: label)
            }
        }

        private mutating func ensureCompiled(for label: String) -> [String] {
            if sealedByOperation == nil { sealedByOperation = label }
            guard !world.isCompiled else { return [] }
            world.compile()
            return ["compile() -> \(world.geomCount) geoms, \(world.dofCount) dof"]
        }

        // MARK: Topology operations

        private mutating func addGround(friction: Double) throws -> String {
            try requireOpenTopology("addGround")
            var material = groundRule ?? MaterialSpec(name: "ground", friction: friction)
            material.friction = friction
            let appearance = Appearance(color: Vec4(0.12, 0.13, 0.15, 1), roughness: 0.9)
            let articulation: Int
            if material.needsFullSurface {
                // World.addGround only forwards friction, so a bouncy or
                // torsionally-damped floor has to be built as a static plane.
                articulation = world.addStaticBody(name: "ground", shape: .plane(extent: 60),
                                                   material: material.surface,
                                                   appearance: appearance)
            } else {
                articulation = world.addGround(friction: friction, appearance: appearance)
            }
            created.append(Created(name: "ground", articulation: articulation, link: 0, kind: nil))
            return String(format: "addGround -> friction %.3f, restitution %.2f",
                          material.friction, material.restitution)
        }

        private mutating func addBodies(count: Int, shape: ShapeSpec, placement: PlacementSpec,
                                        material: MaterialSpec, density: Double) throws -> String {
            try requireOpenTopology("addBodies")
            guard count >= 1, count <= 4096 else {
                throw SceneOperationError.invalidCount(count)
            }
            guard density > 0, density <= 30000 else {
                throw SceneOperationError.invalidValue(operation: "addBodies", value: density)
            }

            let resolved = resolveMaterial(base: material, kind: shape.kind, namePrefix: shape.kind.noun)
            let poses = placement.poses(count: count, extent: shape.verticalExtent)
            let prefix = shape.kind.noun
            let start = nameCounters[prefix] ?? 0

            for (i, pose) in poses.enumerated() {
                let name = "\(prefix)\(start + i)"
                let body = world.addRigidBody(
                    name: name,
                    shape: shape.shape,
                    density: density,
                    pose: pose,
                    material: resolved.surface,
                    appearance: SceneOperationApplier.appearance(index: i, count: count,
                                                                 material: resolved))
                created.append(Created(name: name, articulation: body.articulation,
                                       link: body.link, kind: shape.kind))
            }
            nameCounters[prefix] = start + count

            return "addBodies -> \(count) x \(shape.describedSize(count: count)) "
                + "(\(resolved.name)), \(placement.described), density "
                + fixed(density, 0) + ", seed \(placement.seed)"
        }

        private mutating func setMaterial(target: TargetSpec,
                                          material: MaterialSpec) throws -> String {
            try requireOpenTopology("setMaterial")
            // The C core exposes no post-construction geom mutation, so a
            // material change is a *rule* that binds bodies added later in the
            // plan. The parser emits it ahead of the matching add.
            if case .ground = target {
                groundRule = material
            } else {
                bodyRules.append((target, material))
            }
            let existing = matches(target).filter { $0.name != "ground" }
            let warning = existing.isEmpty
                ? ""
                : " (note: \(existing.count) already-built bodies keep their original surface)"
            return "setMaterial -> \(target.described) now use \(material.name)\(warning)"
        }

        private func resolveMaterial(base: MaterialSpec, kind: ShapeSpec.Kind,
                                     namePrefix: String) -> MaterialSpec {
            var result = base
            for rule in bodyRules {
                switch rule.target {
                case .all:
                    result = rule.material
                case .shape(let k) where k == kind:
                    result = rule.material
                case .matching(let fragment) where namePrefix.contains(fragment):
                    result = rule.material
                case .named(let name) where name.hasPrefix(namePrefix):
                    result = rule.material
                default:
                    continue
                }
            }
            return result
        }

        // MARK: State operations

        private func applyImpulse(target: TargetSpec, direction: [Double],
                                  magnitude: Double) throws -> String {
            guard direction.count == 3 else {
                throw SceneOperationError.invalidValue(operation: "applyImpulse",
                                                       value: Double(direction.count))
            }
            let axis = Vec3(direction[0], direction[1], direction[2]).normalized
            guard axis.length > 1e-9 else {
                throw SceneOperationError.invalidValue(operation: "applyImpulse", value: 0)
            }
            let bodies = matches(target).filter { $0.name != "ground" }
            guard !bodies.isEmpty else {
                throw SceneOperationError.noMatchingTarget(target.described)
            }

            // There is no impulse entry point in the engine -- kn_apply_force
            // accumulates a force for the next step -- so an impulse is applied
            // the honest way: dv = J / m written straight into the free joint's
            // linear velocities.
            var applied = 0
            for body in bodies {
                guard world.jointKind(articulation: body.articulation, link: body.link) == .free
                else { continue }
                let offset = world.dofOffset(articulation: body.articulation)
                guard offset >= 0, offset + 6 <= world.dofCount else { continue }
                let mass = max(world.mass(articulation: body.articulation, link: body.link), 1e-9)
                let dv = axis * (magnitude / mass)
                let velocities = world.velocities
                velocities[offset + 0] += dv.x
                velocities[offset + 1] += dv.y
                velocities[offset + 2] += dv.z
                applied += 1
            }
            world.forward()
            return "applyImpulse -> " + fixed(magnitude, 2) + " N s along ("
                + fixed(axis.x, 2) + ", " + fixed(axis.y, 2) + ", " + fixed(axis.z, 2)
                + ") on \(applied) bodies"
        }

        // MARK: Target resolution

        private func matches(_ target: TargetSpec) -> [Created] {
            switch target {
            case .all:
                return created.isEmpty ? worldBodies() : created
            case .ground:
                return created.filter { $0.name == "ground" }
            case .named(let name):
                if let hit = created.first(where: { $0.name == name }) { return [hit] }
                if let index = world.findArticulation(name) {
                    return [Created(name: name, articulation: index, link: 0, kind: nil)]
                }
                return []
            case .matching(let fragment):
                let local = created.filter { $0.name.contains(fragment) }
                return local.isEmpty ? worldBodies().filter { $0.name.contains(fragment) } : local
            case .lastAdded(let count):
                return Array(created.suffix(max(count, 0)))
            case .shape(let kind):
                let local = created.filter { $0.kind == kind }
                return local.isEmpty ? worldBodies().filter { $0.name.hasPrefix(kind.noun) } : local
            }
        }

        /// Every articulation already in the world, minus the ground that
        /// `World.addGround` names "world".
        private func worldBodies() -> [Created] {
            guard world.isCompiled else { return [] }
            var result: [Created] = []
            for index in 0..<world.articulationCount {
                let name = world.name(articulation: index)
                if name == "world" || name == "ground" { continue }
                result.append(Created(name: name, articulation: index, link: 0, kind: nil))
            }
            return result
        }
    }

    // MARK: Appearance

    /// Bodies of the same batch get a hue ramp so a pile reads as a pile, and
    /// named materials get a look that matches what the user asked for.
    static func appearance(index: Int, count: Int, material: MaterialSpec) -> Appearance {
        let t = count > 1 ? Double(index) / Double(count - 1) : 0
        switch material.name {
        case "ice", "frictionless", "slippery":
            return Appearance(color: Vec4(0.58 + 0.2 * t, 0.80, 0.94, 1),
                              metallic: 0.05, roughness: 0.12)
        case "steel":
            return Appearance(color: Vec4(0.70, 0.72, 0.76, 1), metallic: 0.85, roughness: 0.25)
        case "rubber", "bouncy", "sticky":
            return Appearance(color: Vec4(0.14 + 0.1 * t, 0.15, 0.18, 1), roughness: 0.85)
        default:
            return Appearance(color: Vec4(0.35 + 0.5 * t, 0.45, 0.95 - 0.4 * t, 1),
                              roughness: 0.4)
        }
    }
}
