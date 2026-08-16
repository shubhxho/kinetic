//
//  World.swift
//  Kinetic
//
//  Swift face of the physics engine. The C core owns all simulation state; this
//  type is a thin, safe, value-oriented wrapper over it.
//

import Foundation
import KineticCore
import simd

// MARK: - Specifications

public enum Shape: Equatable, Sendable {
    case sphere(radius: Double)
    case box(halfExtents: Vec3)
    /// Z-aligned capsule: total length is `2 * halfLength + 2 * radius`.
    case capsule(radius: Double, halfLength: Double)
    case cylinder(radius: Double, halfLength: Double)
    /// Infinite ground plane with +Z normal. `extent` only affects rendering.
    case plane(extent: Double = 40)
    case convexHull(mesh: Int, boundingRadius: Double = 1)

    var cType: Int32 {
        switch self {
        case .sphere: return Int32(KN_GEOM_SPHERE.rawValue)
        case .box: return Int32(KN_GEOM_BOX.rawValue)
        case .capsule: return Int32(KN_GEOM_CAPSULE.rawValue)
        case .cylinder: return Int32(KN_GEOM_CYLINDER.rawValue)
        case .plane: return Int32(KN_GEOM_PLANE.rawValue)
        case .convexHull: return Int32(KN_GEOM_CONVEX_HULL.rawValue)
        }
    }

    var cSize: Vec3 {
        switch self {
        case .sphere(let r): return Vec3(r, r, r)
        case .box(let h): return h
        case .capsule(let r, let h): return Vec3(r, h, 0)
        case .cylinder(let r, let h): return Vec3(r, h, 0)
        case .plane(let e): return Vec3(e, e, 0)
        case .convexHull(_, let r): return Vec3(r, r, r)
        }
    }

    var meshIndex: Int32 {
        if case .convexHull(let m, _) = self { return Int32(m) }
        return -1
    }

    /// Volume in cubic metres; used to derive mass from density.
    public var volume: Double {
        switch self {
        case .sphere(let r): return 4.0 / 3.0 * .pi * r * r * r
        case .box(let h): return 8 * h.x * h.y * h.z
        case .capsule(let r, let h):
            return .pi * r * r * 2 * h + 4.0 / 3.0 * .pi * r * r * r
        case .cylinder(let r, let h): return .pi * r * r * 2 * h
        case .plane: return 0
        case .convexHull(_, let r): return 4.0 / 3.0 * .pi * r * r * r
        }
    }

    public func inertia(mass: Double) -> [Double] {
        switch self {
        case .sphere(let r): return Inertia.sphere(mass: mass, radius: r)
        case .box(let h): return Inertia.box(mass: mass, halfExtents: h)
        case .capsule(let r, let h): return Inertia.capsule(mass: mass, radius: r, length: 2 * h)
        case .cylinder(let r, let h): return Inertia.cylinder(mass: mass, radius: r, length: 2 * h)
        case .plane: return Vec3.zero.diagonalInertia
        case .convexHull(_, let r): return Inertia.sphere(mass: mass, radius: r)
        }
    }
}

public struct SurfaceMaterial: Equatable, Sendable {
    public var friction: Double = 1.0
    public var torsionalFriction: Double = 0.005
    public var restitution: Double = 0.0
    /// Contact softness: the time constant of the constraint's error decay.
    public var stiffnessTimeConstant: Double = 0.02
    public var dampingRatio: Double = 1.0
    public var margin: Double = 0.0

    public init(friction: Double = 1.0, restitution: Double = 0.0,
                stiffnessTimeConstant: Double = 0.02, dampingRatio: Double = 1.0,
                torsionalFriction: Double = 0.005, margin: Double = 0) {
        self.friction = friction
        self.restitution = restitution
        self.stiffnessTimeConstant = stiffnessTimeConstant
        self.dampingRatio = dampingRatio
        self.torsionalFriction = torsionalFriction
        self.margin = margin
    }

    public static let `default` = SurfaceMaterial()
    public static let ice = SurfaceMaterial(friction: 0.05)
    public static let rubber = SurfaceMaterial(friction: 1.4, restitution: 0.6)
    public static let steel = SurfaceMaterial(friction: 0.4, restitution: 0.2)
}

public struct Appearance: Equatable, Sendable {
    public var color: Vec4 = Vec4(0.82, 0.83, 0.85, 1)
    public var metallic: Double = 0
    public var roughness: Double = 0.55
    public var emissive: Double = 0

    public init(color: Vec4 = Vec4(0.82, 0.83, 0.85, 1), metallic: Double = 0,
                roughness: Double = 0.55, emissive: Double = 0) {
        self.color = color
        self.metallic = metallic
        self.roughness = roughness
        self.emissive = emissive
    }

