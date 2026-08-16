//
//  PhysicsTests.swift
//  KineticTests
//
//  Physical correctness, not just "it did not crash". Every assertion here has a
//  closed-form or conservation-law reference.
//

import Foundation
import Testing

@testable import Kinetic

@Suite("Rigid-body dynamics")
struct DynamicsTests {

    @Test("Free fall matches the exact semi-implicit Euler solution")
    func freeFall() {
        let world = World()
        world.addRigidBody(name: "ball", shape: .sphere(radius: 0.1), density: 1000,
                           pose: Pose(position: Vec3(0, 0, 10)))
        world.compile()
        var options = world.options
        options.enableContacts = false
        world.options = options

        let h = options.timestep
        let n = 500
        world.step(n)

        // Semi-implicit Euler: z_n = z_0 - g h^2 * n(n+1)/2, exactly.
        let expected = 10 - 9.81 * h * h * Double(n) * Double(n + 1) / 2
        #expect(abs(world.positions[2] - expected) < 1e-9)
        #expect(abs(world.velocities[2] - (-9.81 * h * Double(n))) < 1e-9)
    }

    @Test("A sphere at rest sinks no deeper than the configured slop")
    func restingContact() {
        let world = World()
        world.addGround()
        world.addRigidBody(name: "ball", shape: .sphere(radius: 0.2), density: 500,
                           pose: Pose(position: Vec3(0, 0, 1)))
        world.compile()
        world.step(1500)

        let penetration = 0.2 - world.positions[2]
        #expect(penetration >= 0)
        #expect(penetration < world.options.penetrationSlop * 2 + 1e-6)
        #expect(abs(world.velocities[2]) < 1e-3)
    }

    @Test("The contact normal force supports the resting weight")
    func contactForceBalance() {
        let world = World()
        world.addGround()
        let shape = Shape.box(halfExtents: Vec3(0.1, 0.1, 0.1))
        world.addRigidBody(name: "box", shape: shape, density: 500,
                           pose: Pose(position: Vec3(0, 0, 0.1)))
        world.compile()
        world.step(1200)

        let weight = world.totalMass * 9.81
        let normalForce = world.contacts().reduce(0) { $0 + $1.normalForce }
        #expect(abs(normalForce - weight) / weight < 0.05)
    }

    @Test("An undamped pendulum conserves energy to better than 1% over 10 s")
    func pendulumEnergy() {
        let world = makePendulum()
        var options = world.options
        options.timestep = 1.0 / 2000
        world.options = options
        world.forward()

        let before = world.totalEnergy
        world.step(20_000)
        world.forward()
        let drift = abs(world.totalEnergy - before) / abs(before)
        #expect(drift < 0.01)
    }

    @Test("RK4 conserves angular momentum for a tumbling free body")
    func angularMomentum() {
        let world = World()
        world.addRigidBody(name: "body", shape: .box(halfExtents: Vec3(0.2, 0.1, 0.05)),
                           density: 800, pose: Pose(position: Vec3(0, 0, 2)))
        world.compile()
        var options = world.options
        options.gravity = .zero
        options.enableContacts = false
        options.integrator = .rungeKutta4
        world.options = options
        world.setVelocity(articulation: 0, linear: Vec3(0.4, -0.2, 0.1),
                          angular: Vec3(2.0, 3.0, 1.0))
        world.forward()

        let before = world.angularMomentum
        world.step(4000)
        world.forward()
        let error = (world.angularMomentum - before).length / before.length
        #expect(error < 1e-3)
    }

    @Test("Linear momentum is exactly conserved without gravity or contact")
    func linearMomentum() {
        let world = World()
        world.addRigidBody(name: "a", shape: .sphere(radius: 0.1), density: 500,
                           pose: Pose(position: Vec3(0, 0, 0)))
        world.compile()
        var options = world.options
        options.gravity = .zero
        options.enableContacts = false
        world.options = options
        world.setVelocity(articulation: 0, linear: Vec3(1, 2, -0.5))
        world.forward()

        let before = world.linearMomentum
        world.step(2000)
        world.forward()
        #expect((world.linearMomentum - before).length < 1e-9)
    }

