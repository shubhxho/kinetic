//
//  ImporterTests.swift
//  KineticTests
//

import Foundation
import Testing

@testable import Kinetic

private func fixture(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                      subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: nil)
    else {
        throw ImportFixtureError.missing(name)
    }
    return url
}

enum ImportFixtureError: Error { case missing(String) }

@Suite("URDF import")
struct URDFTests {

    @Test("Links, joints, limits and inertials survive the round trip")
    func twoLinkArm() throws {
        let url = try fixture("two_link.urdf")
        let (world, robot) = try URDF.load(contentsOf: url)

        #expect(robot.name == "two_link")
        #expect(robot.links == ["base", "upper", "lower"])
        #expect(world.linkCount == 3)

        let art = robot.articulation
        let base = try #require(world.findLink(articulation: art, name: "base"))
        let upper = try #require(world.findLink(articulation: art, name: "upper"))
        let lower = try #require(world.findLink(articulation: art, name: "lower"))

        // A URDF without a floating joint gets a free root by default.
        #expect(world.jointKind(articulation: art, link: base) == .free)
        #expect(world.jointKind(articulation: art, link: upper) == .revolute)
        #expect(world.jointKind(articulation: art, link: lower) == .revolute)

        // `continuous` joints carry no limits.
        #expect(world.jointLimits(articulation: art, link: lower) == nil)
        let shoulderLimits = try #require(world.jointLimits(articulation: art, link: upper))
        #expect(abs(shoulderLimits.lowerBound + 1.57) < 1e-9)
        #expect(abs(shoulderLimits.upperBound - 1.57) < 1e-9)

        #expect(abs(world.mass(articulation: art, link: base) - 2.0) < 1e-9)
        #expect(abs(world.totalMass - 3.6) < 1e-9)
        #expect(world.actuatorCount == 2)
        #expect(world.dofCount == 6 + 2)
    }

    @Test("A fixed base removes the floating degrees of freedom")
    func fixedBase() throws {
        let url = try fixture("two_link.urdf")
        var options = URDFImportOptions()
        options.fixedBase = true
        options.addPositionActuators = false
        let (world, _) = try URDF.load(contentsOf: url, options: options)
        #expect(world.dofCount == 2)
        #expect(world.actuatorCount == 0)
    }

    @Test("An inertial with a rotated origin is transformed into the link frame")
    func rotatedInertia() {
        let diagonal: [Double] = [2, 0, 0, 0, 5, 0, 0, 0, 9]
        let rotated = URDF.rotateInertia(diagonal, by: Quat(axis: Vec3(0, 0, 1), angle: .pi / 2))
        // A 90° yaw swaps the xx and yy principal moments.
        #expect(abs(rotated[0] - 5) < 1e-9)
        #expect(abs(rotated[4] - 2) < 1e-9)
        #expect(abs(rotated[8] - 9) < 1e-9)
        // The trace is invariant under rotation.
        #expect(abs((rotated[0] + rotated[4] + rotated[8]) - 16) < 1e-9)
    }

    @Test("Malformed input fails rather than producing a broken model")
    func malformed() {
        let data = Data("<not-a-robot/>".utf8)
        #expect(throws: (any Error).self) { try URDF.load(data: data) }
    }
}

@Suite("MJCF import")
struct MJCFTests {

    @Test("A MuJoCo cart-pole imports with the right topology and options")
    func cartPole() throws {
        let url = try fixture("pendulum.xml")
        let (world, robot) = try MJCF.load(contentsOf: url)

        #expect(robot.name == "mjcf_pendulum")
        #expect(abs(world.options.timestep - 0.002) < 1e-12)
        #expect(abs(world.options.gravity.z + 9.81) < 1e-12)

        let art = robot.articulation
        let cart = try #require(world.findLink(articulation: art, name: "cart"))
        let pole = try #require(world.findLink(articulation: art, name: "pole"))
        #expect(world.jointKind(articulation: art, link: cart) == .prismatic)
        #expect(world.jointKind(articulation: art, link: pole) == .revolute)
        #expect(world.parent(articulation: art, link: pole) == cart)
        #expect(world.dofCount == 2)
        #expect(world.actuatorCount == 1)

        // Balanced upright the pole is at an unstable equilibrium and stays
        // put; nudged off it, gravity must take over.
        world.step(500)
        #expect(world.positions.allSatisfy { $0.isFinite })
        #expect(abs(world.positions[1]) < 1e-9)

        world.reset()
        world.positions[1] = 0.05
        world.step(500)
        #expect(abs(world.positions[1]) > 0.2)
    }

    @Test("A `fromto` capsule is centred and oriented between its end points")
    func fromToCapsule() throws {
        let url = try fixture("pendulum.xml")
        let (world, robot) = try MJCF.load(contentsOf: url)
        let pole = try #require(world.findLink(articulation: robot.articulation, name: "pole"))
        let geom = try #require(world.geomInfo.first {
            $0.articulation == robot.articulation && $0.link == pole
        })
        guard case .capsule(let radius, let halfLength) = geom.shape else {
            Issue.record("expected a capsule, found \(geom.shape)")
            return
        }
        #expect(abs(radius - 0.02) < 1e-9)
        #expect(abs(halfLength - 0.3) < 1e-9)
    }
}
