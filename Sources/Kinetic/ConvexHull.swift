//
//  ConvexHull.swift
//  Kinetic
//
//  Quickhull in three dimensions. Imported meshes are triangle soups with
//  thousands of interior vertices; the collision core's support mapping is a
//  linear scan, so feeding it the raw soup would be both slow and wasteful. The
//  hull typically collapses a 20k-vertex mesh to a few hundred points that
//  describe exactly the same convex volume.
//
//  Degenerate input (fewer than four points, or points that are collinear or
//  coplanar within tolerance) falls back to the oriented bounding box, which is
//  the closest convex body that still simulates sensibly.
//

import Foundation

public struct ConvexHullResult: Sendable {
    public var vertices: [Vec3]
    public var indices: [UInt32]
    public var isDegenerate: Bool
    public var volume: Double
    public var centroid: Vec3
}

public enum ConvexHull {

    /// Builds the convex hull of a point cloud.
    /// - Parameter maxVertices: hard cap on the result; the hull is simplified by
    ///   dropping the least-extremal vertices if it exceeds this.
    public static func compute(points input: [Vec3], tolerance: Double = 1e-10,
                               maxVertices: Int = 256) -> ConvexHullResult {
        let points = deduplicate(input)
        guard points.count >= 4 else { return boundingBoxHull(input) }

        guard var state = initialTetrahedron(points, tolerance: tolerance) else {
            return boundingBoxHull(input)
        }

        // Iteratively absorb the point furthest outside each face.
        var guard_ = 0
        while let faceIndex = state.faces.firstIndex(where: { $0.alive && !$0.outside.isEmpty }) {
            guard_ += 1
            if guard_ > 100_000 { break }

            let face = state.faces[faceIndex]
            var apex = face.outside[0]
            var best = -Double.greatestFiniteMagnitude
            for candidate in face.outside {
                let distance = state.faces[faceIndex].signedDistance(points[candidate])
                if distance > best {
                    best = distance
                    apex = candidate
                }
            }

            // Every face the apex can see is removed; the boundary of that set is
            // the horizon, and the new cone is built from it.
            var visible: [Int] = []
            state.collectVisible(from: apex, points: points, seed: faceIndex, into: &visible,
                                 tolerance: tolerance)
            let horizon = state.horizon(of: visible)
            guard !horizon.isEmpty else {
                state.faces[faceIndex].outside.removeAll()
                continue
            }

            var orphans: [Int] = []
            for index in visible {
                orphans.append(contentsOf: state.faces[index].outside)
                state.faces[index].alive = false
                state.faces[index].outside.removeAll()
            }

            var newFaces: [Int] = []
            for edge in horizon {
                let created = state.addFace(a: edge.0, b: edge.1, c: apex, points: points,
                                            tolerance: tolerance)
                if let created { newFaces.append(created) }
            }
            state.rebuildAdjacency()

            for orphan in orphans where orphan != apex {
                for index in newFaces {
                    if state.faces[index].signedDistance(points[orphan]) > tolerance {
                        state.faces[index].outside.append(orphan)
                        break
                    }
                }
            }
        }

        var used: [Int: UInt32] = [:]
        var vertices: [Vec3] = []
        var indices: [UInt32] = []
        for face in state.faces where face.alive {
            for vertex in [face.a, face.b, face.c] {
                if used[vertex] == nil {
                    used[vertex] = UInt32(vertices.count)
                    vertices.append(points[vertex])
                }
                indices.append(used[vertex]!)
            }
        }
        guard vertices.count >= 4 else { return boundingBoxHull(input) }

        let properties = volumeAndCentroid(vertices: vertices, indices: indices)
        var result = ConvexHullResult(vertices: vertices, indices: indices, isDegenerate: false,
                                      volume: properties.volume, centroid: properties.centroid)
        if result.vertices.count > maxVertices {
            result = simplify(result, to: maxVertices)
        }
        return result
    }

    // MARK: Internals

    private struct Face {
        var a: Int, b: Int, c: Int
        var normal: Vec3
        var offset: Double
        var alive = true
        var outside: [Int] = []
        var neighbours: [Int] = []

        func signedDistance(_ p: Vec3) -> Double { normal.dot(p) - offset }
    }

