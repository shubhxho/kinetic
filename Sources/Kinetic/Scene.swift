//
//  Scene.swift
//  Kinetic
//
//  Convenience construction on top of the raw World API, plus a library of
//  reference scenes used by the CLI, the tests and Studio's welcome screen.
//

import Foundation

/// Handle to a single-link free body.
public struct RigidBody: Sendable {
    public var articulation: Int
    public var link: Int
    public var geom: Int
    public var coordinateOffset: Int
    public var dofOffset: Int
}

/// Handle to a multi-link kinematic tree.
public struct Robot: Sendable {
    public var articulation: Int
    public var name: String
    public var links: [String]
    public var actuators: [Int]
}

extension World {
    /// Static ground plane at `height`, with an optional checker-friendly tint.
    @discardableResult
    public func addGround(height: Double = 0, friction: Double = 1.0, extent: Double = 60,
                          appearance: Appearance = Appearance(color: Vec4(0.12, 0.13, 0.15, 1),
                                                              roughness: 0.9)) -> Int {
        let art = addArticulation(name: "world")
        let link = addLink(articulation: art, parent: -1, name: "ground")
        setJoint(articulation: art, link: link, .fixed)
        var geom = GeomSpec(shape: .plane(extent: extent),
                            localPose: Pose(position: Vec3(0, 0, height)),
                            material: SurfaceMaterial(friction: friction),
                            appearance: appearance,
                            name: "ground")
        geom.group = 1
        addGeom(articulation: art, link: link, geom)
        return art
    }

    /// Free-floating single-link body.
    @discardableResult
    public func addRigidBody(name: String, shape: Shape, density: Double = 500,
                             pose: Pose = .identity, material: SurfaceMaterial = .default,
                             appearance: Appearance = .default) -> RigidBody {
        let art = addArticulation(name: name)
        let link = addLink(articulation: art, parent: -1, name: name)
        setJoint(articulation: art, link: link, .free)
        setInertial(articulation: art, link: link, shape: shape, density: density)
        let geom = addGeom(articulation: art, link: link,
                           GeomSpec(shape: shape, material: material, appearance: appearance,
                                    name: name))
        setDefaultPose(articulation: art, q: [
            pose.position.x, pose.position.y, pose.position.z,
            pose.orientation.w, pose.orientation.x, pose.orientation.y, pose.orientation.z,
        ])
        return RigidBody(articulation: art, link: link, geom: geom,
                         coordinateOffset: 0, dofOffset: 0)
    }

    /// Static (immovable) body, useful for fixtures, walls and ramps.
    @discardableResult
    public func addStaticBody(name: String, shape: Shape, pose: Pose = .identity,
                              material: SurfaceMaterial = .default,
                              appearance: Appearance = .default) -> Int {
        let art = addArticulation(name: name)
        let link = addLink(articulation: art, parent: -1, name: name)
        var joint = JointSpec(kind: .fixed)
        joint.origin = pose
        setJoint(articulation: art, link: link, joint)
        addGeom(articulation: art, link: link,
                GeomSpec(shape: shape, material: material, appearance: appearance, name: name))
        return art
    }

    /// Writes the pose of a free-joint body directly into the state vector.
    public func setPose(articulation: Int, _ pose: Pose) {
        let q = coordinateOffset(articulation: articulation)
        guard q + 7 <= coordinateCount else { return }
        let p = positions
        p[q + 0] = pose.position.x
        p[q + 1] = pose.position.y
        p[q + 2] = pose.position.z
        p[q + 3] = pose.orientation.w
        p[q + 4] = pose.orientation.x
        p[q + 5] = pose.orientation.y
        p[q + 6] = pose.orientation.z
        forward()
    }

    public func pose(articulation: Int) -> Pose {
        let q = coordinateOffset(articulation: articulation)
        guard q + 7 <= coordinateCount else { return .identity }
        let p = positions
        return Pose(position: Vec3(p[q], p[q + 1], p[q + 2]),
                    orientation: Quat(w: p[q + 3], x: p[q + 4], y: p[q + 5], z: p[q + 6]))
    }

    public func setVelocity(articulation: Int, linear: Vec3, angular: Vec3 = .zero) {
        let v = dofOffset(articulation: articulation)
        guard v + 6 <= dofCount else { return }
        let vel = velocities
        vel[v + 0] = linear.x
        vel[v + 1] = linear.y
        vel[v + 2] = linear.z
        vel[v + 3] = angular.x
        vel[v + 4] = angular.y
        vel[v + 5] = angular.z
    }
}

// MARK: - Reference scenes