    public static let `default` = Appearance()
    public static func solid(_ r: Double, _ g: Double, _ b: Double) -> Appearance {
        Appearance(color: Vec4(r, g, b, 1))
    }
}

public struct GeomSpec: Sendable {
    public var name: String = ""
    public var shape: Shape
    public var localPose: Pose = .identity
    public var material: SurfaceMaterial = .default
    public var appearance: Appearance = .default
    public var collidable: Bool = true
    public var visible: Bool = true
    public var group: UInt32 = 1
    public var mask: UInt32 = .max

    public init(shape: Shape, localPose: Pose = .identity, material: SurfaceMaterial = .default,
                appearance: Appearance = .default, collidable: Bool = true, visible: Bool = true,
                name: String = "") {
        self.shape = shape
        self.localPose = localPose
        self.material = material
        self.appearance = appearance
        self.collidable = collidable
        self.visible = visible
        self.name = name
    }
}

public enum JointKind: Int32, Sendable, CaseIterable {
    case fixed = 0
    case revolute = 1
    case prismatic = 2
    case spherical = 3
    case free = 4

    public var dofCount: Int {
        switch self {
        case .fixed: return 0
        case .revolute, .prismatic: return 1
        case .spherical: return 3
        case .free: return 6
        }
    }

    public var coordinateCount: Int {
        switch self {
        case .fixed: return 0
        case .revolute, .prismatic: return 1
        case .spherical: return 4
        case .free: return 7
        }
    }
}

public struct JointSpec: Sendable {
    public var kind: JointKind = .fixed
    public var axis: Vec3 = .up
    public var origin: Pose = .identity
    public var limited: Bool = false
    public var lower: Double = 0
    public var upper: Double = 0
    public var effortLimit: Double = 0
    public var velocityLimit: Double = 0
    public var damping: Double = 0
    public var friction: Double = 0
    public var armature: Double = 0
    public var stiffness: Double = 0
    public var springReference: Double = 0

    public init(kind: JointKind = .fixed, axis: Vec3 = .up, origin: Pose = .identity) {
        self.kind = kind
        self.axis = axis
        self.origin = origin
    }

    public static let fixed = JointSpec(kind: .fixed)
    public static let free = JointSpec(kind: .free)

    public static func revolute(axis: Vec3, origin: Pose = .identity,
                                limits: ClosedRange<Double>? = nil,
                                damping: Double = 0, armature: Double = 0) -> JointSpec {
        var j = JointSpec(kind: .revolute, axis: axis, origin: origin)
        if let l = limits {
            j.limited = true
            j.lower = l.lowerBound
            j.upper = l.upperBound
        }
        j.damping = damping
        j.armature = armature
        return j
    }

    public static func prismatic(axis: Vec3, origin: Pose = .identity,
                                 limits: ClosedRange<Double>? = nil,
                                 damping: Double = 0) -> JointSpec {
        var j = JointSpec(kind: .prismatic, axis: axis, origin: origin)
        if let l = limits {
            j.limited = true
            j.lower = l.lowerBound
            j.upper = l.upperBound
        }
        j.damping = damping
        return j
    }
}

public enum ActuatorKind: Int32, Sendable {
    case motor = 0
    case position = 1
    case velocity = 2
    case damper = 3
}

public struct ActuatorSpec: Sendable {
    public var name: String = ""
    public var kind: ActuatorKind = .motor
    public var articulation: Int
    public var link: Int
    public var gear: Double = 1
    public var kp: Double = 0
    public var kd: Double = 0
    public var controlRange: ClosedRange<Double>? = nil
    public var forceRange: ClosedRange<Double>? = nil

    public init(name: String = "", kind: ActuatorKind = .motor, articulation: Int, link: Int,
                gear: Double = 1, kp: Double = 0, kd: Double = 0,
                controlRange: ClosedRange<Double>? = nil, forceRange: ClosedRange<Double>? = nil) {
        self.name = name
        self.kind = kind
        self.articulation = articulation
        self.link = link
        self.gear = gear
        self.kp = kp
        self.kd = kd
        self.controlRange = controlRange
        self.forceRange = forceRange
    }
}

public enum SensorKind: Int32, Sendable {
    case jointPosition = 0
    case jointVelocity = 1
    case actuatorForce = 2
    case accelerometer = 3
    case gyroscope = 4
    case framePosition = 5
    case frameOrientation = 6
    case frameLinearVelocity = 7
    case forceTorque = 8
    case contactNormalForce = 9
    case rangefinder = 10

