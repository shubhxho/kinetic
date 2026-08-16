//
//  MeshFactory.swift
//  KineticRender
//
//  Tessellated unit primitives plus a cache keyed by shape parameters. Boxes,
//  spheres, cylinders and planes are generated once as unit meshes and scaled
//  per instance; capsules cannot be non-uniformly scaled without distorting the
//  caps, so they are generated per (radius, halfLength) pair and cached.
//

import Foundation
import Kinetic
import Metal
import simd

public struct RenderVertex {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
}

public final class GPUMesh {
    public let vertexBuffer: MTLBuffer
    public let indexBuffer: MTLBuffer
    public let indexCount: Int
    public let boundingRadius: Float

    init(device: MTLDevice, vertices: [RenderVertex], indices: [UInt32], label: String) {
        var radius: Float = 0
        for v in vertices { radius = max(radius, simd_length(v.position)) }
        boundingRadius = radius
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<RenderVertex>.stride * vertices.count,
                                         options: .storageModeShared)!
        indexBuffer = device.makeBuffer(bytes: indices,
                                        length: MemoryLayout<UInt32>.stride * indices.count,
                                        options: .storageModeShared)!
        indexCount = indices.count
        vertexBuffer.label = "\(label).vertices"
        indexBuffer.label = "\(label).indices"
    }
}

/// Identifies a cached mesh. Shapes that scale cleanly collapse to a single key.
public enum MeshKey: Hashable {
    case box
    case sphere
    case cylinder
    case plane
    case capsule(radiusMilli: Int, halfLengthMilli: Int)
    case hull(index: Int)
    case arrow
}

public final class MeshLibrary {
    private let device: MTLDevice
    private var cache: [MeshKey: GPUMesh] = [:]

    public init(device: MTLDevice) {
        self.device = device
    }

    public func mesh(for key: MeshKey, world: World? = nil) -> GPUMesh {
        if let existing = cache[key] { return existing }
        let generated: (vertices: [RenderVertex], indices: [UInt32])
        switch key {
        case .box: generated = MeshFactory.box(halfExtents: SIMD3<Float>(1, 1, 1))
        case .sphere: generated = MeshFactory.sphere(radius: 1, segments: 32, rings: 16)
        case .cylinder: generated = MeshFactory.cylinder(radius: 1, halfLength: 1, segments: 32)
        case .plane: generated = MeshFactory.plane(extent: 1)
        case .arrow: generated = MeshFactory.arrow()
        case .capsule(let r, let h):
            generated = MeshFactory.capsule(radius: Float(r) / 1000, halfLength: Float(h) / 1000,
                                            segments: 24, rings: 12)
        case .hull(let index):
            if let world, index >= 0, index < 64 {
                let data = world.meshData(index)
                generated = MeshFactory.fromTriangles(vertices: data.vertices,
                                                      indices: data.indices)
            } else {
                generated = MeshFactory.box(halfExtents: SIMD3<Float>(1, 1, 1))
            }
        }
        let mesh = GPUMesh(device: device, vertices: generated.vertices,
                           indices: generated.indices, label: "\(key)")
        cache[key] = mesh
        return mesh
    }

    /// Mesh key plus the per-instance scale that turns the unit mesh into `shape`.
    public static func resolve(_ shape: Shape) -> (key: MeshKey, scale: SIMD3<Float>) {
        switch shape {
        case .sphere(let r):
            return (.sphere, SIMD3<Float>(repeating: Float(r)))
        case .box(let h):
            return (.box, SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z)))
        case .cylinder(let r, let h):
            return (.cylinder, SIMD3<Float>(Float(r), Float(r), Float(h)))
        case .capsule(let r, let h):
            let key = MeshKey.capsule(radiusMilli: Int((r * 1000).rounded()),
                                      halfLengthMilli: Int((h * 1000).rounded()))
            return (key, SIMD3<Float>(repeating: 1))
        case .plane(let extent):
            return (.plane, SIMD3<Float>(Float(extent), Float(extent), 1))
        case .convexHull(let mesh, _):
            return (.hull(index: mesh), SIMD3<Float>(repeating: 1))
        }
    }
}

