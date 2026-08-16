//
//  USDImporter.swift
//  Kinetic
//
//  USD import for assets authored in NVIDIA Omniverse / Isaac Sim.
//
//  What this file can and cannot do, stated once so it does not have to be
//  rediscovered later:
//
//    * macOS ships ModelIO, and `MDLAsset(url:)` reads `.usd`, `.usda`, `.usdc`
//      and `.usdz`. ModelIO runs a real USD composition engine, so references,
//      payloads, variants and sublayers are resolved for us. Everything
//      geometric — the prim hierarchy, prim paths, local transforms, triangle
//      data, materials — comes back complete and is READ, not guessed.
//
//    * ModelIO does NOT expose the UsdPhysics schema. `PhysicsRigidBodyAPI`,
//      `PhysicsMassAPI`, joints, articulation roots and collision
//      approximations are not surfaced by any ModelIO selector. They are
//      recovered separately, and only from ASCII layers, by `USDPhysics`.
//      Binary crate (`.usdc`) and packages (`.usdz`) cannot be text-parsed.
//
//    * ModelIO applies neither `metersPerUnit` nor `upAxis`. Verified: a stage
//      with `metersPerUnit = 0.01` hands back points at their authored
//      magnitude, and a Y-up stage hands back Y-up vertices. Both conversions
//      are therefore done here, explicitly.
//
//  Nothing in this importer invents physical quantities silently. Every value
//  that is derived rather than read is reported through `onWarning`.
//

import Foundation
import ModelIO
import simd

// MARK: - Options

public struct USDImportOptions: Sendable {

    /// How the stage's up axis is resolved.
    public enum UpAxisHandling: Sendable, Equatable {
        /// Ask ModelIO (`MDLAsset.upAxis`), which reports the stage's authored
        /// `upAxis` for both ASCII and crate layers. This is the default and is
        /// correct for every well-formed stage.
        case fromStage
        /// Force the Y-up → Z-up conversion regardless of what the stage says.
        case assumeYUp
        /// Treat the stage as already Z-up.
        case assumeZUp
        /// Import raw. The caller is asserting the asset needs no conversion;
        /// a Y-up asset imported this way will fall over sideways.
        case none
    }

    /// Whether the asset becomes scenery or movable bodies.
    public enum BodyPolicy: Sendable, Equatable {
        /// Every mesh is world-fixed geometry. Correct for environments,
        /// fixtures, ramps and Isaac "background" stages.
        case staticGeometry
        /// One free-floating body per top-level prim, with that prim's whole
        /// subtree welded into it.
        case freeBodyPerTopLevelPrim
    }

    /// Metres per authored unit. `nil` reads `metersPerUnit` from the stage when
    /// the layer is ASCII, and falls back to `fallbackUnitScale` otherwise —
    /// ModelIO does not expose stage metadata beyond the up axis, so a crate
    /// layer's `metersPerUnit` is genuinely unavailable.
    ///
    /// Omniverse and Isaac Sim stages are very often authored in centimetres
    /// (`metersPerUnit = 0.01`).
    public var unitScale: Double? = nil

    /// Used when `unitScale` is `nil` and the stage metadata cannot be read.
    /// 1.0 means "assume the asset is already in metres", and a warning is
    /// emitted whenever this fallback is taken.
    public var fallbackUnitScale: Double = 1.0

    public var upAxis: UpAxisHandling = .fromStage

    /// Concatenate an `MDLMesh`'s submeshes into one `LoadedMesh`. Submeshes are
    /// material partitions of the same point set; merging them gives one
    /// collision hull per mesh prim, which is almost always what a simulator
    /// wants. Set to `false` to keep one `LoadedMesh` per material.
    public var mergeSubmeshes: Bool = true

    /// Hard cap on convex hull vertices, passed straight to `ConvexHull.compute`.
    /// The collision core's support mapping is a linear scan, so this is a
    /// direct performance knob.
    public var maxHullVertices: Int = 256

    public var bodyPolicy: BodyPolicy = .staticGeometry

    /// Density used when a mass has to be derived from hull volume. Only ever
    /// applied when the stage authored no `physics:mass`/`physics:density`, and
    /// always accompanied by a warning.
    public var density: Double = 1000

    /// Emit a visible non-collidable geom carrying the authored triangles plus
    /// an invisible collidable geom carrying the convex hull. USD has no
    /// visual/collision split of its own, so this is how a concave asset can
    /// look right and still collide sanely.
    public var separateVisualAndCollision: Bool = true

    /// When the layer is ASCII and carries UsdPhysics prims, build a real
    /// articulation from them via `USDPhysics` instead of applying
    /// `bodyPolicy`.
    public var importPhysics: Bool = true

    /// Refuse the import rather than fall back to geometry-only approximation
    /// when physics cannot be recovered. Turns a silent downgrade into a
    /// `USDImportError.physicsSchemaNotExposed`.
    public var requirePhysics: Bool = false

    public var material: SurfaceMaterial = .default

    /// Used for prims whose material ModelIO does not resolve to a plain colour.
    public var appearance: Appearance = .default

    /// Read `baseColor` from the bound `MDLMaterial` when it is a plain colour.
    public var readMaterialColors: Bool = true

    public var selfCollision: Bool = false

    public var onWarning: (@Sendable (String) -> Void)? = nil

    public init() {}
}

// MARK: - Report types

public enum USDEncoding: String, Sendable {
    /// `.usda`, or a `.usd` whose first bytes are `#usda`. Text; physics is
    /// recoverable.
    case ascii
    /// `.usdc`, or a `.usd` whose first bytes are `PXR-USDC`. Crate-encoded
    /// binary; physics is not recoverable.
    case crate
    /// `.usdz` — a zip package. Physics is not recoverable.
    case package
    case unknown
}

public enum USDUpAxis: String, Sendable {
    case y
    case z
    case unknown
}