    public var dimension: Int {
        switch self {
        case .jointPosition, .jointVelocity, .actuatorForce, .contactNormalForce, .rangefinder:
            return 1
        case .accelerometer, .gyroscope, .framePosition, .frameLinearVelocity: return 3
        case .frameOrientation: return 4
        case .forceTorque: return 6
        }
    }
}

public struct SensorSpec: Sendable {
    public var name: String = ""
    public var kind: SensorKind
    public var articulation: Int
    public var link: Int
    public var localPose: Pose = .identity
    public var noiseStandardDeviation: Double = 0
    public var bias: Double = 0
    public var cutoff: Double = 0

    public init(name: String = "", kind: SensorKind, articulation: Int, link: Int,
                localPose: Pose = .identity, noiseStandardDeviation: Double = 0,
                bias: Double = 0, cutoff: Double = 0) {
        self.name = name
        self.kind = kind
        self.articulation = articulation
        self.link = link
        self.localPose = localPose
        self.noiseStandardDeviation = noiseStandardDeviation
        self.bias = bias
        self.cutoff = cutoff
    }
}

public struct SimulationOptions: Sendable {
    public var timestep: Double = 1.0 / 500.0
    public var gravity: Vec3 = Vec3(0, 0, -9.81)
    public var solverIterations: Int = 30
    public var relaxationIterations: Int = 6
    public var solverTolerance: Double = 1e-10
    public var warmStart: Bool = true
    public var contactMargin: Double = 0.002
    public var penetrationSlop: Double = 0.0005
    public var maxCorrectionVelocity: Double = 3.0
    public var linearDamping: Double = 0
    public var angularDamping: Double = 0
    public var maxVelocity: Double = 1000
    public var enableContacts: Bool = true
    public var enableJointLimits: Bool = true
    public var enableEqualities: Bool = true
    public var multithreaded: Bool = true

    public init() {}

    init(_ c: kn_options) {
        timestep = c.timestep
        gravity = Vec3(c.gravity.0, c.gravity.1, c.gravity.2)
        solverIterations = Int(c.solverIterations)
        relaxationIterations = Int(c.relaxationIterations)
        solverTolerance = c.solverTolerance
        warmStart = c.warmStart
        contactMargin = c.contactMargin
        penetrationSlop = c.penetrationSlop
        maxCorrectionVelocity = c.maxCorrectionVelocity
        linearDamping = c.linearDamping
        angularDamping = c.angularDamping
        maxVelocity = c.maxVelocity
        enableContacts = c.enableContacts
        enableJointLimits = c.enableJointLimits
        enableEqualities = c.enableEqualities
        multithreaded = c.multithreaded
    }

    var cValue: kn_options {
        var c = kn_options()
        kn_options_defaults(&c)
        c.timestep = timestep
        c.gravity = (gravity.x, gravity.y, gravity.z)
        c.solverIterations = Int32(solverIterations)
        c.relaxationIterations = Int32(relaxationIterations)
        c.solverTolerance = solverTolerance
        c.warmStart = warmStart
        c.contactMargin = contactMargin
        c.penetrationSlop = penetrationSlop
        c.maxCorrectionVelocity = maxCorrectionVelocity
        c.linearDamping = linearDamping
        c.angularDamping = angularDamping
        c.maxVelocity = maxVelocity
        c.enableContacts = enableContacts
        c.enableJointLimits = enableJointLimits
        c.enableEqualities = enableEqualities
        c.multithreaded = multithreaded
        return c
    }
}

// MARK: - Snapshots

public struct Contact: Sendable {
    public var point: Vec3
    public var normal: Vec3
    public var force: Vec3
    public var depth: Double
    public var geomA: Int
    public var geomB: Int
    public var normalForce: Double { force.dot(normal) }
}

public struct StepProfile: Sendable {
    public var kinematics = 0.0
    public var inertia = 0.0
    public var bias = 0.0
    public var collision = 0.0
    public var constraintSetup = 0.0
    public var solve = 0.0
    public var integrate = 0.0
    public var sensors = 0.0
    public var total = 0.0
    public var contactCount = 0
    public var constraintCount = 0
    public var broadphasePairs = 0
    public var solverIterations = 0
    public var solverResidual = 0.0

    public init() {}

    init(_ c: kn_profile) {
        kinematics = c.kinematics
        inertia = c.inertia
        bias = c.bias
        collision = c.collision
        constraintSetup = c.constraintSetup
        solve = c.solve
        integrate = c.integrate
        sensors = c.sensors
        total = c.total
        contactCount = Int(c.contactCount)
        constraintCount = Int(c.constraintCount)
        broadphasePairs = Int(c.broadphasePairs)
        solverIterations = Int(c.solverIterations)
        solverResidual = c.solverResidual
    }
}