public enum MeshFactory {
    public static func box(halfExtents h: SIMD3<Float>) -> ([RenderVertex], [UInt32]) {
        let faces: [(normal: SIMD3<Float>, corners: [SIMD3<Float>])] = [
            (SIMD3(0, 0, 1), [SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]),
            (SIMD3(0, 0, -1), [SIMD3(-1, 1, -1), SIMD3(1, 1, -1), SIMD3(1, -1, -1), SIMD3(-1, -1, -1)]),
            (SIMD3(1, 0, 0), [SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(1, 1, 1), SIMD3(1, -1, 1)]),
            (SIMD3(-1, 0, 0), [SIMD3(-1, -1, 1), SIMD3(-1, 1, 1), SIMD3(-1, 1, -1), SIMD3(-1, -1, -1)]),
            (SIMD3(0, 1, 0), [SIMD3(-1, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1)]),
            (SIMD3(0, -1, 0), [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, -1, 1), SIMD3(-1, -1, 1)]),
        ]
        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []
        for face in faces {
            let base = UInt32(vertices.count)
            for corner in face.corners {
                vertices.append(RenderVertex(position: corner * h, normal: face.normal))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (vertices, indices)
    }

    public static func sphere(radius: Float, segments: Int, rings: Int)
        -> ([RenderVertex], [UInt32])
    {
        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let phi = v * Float.pi
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let theta = u * 2 * Float.pi
                let n = SIMD3<Float>(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi))
                vertices.append(RenderVertex(position: n * radius, normal: n))
            }
        }
        let stride = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * stride + segment)
                let b = UInt32((ring + 1) * stride + segment)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (vertices, indices)
    }

    public static func cylinder(radius: Float, halfLength: Float, segments: Int)
        -> ([RenderVertex], [UInt32])
    {
        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []

        // Side wall.
        for segment in 0...segments {
            let u = Float(segment) / Float(segments)
            let theta = u * 2 * Float.pi
            let n = SIMD3<Float>(cos(theta), sin(theta), 0)
            vertices.append(RenderVertex(position: n * radius + SIMD3(0, 0, -halfLength), normal: n))
            vertices.append(RenderVertex(position: n * radius + SIMD3(0, 0, halfLength), normal: n))
        }
        for segment in 0..<segments {
            let a = UInt32(segment * 2)
            indices += [a, a + 1, a + 2, a + 2, a + 1, a + 3]
        }

        // Caps.
        for (z, normal) in [(-halfLength, SIMD3<Float>(0, 0, -1)), (halfLength, SIMD3<Float>(0, 0, 1))] {
            let center = UInt32(vertices.count)
            vertices.append(RenderVertex(position: SIMD3(0, 0, z), normal: normal))
            for segment in 0...segments {
                let theta = Float(segment) / Float(segments) * 2 * Float.pi
                vertices.append(RenderVertex(
                    position: SIMD3(cos(theta) * radius, sin(theta) * radius, z), normal: normal))
            }
            for segment in 0..<segments {
                let a = center + 1 + UInt32(segment)
                if normal.z > 0 {
                    indices += [center, a, a + 1]
                } else {
                    indices += [center, a + 1, a]
                }
            }
        }
        return (vertices, indices)
    }

    public static func capsule(radius: Float, halfLength: Float, segments: Int, rings: Int)
        -> ([RenderVertex], [UInt32])
    {
        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []
        let totalRings = rings * 2 + 1

        for ring in 0...totalRings {
            // Rings 0..rings sweep the top cap, the rest sweep the bottom cap;
            // the seam in the middle shares the cylinder wall.
            let isTop = ring <= rings
            let t = isTop ? Float(ring) / Float(rings) : Float(ring - rings - 1) / Float(rings)
            let phi = isTop ? t * Float.pi / 2 : (t * Float.pi / 2 + Float.pi / 2)
            let zOffset = isTop ? halfLength : -halfLength
            for segment in 0...segments {
                let theta = Float(segment) / Float(segments) * 2 * Float.pi
                let n = SIMD3<Float>(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi))
                let position = n * radius + SIMD3<Float>(0, 0, zOffset)
                vertices.append(RenderVertex(position: position, normal: n))
            }
        }

        let stride = segments + 1
        for ring in 0..<totalRings {
            for segment in 0..<segments {
                let a = UInt32(ring * stride + segment)
                let b = UInt32((ring + 1) * stride + segment)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (vertices, indices)
    }

    public static func plane(extent: Float) -> ([RenderVertex], [UInt32]) {
        let n = SIMD3<Float>(0, 0, 1)
        let vertices = [
            RenderVertex(position: SIMD3(-extent, -extent, 0), normal: n),
            RenderVertex(position: SIMD3(extent, -extent, 0), normal: n),
            RenderVertex(position: SIMD3(extent, extent, 0), normal: n),
            RenderVertex(position: SIMD3(-extent, extent, 0), normal: n),
        ]
        return (vertices, [0, 1, 2, 0, 2, 3])
    }

    /// Unit arrow pointing along +Z: shaft from 0 to 0.75, head to 1.0.
    public static func arrow() -> ([RenderVertex], [UInt32]) {
        var (vertices, indices) = cylinder(radius: 0.035, halfLength: 0.375, segments: 12)
        for i in vertices.indices { vertices[i].position.z += 0.375 }

        let segments = 12
        let base = UInt32(vertices.count)
        let tip = SIMD3<Float>(0, 0, 1)
        vertices.append(RenderVertex(position: tip, normal: SIMD3(0, 0, 1)))
        for segment in 0...segments {
            let theta = Float(segment) / Float(segments) * 2 * Float.pi
            let dir = SIMD3<Float>(cos(theta), sin(theta), 0)
            let n = simd_normalize(dir * 0.8 + SIMD3<Float>(0, 0, 0.6))
            vertices.append(RenderVertex(position: dir * 0.1 + SIMD3(0, 0, 0.75), normal: n))
        }
        for segment in 0..<segments {
            indices += [base, base + 1 + UInt32(segment), base + 2 + UInt32(segment)]
        }
        return (vertices, indices)
    }

    /// Triangle soup with flat normals, used for imported convex hulls.
    public static func fromTriangles(vertices sourceVertices: [Vec3], indices sourceIndices: [UInt32])
        -> ([RenderVertex], [UInt32])
    {
        guard !sourceIndices.isEmpty else {
            // No topology: fall back to the point cloud's bounding box.
            var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in sourceVertices {
                let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
                mn = simd_min(mn, p)
                mx = simd_max(mx, p)
            }
            if sourceVertices.isEmpty { return box(halfExtents: SIMD3(0.05, 0.05, 0.05)) }
            let center = (mn + mx) * 0.5
            var (verts, idx) = box(halfExtents: (mx - mn) * 0.5)
            for i in verts.indices { verts[i].position += center }
            return (verts, idx.map { $0 })
        }

        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(sourceIndices.count)
        var i = 0
        while i + 2 < sourceIndices.count {
            let ia = Int(sourceIndices[i]), ib = Int(sourceIndices[i + 1]), ic = Int(sourceIndices[i + 2])
            guard ia < sourceVertices.count, ib < sourceVertices.count, ic < sourceVertices.count
            else { i += 3; continue }
            let a = SIMD3<Float>(Float(sourceVertices[ia].x), Float(sourceVertices[ia].y),
                                 Float(sourceVertices[ia].z))
            let b = SIMD3<Float>(Float(sourceVertices[ib].x), Float(sourceVertices[ib].y),
                                 Float(sourceVertices[ib].z))
            let c = SIMD3<Float>(Float(sourceVertices[ic].x), Float(sourceVertices[ic].y),
                                 Float(sourceVertices[ic].z))
            let n = simd_normalize(simd_cross(b - a, c - a))
            let base = UInt32(vertices.count)
            vertices.append(RenderVertex(position: a, normal: n))
            vertices.append(RenderVertex(position: b, normal: n))
            vertices.append(RenderVertex(position: c, normal: n))
            indices += [base, base + 1, base + 2]
            i += 3
        }
        return (vertices, indices)
    }
}