/// Non-destructive report on a USD file. `inspect` never mutates a `World`.
public struct USDDocument: Sendable {
    public var url: URL
    public var encoding: USDEncoding
    /// As reported by `MDLAsset.upAxis`, which was verified to track the stage's
    /// authored `upAxis` for both ASCII and crate layers.
    public var upAxis: USDUpAxis
    /// `nil` when the layer is binary: `metersPerUnit` lives in stage metadata
    /// that ModelIO does not expose, and the crate encoding cannot be read here.
    public var metersPerUnit: Double?
    /// Number of prims ModelIO surfaced, including physics prims (which appear
    /// as bare `MDLObject`s carrying only a name and a path).
    public var primCount: Int
    public var meshCount: Int
    public var triangleCount: Int
    /// True when UsdPhysics schema names were found in the file.
    public var hasPhysicsSchemas: Bool
    /// The schema and prim-type names that were found.
    public var physicsSchemaNames: [String]
    /// True when `hasPhysicsSchemas` came from a raw byte scan of a binary
    /// layer rather than a parse. A crate layer's token section may be
    /// LZ4-compressed, so a `false` result there is not proof of absence.
    public var physicsDetectionIsHeuristic: Bool
    /// Populated only for ASCII layers.
    public var physicsCoverage: Double?
    public var warnings: [String]
}

/// One prim's worth of geometry, already in metres and already in Kinetic's
/// Z-up frame.
public struct USDNode: Sendable {
    /// The prim name (the last path component).
    public var name: String
    /// The full USD prim path, e.g. `/World/Robot/base_link`. This is the key
    /// that `USDPhysics` uses to bind recovered bodies to geometry.
    public var path: String
    /// Absolute (world) rigid transform, not relative to `parent`. Non-uniform
    /// scale is not representable here and has been baked into the vertices.
    public var worldTransform: Pose
    /// Scale that was baked into the mesh vertices, in case a caller needs it.
    public var bakedScale: Vec3
    /// Meshes owned by this prim. Empty for `Xform`, `Scope` and physics prims.
    public var meshes: [LoadedMesh]
    public var children: [USDNode]

    /// This node and every descendant, each with `children` cleared so a caller
    /// can iterate the whole asset without double-counting.
    public var flattened: [USDNode] {
        var leaf = self
        leaf.children = []
        return [leaf] + children.flatMap(\.flattened)
    }
}

extension Array where Element == USDNode {
    /// Every node in the forest, `children` cleared. World transforms are
    /// already absolute, so the flattened list is fully self-describing.
    public var flattened: [USDNode] { flatMap(\.flattened) }
}

// MARK: - Errors

public enum USDImportError: Error, CustomStringConvertible {
    case unreadable(URL)
    case unsupportedExtension(String)
    case emptyStage(URL)
    /// The physics of this asset lives in the UsdPhysics schema, which ModelIO
    /// does not expose, and this layer cannot be text-parsed either.
    case physicsSchemaNotExposed(url: URL, encoding: USDEncoding, detail: String)
    /// Asked to text-parse physics out of a crate or package layer.
    case binaryPhysicsUnreadable(url: URL, encoding: USDEncoding)
    /// The recovered joint graph is not a tree.
    case kinematicLoop(String)
    /// The stage declared no `PhysicsRigidBodyAPI` prims.
    case noRigidBodies(URL)

    public var description: String {
        switch self {
        case .unreadable(let url):
            return "cannot read USD at \(url.path)"
        case .unsupportedExtension(let ext):
            return "'.\(ext)' is not a USD file; expected .usd, .usda, .usdc or .usdz"
        case .emptyStage(let url):
            return "the stage at \(url.path) contains no meshes"
        case .physicsSchemaNotExposed(let url, let encoding, let detail):
            return """
                \(url.lastPathComponent) is a \(encoding.rawValue) USD layer whose physics lives in \
                the UsdPhysics schema. ModelIO reads its geometry but exposes no part of that \
                schema — masses, joints, articulation roots and collision approximations are \
                simply not available through any ModelIO API, and \(encoding.rawValue) layers \
                cannot be text-parsed either. \(detail) To bring the physics across, either \
                flatten the stage to ASCII first (`usdcat -o flat.usda \
                \(url.lastPathComponent)`, or File ▸ Export as .usda in Omniverse) and re-import \
                that, or export the asset to URDF or MJCF and use Kinetic's URDF/MJCF importers, \
                which read physics natively. Alternatively set \
                `USDImportOptions.requirePhysics = false` to import the geometry alone.
                """
        case .binaryPhysicsUnreadable(let url, let encoding):
            let form = encoding == .package ? "a zip package" : "crate-encoded"
            return """
                \(url.lastPathComponent) is \(form) and cannot be parsed as text. Convert it with \
                `usdcat -o flat.usda \(url.lastPathComponent)` and parse that.
                """
        case .kinematicLoop(let detail):
            return """
                the recovered joint graph is not a tree: \(detail). Kinetic articulations are \
                trees; close the loop yourself with World.connect (a ball equality constraint) \
                or World.weld after building the tree.
                """
        case .noRigidBodies(let url):
            return "no PhysicsRigidBodyAPI prims were recovered from \(url.lastPathComponent)"
        }
    }
}

// MARK: - Importer

public enum USDImporter {

    // MARK: Frame conversion

    /// USD is frequently Y-up; Kinetic is Z-UP. The conversion is a +90°
    /// rotation about +X:
    ///
    ///     (x, y, z) → (x, -z, y)
    ///
    /// which sends USD's up (+Y) to Kinetic's up (+Z) and USD's forward (-Z) to
    /// +Y. Its determinant is +1, so no triangle winding is inverted and no
    /// handedness is changed. This is the same convention `usdview` and Isaac
    /// Sim use when reconciling a Y-up layer with a Z-up stage.
    ///
    /// It is applied in two places, and they must agree:
    ///   * mesh vertices, which are rotated point by point;
    ///   * node transforms, which are conjugated: `M' = R · M · R⁻¹`.
    ///
    /// Conjugation rather than left-multiplication is what keeps the two
    /// consistent: with vertices expressed in the rotated local frame
    /// (`p' = R·p`), `M'·p' = R·M·R⁻¹·R·p = R·(M·p)`, i.e. exactly the rotated
    /// world position. Left-multiplying the transform alone would rotate the
    /// world position twice.
    public static let yUpToZUp = Quat(axis: Vec3(1, 0, 0), angle: .pi / 2)