    private struct State {
        var faces: [Face] = []
        /// A point strictly inside the hull. Every face is oriented so that this
        /// point is on its negative side, which keeps `signedDistance` meaning
        /// "outside" for all faces, including the ones built during expansion.
        var interior = Vec3.zero

        mutating func addFace(a: Int, b: Int, c: Int, points: [Vec3],
                              tolerance: Double) -> Int? {
            let pa = points[a], pb = points[b], pc = points[c]
            var normal = (pb - pa).cross(pc - pa)
            let length = normal.length
            guard length > tolerance else { return nil }
            normal = normal / length
            var offset = normal.dot(pa)
            var face = Face(a: a, b: b, c: c, normal: normal, offset: offset)
            if normal.dot(interior) - offset > 0 {
                normal = -normal
                offset = -offset
                face = Face(a: a, b: c, c: b, normal: normal, offset: offset)
            }
            faces.append(face)
            return faces.count - 1
        }

        /// Flood-fills the set of live faces visible from `apex`.
        mutating func collectVisible(from apex: Int, points: [Vec3], seed: Int,
                                     into result: inout [Int], tolerance: Double) {
            var stack = [seed]
            var seen: Set<Int> = [seed]
            while let index = stack.popLast() {
                guard faces[index].alive else { continue }
                guard faces[index].signedDistance(points[apex]) > tolerance else { continue }
                result.append(index)
                for neighbour in faces[index].neighbours where !seen.contains(neighbour) {
                    seen.insert(neighbour)
                    stack.append(neighbour)
                }
            }
        }

        /// Edges that belong to exactly one visible face form the horizon.
        func horizon(of visible: [Int]) -> [(Int, Int)] {
            var counts: [Edge: Int] = [:]
            var directed: [Edge: (Int, Int)] = [:]
            for index in visible {
                let face = faces[index]
                for edge in [(face.a, face.b), (face.b, face.c), (face.c, face.a)] {
                    let key = Edge(edge.0, edge.1)
                    counts[key, default: 0] += 1
                    directed[key] = edge
                }
            }
            return counts.filter { $0.value == 1 }.compactMap { directed[$0.key] }
        }

        mutating func rebuildAdjacency() {
            var byEdge: [Edge: [Int]] = [:]
            for (index, face) in faces.enumerated() where face.alive {
                for edge in [(face.a, face.b), (face.b, face.c), (face.c, face.a)] {
                    byEdge[Edge(edge.0, edge.1), default: []].append(index)
                }
            }
            for index in faces.indices { faces[index].neighbours.removeAll(keepingCapacity: true) }
            for (_, owners) in byEdge where owners.count == 2 {
                faces[owners[0]].neighbours.append(owners[1])
                faces[owners[1]].neighbours.append(owners[0])
            }
        }
    }

    private struct Edge: Hashable {
        let low: Int, high: Int
        init(_ a: Int, _ b: Int) {
            low = min(a, b)
            high = max(a, b)
        }
    }

    private static func initialTetrahedron(_ points: [Vec3], tolerance: Double) -> State? {
        // Extremes along each axis give a well-conditioned starting simplex.
        var minIndex = [0, 0, 0], maxIndex = [0, 0, 0]
        for (i, p) in points.enumerated() {
            for axis in 0..<3 {
                if p[axis] < points[minIndex[axis]][axis] { minIndex[axis] = i }
                if p[axis] > points[maxIndex[axis]][axis] { maxIndex[axis] = i }
            }
        }
        var a = 0, b = 0
        var span = -1.0
        for axis in 0..<3 {
            let d = points[maxIndex[axis]][axis] - points[minIndex[axis]][axis]
            if d > span {
                span = d
                a = minIndex[axis]
                b = maxIndex[axis]
            }
        }
        guard span > tolerance, a != b else { return nil }

        var c = -1
        var bestArea = tolerance
        for (i, p) in points.enumerated() where i != a && i != b {
            let area = (points[b] - points[a]).cross(p - points[a]).length
            if area > bestArea {
                bestArea = area
                c = i
            }
        }
        guard c >= 0 else { return nil }

        let normal = (points[b] - points[a]).cross(points[c] - points[a]).normalized
        var d = -1
        var bestHeight = tolerance
        for (i, p) in points.enumerated() where i != a && i != b && i != c {
            let height = abs(normal.dot(p - points[a]))
            if height > bestHeight {
                bestHeight = height
                d = i
            }
        }
        guard d >= 0 else { return nil }

        var state = State()
        state.interior = (points[a] + points[b] + points[c] + points[d]) / 4
        _ = state.addFace(a: a, b: b, c: c, points: points, tolerance: tolerance)
        _ = state.addFace(a: a, b: b, c: d, points: points, tolerance: tolerance)
        _ = state.addFace(a: a, b: c, c: d, points: points, tolerance: tolerance)
        _ = state.addFace(a: b, b: c, c: d, points: points, tolerance: tolerance)
        guard state.faces.count == 4 else { return nil }
        state.rebuildAdjacency()

        let seeds = Set([a, b, c, d])
        for (i, p) in points.enumerated() where !seeds.contains(i) {
            for index in state.faces.indices {
                if state.faces[index].signedDistance(p) > tolerance {
                    state.faces[index].outside.append(i)
                    break
                }
            }
        }
        return state
    }