public enum SceneLibrary {
    public struct Entry: Sendable {
        public let id: String
        public let title: String
        public let summary: String
        public let build: @Sendable () -> World
    }

    public static let all: [Entry] = [
        Entry(id: "stack", title: "Box stack",
              summary: "Ten boxes settling into a tower — contact manifold and warm-start test.",
              build: { boxStack(count: 10) }),
        Entry(id: "arm", title: "6-DOF arm",
              summary: "Serial manipulator with position actuators and joint limits.",
              build: { articulatedArm() }),
        Entry(id: "quadruped", title: "Quadruped",
              summary: "Twelve-actuator walker on a floating base.",
              build: { quadruped() }),
        Entry(id: "cartpole", title: "Cart-pole",
              summary: "Classic underactuated control benchmark.",
              build: { cartPole() }),
        Entry(id: "chain", title: "Pendulum chain",
              summary: "Twenty-link chain — solver conditioning stress test.",
              build: { pendulumChain(links: 20) }),
        Entry(id: "dominoes", title: "Dominoes",
              summary: "Sixty toppling slabs — friction and restitution.",
              build: { dominoes() }),
        Entry(id: "mixed", title: "Mixed primitives",
              summary: "Spheres, capsules, cylinders and hulls in one pile.",
              build: { mixedPrimitives() }),
    ]

    public static func build(_ id: String) -> World? {
        all.first(where: { $0.id == id })?.build()
    }

    // MARK: Scenes

    public static func boxStack(count: Int = 10) -> World {
        let world = World()
        world.addGround()
        for i in 0..<count {
            let hue = Double(i) / Double(max(count - 1, 1))
            world.addRigidBody(
                name: "box\(i)",
                shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
                density: 500,
                pose: Pose(position: Vec3(0, 0, 0.1 + 0.2005 * Double(i))),
                appearance: Appearance(color: Vec4(0.35 + 0.5 * hue, 0.45, 0.95 - 0.4 * hue, 1),
                                       roughness: 0.4))
        }
        world.compile()
        return world
    }

    public static func boxStack() -> World { boxStack(count: 10) }

    /// Six-axis manipulator with the joint layout of a typical collaborative arm.
    public static func articulatedArm() -> World {
        let world = World()
        world.addGround()

        let art = world.addArticulation(name: "arm")
        var parent = -1
        var actuators: [Int] = []

        struct Segment {
            let name: String
            let axis: Vec3
            let offset: Vec3
            let length: Double
            let radius: Double
            let limits: ClosedRange<Double>
        }

        let segments: [Segment] = [
            Segment(name: "base", axis: Vec3(0, 0, 1), offset: Vec3(0, 0, 0.10), length: 0.10,
                    radius: 0.075, limits: -2.9...2.9),
            Segment(name: "shoulder", axis: Vec3(0, 1, 0), offset: Vec3(0, 0, 0.14), length: 0.22,
                    radius: 0.06, limits: -1.9...1.9),
            Segment(name: "elbow", axis: Vec3(0, 1, 0), offset: Vec3(0, 0, 0.26), length: 0.20,
                    radius: 0.05, limits: -2.6...2.6),
            Segment(name: "wrist1", axis: Vec3(0, 0, 1), offset: Vec3(0, 0, 0.22), length: 0.08,
                    radius: 0.042, limits: -3.1...3.1),
            Segment(name: "wrist2", axis: Vec3(0, 1, 0), offset: Vec3(0, 0, 0.09), length: 0.08,
                    radius: 0.040, limits: -2.0...2.0),
            Segment(name: "wrist3", axis: Vec3(0, 0, 1), offset: Vec3(0, 0, 0.08), length: 0.05,
                    radius: 0.036, limits: -3.1...3.1),
        ]

        for (i, seg) in segments.enumerated() {
            let link = world.addLink(articulation: art, parent: parent, name: seg.name)
            var joint = JointSpec.revolute(
                axis: seg.axis,
                origin: Pose(position: seg.offset),
                limits: seg.limits,
                damping: 2.0,
                armature: 0.02)
            joint.effortLimit = 200
            world.setJoint(articulation: art, link: link, joint)

            let shape = Shape.capsule(radius: seg.radius, halfLength: seg.length * 0.5)
            let mass = max(shape.volume * 1200, 0.2)
            world.setInertial(articulation: art, link: link, mass: mass,
                              com: Vec3(0, 0, seg.length * 0.5),
                              inertia: shape.inertia(mass: mass))
            world.addGeom(
                articulation: art, link: link,
                GeomSpec(shape: shape,
                         localPose: Pose(position: Vec3(0, 0, seg.length * 0.5)),
                         appearance: Appearance(
                            color: i % 2 == 0 ? Vec4(0.93, 0.94, 0.96, 1) : Vec4(0.20, 0.21, 0.24, 1),
                            metallic: 0.15, roughness: 0.35),
                         name: seg.name))

            actuators.append(world.addActuator(ActuatorSpec(
                name: "\(seg.name)_pos", kind: .position, articulation: art, link: link,
                gear: 1, kp: 800, kd: 60,
                controlRange: seg.limits, forceRange: -200...200)))
            parent = link
        }

        // End-effector plate so the tool frame is visible.
        let tool = world.addLink(articulation: art, parent: parent, name: "tool")
        world.setJoint(articulation: art, link: tool,
                       JointSpec(kind: .fixed, origin: Pose(position: Vec3(0, 0, 0.06))))
        let toolShape = Shape.box(halfExtents: Vec3(0.05, 0.05, 0.012))
        world.setInertial(articulation: art, link: tool, shape: toolShape, density: 1500)
        world.addGeom(articulation: art, link: tool,
                      GeomSpec(shape: toolShape,
                               appearance: Appearance(color: Vec4(0.05, 0.55, 1.0, 1),
                                                      metallic: 0.4, roughness: 0.25),
                               name: "tool"))
        world.addSensor(SensorSpec(name: "tool_position", kind: .framePosition,
                                   articulation: art, link: tool))
        world.addSensor(SensorSpec(name: "tool_orientation", kind: .frameOrientation,
                                   articulation: art, link: tool))

        let restPose: [Double] = [0, 0.55, -1.1, 0, 0.55, 0]
        world.setDefaultPose(articulation: art, q: restPose)
        world.compile()
        for (i, value) in restPose.enumerated() where i < world.actuatorCount {
            world.control[i] = value
        }
        _ = actuators
        return world
    }