    @Test("Coulomb friction holds below the cone and slides above it")
    func friction() {
        func slide(force: Double) -> Double {
            let world = World()
            world.addGround(friction: 1.0)
            let body = world.addRigidBody(name: "box",
                                          shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
                                          density: 500, pose: Pose(position: Vec3(0, 0, 0.1)))
            world.compile()
            world.step(200)
            for _ in 0..<300 {
                world.applyForce(articulation: body.articulation, link: 0,
                                 force: Vec3(force, 0, 0), at: Vec3(0, 0, 0.1))
                world.step()
                world.clearAppliedForces()
            }
            return world.positions[0]
        }

        // Weight is 4 kg * 9.81 = 39.2 N, so mu * N = 39.2 N is the threshold.
        #expect(abs(slide(force: 20)) < 0.003)
        #expect(slide(force: 120) > 0.1)
    }

    @Test("A ten-box stack stays stacked")
    func boxStack() {
        let world = SceneLibrary.boxStack(count: 10)
        world.step(3000)
        for i in 0..<10 {
            let z = world.positions[i * 7 + 2]
            #expect(abs(z - (0.1 + 0.2 * Double(i))) < 0.02)
        }
    }

    @Test("Restitution produces a bounce of the expected height")
    func restitution() {
        let world = World()
        world.addGround()
        world.addRigidBody(name: "ball", shape: .sphere(radius: 0.1), density: 500,
                           pose: Pose(position: Vec3(0, 0, 1.0)),
                           material: SurfaceMaterial(friction: 0.5, restitution: 0.7))
        world.compile()

        var peak = 0.0
        var hasBounced = false
        for _ in 0..<2500 {
            world.step()
            let z = world.positions[2]
            if z < 0.11 { hasBounced = true }
            if hasBounced { peak = max(peak, z) }
        }
        // Drop height 0.9 m above contact; e = 0.7 gives 0.49 * 0.9 = 0.44 m.
        #expect(peak > 0.2)
        #expect(peak < 0.75)
    }

    @Test("Joint limits are respected under load")
    func jointLimits() {
        let world = World()
        let art = world.addArticulation(name: "arm")
        let link = world.addLink(articulation: art, parent: -1, name: "link")
        world.setJoint(articulation: art, link: link,
                       JointSpec.revolute(axis: Vec3(1, 0, 0), limits: -0.5...0.5))
        world.setInertial(articulation: art, link: link, mass: 2, com: Vec3(0, 0, -0.5),
                          inertia: [0.7, 0, 0, 0, 0.7, 0, 0, 0, 0.01])
        world.setDefaultPose(articulation: art, q: [0.4])
        world.compile()
        world.step(2000)
        #expect(world.positions[0] <= 0.5 + 1e-3)
        #expect(world.positions[0] >= -0.5 - 1e-3)
    }

    @Test("A position actuator drives its joint to the commanded angle")
    func positionActuator() {
        let world = World()
        let art = world.addArticulation(name: "arm")
        let link = world.addLink(articulation: art, parent: -1, name: "link")
        world.setJoint(articulation: art, link: link,
                       JointSpec.revolute(axis: Vec3(1, 0, 0), damping: 0.5))
        world.setInertial(articulation: art, link: link, mass: 1, com: Vec3(0, 0, -0.3),
                          inertia: [0.1, 0, 0, 0, 0.1, 0, 0, 0, 0.01])
        world.addActuator(ActuatorSpec(kind: .position, articulation: art, link: link,
                                       gear: 1, kp: 200, kd: 20))
        world.compile()
        world.control[0] = 0.6
        world.step(4000)
        #expect(abs(world.positions[0] - 0.6) < 0.05)
    }

    @Test("Simulation is bit-exact reproducible")
    func determinism() {
        func run() -> [Double] {
            let world = SceneLibrary.mixedPrimitives()
            world.step(600)
            return Array(world.positions) + Array(world.velocities)
        }
        #expect(run() == run())
    }

    @Test("Save and restore round-trips the full state")
    func stateRoundTrip() {
        let world = SceneLibrary.boxStack(count: 4)
        world.step(300)
        let saved = world.saveState()
        let reference = Array(world.positions)

        world.step(500)
        #expect(Array(world.positions) != reference)

        world.loadState(saved)
        #expect(Array(world.positions) == reference)
    }