public struct RaycastHit: Sendable {
    public var distance: Double
    public var point: Vec3
    public var normal: Vec3
    public var geom: Int
    public var articulation: Int
    public var link: Int
}

/// Everything the renderer needs about one geom, resolved once at compile time.
public struct GeomInfo: Sendable {
    public var index: Int
    public var name: String
    public var shape: Shape
    public var appearance: Appearance
    public var articulation: Int
    public var link: Int
    public var visible: Bool
    public var collidable: Bool
}

// MARK: - World

public final class World {
    let ptr: OpaquePointer

    public init() {
        ptr = kn_world_create()
    }

    deinit {
        kn_world_destroy(ptr)
    }

    // MARK: Options

    public var options: SimulationOptions {
        get {
            var c = kn_options()
            kn_world_get_options(ptr, &c)
            return SimulationOptions(c)
        }
        set {
            var c = newValue.cValue
            kn_world_set_options(ptr, &c)
        }
    }

    // MARK: Construction

    @discardableResult
    public func addArticulation(name: String) -> Int {
        Int(kn_add_articulation(ptr, name))
    }

    @discardableResult
    public func addLink(articulation: Int, parent: Int = -1, name: String) -> Int {
        Int(kn_add_link(ptr, Int32(articulation), Int32(parent), name))
    }

    public func setInertial(articulation: Int, link: Int, mass: Double, com: Vec3 = .zero,
                            inertia: [Double]) {
        var c = (com.x, com.y, com.z)
        var i = inertia
        withUnsafePointer(to: &c) { comPtr in
            comPtr.withMemoryRebound(to: Double.self, capacity: 3) { cp in
                kn_set_inertial(ptr, Int32(articulation), Int32(link), mass, cp, &i)
            }
        }
    }

    public func setInertial(articulation: Int, link: Int, shape: Shape, density: Double,
                            com: Vec3 = .zero) {
        let mass = max(shape.volume * density, 1e-9)
        setInertial(articulation: articulation, link: link, mass: mass, com: com,
                    inertia: shape.inertia(mass: mass))
    }

    public func setJoint(articulation: Int, link: Int, _ joint: JointSpec) {
        var d = kn_joint_desc()
        kn_joint_defaults(&d)
        d.type = joint.kind.rawValue
        d.axis = (joint.axis.x, joint.axis.y, joint.axis.z)
        d.originPos = (joint.origin.position.x, joint.origin.position.y, joint.origin.position.z)
        d.originQuat = (joint.origin.orientation.w, joint.origin.orientation.x,
                        joint.origin.orientation.y, joint.origin.orientation.z)
        d.limited = joint.limited
        d.lower = joint.lower
        d.upper = joint.upper
        d.effortLimit = joint.effortLimit
        d.velocityLimit = joint.velocityLimit
        d.damping = joint.damping
        d.friction = joint.friction
        d.armature = joint.armature
        d.stiffness = joint.stiffness
        d.springRef = joint.springReference
        kn_set_joint(ptr, Int32(articulation), Int32(link), &d)
    }

    @discardableResult
    public func addGeom(articulation: Int, link: Int, _ geom: GeomSpec) -> Int {
        var d = kn_geom_desc()
        kn_geom_defaults(&d)
        d.type = geom.shape.cType
        let s = geom.shape.cSize
        d.size = (s.x, s.y, s.z)
        d.meshIndex = geom.shape.meshIndex
        d.localPos = (geom.localPose.position.x, geom.localPose.position.y, geom.localPose.position.z)
        d.localQuat = (geom.localPose.orientation.w, geom.localPose.orientation.x,
                       geom.localPose.orientation.y, geom.localPose.orientation.z)
        d.friction = geom.material.friction
        d.torsionalFriction = geom.material.torsionalFriction
        d.restitution = geom.material.restitution
        d.stiffnessTimeConst = geom.material.stiffnessTimeConstant
        d.dampingRatio = geom.material.dampingRatio
        d.margin = geom.material.margin
        d.rgba = (geom.appearance.color.x, geom.appearance.color.y, geom.appearance.color.z,
                  geom.appearance.color.w)
        d.metallic = geom.appearance.metallic
        d.roughness = geom.appearance.roughness
        d.emissive = geom.appearance.emissive
        d.collidable = geom.collidable
        d.visible = geom.visible
        d.group = geom.group
        d.mask = geom.mask
        let index = Int(kn_add_geom(ptr, Int32(articulation), Int32(link), &d))
        geomNames[index] = geom.name
        return index
    }