    public static func quadruped() -> World {
        let world = World()
        world.addGround(friction: 1.1)

        let art = world.addArticulation(name: "quadruped")
        let torso = world.addLink(articulation: art, parent: -1, name: "torso")
        world.setJoint(articulation: art, link: torso, .free)
        let torsoShape = Shape.box(halfExtents: Vec3(0.24, 0.11, 0.055))
        world.setInertial(articulation: art, link: torso, shape: torsoShape, density: 900)
        world.addGeom(articulation: art, link: torso,
                      GeomSpec(shape: torsoShape,
                               appearance: Appearance(color: Vec4(0.16, 0.17, 0.20, 1),
                                                      metallic: 0.2, roughness: 0.4),
                               name: "torso"))

        let legOffsets: [(String, Vec3)] = [
            ("fl", Vec3(0.19, 0.13, 0)), ("fr", Vec3(0.19, -0.13, 0)),
            ("hl", Vec3(-0.19, 0.13, 0)), ("hr", Vec3(-0.19, -0.13, 0)),
        ]

        for (name, offset) in legOffsets {
            // hip abduction
            let hip = world.addLink(articulation: art, parent: torso, name: "\(name)_hip")
            world.setJoint(articulation: art, link: hip,
                           JointSpec.revolute(axis: Vec3(1, 0, 0),
                                              origin: Pose(position: offset),
                                              limits: -0.8...0.8, damping: 0.4, armature: 0.01))
            let hipShape = Shape.capsule(radius: 0.032, halfLength: 0.03)
            world.setInertial(articulation: art, link: hip, shape: hipShape, density: 1000)
            world.addGeom(articulation: art, link: hip,
                          GeomSpec(shape: hipShape,
                                   localPose: Pose(orientation: Quat(axis: Vec3(1, 0, 0),
                                                                     angle: .pi / 2)),
                                   appearance: Appearance(color: Vec4(0.75, 0.76, 0.80, 1)),
                                   name: "\(name)_hip"))

            // thigh
            let thigh = world.addLink(articulation: art, parent: hip, name: "\(name)_thigh")
            world.setJoint(articulation: art, link: thigh,
                           JointSpec.revolute(axis: Vec3(0, 1, 0),
                                              origin: Pose(position: Vec3(0, 0, -0.02)),
                                              limits: -2.2...1.2, damping: 0.4, armature: 0.01))
            let thighShape = Shape.capsule(radius: 0.026, halfLength: 0.085)
            world.setInertial(articulation: art, link: thigh, mass: 0.9,
                              com: Vec3(0, 0, -0.085),
                              inertia: thighShape.inertia(mass: 0.9))
            world.addGeom(articulation: art, link: thigh,
                          GeomSpec(shape: thighShape,
                                   localPose: Pose(position: Vec3(0, 0, -0.085)),
                                   appearance: Appearance(color: Vec4(0.90, 0.91, 0.94, 1)),
                                   name: "\(name)_thigh"))

            // shank + foot
            let shank = world.addLink(articulation: art, parent: thigh, name: "\(name)_shank")
            world.setJoint(articulation: art, link: shank,
                           JointSpec.revolute(axis: Vec3(0, 1, 0),
                                              origin: Pose(position: Vec3(0, 0, -0.19)),
                                              limits: 0.2...2.7, damping: 0.4, armature: 0.01))
            let shankShape = Shape.capsule(radius: 0.020, halfLength: 0.082)
            world.setInertial(articulation: art, link: shank, mass: 0.5,
                              com: Vec3(0, 0, -0.082),
                              inertia: shankShape.inertia(mass: 0.5))
            world.addGeom(articulation: art, link: shank,
                          GeomSpec(shape: shankShape,
                                   localPose: Pose(position: Vec3(0, 0, -0.082)),
                                   appearance: Appearance(color: Vec4(0.22, 0.23, 0.26, 1)),
                                   name: "\(name)_shank"))
            world.addGeom(articulation: art, link: shank,
                          GeomSpec(shape: .sphere(radius: 0.026),
                                   localPose: Pose(position: Vec3(0, 0, -0.175)),
                                   material: SurfaceMaterial(friction: 1.3),
                                   appearance: Appearance(color: Vec4(0.05, 0.55, 1.0, 1),
                                                          roughness: 0.7),
                                   name: "\(name)_foot"))
            world.addSensor(SensorSpec(name: "\(name)_contact", kind: .contactNormalForce,
                                       articulation: art, link: shank))

            for (link, label) in [(hip, "hip"), (thigh, "thigh"), (shank, "shank")] {
                world.addActuator(ActuatorSpec(
                    name: "\(name)_\(label)", kind: .position, articulation: art, link: link,
                    gear: 1, kp: 60, kd: 2.0, forceRange: -40...40))
            }
        }

        world.addSensor(SensorSpec(name: "imu_gyro", kind: .gyroscope, articulation: art,
                                   link: torso))
        world.addSensor(SensorSpec(name: "imu_accel", kind: .accelerometer, articulation: art,
                                   link: torso))
        // Legs sweep through the torso volume by design; leg-on-leg contact is
        // not what this scene is demonstrating, so self-collision stays off.
        world.setSelfCollision(articulation: art, enabled: false)
        world.setDefaultPose(articulation: art, q: quadrupedRestPose())
        world.compile()
        // Hold the crouch the default pose describes; without this the position
        // actuators would drive every joint to zero and the robot would collapse.
        for leg in 0..<4 {
            world.control[leg * 3 + 0] = 0.0
            world.control[leg * 3 + 1] = -0.8
            world.control[leg * 3 + 2] = 1.6
        }
        return world
    }