    private func makePendulum() -> World {
        let world = World()
        let art = world.addArticulation(name: "pendulum")
        let link = world.addLink(articulation: art, parent: -1, name: "arm")
        world.setJoint(articulation: art, link: link, JointSpec.revolute(axis: Vec3(1, 0, 0)))
        world.setInertial(articulation: art, link: link, mass: 1, com: Vec3(0, 0, -0.5),
                          inertia: [1.0 / 3, 0, 0, 0, 1.0 / 3, 0, 0, 0, 1e-4])
        world.setDefaultPose(articulation: art, q: [1.5])
        world.compile()
        return world
    }
}

@Suite("Kinematics and linear algebra")
struct KinematicsTests {

    @Test("The point Jacobian matches a finite-difference of forward kinematics")
    func jacobianAgainstFiniteDifference() {
        let world = SceneLibrary.articulatedArm()
        let arm = world.findArticulation("arm")!
        let tool = world.findLink(articulation: arm, name: "tool")!

        // Put the arm somewhere generic.
        let qOffset = world.coordinateOffset(articulation: arm)
        for (i, value) in [0.3, -0.7, 0.9, 0.2, -0.4, 1.1].enumerated() {
            world.positions[qOffset + i] = value
        }
        world.forward()

        let poses = world.linkPoses()
        var linkIndex = 0
        for a in 0..<arm { linkIndex += world.linkCount(articulation: a) }
        linkIndex += tool
        let point = poses[linkIndex].position

        let jacobian = world.pointJacobian(articulation: arm, link: tool, worldPoint: point)
        let n = world.dofCount - world.dofOffset(articulation: arm)

        let epsilon = 1e-6
        for dof in 0..<6 {
            let before = world.positions[qOffset + dof]
            world.positions[qOffset + dof] = before + epsilon
            world.forward()
            let plus = world.linkPoses()[linkIndex]
            world.positions[qOffset + dof] = before - epsilon
            world.forward()
            let minus = world.linkPoses()[linkIndex]
            world.positions[qOffset + dof] = before
            world.forward()

            // The material point coincides with `point` at the nominal pose, so
            // differentiate its world position through the link transform.
            let local = poses[linkIndex].applyInverse(point)
            let numerical = (plus.apply(local) - minus.apply(local)) / (2 * epsilon)
            let analytic = Vec3(jacobian[0 * n + dof], jacobian[1 * n + dof], jacobian[2 * n + dof])
            #expect((numerical - analytic).length < 1e-5)
        }
    }

    @Test("The joint-space inertia matrix is symmetric and positive definite")
    func massMatrix() {
        let world = SceneLibrary.articulatedArm()
        world.forward()
        let arm = world.findArticulation("arm")!
        let n = 6
        let m = world.massMatrix(articulation: arm)

        for i in 0..<n {
            for j in 0..<n {
                #expect(abs(m[i * n + j] - m[j * n + i]) < 1e-12)
            }
            #expect(m[i * n + i] > 0)
        }

        // Positive definiteness via a Cholesky attempt.
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = m[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    #expect(sum > 0)
                    l[i * n + j] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
    }

    @Test("Kinetic energy equals ½ vᵀ M v")
    func kineticEnergyMatchesMassMatrix() {
        let world = SceneLibrary.articulatedArm()
        let arm = world.findArticulation("arm")!
        let vOffset = world.dofOffset(articulation: arm)
        for i in 0..<6 { world.velocities[vOffset + i] = Double(i + 1) * 0.17 }
        world.forward()

        let m = world.massMatrix(articulation: arm)
        var quadratic = 0.0
        for i in 0..<6 {
            for j in 0..<6 {
                quadratic += world.velocities[vOffset + i] * m[i * 6 + j]
                    * world.velocities[vOffset + j]
            }
        }
        #expect(abs(0.5 * quadratic - world.kineticEnergy) < 1e-9)
    }

    @Test("Raycasting hits the expected geometry")
    func raycast() {
        let world = World()
        world.addGround()
        world.addRigidBody(name: "target", shape: .sphere(radius: 0.25), density: 500,
                           pose: Pose(position: Vec3(0, 0, 2)))
        world.compile()
        world.forward()

        let hit = world.raycast(origin: Vec3(0, 0, 5), direction: Vec3(0, 0, -1))
        #expect(hit != nil)
        #expect(abs((hit?.distance ?? 0) - 2.75) < 1e-6)
        #expect((hit?.normal.z ?? 0) > 0.99)

        #expect(world.raycast(origin: Vec3(10, 10, 5), direction: Vec3(0, 0, 1)) == nil)
    }

    @Test("Quaternion and pose algebra round-trips")
    func poseAlgebra() {
        let q = Quat(roll: 0.3, pitch: -0.8, yaw: 1.9)
        let rpy = q.eulerRPY
        let reconstructed = Quat(roll: rpy.x, pitch: rpy.y, yaw: rpy.z)
        let v = Vec3(0.4, -0.2, 0.9)
        #expect((q.rotate(v) - reconstructed.rotate(v)).length < 1e-12)

        let pose = Pose(position: Vec3(1, -2, 3), orientation: q)
        #expect((pose.applyInverse(pose.apply(v)) - v).length < 1e-12)

        let composed = pose * pose.inverse
        #expect(composed.position.length < 1e-12)
    }
}

@Suite("Constraints")
struct ConstraintTests {

