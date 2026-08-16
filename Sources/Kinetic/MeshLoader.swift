//
//  MeshLoader.swift
//  Kinetic
//
//  Mesh import for the geometry that URDF and MJCF reference: STL (binary and
//  ASCII), OBJ, and PLY (ascii). Resolves `package://`, `file://` and relative
//  URIs against a search path, caches by resolved path, and hands the collision
//  core a convex hull while keeping the original triangles for rendering.
//

import Foundation

public struct LoadedMesh: Sendable {
    public var name: String
    /// Triangles as authored, for rendering.
    public var vertices: [Vec3]
    public var indices: [UInt32]
    /// Convex hull of the same points, for collision.
    public var hullVertices: [Vec3]
    public var hullIndices: [UInt32]
    public var boundingRadius: Double
    public var aabbMin: Vec3
    public var aabbMax: Vec3
    public var volume: Double
    public var centroid: Vec3
    public var usedFallbackHull: Bool
}

public enum MeshLoaderError: Error, CustomStringConvertible {
    case unreadable(URL)
    case unsupported(String)
    case empty(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): return "cannot read mesh at \(url.path)"
        case .unsupported(let ext): return "unsupported mesh format '.\(ext)'"
        case .empty(let url): return "mesh at \(url.path) contains no triangles"
        }
    }
}

/// Thread-safe cache of decoded meshes. Imports may run off the main thread, so
/// every mutation goes through the lock.
public final class MeshLibrary: @unchecked Sendable {
    private var cache: [String: LoadedMesh] = [:]
    private var paths: [URL]
    private let lock = NSLock()

    public init(searchPaths: [URL] = []) {
        self.paths = searchPaths
    }

    public var searchPaths: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    public func addSearchPath(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !paths.contains(url) else { return }
        paths.append(url)
    }