    private static func quadrupedRestPose() -> [Double] {
        // free joint (7) + 4 legs x 3 revolute joints
        var q: [Double] = [0, 0, 0.30, 1, 0, 0, 0]
        for _ in 0..<4 {
            q += [0.0, -0.8, 1.6]
        }
        return q
    }

    public static func cartPole() -> World {
        let world = World()
        world.addGround()

        let art = world.addArticulation(name: "cartpole")
        let rail = world.addLink(articulation: art, parent: -1, name: "cart")
        var slide = JointSpec.prismatic(axis: Vec3(1, 0, 0),
                                        origin: Pose(position: Vec3(0, 0, 0.6)),
                                        limits: -2.4...2.4, damping: 0.1)
        slide.armature = 0.01
        world.setJoint(articulation: art, link: rail, slide)
        let cartShape = Shape.box(halfExtents: Vec3(0.12, 0.07, 0.05))
        world.setInertial(articulation: art, link: rail, shape: cartShape, density: 800)
        world.addGeom(articulation: art, link: rail,
                      GeomSpec(shape: cartShape,
                               appearance: Appearance(color: Vec4(0.93, 0.94, 0.96, 1)),
                               collidable: false, name: "cart"))

        let pole = world.addLink(articulation: art, parent: rail, name: "pole")
        world.setJoint(articulation: art, link: pole,
                       JointSpec.revolute(axis: Vec3(0, 1, 0), damping: 0.002, armature: 0.001))
        let poleShape = Shape.capsule(radius: 0.018, halfLength: 0.3)
        world.setInertial(articulation: art, link: pole, mass: 0.4, com: Vec3(0, 0, 0.3),
                          inertia: poleShape.inertia(mass: 0.4))
        world.addGeom(articulation: art, link: pole,
                      GeomSpec(shape: poleShape, localPose: Pose(position: Vec3(0, 0, 0.3)),
                               appearance: Appearance(color: Vec4(0.05, 0.55, 1.0, 1)),
                               collidable: false, name: "pole"))

        world.addActuator(ActuatorSpec(name: "slide", kind: .motor, articulation: art, link: rail,
                                       gear: 50, controlRange: -1...1))
        world.addSensor(SensorSpec(name: "cart_x", kind: .jointPosition, articulation: art,
                                   link: rail))
        world.addSensor(SensorSpec(name: "pole_angle", kind: .jointPosition, articulation: art,
                                   link: pole))
        world.setDefaultPose(articulation: art, q: [0, 0.08])
        world.compile()
        return world
    }