    @discardableResult
    public func addMesh(vertices: [Vec3], indices: [UInt32], name: String = "") -> Int {
        var flat = [Double]()
        flat.reserveCapacity(vertices.count * 3)
        for v in vertices {
            flat.append(v.x)
            flat.append(v.y)
            flat.append(v.z)
        }
        var idx = indices
        return Int(kn_add_mesh(ptr, flat, Int32(vertices.count), &idx, Int32(indices.count), name))
    }

    @discardableResult
    public func addActuator(_ spec: ActuatorSpec) -> Int {
        var d = kn_actuator_desc()
        kn_actuator_defaults(&d)
        d.type = spec.kind.rawValue
        d.articulation = Int32(spec.articulation)
        d.link = Int32(spec.link)
        d.gear = spec.gear
        d.kp = spec.kp
        d.kd = spec.kd
        if let r = spec.controlRange {
            d.ctrlMin = r.lowerBound
            d.ctrlMax = r.upperBound
        }
        if let r = spec.forceRange {
            d.forceMin = r.lowerBound
            d.forceMax = r.upperBound
        }
        return Int(kn_add_actuator(ptr, &d, spec.name))
    }

    @discardableResult
    public func addSensor(_ spec: SensorSpec) -> Int {
        var d = kn_sensor_desc()
        kn_sensor_defaults(&d)
        d.type = spec.kind.rawValue
        d.articulation = Int32(spec.articulation)
        d.link = Int32(spec.link)
        d.localPos = (spec.localPose.position.x, spec.localPose.position.y, spec.localPose.position.z)
        d.localQuat = (spec.localPose.orientation.w, spec.localPose.orientation.x,
                       spec.localPose.orientation.y, spec.localPose.orientation.z)
        d.noiseStdDev = spec.noiseStandardDeviation
        d.bias = spec.bias
        d.cutoff = spec.cutoff
        let index = Int(kn_add_sensor(ptr, &d, spec.name))
        sensorNames.append(spec.name.isEmpty ? "sensor\(index)" : spec.name)
        sensorKinds.append(spec.kind)
        return index
    }

    /// Ball joint between two links (or a link and the world when `articulationB` is nil).
    @discardableResult
    public func connect(articulationA: Int, linkA: Int, anchorA: Vec3,
                        articulationB: Int? = nil, linkB: Int = 0, anchorB: Vec3) -> Int {
        var d = kn_equality_desc()
        kn_equality_defaults(&d)
        d.type = Int32(KN_EQ_CONNECT.rawValue)
        d.articulationA = Int32(articulationA)
        d.linkA = Int32(linkA)
        d.articulationB = Int32(articulationB ?? -1)
        d.linkB = Int32(linkB)
        d.anchorA = (anchorA.x, anchorA.y, anchorA.z)
        d.anchorB = (anchorB.x, anchorB.y, anchorB.z)
        return Int(kn_add_equality(ptr, &d))
    }

    @discardableResult
    public func weld(articulationA: Int, linkA: Int, articulationB: Int? = nil, linkB: Int = 0,
                     anchorA: Vec3 = .zero, anchorB: Vec3 = .zero,
                     relativeOrientation: Quat = .identity) -> Int {
        var d = kn_equality_desc()
        kn_equality_defaults(&d)
        d.type = Int32(KN_EQ_WELD.rawValue)
        d.articulationA = Int32(articulationA)
        d.linkA = Int32(linkA)
        d.articulationB = Int32(articulationB ?? -1)
        d.linkB = Int32(linkB)
        d.anchorA = (anchorA.x, anchorA.y, anchorA.z)
        d.anchorB = (anchorB.x, anchorB.y, anchorB.z)
        d.relQuat = (relativeOrientation.w, relativeOrientation.x, relativeOrientation.y,
                     relativeOrientation.z)
        return Int(kn_add_equality(ptr, &d))
    }

    public func setSelfCollision(articulation: Int, enabled: Bool) {
        kn_set_self_collision(ptr, Int32(articulation), enabled)
    }

    public func setEnabled(articulation: Int, enabled: Bool) {
        kn_set_articulation_enabled(ptr, Int32(articulation), enabled)
    }

    public func setDefaultPose(articulation: Int, q: [Double]) {
        var v = q
        kn_set_default_pose(ptr, Int32(articulation), &v, Int32(q.count))
    }

    public func compile() {
        kn_compile(ptr)
        cachedGeomInfo = nil
    }

    public var isCompiled: Bool { kn_is_compiled(ptr) }

    // MARK: Sizes