    /// Rotates a pose that is expressed in a local frame into the Z-up frame.
    static func convertLocalPose(_ pose: Pose, by rotation: Quat) -> Pose {
        Pose(position: rotation.rotate(pose.position),
             orientation: (rotation * pose.orientation * rotation.conjugate).normalized)
    }

    // MARK: Encoding

    /// Classifies a layer from its magic bytes, falling back to the extension.
    /// `#usda` and `PXR-USDC` are the two USD magic strings; `.usdz` is a plain
    /// zip, so it starts with `PK`.
    public static func encoding(of url: URL) -> USDEncoding {
        let handle = try? FileHandle(forReadingFrom: url)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: 8)) ?? nil

        if let head, head.count >= 5 {
            if head.prefix(5).elementsEqual(Array("#usda".utf8)) { return .ascii }
            if head.count >= 8, head.prefix(8).elementsEqual(Array("PXR-USDC".utf8)) {
                return .crate
            }
            if head.prefix(2).elementsEqual([0x50, 0x4B]) { return .package }
        }

        switch url.pathExtension.lowercased() {
        case "usda": return .ascii
        case "usdc": return .crate
        case "usdz": return .package
        default: return .unknown
        }
    }

    /// Reads a layer as text, or returns `nil` when it is not ASCII.
    static func asciiText(of url: URL, encoding: USDEncoding) -> String? {
        guard encoding == .ascii, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: inspect

    /// Reports what is in a USD file without touching a `World`.
    public static func inspect(contentsOf url: URL) throws -> USDDocument {
        let ext = url.pathExtension.lowercased()
        guard ["usd", "usda", "usdc", "usdz"].contains(ext) else {
            throw USDImportError.unsupportedExtension(ext)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw USDImportError.unreadable(url)
        }

        var warnings: [String] = []
        let layer = encoding(of: url)
        if layer == .unknown {
            warnings.append("could not identify the layer encoding from its magic bytes")
        }

        let asset = MDLAsset(url: url)
        let up = upAxis(of: asset)
        if up == .unknown {
            warnings.append("the stage declares no recognisable up axis; assuming Z-up")
        }

        var primCount = 0
        var meshCount = 0
        var triangleCount = 0
        for i in 0..<asset.count {
            walk(asset.object(at: i)) { object in
                primCount += 1
                guard let mesh = object as? MDLMesh else { return }
                meshCount += 1
                for case let submesh as MDLSubmesh in (mesh.submeshes ?? []) {
                    if submesh.geometryType == .triangles {
                        triangleCount += submesh.indexCount / 3
                    } else {
                        warnings.append(
                            "\(object.path): submesh '\(submesh.name)' is not triangulated "
                            + "(\(describe(submesh.geometryType))) and will be skipped")
                    }
                }
            }
        }
        if meshCount == 0 { warnings.append("ModelIO surfaced no meshes in this stage") }

        // Physics detection. ASCII layers get a real parse; binary layers get a
        // byte scan for the schema token strings, which is a heuristic and is
        // labelled as one.
        var metersPerUnit: Double?
        var schemas: [String] = []
        var coverage: Double?
        var heuristic = false

        if let text = asciiText(of: url, encoding: layer) {
            let stage = USDPhysics.stageInfo(text)
            metersPerUnit = stage.metersPerUnit
            let scene = USDPhysics.parse(text)
            schemas = scene.recognisedSchemaNames
            coverage = scene.coverage
            warnings.append(contentsOf: scene.unsupported.map { "unsupported: \($0)" })
            if metersPerUnit == nil {
                warnings.append("the stage declares no metersPerUnit; assuming 1 unit = 1 metre")
            }
        } else {
            heuristic = true
            warnings.append(
                "this is a \(layer.rawValue) layer: metersPerUnit is unavailable and UsdPhysics "
                + "cannot be recovered, because ModelIO exposes no part of that schema")
            if let data = try? Data(contentsOf: url) {
                schemas = scanForPhysicsTokens(data)
            }
            if !schemas.isEmpty {
                warnings.append(
                    "raw byte scan found UsdPhysics token strings (\(schemas.joined(separator: ", ")))"
                    + " — this asset has physics that this importer cannot read from a binary layer")
            }
        }

        return USDDocument(
            url: url,
            encoding: layer,
            upAxis: up,
            metersPerUnit: metersPerUnit,
            primCount: primCount,
            meshCount: meshCount,
            triangleCount: triangleCount,
            hasPhysicsSchemas: !schemas.isEmpty,
            physicsSchemaNames: schemas,
            physicsDetectionIsHeuristic: heuristic,
            physicsCoverage: coverage,
            warnings: warnings)
    }

    /// UsdPhysics token strings, searched for verbatim in binary layers. Crate
    /// stores tokens as plain UTF-8 in its token section unless that section is
    /// compressed, so a hit is conclusive and a miss is not.
    private static let physicsTokens = [
        "PhysicsRigidBodyAPI", "PhysicsMassAPI", "PhysicsCollisionAPI",
        "PhysicsArticulationRootAPI", "PhysicsMeshCollisionAPI", "PhysicsDriveAPI",
        "PhysicsRevoluteJoint", "PhysicsPrismaticJoint", "PhysicsFixedJoint",
        "PhysicsSphericalJoint", "PhysicsJoint", "PhysicsScene",
    ]

    private static func scanForPhysicsTokens(_ data: Data) -> [String] {
        physicsTokens.filter { token in
            data.range(of: Data(token.utf8)) != nil
        }
    }

    // MARK: loadGeometry

    /// Flattens the stage into world-space nodes carrying `LoadedMesh`
    /// payloads. Vertices are in metres and in Kinetic's Z-up frame; hulls are
    /// built with the same `ConvexHull.compute` call `MeshLoader` uses, so an
    /// imported USD mesh collides exactly like an imported STL.
    public static func loadGeometry(contentsOf url: URL,
                                    options: USDImportOptions = USDImportOptions()) throws
        -> [USDNode]
    {
        let ext = url.pathExtension.lowercased()
        guard ["usd", "usda", "usdc", "usdz"].contains(ext) else {
            throw USDImportError.unsupportedExtension(ext)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw USDImportError.unreadable(url)
        }

        let layer = encoding(of: url)
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { throw USDImportError.emptyStage(url) }

        let scale = resolvedUnitScale(url: url, encoding: layer, options: options)
        let rotation = resolvedUpAxisRotation(asset: asset, options: options)

        var nodes: [USDNode] = []
        for i in 0..<asset.count {
            if let node = build(object: asset.object(at: i),
                                parentWorld: matrix_identity_double4x4,
                                unitScale: scale, rotation: rotation, options: options) {
                nodes.append(node)
            }
        }
        guard nodes.contains(where: { !$0.flattened.allSatisfy(\.meshes.isEmpty) }) else {
            throw USDImportError.emptyStage(url)
        }
        return nodes
    }

    /// Resolves the unit scale, warning whenever the value had to be assumed
    /// rather than read.
    static func resolvedUnitScale(url: URL, encoding layer: USDEncoding,
                                  options: USDImportOptions) -> Double {
        if let explicit = options.unitScale { return explicit }
        if let text = asciiText(of: url, encoding: layer),
           let authored = USDPhysics.stageInfo(text).metersPerUnit {
            return authored
        }
        options.onWarning?(
            "metersPerUnit could not be read (\(layer.rawValue) layers do not expose stage "
            + "metadata through ModelIO); assuming \(options.fallbackUnitScale) m per unit. "
            + "Omniverse and Isaac Sim assets are commonly authored in centimetres — pass "
            + "USDImportOptions.unitScale = 0.01 if this asset is.")
        return options.fallbackUnitScale
    }

    static func upAxis(of asset: MDLAsset) -> USDUpAxis {
        let axis = asset.upAxis
        if abs(axis.y) > 0.5 { return .y }
        if abs(axis.z) > 0.5 { return .z }
        return .unknown
    }

    static func resolvedUpAxisRotation(asset: MDLAsset, options: USDImportOptions) -> Quat {
        switch options.upAxis {
        case .assumeYUp: return yUpToZUp
        case .assumeZUp, .none: return .identity
        case .fromStage:
            switch upAxis(of: asset) {
            case .y: return yUpToZUp
            case .z: return .identity
            case .unknown:
                options.onWarning?(
                    "the stage declares no recognisable up axis; importing without conversion. "
                    + "Set USDImportOptions.upAxis explicitly if the asset lands sideways.")
                return .identity
            }
        }
    }

    // MARK: Hierarchy walk

    private static func walk(_ object: MDLObject, _ visit: (MDLObject) -> Void) {
        visit(object)
        for child in object.children.objects { walk(child, visit) }
    }

    /// Recursively converts one `MDLObject` and its subtree.
    ///
    /// `parentWorld` is the accumulated USD-space matrix in authored units.
    /// Conversion to Kinetic's frame happens once, at the leaf, so that the
    /// accumulation itself stays in the asset's own coordinate system and no
    /// rounding is introduced per level.
    private static func build(object: MDLObject, parentWorld: simd_double4x4,
                              unitScale: Double, rotation: Quat,
                              options: USDImportOptions) -> USDNode? {
        let local = localMatrix(of: object)
        let world = parentWorld * local

        var decomposed = decompose(world)
        if decomposed.hasShear {
            options.onWarning?(
                "\(object.path): the accumulated transform is sheared; Kinetic poses are rigid, "
                + "so the shear has been dropped")
        }
        if decomposed.isMirrored {
            options.onWarning?(
                "\(object.path): the accumulated transform mirrors the geometry; the reflection "
                + "has been baked into the vertices and the triangle winding reversed")
        }

        // Translation is the only part of the matrix that carries length, so it
        // is the only part `metersPerUnit` applies to. The linear part is a
        // unitless scale-plus-rotation and is left alone.
        decomposed.translation *= unitScale

        // The node's rigid pose, expressed in Kinetic's frame.
        let pose = convertLocalPose(
            Pose(position: decomposed.translation, orientation: decomposed.rotation),
            by: rotation)

        var meshes: [LoadedMesh] = []
        if let mdlMesh = object as? MDLMesh {
            meshes = loadedMeshes(from: mdlMesh, path: object.path,
                                  unitScale: unitScale, bakedScale: decomposed.scale,
                                  reverseWinding: decomposed.isMirrored, rotation: rotation,
                                  options: options)
        }

        var children: [USDNode] = []
        for child in object.children.objects {
            if let node = build(object: child, parentWorld: world, unitScale: unitScale,
                                rotation: rotation, options: options) {
                children.append(node)
            }
        }

        return USDNode(name: object.name.isEmpty ? lastComponent(of: object.path) : object.name,
                       path: object.path,
                       worldTransform: pose,
                       bakedScale: decomposed.scale,
                       meshes: meshes,
                       children: children)
    }

    private static func lastComponent(of path: String) -> String {
        String(path.split(separator: "/").last ?? "prim")
    }

    private static func localMatrix(of object: MDLObject) -> simd_double4x4 {
        guard let transform = object.transform else { return matrix_identity_double4x4 }
        let m = transform.matrix
        return simd_double4x4(
            SIMD4<Double>(Double(m.columns.0.x), Double(m.columns.0.y),
                          Double(m.columns.0.z), Double(m.columns.0.w)),
            SIMD4<Double>(Double(m.columns.1.x), Double(m.columns.1.y),
                          Double(m.columns.1.z), Double(m.columns.1.w)),
            SIMD4<Double>(Double(m.columns.2.x), Double(m.columns.2.y),
                          Double(m.columns.2.z), Double(m.columns.2.w)),
            SIMD4<Double>(Double(m.columns.3.x), Double(m.columns.3.y),
                          Double(m.columns.3.z), Double(m.columns.3.w)))
    }

    // MARK: Transform decomposition

    struct Decomposed {
        var translation: Vec3
        var rotation: Quat
        var scale: Vec3
        var isMirrored: Bool
        var hasShear: Bool
    }

    /// Splits an affine matrix into translation, a proper rotation and a
    /// per-axis scale. Kinetic poses are rigid, so the scale has to leave the
    /// pose and be baked into vertices instead.
    static func decompose(_ m: simd_double4x4) -> Decomposed {
        let translation = Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var c0 = Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        var c1 = Vec3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        var c2 = Vec3(m.columns.2.x, m.columns.2.y, m.columns.2.z)

        var sx = c0.length, sy = c1.length, sz = c2.length
        guard sx > 1e-12, sy > 1e-12, sz > 1e-12 else {
            // A collapsed axis carries no orientation information; the only
            // honest reading is "no rotation, degenerate scale".
            return Decomposed(translation: translation, rotation: .identity,
                              scale: Vec3(max(sx, 0), max(sy, 0), max(sz, 0)),
                              isMirrored: false, hasShear: false)
        }
        c0 /= sx
        c1 /= sy
        c2 /= sz

        // A negative determinant is a reflection. Fold it onto X so what is left
        // is a proper rotation; the sign travels with the baked scale.
        let mirrored = c0.dot(c1.cross(c2)) < 0
        if mirrored {
            c0 = -c0
            sx = -sx
        }

        let shear = max(abs(c0.dot(c1)), max(abs(c0.dot(c2)), abs(c1.dot(c2))))

        // Gram-Schmidt so the quaternion extraction sees a genuinely orthonormal
        // basis even when the input was slightly sheared.
        let e0 = c0.normalized
        let e1 = (c1 - e0 * e0.dot(c1)).normalized
        let e2 = e0.cross(e1)

        let basis = simd_double3x3(columns: (e0, e1, e2))
        return Decomposed(translation: translation,
                          rotation: Quat(simd_quatd(basis)).normalized,
                          scale: Vec3(sx, sy, sz),
                          isMirrored: mirrored,
                          hasShear: shear > 1e-6)
    }

    // MARK: Mesh extraction

    private static func describe(_ type: MDLGeometryType) -> String {
        switch type {
        case .points: return "points"
        case .lines: return "lines"
        case .triangles: return "triangles"
        case .triangleStrips: return "triangle strips"
        case .quads: return "quads"
        case .variableTopology: return "variable topology"
        @unknown default: return "unknown topology"
        }
    }

    /// Pulls positions and triangle indices out of an `MDLMesh` and packages
    /// them as `LoadedMesh` values, applying unit scale, baked scale and the
    /// up-axis rotation to every vertex.
    private static func loadedMeshes(from mesh: MDLMesh, path: String,
                                     unitScale: Double, bakedScale: Vec3,
                                     reverseWinding: Bool, rotation: Quat,
                                     options: USDImportOptions) -> [LoadedMesh] {
        guard let attribute = mesh.vertexAttributeData(
                forAttributeNamed: MDLVertexAttributePosition, as: .float3),
              mesh.vertexCount > 0
        else {
            options.onWarning?("\(path): mesh has no float3 position attribute; skipped")
            return []
        }

        // Positions are read once and transformed once. The order matters:
        // authored units → metres, then the node's baked scale, then the
        // Y-up→Z-up rotation. Doing the rotation last is what keeps it
        // consistent with the conjugated node transform.
        var positions = [Vec3]()
        positions.reserveCapacity(mesh.vertexCount)
        // `attribute` owns the mapping that `dataStart` points into, so it has
        // to outlive the read.
        withExtendedLifetime(attribute) {
            let step = attribute.stride
            let base = attribute.dataStart
            for i in 0..<mesh.vertexCount {
                let p = base.advanced(by: i * step).assumingMemoryBound(to: Float.self)
                let raw = Vec3(Double(p[0]), Double(p[1]), Double(p[2])) * unitScale
                positions.append(rotation.rotate(raw * bakedScale))
            }
        }

        var parts: [(name: String, indices: [UInt32])] = []
        var merged: [UInt32] = []

        // Index of the first corner of each complete triangle. A trailing
        // partial triangle is ignored rather than read past the end.
        func triangleStarts(_ count: Int) -> StrideTo<Int> {
            stride(from: 0, to: max(count - 2, 0), by: 3)
        }

        for case let submesh as MDLSubmesh in (mesh.submeshes ?? []) {
            guard submesh.geometryType == .triangles else {
                options.onWarning?(
                    "\(path): submesh '\(submesh.name)' is \(describe(submesh.geometryType)), "
                    + "not triangles; skipped")
                continue
            }
            var indices = readIndices(submesh, vertexCount: positions.count)
            guard !indices.isEmpty else { continue }
            if reverseWinding {
                for t in triangleStarts(indices.count) { indices.swapAt(t + 1, t + 2) }
            }
            if options.mergeSubmeshes {
                merged.append(contentsOf: indices)
            } else {
                parts.append((submesh.name.isEmpty ? "submesh\(parts.count)" : submesh.name,
                              indices))
            }
        }
        if options.mergeSubmeshes && !merged.isEmpty {
            parts = [(lastComponent(of: path), merged)]
        }

        var result: [LoadedMesh] = []
        for part in parts {
            // Per-material parts share the mesh's point set, so compact each
            // one down to the vertices it actually references.
            let (vertices, indices) = options.mergeSubmeshes
                ? (positions, part.indices)
                : compact(positions: positions, indices: part.indices)
            guard !vertices.isEmpty, indices.count >= 3 else { continue }
            if let loaded = makeLoadedMesh(name: part.name, vertices: vertices, indices: indices,
                                           options: options) {
                result.append(loaded)
            }
        }
        if result.isEmpty {
            options.onWarning?("\(path): no triangulated geometry could be read from this mesh")
        }
        return result
    }

    /// Start offsets of every whole triangle in an index run.
    private static func triangleStarts(_ count: Int) -> StrideTo<Int> {
        Swift.stride(from: 0, to: count - count % 3, by: 3)
    }

    private static func readIndices(_ submesh: MDLSubmesh, vertexCount: Int) -> [UInt32] {
        // `indexBuffer(asIndexType:)` widens 8- and 16-bit index buffers for us,
        // so there is only one width to handle here.
        let buffer = submesh.indexBuffer(asIndexType: .uInt32)
        let available = buffer.length / MemoryLayout<UInt32>.size
        let count = min(submesh.indexCount, available)
        guard count >= 3 else { return [] }
        var indices = [UInt32]()
        indices.reserveCapacity(count - count % 3)
        // The map owns the pointer, so it has to outlive the read.
        let map = buffer.map()
        withExtendedLifetime(map) {
            let raw = map.bytes.assumingMemoryBound(to: UInt32.self)
            // Triangles referencing out-of-range vertices are dropped rather
            // than clamped: a clamped index is a silently wrong triangle.
            for t in triangleStarts(count) {
                let a = raw[t], b = raw[t + 1], c = raw[t + 2]
                guard Int(a) < vertexCount, Int(b) < vertexCount, Int(c) < vertexCount else {
                    continue
                }
                indices.append(contentsOf: [a, b, c])
            }
        }
        return indices
    }

    private static func compact(positions: [Vec3],
                                indices: [UInt32]) -> (vertices: [Vec3], indices: [UInt32]) {
        var remap = [Int32](repeating: -1, count: positions.count)
        var vertices: [Vec3] = []
        var out = [UInt32]()
        out.reserveCapacity(indices.count)
        for index in indices {
            let i = Int(index)
            if remap[i] < 0 {
                remap[i] = Int32(vertices.count)
                vertices.append(positions[i])
            }
            out.append(UInt32(remap[i]))
        }
        return (vertices, out)
    }

    /// Builds a `LoadedMesh` exactly the way `MeshLoader` does — same hull call,
    /// same bounds, same fallback flag — so collision behaviour is identical to
    /// any other imported mesh.
    private static func makeLoadedMesh(name: String, vertices: [Vec3], indices: [UInt32],
                                       options: USDImportOptions) -> LoadedMesh? {
        guard let first = vertices.first else { return nil }
        let hull = ConvexHull.compute(points: vertices, maxVertices: options.maxHullVertices)
        var lo = first, hi = first
        var radius = 0.0
        for v in vertices {
            lo = Vec3(min(lo.x, v.x), min(lo.y, v.y), min(lo.z, v.z))
            hi = Vec3(max(hi.x, v.x), max(hi.y, v.y), max(hi.z, v.z))
            radius = max(radius, v.length)
        }
        if hull.isDegenerate {
            options.onWarning?(
                "'\(name)': the convex hull degenerated (flat or near-empty geometry); "
                + "its oriented bounding box is being used for collision instead")
        }
        return LoadedMesh(name: name, vertices: vertices, indices: indices,
                          hullVertices: hull.vertices, hullIndices: hull.indices,
                          boundingRadius: radius, aabbMin: lo, aabbMax: hi,
                          volume: hull.volume, centroid: hull.centroid,
                          usedFallbackHull: hull.isDegenerate)
    }

    // MARK: addToWorld

    /// Registers every mesh in the stage with `world` and creates geoms for it.
    ///
    /// When `options.importPhysics` is set and the layer is ASCII with
    /// recoverable UsdPhysics prims, the articulation is built by
    /// `USDPhysics.buildArticulation` from values that were actually authored.
    /// Otherwise the asset is imported as geometry under `options.bodyPolicy`
    /// and every mass is derived from convex hull volume × `options.density` —
    /// a number the stage never stated, so a warning is emitted for each body.
    @discardableResult
    public static func addToWorld(_ url: URL, world: World,
                                  options: USDImportOptions = USDImportOptions()) throws -> Robot {
        let layer = encoding(of: url)
        let geometry = try loadGeometry(contentsOf: url, options: options)

        if options.importPhysics {
            if let text = asciiText(of: url, encoding: layer) {
                let scene = USDPhysics.parse(text)
                if scene.bodies.contains(where: \.isRigidBody) {
                    for note in scene.unsupported { options.onWarning?("unsupported: \(note)") }
                    // The rotation has to match the one `loadGeometry` used, or
                    // joint frames and mesh vertices would disagree.
                    let rotation = resolvedUpAxisRotation(asset: MDLAsset(url: url),
                                                          options: options)
                    return try USDPhysics.buildArticulation(
                        scene, geometry: geometry, world: world,
                        unitScale: resolvedUnitScale(url: url, encoding: layer, options: options),
                        upAxisRotation: rotation,
                        density: options.density,
                        material: options.material,
                        appearance: options.appearance,
                        selfCollision: options.selfCollision,
                        onWarning: options.onWarning)
                }
                if options.requirePhysics {
                    throw USDImportError.physicsSchemaNotExposed(
                        url: url, encoding: layer,
                        detail: "This ASCII layer declares no PhysicsRigidBodyAPI prims; "
                            + "the physics may live in a referenced layer that ModelIO composed "
                            + "for geometry but that this text parser never opened.")
                }
                options.onWarning?(
                    "no UsdPhysics rigid bodies were found in this layer; importing geometry only")
            } else if options.requirePhysics {
                throw USDImportError.physicsSchemaNotExposed(
                    url: url, encoding: layer,
                    detail: "Nothing in this layer can be text-parsed.")
            } else if layer != .ascii {
                options.onWarning?(
                    "\(layer.rawValue) layer: UsdPhysics is not recoverable, because ModelIO "
                    + "exposes no part of that schema and this encoding cannot be text-parsed. "
                    + "Importing geometry only.")
            }
        }

        return buildGeometryOnly(url: url, geometry: geometry, world: world, options: options)
    }

    /// The geometry-only path. Everything inertial here is DERIVED, never read.
    private static func buildGeometryOnly(url: URL, geometry: [USDNode], world: World,
                                          options: USDImportOptions) -> Robot {
        let assetName = url.deletingPathExtension().lastPathComponent
        let articulation = world.addArticulation(name: assetName)
        var linkNames: [String] = []
        var defaultPose: [Double] = []

        options.onWarning?(
            "importing geometry only: no UsdPhysics values are being read, so every mass below is "
            + "derived as convex hull volume × \(options.density) kg/m³ and every inertia tensor "
            + "is that hull's own, computed about that mass. These are Kinetic's numbers, not the "
            + "asset's.")

        switch options.bodyPolicy {
        case .staticGeometry:
            // One fixed root, one fixed child link per mesh-bearing prim. Zero
            // degrees of freedom: this is scenery.
            let root = world.addLink(articulation: articulation, parent: -1, name: assetName)
            world.setJoint(articulation: articulation, link: root, .fixed)
            world.setInertial(articulation: articulation, link: root, mass: 1,
                              com: .zero, inertia: Inertia.sphere(mass: 1, radius: 0.1))
            linkNames.append(assetName)

            for node in geometry.flattened where !node.meshes.isEmpty {
                let name = uniqueName(node, taken: linkNames)
                let link = world.addLink(articulation: articulation, parent: root, name: name)
                var joint = JointSpec(kind: .fixed)
                joint.origin = node.worldTransform
                world.setJoint(articulation: articulation, link: link, joint)
                applyInertial(node: node, articulation: articulation, link: link,
                              world: world, density: options.density)
                addGeoms(for: node, articulation: articulation, link: link, world: world,
                         localPose: .identity, options: options)
                linkNames.append(name)
            }

        case .freeBodyPerTopLevelPrim:
            // Kinetic stores an articulation's links as a parent-indexed forest
            // and treats parent < 0 as "anchored to the world frame", so several
            // free-jointed roots in one articulation is legal and keeps the
            // whole import addressable through a single Robot handle.
            for prim in topLevelBodies(in: geometry, options: options) {
                let name = uniqueName(prim, taken: linkNames)
                let root = world.addLink(articulation: articulation, parent: -1, name: name)
                world.setJoint(articulation: articulation, link: root, .free)
                let subtree = prim.flattened.filter { !$0.meshes.isEmpty }
                applyInertial(nodes: subtree, base: prim.worldTransform,
                              articulation: articulation, link: root,
                              world: world, density: options.density)
                linkNames.append(name)

                // The body's own frame is the prim's world pose; the free
                // joint's coordinates carry it, so the geoms are placed
                // relative to that frame.
                let inverse = prim.worldTransform.inverse
                for node in subtree {
                    addGeoms(for: node, articulation: articulation, link: root, world: world,
                             localPose: inverse * node.worldTransform, options: options)
                }
                let p = prim.worldTransform
                defaultPose += [p.position.x, p.position.y, p.position.z,
                                p.orientation.w, p.orientation.x, p.orientation.y,
                                p.orientation.z]
            }
            if !defaultPose.isEmpty {
                world.setDefaultPose(articulation: articulation, q: defaultPose)
            }
        }

        world.setSelfCollision(articulation: articulation, enabled: options.selfCollision)
        return Robot(articulation: articulation, name: assetName, links: linkNames, actuators: [])
    }

    /// The prims that become free bodies. A stage root that owns no geometry of
    /// its own is a container (`/World` is near-universal in Omniverse assets),
    /// so its children are used instead. Prims whose whole subtree is empty of
    /// geometry — joint prims, scopes, lights — are not bodies at all. The
    /// choice is always reported.
    private static func topLevelBodies(in geometry: [USDNode],
                                       options: USDImportOptions) -> [USDNode] {
        var result: [USDNode] = []
        for root in geometry {
            if root.meshes.isEmpty && !root.children.isEmpty {
                let candidates = root.children.filter { child in
                    child.flattened.contains { !$0.meshes.isEmpty }
                }
                options.onWarning?(
                    "'\(root.path)' owns no geometry, so its \(candidates.count) mesh-bearing "
                    + "child prim(s) became the free bodies instead of the root itself")
                result.append(contentsOf: candidates)
            } else if !root.flattened.allSatisfy(\.meshes.isEmpty) {
                result.append(root)
            }
        }
        return result
    }

    private static func uniqueName(_ node: USDNode, taken: [String]) -> String {
        let base = node.path.isEmpty
            ? node.name
            : node.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: ".")
        guard taken.contains(base) else { return base }
        var i = 1
        while taken.contains("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }

    private static func addGeoms(for node: USDNode, articulation: Int, link: Int, world: World,
                                 localPose: Pose, options: USDImportOptions) {
        for mesh in node.meshes {
            guard !mesh.hullVertices.isEmpty else { continue }
            let hullIndex = world.addMesh(vertices: mesh.hullVertices, indices: mesh.hullIndices,
                                          name: "\(mesh.name).hull")
            let hullShape = Shape.convexHull(mesh: hullIndex,
                                             boundingRadius: mesh.boundingRadius)
            var collision = GeomSpec(shape: hullShape, localPose: localPose,
                                     material: options.material,
                                     appearance: options.appearance,
                                     collidable: true,
                                     visible: !options.separateVisualAndCollision,
                                     name: "\(node.name).collision")
            collision.appearance = options.appearance
            world.addGeom(articulation: articulation, link: link, collision)

            guard options.separateVisualAndCollision, !mesh.indices.isEmpty else { continue }
            // The authored triangles, for rendering only. USD has no
            // visual/collision split, so this pair is Kinetic's doing.
            let visualIndex = world.addMesh(vertices: mesh.vertices, indices: mesh.indices,
                                            name: mesh.name)
            let visual = GeomSpec(
                shape: .convexHull(mesh: visualIndex, boundingRadius: mesh.boundingRadius),
                localPose: localPose, material: options.material,
                appearance: options.appearance, collidable: false, visible: true,
                name: node.name)
            world.addGeom(articulation: articulation, link: link, visual)
        }
    }

    // MARK: Derived inertia

    static func applyInertial(node: USDNode, articulation: Int, link: Int, world: World,
                              density: Double) {
        applyInertial(nodes: [node], base: node.worldTransform, articulation: articulation,
                      link: link, world: world, density: density)
    }

    /// Sums the convex hulls of `nodes`, expressed in the frame `base`, and
    /// installs the resulting mass, centre of mass and inertia tensor.
    ///
    /// The tensor is exact for the union of hulls (they are integrated
    /// individually and combined with the parallel axis theorem); only the
    /// density is an assumption, and callers announce it.
    static func applyInertial(nodes: [USDNode], base: Pose, articulation: Int, link: Int,
                              world: World, density: Double) {
        let toBase = base.inverse
        var totalMass = 0.0
        var weightedCom = Vec3.zero
        var pieces: [(mass: Double, com: Vec3, inertia: [Double])] = []

        for node in nodes {
            let toLink = toBase * node.worldTransform
            for mesh in node.meshes where mesh.volume > 1e-12 {
                let mass = mesh.volume * density
                guard let solid = USDInertia.hull(vertices: mesh.hullVertices,
                                                  indices: mesh.hullIndices,
                                                  mass: mass) else { continue }
                let com = toLink.apply(solid.centerOfMass)
                let rotated = USDInertia.rotate(solid.inertia, by: toLink.orientation)
                pieces.append((mass, com, rotated))
                totalMass += mass
                weightedCom += com * mass
            }
        }

        guard totalMass > 1e-12 else {
            // No usable volume. A tiny point mass keeps the mass matrix
            // positive definite without pretending to describe the asset.
            let mass = 1e-3
            world.setInertial(articulation: articulation, link: link, mass: mass, com: .zero,
                              inertia: Inertia.sphere(mass: mass, radius: 0.01))
            return
        }

        let com = weightedCom / totalMass
        var inertia = [Double](repeating: 0, count: 9)
        for piece in pieces {
            let d = piece.com - com
            let d2 = d.dot(d)
            // Parallel axis: I += m (|d|² δ − d dᵀ)
            inertia[0] += piece.inertia[0] + piece.mass * (d2 - d.x * d.x)
            inertia[1] += piece.inertia[1] - piece.mass * d.x * d.y
            inertia[2] += piece.inertia[2] - piece.mass * d.x * d.z
            inertia[3] += piece.inertia[3] - piece.mass * d.y * d.x
            inertia[4] += piece.inertia[4] + piece.mass * (d2 - d.y * d.y)
            inertia[5] += piece.inertia[5] - piece.mass * d.y * d.z
            inertia[6] += piece.inertia[6] - piece.mass * d.z * d.x
            inertia[7] += piece.inertia[7] - piece.mass * d.z * d.y
            inertia[8] += piece.inertia[8] + piece.mass * (d2 - d.z * d.z)
        }
        world.setInertial(articulation: articulation, link: link, mass: totalMass, com: com,
                          inertia: inertia)
    }
}

// MARK: - Inertia of a closed triangle mesh

/// Exact rigid-body integrals over a closed triangle mesh, by signed
/// tetrahedron decomposition about the origin.
///
/// This is used only to turn a mass into an inertia tensor; the mass itself
/// always comes from somewhere the caller can name. Using the mesh's own
/// integral rather than a bounding-box approximation matters for anything long
/// and thin, which is most robot links.
enum USDInertia {

    struct Solid {
        var volume: Double
        var centerOfMass: Vec3
        /// Row-major 3×3 about `centerOfMass`.
        var inertia: [Double]
    }

    static func hull(vertices: [Vec3], indices: [UInt32], mass: Double) -> Solid? {
        guard indices.count >= 3, mass > 0 else { return nil }

        var volume = 0.0
        var firstMoment = Vec3.zero
        // Second-moment (covariance) integral ∫ x xᵀ dV, row-major.
        var covariance = [Double](repeating: 0, count: 9)

        var t = 0
        while t + 2 < indices.count {
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            t += 3
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]

            // Six times the signed volume of the tetrahedron (0, a, b, c).
            let det = a.dot(b.cross(c))
            volume += det / 6
            firstMoment += (a + b + c) * (det / 24)

            // ∫ x xᵀ over that tetrahedron:
            //   (det/120) · (aaᵀ + bbᵀ + ccᵀ + ssᵀ), s = a + b + c
            let s = a + b + c
            let k = det / 120
            addOuter(&covariance, a, k)
            addOuter(&covariance, b, k)
            addOuter(&covariance, c, k)
            addOuter(&covariance, s, k)
        }

        // An inward-wound mesh integrates to a negative volume; the magnitudes
        // are still right, so flip the sign rather than reject the mesh.
        if volume < 0 {
            volume = -volume
            firstMoment = -firstMoment
            for i in covariance.indices { covariance[i] = -covariance[i] }
        }
        guard volume > 1e-15 else { return nil }

        let com = firstMoment / volume
        let density = mass / volume
        for i in covariance.indices { covariance[i] *= density }

        // I = trace(C)·δ − C, about the origin.
        let trace = covariance[0] + covariance[4] + covariance[8]
        var inertia = [Double](repeating: 0, count: 9)
        for i in 0..<9 { inertia[i] = -covariance[i] }
        inertia[0] += trace
        inertia[4] += trace
        inertia[8] += trace

        // Shift to the centre of mass: I_com = I_origin − m(|c|²δ − c cᵀ).
        let c2 = com.dot(com)
        inertia[0] -= mass * (c2 - com.x * com.x)
        inertia[1] += mass * com.x * com.y
        inertia[2] += mass * com.x * com.z
        inertia[3] += mass * com.y * com.x
        inertia[4] -= mass * (c2 - com.y * com.y)
        inertia[5] += mass * com.y * com.z
        inertia[6] += mass * com.z * com.x
        inertia[7] += mass * com.z * com.y
        inertia[8] -= mass * (c2 - com.z * com.z)

        return Solid(volume: volume, centerOfMass: com, inertia: inertia)
    }

    private static func addOuter(_ m: inout [Double], _ v: Vec3, _ k: Double) {
        m[0] += k * v.x * v.x
        m[1] += k * v.x * v.y
        m[2] += k * v.x * v.z
        m[3] += k * v.y * v.x
        m[4] += k * v.y * v.y
        m[5] += k * v.y * v.z
        m[6] += k * v.z * v.x
        m[7] += k * v.z * v.y
        m[8] += k * v.z * v.z
    }

    /// R · I · Rᵀ for a row-major 3×3.
    static func rotate(_ inertia: [Double], by q: Quat) -> [Double] {
        guard inertia.count == 9, q != .identity else { return inertia }
        let r = [q.rotate(Vec3(1, 0, 0)), q.rotate(Vec3(0, 1, 0)), q.rotate(Vec3(0, 0, 1))]
        // r[j] is column j of R, so R[i][j] = r[j][i].
        func rot(_ i: Int, _ j: Int) -> Double { r[j][i] }
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    for l in 0..<3 {
                        sum += rot(i, k) * inertia[k * 3 + l] * rot(j, l)
                    }
                }
                out[i * 3 + j] = sum
            }
        }
        return out
    }
}
