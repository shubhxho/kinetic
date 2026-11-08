//
//  BenchmarkTests.swift
//  KineticTests
//
//  Timed runs of every SceneLibrary entry, with invariants that do not depend
//  on the host's clock. Wall-clock milliseconds-per-step are printed so CI
//  logs have a table; they are not asserted against the published M4 numbers.
//

import Foundation
import Testing

@testable import Kinetic

struct BenchRow: Sendable {
    var id: String
    var nv: Int
    var geoms: Int
    var steps: Int
    var seconds: Double
    var elapsed: Double
    var msPerStep: Double
    var stepsPerSecond: Double
    var realtime: Double
    var contacts: Int
    var profile: StepProfile
}

enum BenchHarness {
    /// Same protocol as `kinetic bench`: warm 50 steps (or fewer), then time
    /// `seconds` of simulated time.
    static func run(_ id: String, seconds: Double = 0.4, threaded: Bool = true) -> BenchRow {
        guard let world = SceneLibrary.build(id) else {
            Issue.record("unknown scene \(id)")
            return BenchRow(id: id, nv: 0, geoms: 0, steps: 0, seconds: seconds,
                            elapsed: 0, msPerStep: 0, stepsPerSecond: 0, realtime: 0,
                            contacts: 0, profile: StepProfile())
        }
        var options = world.options
        options.multithreaded = threaded
        world.options = options
        let steps = max(1, Int(seconds / world.options.timestep))
        world.step(min(50, steps))

        let start = Date()
        world.step(steps)
        let elapsed = Date().timeIntervalSince(start)
        let profile = world.profile
        let ms = elapsed / Double(steps) * 1000

        #expect(world.positions.allSatisfy(\.isFinite))
        #expect(world.velocities.allSatisfy(\.isFinite))

        return BenchRow(id: id, nv: world.dofCount, geoms: world.geomCount, steps: steps,
                        seconds: seconds, elapsed: elapsed, msPerStep: ms,
                        stepsPerSecond: 1000 / max(ms, 1e-12),
                        realtime: seconds / max(elapsed, 1e-12),
                        contacts: profile.contactCount, profile: profile)
    }