    public static func pendulumChain(links: Int = 20) -> World {
        let world = World()
        world.addGround(height: -3)

        let art = world.addArticulation(name: "chain")
        var parent = -1
        let segment = 0.12
        for i in 0..<links {
            let link = world.addLink(articulation: art, parent: parent, name: "link\(i)")
            let origin = i == 0 ? Pose(position: Vec3(0, 0, 2.5))
                                : Pose(position: Vec3(0, 0, -segment))
            world.setJoint(articulation: art, link: link,
                           JointSpec.revolute(axis: Vec3(0, 1, 0), origin: origin, damping: 0.002))
            let shape = Shape.capsule(radius: 0.018, halfLength: segment * 0.4)
            world.setInertial(articulation: art, link: link, mass: 0.15,
                              com: Vec3(0, 0, -segment * 0.5),
                              inertia: shape.inertia(mass: 0.15))
            let t = Double(i) / Double(max(links - 1, 1))
            world.addGeom(articulation: art, link: link,
                          GeomSpec(shape: shape,
                                   localPose: Pose(position: Vec3(0, 0, -segment * 0.5)),
                                   appearance: Appearance(
                                    color: Vec4(0.05 + 0.9 * t, 0.55 - 0.2 * t, 1.0 - 0.6 * t, 1),
                                    metallic: 0.3, roughness: 0.3),
                                   collidable: false, name: "link\(i)"))
            parent = link
        }
        world.setDefaultPose(articulation: art,
                             q: (0..<links).map { $0 == 0 ? 1.4 : 0.02 })
        world.compile()
        return world
    }

    public static func dominoes(count: Int = 60) -> World {
        let world = World()
        world.addGround(friction: 0.9)
        for i in 0..<count {
            let x = Double(i) * 0.085
            let lean = i == 0 ? 0.22 : 0.0
            world.addRigidBody(
                name: "domino\(i)",
                shape: .box(halfExtents: Vec3(0.008, 0.045, 0.09)),
                density: 900,
                pose: Pose(position: Vec3(x, 0, 0.0902),
                           orientation: Quat(axis: Vec3(0, 1, 0), angle: lean)),
                material: SurfaceMaterial(friction: 0.7, restitution: 0.05),
                appearance: Appearance(
                    color: Vec4(0.95 - 0.5 * Double(i) / Double(count), 0.95, 0.98, 1),
                    roughness: 0.35))
        }
        world.compile()
        return world
    }

    public static func mixedPrimitives() -> World {
        let world = World()
        world.addGround()
        let shapes: [Shape] = [
            .sphere(radius: 0.09),
            .box(halfExtents: Vec3(0.08, 0.08, 0.08)),
            .capsule(radius: 0.06, halfLength: 0.09),
            .cylinder(radius: 0.075, halfLength: 0.07),
        ]
        for i in 0..<24 {
            let shape = shapes[i % shapes.count]
            let ring = Double(i / 4)
            let angle = Double(i % 4) * .pi / 2 + ring * 0.4
            let radius = 0.22 + 0.03 * ring
            world.addRigidBody(
                name: "prim\(i)",
                shape: shape,
                density: 400,
                pose: Pose(position: Vec3(cos(angle) * radius, sin(angle) * radius,
                                          0.25 + 0.28 * ring),
                           orientation: Quat(axis: Vec3(0.3, 1, 0.2), angle: 0.6 * Double(i))),
                material: SurfaceMaterial(friction: 0.8, restitution: 0.15),
                appearance: Appearance(
                    color: Vec4(0.2 + 0.7 * Double(i % 4) / 3, 0.5, 0.95 - 0.4 * ring / 5, 1),
                    metallic: 0.1, roughness: 0.45))
        }
        world.compile()
        return world
    }
}