    public var dofCount: Int { Int(kn_nv(ptr)) }
    public var coordinateCount: Int { Int(kn_nq(ptr)) }
    public var actuatorCount: Int { Int(kn_nu(ptr)) }
    public var sensorDataCount: Int { Int(kn_nsensordata(ptr)) }
    public var articulationCount: Int { Int(kn_narticulation(ptr)) }
    public var linkCount: Int { Int(kn_nlink(ptr)) }
    public var geomCount: Int { Int(kn_ngeom(ptr)) }

    public func linkCount(articulation: Int) -> Int { Int(kn_link_count(ptr, Int32(articulation))) }
    public func coordinateOffset(articulation: Int) -> Int {
        Int(kn_articulation_qoffset(ptr, Int32(articulation)))
    }
    public func dofOffset(articulation: Int) -> Int {
        Int(kn_articulation_voffset(ptr, Int32(articulation)))
    }

    // MARK: State

    public var positions: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_qpos(ptr), count: coordinateCount)
    }
    public var velocities: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_qvel(ptr), count: dofCount)
    }
    public var accelerations: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_qacc(ptr), count: dofCount)
    }
    public var control: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_ctrl(ptr), count: actuatorCount)
    }
    public var actuatorForces: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_actuator_force(ptr), count: actuatorCount)
    }
    public var sensorReadings: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_sensor_data(ptr), count: sensorDataCount)
    }
    public var appliedGeneralizedForces: UnsafeMutableBufferPointer<Double> {
        UnsafeMutableBufferPointer(start: kn_qfrc_applied(ptr), count: dofCount)
    }

    public var time: Double {
        get { kn_time(ptr) }
        set { kn_set_time(ptr, newValue) }
    }

    public func step(_ count: Int = 1) { kn_step(ptr, Int32(count)) }
    public func forward() { kn_forward(ptr) }
    public func reset() { kn_reset(ptr) }

    public func applyForce(articulation: Int, link: Int, force: Vec3, at worldPoint: Vec3) {
        var f = (force.x, force.y, force.z)
        var p = (worldPoint.x, worldPoint.y, worldPoint.z)
        withUnsafePointer(to: &f) { fp in
            fp.withMemoryRebound(to: Double.self, capacity: 3) { fpp in
                withUnsafePointer(to: &p) { pp in
                    pp.withMemoryRebound(to: Double.self, capacity: 3) { ppp in
                        kn_apply_force(ptr, Int32(articulation), Int32(link), fpp, ppp)
                    }
                }
            }
        }
    }

    public func applyTorque(articulation: Int, link: Int, torque: Vec3) {
        var t = (torque.x, torque.y, torque.z)
        withUnsafePointer(to: &t) { tp in
            tp.withMemoryRebound(to: Double.self, capacity: 3) { tpp in
                kn_apply_torque(ptr, Int32(articulation), Int32(link), tpp)
            }
        }
    }

    public func clearAppliedForces() { kn_clear_applied_forces(ptr) }

    public func saveState() -> [Double] {
        var buffer = [Double](repeating: 0, count: Int(kn_state_size(ptr)))
        _ = kn_save_state(ptr, &buffer, Int32(buffer.count))
        return buffer
    }

    public func loadState(_ state: [Double]) {
        var s = state
        kn_load_state(ptr, &s, Int32(s.count))
    }

    // MARK: Introspection

    public func linkPoses() -> [Pose] {
        let n = linkCount
        guard n > 0 else { return [] }
        var raw = [Double](repeating: 0, count: n * 7)
        kn_link_poses(ptr, &raw)
        return (0..<n).map { i in
            Pose(position: Vec3(raw[i * 7], raw[i * 7 + 1], raw[i * 7 + 2]),
                 orientation: Quat(w: raw[i * 7 + 3], x: raw[i * 7 + 4], y: raw[i * 7 + 5],
                                   z: raw[i * 7 + 6]))
        }
    }

    /// Fills `out` with one column-major 4x4 per geom. Sized for the render loop:
    /// no allocations after the first call.
    public func fillGeomTransforms(_ out: inout [simd_float4x4], scratch: inout [Double]) {
        let n = geomCount
        if scratch.count != n * 7 { scratch = [Double](repeating: 0, count: n * 7) }
        if out.count != n { out = [simd_float4x4](repeating: matrix_identity_float4x4, count: n) }
        guard n > 0 else { return }
        kn_geom_poses(ptr, &scratch)
        for i in 0..<n {
            let pose = Pose(
                position: Vec3(scratch[i * 7], scratch[i * 7 + 1], scratch[i * 7 + 2]),
                orientation: Quat(w: scratch[i * 7 + 3], x: scratch[i * 7 + 4],
                                  y: scratch[i * 7 + 5], z: scratch[i * 7 + 6]))
            out[i] = pose.matrix
        }
    }

    public func geomPoses() -> [Pose] {
        let n = geomCount
        guard n > 0 else { return [] }
        var raw = [Double](repeating: 0, count: n * 7)
        kn_geom_poses(ptr, &raw)
        return (0..<n).map { i in
            Pose(position: Vec3(raw[i * 7], raw[i * 7 + 1], raw[i * 7 + 2]),
                 orientation: Quat(w: raw[i * 7 + 3], x: raw[i * 7 + 4], y: raw[i * 7 + 5],
                                   z: raw[i * 7 + 6]))
        }
    }

    private var cachedGeomInfo: [GeomInfo]?
    private var geomNames: [Int: String] = [:]
    private(set) public var sensorNames: [String] = []
    private(set) public var sensorKinds: [SensorKind] = []

    public var geomInfo: [GeomInfo] {
        if let cached = cachedGeomInfo { return cached }
        var result: [GeomInfo] = []
        result.reserveCapacity(geomCount)
        for i in 0..<geomCount {
            var d = kn_geom_desc()
            kn_geom_info(ptr, Int32(i), &d)
            let size = Vec3(d.size.0, d.size.1, d.size.2)
            let shape: Shape
            switch d.type {
            case Int32(KN_GEOM_SPHERE.rawValue): shape = .sphere(radius: size.x)
            case Int32(KN_GEOM_BOX.rawValue): shape = .box(halfExtents: size)
            case Int32(KN_GEOM_CAPSULE.rawValue): shape = .capsule(radius: size.x, halfLength: size.y)
            case Int32(KN_GEOM_CYLINDER.rawValue):
                shape = .cylinder(radius: size.x, halfLength: size.y)
            case Int32(KN_GEOM_PLANE.rawValue): shape = .plane(extent: size.x)
            default: shape = .convexHull(mesh: Int(d.meshIndex), boundingRadius: size.x)
            }
            result.append(GeomInfo(
                index: i,
                name: geomNames[i] ?? "geom\(i)",
                shape: shape,
                appearance: Appearance(color: Vec4(d.rgba.0, d.rgba.1, d.rgba.2, d.rgba.3),
                                       metallic: d.metallic, roughness: d.roughness,
                                       emissive: d.emissive),
                articulation: Int(kn_geom_articulation(ptr, Int32(i))),
                link: Int(kn_geom_link(ptr, Int32(i))),
                visible: d.visible,
                collidable: d.collidable))
        }
        cachedGeomInfo = result
        return result
    }

    public func meshData(_ index: Int) -> (vertices: [Vec3], indices: [UInt32]) {
        let vc = Int(kn_mesh_vertex_count(ptr, Int32(index)))
        let ic = Int(kn_mesh_index_count(ptr, Int32(index)))
        guard vc > 0 else { return ([], []) }
        var raw = [Double](repeating: 0, count: vc * 3)
        var idx = [UInt32](repeating: 0, count: max(ic, 1))
        kn_mesh_data(ptr, Int32(index), &raw, &idx)
        let verts = (0..<vc).map { Vec3(raw[$0 * 3], raw[$0 * 3 + 1], raw[$0 * 3 + 2]) }
        return (verts, Array(idx.prefix(ic)))
    }

    public func contacts() -> [Contact] {
        let n = Int(kn_contact_count(ptr))
        guard n > 0 else { return [] }
        var raw = [kn_contact](repeating: kn_contact(), count: n)
        let count = Int(kn_get_contacts(ptr, &raw, Int32(n)))
        return (0..<count).map { i in
            let c = raw[i]
            return Contact(point: Vec3(c.point.0, c.point.1, c.point.2),
                           normal: Vec3(c.normal.0, c.normal.1, c.normal.2),
                           force: Vec3(c.force.0, c.force.1, c.force.2),
                           depth: c.depth,
                           geomA: Int(c.geomA), geomB: Int(c.geomB))
        }
    }

    public var profile: StepProfile {
        var c = kn_profile()
        kn_get_profile(ptr, &c)
        return StepProfile(c)
    }

    public func name(articulation: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        kn_articulation_name(ptr, Int32(articulation), &buffer, 128)
        return String(cString: buffer)
    }

    public func name(articulation: Int, link: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        kn_link_name(ptr, Int32(articulation), Int32(link), &buffer, 128)
        return String(cString: buffer)
    }

    public func findArticulation(_ name: String) -> Int? {
        let i = Int(kn_find_articulation(ptr, name))
        return i >= 0 ? i : nil
    }

    public func findLink(articulation: Int, name: String) -> Int? {
        let i = Int(kn_find_link(ptr, Int32(articulation), name))
        return i >= 0 ? i : nil
    }

    public func findActuator(_ name: String) -> Int? {
        let i = Int(kn_find_actuator(ptr, name))
        return i >= 0 ? i : nil
    }

    public func jointKind(articulation: Int, link: Int) -> JointKind {
        JointKind(rawValue: kn_link_joint_type(ptr, Int32(articulation), Int32(link))) ?? .fixed
    }

    public func jointCoordinateIndex(articulation: Int, link: Int) -> Int {
        Int(kn_link_joint_qindex(ptr, Int32(articulation), Int32(link)))
    }

    public func jointDofIndex(articulation: Int, link: Int) -> Int {
        Int(kn_link_joint_vindex(ptr, Int32(articulation), Int32(link)))
    }

    public func jointLimits(articulation: Int, link: Int) -> ClosedRange<Double>? {
        var lower = 0.0, upper = 0.0, limited = false
        kn_link_joint_limits(ptr, Int32(articulation), Int32(link), &lower, &upper, &limited)
        guard limited, lower <= upper else { return nil }
        return lower...upper
    }

    public func mass(articulation: Int, link: Int) -> Double {
        kn_link_mass(ptr, Int32(articulation), Int32(link))
    }

    public func parent(articulation: Int, link: Int) -> Int {
        Int(kn_link_parent(ptr, Int32(articulation), Int32(link)))
    }

    public var kineticEnergy: Double { kn_kinetic_energy(ptr) }
    public var potentialEnergy: Double { kn_potential_energy(ptr) }
    public var totalEnergy: Double { kineticEnergy + potentialEnergy }
    public var totalMass: Double { kn_total_mass(ptr) }

    public var centerOfMass: Vec3 {
        var out = (0.0, 0.0, 0.0)
        withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: Double.self, capacity: 3) { kn_center_of_mass(ptr, $0) }
        }
        return Vec3(out.0, out.1, out.2)
    }

    public var linearMomentum: Vec3 {
        var out = (0.0, 0.0, 0.0)
        withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: Double.self, capacity: 3) { kn_linear_momentum(ptr, $0) }
        }
        return Vec3(out.0, out.1, out.2)
    }

    public var angularMomentum: Vec3 {
        var out = (0.0, 0.0, 0.0)
        withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: Double.self, capacity: 3) { kn_angular_momentum(ptr, $0) }
        }
        return Vec3(out.0, out.1, out.2)
    }

    public func raycast(origin: Vec3, direction: Vec3, maxDistance: Double = 100,
                        mask: UInt32 = .max, ignoring articulation: Int = -1) -> RaycastHit? {
        var o = (origin.x, origin.y, origin.z)
        var d = (direction.x, direction.y, direction.z)
        let hit: kn_ray_hit = withUnsafePointer(to: &o) { op in
            op.withMemoryRebound(to: Double.self, capacity: 3) { opp in
                withUnsafePointer(to: &d) { dp in
                    dp.withMemoryRebound(to: Double.self, capacity: 3) { dpp in
                        kn_raycast(ptr, opp, dpp, maxDistance, mask, Int32(articulation))
                    }
                }
            }
        }
        guard hit.hit else { return nil }
        return RaycastHit(distance: hit.distance,
                          point: Vec3(hit.point.0, hit.point.1, hit.point.2),
                          normal: Vec3(hit.normal.0, hit.normal.1, hit.normal.2),
                          geom: Int(hit.geom), articulation: Int(hit.articulation),
                          link: Int(hit.link))
    }

    /// 3 x nv Jacobian of a world point rigidly attached to `link`, row-major.
    public func pointJacobian(articulation: Int, link: Int, worldPoint: Vec3) -> [Double] {
        let n = Int(kn_articulation_nv(ptr, Int32(articulation)))
        var out = [Double](repeating: 0, count: 3 * n)
        var p = (worldPoint.x, worldPoint.y, worldPoint.z)
        withUnsafePointer(to: &p) { pp in
            pp.withMemoryRebound(to: Double.self, capacity: 3) { ppp in
                kn_point_jacobian(ptr, Int32(articulation), Int32(link), ppp, &out)
            }
        }
        return out
    }

    /// nv x nv joint-space inertia of one articulation, row-major.
    public func massMatrix(articulation: Int) -> [Double] {
        let n = Int(kn_articulation_nv(ptr, Int32(articulation)))
        var out = [Double](repeating: 0, count: n * n)
        kn_mass_matrix(ptr, Int32(articulation), &out)
        return out
    }

    public static var versionString: String { String(cString: kn_version_string()) }
}