    static func printTable(_ rows: [BenchRow]) {
        let header = pad("scene", 14) + padLeft("nv", 5) + padLeft("geoms", 7)
            + padLeft("steps", 8) + padLeft("ms/step", 10) + padLeft("steps/s", 10)
            + padLeft("realtime", 10) + padLeft("contacts", 10)
        print(header)
        for row in rows {
            print(pad(row.id, 14)
                  + padLeft("\(row.nv)", 5)
                  + padLeft("\(row.geoms)", 7)
                  + padLeft("\(row.steps)", 8)
                  + padLeft(format(row.msPerStep, 4), 10)
                  + padLeft(format(row.stepsPerSecond, 0), 10)
                  + padLeft(format(row.realtime, 1) + "x", 10)
                  + padLeft("\(row.contacts)", 10))
        }
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    static func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

struct PublishedScene: Sendable {
    var id: String
    var nv: Int
    var geoms: Int
}

@Suite("Benchmarks")
struct BenchmarkTests {

    static let published: [PublishedScene] = [
        .init(id: "cartpole", nv: 2, geoms: 3),
        .init(id: "arm", nv: 6, geoms: 8),
        .init(id: "chain", nv: 20, geoms: 21),
        .init(id: "quadruped", nv: 18, geoms: 18),
        .init(id: "stack", nv: 60, geoms: 11),
        .init(id: "mixed", nv: 144, geoms: 25),
        .init(id: "dominoes", nv: 360, geoms: 61),
    ]

    @Test("Every SceneLibrary entry has the published nv and geom counts")
    func publishedSizes() {
        #expect(Set(SceneLibrary.all.map(\.id)) == Set(Self.published.map(\.id)))
        for row in Self.published {
            let world = SceneLibrary.build(row.id)
            #expect(world != nil, "missing scene \(row.id)")
            guard let world else { continue }
            #expect(world.dofCount == row.nv, "\(row.id) nv \(world.dofCount) != \(row.nv)")
            #expect(world.geomCount == row.geoms, "\(row.id) geoms \(world.geomCount) != \(row.geoms)")
        }
    }

    @Test("Timed run of every scene stays finite and prints a bench table")
    func timedRunTable() {
        var rows: [BenchRow] = []
        for scene in Self.published {
            rows.append(BenchHarness.run(scene.id, seconds: 0.4, threaded: true))
        }
        BenchHarness.printTable(rows)
        for (scene, row) in zip(Self.published, rows) {
            #expect(row.nv == scene.nv)
            #expect(row.geoms == scene.geoms)
            #expect(row.steps == 200)
            #expect(row.elapsed > 0)
            #expect(row.msPerStep > 0)
            #expect(row.realtime.isFinite)
        }
    }

    @Test("Contact-free scenes stay contact-free; contact-rich scenes produce contacts")
    func contactCharacter() {
        let cartpole = BenchHarness.run("cartpole", seconds: 0.4)
        let chain = BenchHarness.run("chain", seconds: 0.4)
        let stack = BenchHarness.run("stack", seconds: 0.4)
        let mixed = BenchHarness.run("mixed", seconds: 0.4)
        let dominoes = BenchHarness.run("dominoes", seconds: 0.4)
        let quadruped = BenchHarness.run("quadruped", seconds: 0.4)

        #expect(cartpole.contacts == 0)
        #expect(chain.contacts == 0)
        #expect(stack.contacts > 0)
        #expect(mixed.contacts > 0)
        #expect(dominoes.contacts > 0)
        #expect(quadruped.contacts > 0)
    }

    @Test("Articulated scenes are cheaper per step than contact-rich piles")
    func costOrdering() {
        let cartpole = BenchHarness.run("cartpole", seconds: 0.4)
        let arm = BenchHarness.run("arm", seconds: 0.4)
        let chain = BenchHarness.run("chain", seconds: 0.4)
        let stack = BenchHarness.run("stack", seconds: 0.4)
        let mixed = BenchHarness.run("mixed", seconds: 0.4)
        let dominoes = BenchHarness.run("dominoes", seconds: 0.4)

        #expect(cartpole.msPerStep < stack.msPerStep)
        #expect(arm.msPerStep < stack.msPerStep)
        #expect(chain.msPerStep < mixed.msPerStep)
        #expect(stack.msPerStep < dominoes.msPerStep)
    }

    @Test("Threaded and serial narrowphase stay bit-identical after a timed run")
    func threadedMatchesSerial() {
        func capture(threaded: Bool) -> [Double] {
            let world = SceneLibrary.dominoes(count: 60)
            var options = world.options
            options.multithreaded = threaded
            world.options = options
            world.step(400)
            return Array(world.positions) + Array(world.velocities)
        }
        #expect(capture(threaded: false) == capture(threaded: true))
    }

    @Test("Two consecutive timed runs of mixed primitives are bit-identical")
    func repeatable() {
        func capture() -> [Double] {
            let world = SceneLibrary.mixedPrimitives()
            world.step(600)
            return Array(world.positions) + Array(world.velocities)
        }
        #expect(capture() == capture())
    }

    @Test("Step profile stages are non-negative and the total is positive")
    func profileAccounting() {
        let row = BenchHarness.run("stack", seconds: 0.4)
        let p = row.profile
        #expect(p.kinematics >= 0)
        #expect(p.inertia >= 0)
        #expect(p.bias >= 0)
        #expect(p.collision >= 0)
        #expect(p.constraintSetup >= 0)
        #expect(p.solve >= 0)
        #expect(p.integrate >= 0)
        #expect(p.sensors >= 0)
        #expect(p.total > 0)
        #expect(p.solverResidual.isFinite)
        #expect(p.contactCount > 0)
    }

    @Test("A ten-box stack stays stacked across a timed bench run")
    func stackStaysStacked() {
        let world = SceneLibrary.boxStack(count: 10)
        let steps = 200
        world.step(min(50, steps))
        world.step(steps)
        for i in 0..<10 {
            let z = world.positions[i * 7 + 2]
            #expect(abs(z - (0.1 + 0.2 * Double(i))) < 0.02)
        }
    }
}