    @Test("A connect constraint holds two bodies together")
    func connectConstraint() {
        let world = World()
        let anchor = world.addRigidBody(name: "anchor", shape: .sphere(radius: 0.05),
                                        density: 500, pose: Pose(position: Vec3(0, 0, 2)))
        let hanging = world.addRigidBody(name: "hanging", shape: .sphere(radius: 0.05),
                                         density: 500, pose: Pose(position: Vec3(0, 0, 1.7)))
        world.connect(articulationA: hanging.articulation, linkA: 0, anchorA: Vec3(0, 0, 0.3),
                      anchorB: Vec3(0, 0, 2))
        world.compile()
        var options = world.options
        options.enableContacts = false
        world.options = options
        world.setEnabled(articulation: anchor.articulation, enabled: false)

        world.step(2000)
        let position = world.pose(articulation: hanging.articulation).position
        // The constraint anchors the point 0.3 m above the body to (0, 0, 2).
        #expect(abs(position.z - 1.7) < 0.05)
    }

    @Test("Self-collision can be enabled per articulation")
    func selfCollisionToggle() {
        let world = World()
        let art = world.addArticulation(name: "folded")
        let base = world.addLink(articulation: art, parent: -1, name: "base")
        world.setJoint(articulation: art, link: base, .fixed)
        world.setInertial(articulation: art, link: base, shape: .sphere(radius: 0.1), density: 500)
        world.addGeom(articulation: art, link: base, GeomSpec(shape: .sphere(radius: 0.1)))

        let middle = world.addLink(articulation: art, parent: base, name: "middle")
        world.setJoint(articulation: art, link: middle,
                       JointSpec.revolute(axis: Vec3(0, 1, 0),
                                          origin: Pose(position: Vec3(0, 0, 0.05))))
        world.setInertial(articulation: art, link: middle, shape: .sphere(radius: 0.05),
                          density: 500)
        world.addGeom(articulation: art, link: middle, GeomSpec(shape: .sphere(radius: 0.05)))

        let tip = world.addLink(articulation: art, parent: middle, name: "tip")
        world.setJoint(articulation: art, link: tip,
                       JointSpec.revolute(axis: Vec3(0, 1, 0),
                                          origin: Pose(position: Vec3(0, 0, 0.05))))
        world.setInertial(articulation: art, link: tip, shape: .sphere(radius: 0.08), density: 500)
        // Offset laterally: a perfectly coaxial overlap would put the contact
        // normal in the nullspace of both revolute joints, and the solver drops
        // such a row rather than feeding a singular constraint to the PGS sweep.
        world.addGeom(articulation: art, link: tip,
                      GeomSpec(shape: .sphere(radius: 0.08),
                               localPose: Pose(position: Vec3(0.06, 0, 0))))

        world.setSelfCollision(articulation: art, enabled: true)
        world.compile()
        // base and tip are two links apart and overlap by 80 mm, so they are
        // eligible to collide; the first step must already resolve that.
        world.step()
        #expect(world.contacts().count >= 1)

        world.setSelfCollision(articulation: art, enabled: false)
        world.reset()
        world.step()
        #expect(world.contacts().isEmpty)
    }
}
