//
//  MeshTests.swift
//  KineticTests
//

import Foundation
import Testing

@testable import Kinetic

@Suite("Convex hull")
struct ConvexHullTests {

    private func cubeCloud(half: Double, interior: Int = 200) -> [Vec3] {
        var points: [Vec3] = []
        for i in 0..<8 {
            points.append(Vec3((i & 1) != 0 ? half : -half,
                               (i & 2) != 0 ? half : -half,
                               (i & 4) != 0 ? half : -half))
        }
        // Interior points must not survive the hull.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
        for _ in 0..<interior {
            points.append(Vec3(random(), random(), random()) * (half * 0.8))
        }
        return points
    }

    @Test("A cube point cloud collapses to its eight corners")
    func cube() {
        let hull = ConvexHull.compute(points: cubeCloud(half: 0.5))
        #expect(!hull.isDegenerate)
        #expect(hull.vertices.count == 8)
        #expect(abs(hull.volume - 1.0) < 1e-6)
        #expect(hull.centroid.length < 1e-9)
        // A closed triangulation of a cube is 12 triangles.
        #expect(hull.indices.count == 36)
    }

    @Test("The hull contains every input point")
    func containment() {
        let points = cubeCloud(half: 0.3, interior: 400)
        let hull = ConvexHull.compute(points: points)
        // Every face plane must have all points on its inner side.
        var i = 0
        while i + 2 < hull.indices.count {
            let a = hull.vertices[Int(hull.indices[i])]
            let b = hull.vertices[Int(hull.indices[i + 1])]
            let c = hull.vertices[Int(hull.indices[i + 2])]
            let normal = (b - a).cross(c - a)
            if normal.length > 1e-12 {
                let unit = normal.normalized
                let offset = unit.dot(a)
                let outward = unit.dot(hull.centroid) - offset < 0 ? unit : -unit
                let plane = outward.dot(a)
                for p in points {
                    #expect(outward.dot(p) - plane < 1e-6)
                }
            }
            i += 3
        }
    }

    @Test("An icosphere hull recovers the sphere's volume")
    func sphere() {
        var points: [Vec3] = []
        let radius = 0.4
        for i in 0...24 {
            for j in 0..<24 {
                let phi = Double(i) / 24 * .pi
                let theta = Double(j) / 24 * 2 * .pi
                points.append(Vec3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi)) * radius)
            }
        }
        let hull = ConvexHull.compute(points: points)
        #expect(!hull.isDegenerate)
        let exact = 4.0 / 3.0 * Double.pi * radius * radius * radius
        // An inscribed 24x24 polyhedron sits ~5% under the true sphere
        // (1 - O(1/n^2)); it must never exceed it.
        #expect(hull.volume < exact)
        #expect(hull.volume > exact * 0.94)
    }

    @Test("Degenerate clouds fall back to a bounding box")
    func degenerate() {
        let coplanar = (0..<20).map { Vec3(Double($0) * 0.1, Double($0 % 5) * 0.1, 0) }
        let hull = ConvexHull.compute(points: coplanar)
        #expect(hull.isDegenerate)
        #expect(hull.vertices.count == 8)
        #expect(hull.volume > 0)

        let empty = ConvexHull.compute(points: [])
        #expect(empty.isDegenerate)
        #expect(empty.vertices.isEmpty)
    }

    @Test("The vertex cap is honoured")
    func vertexCap() {
        var points: [Vec3] = []
        for i in 0..<40 {
            for j in 0..<40 {
                let phi = Double(i) / 40 * .pi
                let theta = Double(j) / 40 * 2 * .pi
                points.append(Vec3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi)))
            }
        }
        let hull = ConvexHull.compute(points: points, maxVertices: 64)
        #expect(hull.vertices.count <= 64)
        #expect(!hull.vertices.isEmpty)
    }
}