    private static func deduplicate(_ points: [Vec3]) -> [Vec3] {
        struct Key: Hashable {
            let x: Int64, y: Int64, z: Int64
        }
        var seen = Set<Key>()
        var out: [Vec3] = []
        out.reserveCapacity(points.count)
        for p in points {
            // 0.1 micrometre quantisation: below any meaningful robot tolerance.
            let key = Key(x: Int64((p.x * 1e7).rounded()),
                          y: Int64((p.y * 1e7).rounded()),
                          z: Int64((p.z * 1e7).rounded()))
            if seen.insert(key).inserted { out.append(p) }
        }
        return out
    }

    private static func boundingBoxHull(_ points: [Vec3]) -> ConvexHullResult {
        guard !points.isEmpty else {
            return ConvexHullResult(vertices: [], indices: [], isDegenerate: true, volume: 0,
                                    centroid: .zero)
        }
        var lo = points[0], hi = points[0]
        for p in points {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        // Give a flat or degenerate cloud a little thickness so the mass
        // properties and the support mapping stay well defined.
        let epsilon = max((hi - lo).length * 1e-3, 1e-4)
        for axis in 0..<3 where hi[axis] - lo[axis] < epsilon {
            lo[axis] -= epsilon * 0.5
            hi[axis] += epsilon * 0.5
        }

        var vertices: [Vec3] = []
        for i in 0..<8 {
            vertices.append(Vec3((i & 1) != 0 ? hi.x : lo.x,
                                 (i & 2) != 0 ? hi.y : lo.y,
                                 (i & 4) != 0 ? hi.z : lo.z))
        }
        let faces: [[Int]] = [
            [0, 2, 3], [0, 3, 1], [4, 5, 7], [4, 7, 6],
            [0, 1, 5], [0, 5, 4], [2, 6, 7], [2, 7, 3],
            [0, 4, 6], [0, 6, 2], [1, 3, 7], [1, 7, 5],
        ]
        let indices = faces.flatMap { $0.map { UInt32($0) } }
        let size = hi - lo
        return ConvexHullResult(vertices: vertices, indices: indices, isDegenerate: true,
                                volume: size.x * size.y * size.z, centroid: (lo + hi) * 0.5)
    }

    /// Signed-tetrahedron sum over the closed hull.
    static func volumeAndCentroid(vertices: [Vec3], indices: [UInt32]) -> (volume: Double,
                                                                          centroid: Vec3) {
        var volume = 0.0
        var centroid = Vec3.zero
        var i = 0
        while i + 2 < indices.count {
            let a = vertices[Int(indices[i])]
            let b = vertices[Int(indices[i + 1])]
            let c = vertices[Int(indices[i + 2])]
            let signed = a.dot(b.cross(c)) / 6
            volume += signed
            centroid += (a + b + c) * (signed / 4)
            i += 3
        }
        if abs(volume) < 1e-15 { return (0, .zero) }
        return (abs(volume), centroid / volume)
    }

    /// Drops the vertices whose removal changes the hull least, then rebuilds.
    private static func simplify(_ hull: ConvexHullResult, to limit: Int) -> ConvexHullResult {
        let centre = hull.centroid
        let ranked = hull.vertices.sorted { (a, b) in
            (a - centre).length > (b - centre).length
        }
        return compute(points: Array(ranked.prefix(limit)), maxVertices: limit)
    }
}