    /// Resolves a URDF/MJCF mesh reference to a file on disk.
    ///
    /// `package://my_robot/meshes/link.stl` is tried against every search path
    /// both with and without the leading package component, which covers the two
    /// layouts real ROS packages ship in.
    public func resolve(_ uri: String) -> URL? {
        if uri.hasPrefix("file://"), let url = URL(string: uri) { return url }

        var relative = uri
        if relative.hasPrefix("package://") {
            relative = String(relative.dropFirst("package://".count))
        } else if relative.hasPrefix("model://") {
            relative = String(relative.dropFirst("model://".count))
        }

        let direct = URL(fileURLWithPath: relative)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let withoutPackage = relative.contains("/")
            ? String(relative.drop(while: { $0 != "/" }).dropFirst())
            : relative

        for root in searchPaths {
            for candidate in [relative, withoutPackage] where !candidate.isEmpty {
                let url = root.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public func load(_ uri: String, scale: Vec3 = Vec3(1, 1, 1)) throws -> LoadedMesh {
        guard let url = resolve(uri) else { throw MeshLoaderError.unreadable(URL(fileURLWithPath: uri)) }
        let key = "\(url.path)|\(scale.x),\(scale.y),\(scale.z)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        let mesh = try MeshLoader.load(contentsOf: url, scale: scale)
        lock.lock()
        cache[key] = mesh
        lock.unlock()
        return mesh
    }
}

public enum MeshLoader {

    public static func load(contentsOf url: URL, scale: Vec3 = Vec3(1, 1, 1)) throws -> LoadedMesh {
        guard let data = try? Data(contentsOf: url) else { throw MeshLoaderError.unreadable(url) }
        let ext = url.pathExtension.lowercased()

        var triangles: (vertices: [Vec3], indices: [UInt32])
        switch ext {
        case "stl": triangles = try parseSTL(data)
        case "obj": triangles = try parseOBJ(data)
        case "ply": triangles = try parsePLY(data)
        case "dae", "gltf", "glb":
            // Scene formats carry transforms and materials this importer does not
            // model; surface a clear error instead of a silently wrong mesh.
            throw MeshLoaderError.unsupported(ext)
        default: throw MeshLoaderError.unsupported(ext)
        }
        guard !triangles.vertices.isEmpty, !triangles.indices.isEmpty else {
            throw MeshLoaderError.empty(url)
        }

        if scale != Vec3(1, 1, 1) {
            for i in triangles.vertices.indices {
                triangles.vertices[i] = triangles.vertices[i] * scale
            }
        }

        let hull = ConvexHull.compute(points: triangles.vertices)
        var lo = triangles.vertices[0], hi = triangles.vertices[0]
        var radius = 0.0
        for v in triangles.vertices {
            lo = Vec3(min(lo.x, v.x), min(lo.y, v.y), min(lo.z, v.z))
            hi = Vec3(max(hi.x, v.x), max(hi.y, v.y), max(hi.z, v.z))
            radius = max(radius, v.length)
        }

        return LoadedMesh(
            name: url.deletingPathExtension().lastPathComponent,
            vertices: triangles.vertices,
            indices: triangles.indices,
            hullVertices: hull.vertices,
            hullIndices: hull.indices,
            boundingRadius: radius,
            aabbMin: lo, aabbMax: hi,
            volume: hull.volume,
            centroid: hull.centroid,
            usedFallbackHull: hull.isDegenerate)
    }

    // MARK: STL

    static func parseSTL(_ data: Data) throws -> (vertices: [Vec3], indices: [UInt32]) {
        // A binary STL is 84 + 50 * n bytes; anything else that starts with
        // "solid" is treated as ASCII.
        let looksASCII = data.count > 5
            && data.prefix(5).elementsEqual(Array("solid".utf8))
        if looksASCII && !isBinarySTL(data) { return parseASCIISTL(data) }
        return try parseBinarySTL(data)
    }

    private static func isBinarySTL(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian
        }
        return data.count == 84 + Int(count) * 50
    }

    private static func parseBinarySTL(_ data: Data) throws -> (vertices: [Vec3], indices: [UInt32]) {
        guard data.count >= 84 else { throw MeshLoaderError.unsupported("stl") }
        let triangleCount = Int(data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian
        })
        guard data.count >= 84 + triangleCount * 50 else {
            throw MeshLoaderError.unsupported("stl")
        }

        var vertices: [Vec3] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(triangleCount * 3)
        indices.reserveCapacity(triangleCount * 3)

        data.withUnsafeBytes { raw in
            for triangle in 0..<triangleCount {
                let base = 84 + triangle * 50 + 12  // skip the per-facet normal
                for corner in 0..<3 {
                    let offset = base + corner * 12
                    let x = raw.loadUnaligned(fromByteOffset: offset, as: Float32.self)
                    let y = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float32.self)
                    let z = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float32.self)
                    indices.append(UInt32(vertices.count))
                    vertices.append(Vec3(Double(x), Double(y), Double(z)))
                }
            }
        }
        return (vertices, indices)
    }

    private static func parseASCIISTL(_ data: Data) -> (vertices: [Vec3], indices: [UInt32]) {
        var vertices: [Vec3] = []
        var indices: [UInt32] = []
        let text = String(decoding: data, as: UTF8.self)
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("vertex") else { return }
            let parts = trimmed.split(separator: " ").compactMap { Double($0) }
            guard parts.count >= 3 else { return }
            indices.append(UInt32(vertices.count))
            vertices.append(Vec3(parts[0], parts[1], parts[2]))
        }
        return (vertices, indices)
    }

    // MARK: OBJ

    static func parseOBJ(_ data: Data) throws -> (vertices: [Vec3], indices: [UInt32]) {
        var positions: [Vec3] = []
        var indices: [UInt32] = []
        let text = String(decoding: data, as: UTF8.self)

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("v ") {
                let parts = trimmed.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
                let numbers = parts.compactMap { Double($0) }
                if numbers.count >= 3 { positions.append(Vec3(numbers[0], numbers[1], numbers[2])) }
            } else if trimmed.hasPrefix("f ") {
                let tokens = trimmed.dropFirst(2)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                // A face may be a polygon; fan-triangulate it.
                var corner: [UInt32] = []
                for token in tokens {
                    let vertexField = token.split(separator: "/", omittingEmptySubsequences: false)
                        .first ?? ""
                    guard var index = Int(vertexField) else { continue }
                    if index < 0 { index = positions.count + index + 1 }
                    guard index >= 1, index <= positions.count else { continue }
                    corner.append(UInt32(index - 1))
                }
                guard corner.count >= 3 else { return }
                for i in 1..<(corner.count - 1) {
                    indices.append(contentsOf: [corner[0], corner[i], corner[i + 1]])
                }
            }
        }
        return (positions, indices)
    }

    // MARK: PLY (ascii)

    static func parsePLY(_ data: Data) throws -> (vertices: [Vec3], indices: [UInt32]) {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "ply" else {
            throw MeshLoaderError.unsupported("ply")
        }

        var vertexCount = 0, faceCount = 0
        var headerEnd = 0
        var isAscii = false
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "format" { isAscii = parts.count > 1 && parts[1] == "ascii" }
            if parts.count >= 3, parts[0] == "element", parts[1] == "vertex" {
                vertexCount = Int(parts[2]) ?? 0
            }
            if parts.count >= 3, parts[0] == "element", parts[1] == "face" {
                faceCount = Int(parts[2]) ?? 0
            }
            if parts.first == "end_header" {
                headerEnd = i + 1
                break
            }
        }
        guard isAscii else { throw MeshLoaderError.unsupported("ply (binary)") }

        var vertices: [Vec3] = []
        var indices: [UInt32] = []
        lines = Array(lines.dropFirst(headerEnd))
        for i in 0..<min(vertexCount, lines.count) {
            let numbers = lines[i].split(separator: " ").compactMap { Double($0) }
            if numbers.count >= 3 { vertices.append(Vec3(numbers[0], numbers[1], numbers[2])) }
        }
        for i in vertexCount..<min(vertexCount + faceCount, lines.count) {
            let numbers = lines[i].split(separator: " ").compactMap { Int($0) }
            guard let n = numbers.first, numbers.count >= n + 1, n >= 3 else { continue }
            let corner = Array(numbers[1...n]).map { UInt32($0) }
            for k in 1..<(corner.count - 1) {
                indices.append(contentsOf: [corner[0], corner[k], corner[k + 1]])
            }
        }
        return (vertices, indices)
    }
}