@Suite("Mesh import")
struct MeshLoaderTests {

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kinetic-mesh-\(UUID().uuidString).\(ext)")
    }

    /// Writes a unit cube as a binary STL.
    private func writeBinarySTL(to url: URL, half: Float) throws {
        let corners: [SIMD3<Float>] = (0..<8).map { i in
            SIMD3<Float>((i & 1) != 0 ? half : -half,
                         (i & 2) != 0 ? half : -half,
                         (i & 4) != 0 ? half : -half)
        }
        let faces: [[Int]] = [
            [0, 2, 3], [0, 3, 1], [4, 5, 7], [4, 7, 6],
            [0, 1, 5], [0, 5, 4], [2, 6, 7], [2, 7, 3],
            [0, 4, 6], [0, 6, 2], [1, 3, 7], [1, 7, 5],
        ]
        var data = Data(count: 80)
        var count = UInt32(faces.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        // SIMD3<Float> occupies 16 bytes, but STL packs three tightly, so the
        // components go out one at a time.
        func appendFloat3(_ v: SIMD3<Float>) {
            for component in [v.x, v.y, v.z] {
                var value = component.bitPattern.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        for face in faces {
            appendFloat3(SIMD3<Float>(0, 0, 1))
            for index in face { appendFloat3(corners[index]) }
            var attribute = UInt16(0).littleEndian
            withUnsafeBytes(of: &attribute) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    @Test("A binary STL loads, hulls and measures correctly")
    func binarySTL() throws {
        let url = temporaryURL("stl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBinarySTL(to: url, half: 0.25)

        let mesh = try MeshLoader.load(contentsOf: url)
        #expect(mesh.vertices.count == 36)
        #expect(mesh.indices.count == 36)
        #expect(mesh.hullVertices.count == 8)
        #expect(abs(mesh.volume - 0.125) < 1e-6)
        #expect(abs(mesh.boundingRadius - Vec3(0.25, 0.25, 0.25).length) < 1e-6)
        #expect(!mesh.usedFallbackHull)
    }

    @Test("Scale is applied before hulling")
    func scaled() throws {
        let url = temporaryURL("stl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBinarySTL(to: url, half: 0.5)

        let mesh = try MeshLoader.load(contentsOf: url, scale: Vec3(2, 1, 1))
        #expect(abs(mesh.aabbMax.x - 1.0) < 1e-6)
        #expect(abs(mesh.aabbMax.y - 0.5) < 1e-6)
        #expect(abs(mesh.volume - 2.0) < 1e-6)
    }

    @Test("OBJ faces, negative indices and polygons all parse")
    func obj() throws {
        let text = """
        # a square pyramid
        v -1 -1 0
        v  1 -1 0
        v  1  1 0
        v -1  1 0
        v  0  0 1.5
        f 1 2 3 4
        f 1 2 5
        f 2 3 5
        f 3 4 5
        f 4 1 -1
        """
        let url = temporaryURL("obj")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(text.utf8).write(to: url)

        let mesh = try MeshLoader.load(contentsOf: url)
        #expect(mesh.vertices.count == 5)
        // The quad base fans into two triangles, plus four sides.
        #expect(mesh.indices.count == 18)
        #expect(mesh.hullVertices.count == 5)
        #expect(abs(mesh.volume - 2.0) < 1e-6)
    }

    @Test("An unsupported extension reports rather than guessing")
    func unsupported() throws {
        let url = temporaryURL("dae")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<COLLADA/>".utf8).write(to: url)
        #expect(throws: (any Error).self) { try MeshLoader.load(contentsOf: url) }
    }

    @Test("package:// URIs resolve against the search path")
    func packageResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinetic-pkg-\(UUID().uuidString)")
        let meshes = root.appendingPathComponent("meshes")
        try FileManager.default.createDirectory(at: meshes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = meshes.appendingPathComponent("block.stl")
        try writeBinarySTL(to: file, half: 0.1)

        let library = MeshLibrary(searchPaths: [root])
        #expect(library.resolve("package://my_robot/meshes/block.stl") == file)
        #expect(library.resolve("meshes/block.stl") == file)
        #expect(library.resolve("package://my_robot/meshes/missing.stl") == nil)

        let loaded = try library.load("package://my_robot/meshes/block.stl")
        #expect(loaded.hullVertices.count == 8)
    }

    @Test("A hull geom collides and comes to rest on the ground")
    func hullSimulates() throws {
        let url = temporaryURL("stl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBinarySTL(to: url, half: 0.1)
        let mesh = try MeshLoader.load(contentsOf: url)

        let world = World()
        world.addGround()
        let index = world.addMesh(vertices: mesh.hullVertices, indices: mesh.hullIndices,
                                  name: "block")
        let art = world.addArticulation(name: "block")
        let link = world.addLink(articulation: art, parent: -1, name: "block")
        world.setJoint(articulation: art, link: link, .free)
        world.setInertial(articulation: art, link: link, mass: 1, com: .zero,
                          inertia: Inertia.box(mass: 1, halfExtents: Vec3(0.1, 0.1, 0.1)))
        world.addGeom(articulation: art, link: link,
                      GeomSpec(shape: .convexHull(mesh: index,
                                                  boundingRadius: mesh.boundingRadius)))
        world.setDefaultPose(articulation: art, q: [0, 0, 0.6, 1, 0, 0, 0])
        world.compile()
        world.step(2000)

        #expect(world.positions[2] > 0.09)
        #expect(world.positions[2] < 0.115)
        #expect(abs(world.velocities[2]) < 1e-2)
        #expect(!world.contacts().isEmpty)
    }
}
