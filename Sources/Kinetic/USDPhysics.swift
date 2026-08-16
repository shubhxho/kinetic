//
//  USDPhysics.swift
//  Kinetic
//
//  Best-effort recovery of the UsdPhysics schema from ASCII USD.
//
//  Why this file exists at all: ModelIO composes a USD stage and hands back its
//  geometry, but exposes no part of UsdPhysics. There is no ModelIO selector for
//  `physics:mass`, for a `PhysicsRevoluteJoint`, or for an articulation root. So
//  for `.usda` layers — which are plain text — the schema is read back out of
//  the source instead. Binary crate (`.usdc`) and packages (`.usdz`) are not
//  parsed here; they are detected and refused, because a half-decoded crate file
//  would produce plausible-looking nonsense.
//
//  Two limits are worth stating plainly, because they bound what this file can
//  ever return:
//
//    1. This is a *layer* parser, not a composition engine. References,
//       payloads, sublayers, variants, inherits and specializes are recorded as
//       unsupported, not followed. ModelIO's geometry is fully composed; the
//       physics recovered here is only what the given file itself spells out.
//       For a stage that references its robot from another layer, geometry will
//       be complete and physics will be empty — and `coverage` will say so.
//
//    2. Values are stored exactly as authored. USD writes revolute joint limits
//       in degrees and lengths in stage units; the conversion to radians and
//       metres happens in `buildArticulation`, where the stage's
//       `metersPerUnit` is known, and never silently inside the parser.
//

import Foundation

// MARK: - Recovered values

/// Stage metadata from the leading `( ... )` block of an ASCII layer.
public struct USDStageInfo: Sendable {
    public var upAxis: String?
    public var metersPerUnit: Double?
    public var kilogramsPerUnit: Double?
    public var defaultPrim: String?

    public init(upAxis: String? = nil, metersPerUnit: Double? = nil,
                kilogramsPerUnit: Double? = nil, defaultPrim: String? = nil) {
        self.upAxis = upAxis
        self.metersPerUnit = metersPerUnit
        self.kilogramsPerUnit = kilogramsPerUnit
        self.defaultPrim = defaultPrim
    }
}

/// A prim that carries at least one UsdPhysics API schema.
///
/// Every optional here is `nil` when the stage did not author it. Nothing is
/// filled in with a default: a `nil` mass means "this file does not say", which
/// is materially different from "this file says zero".
public struct USDPhysicsBody: Sendable {
    public var path: String
    public var name: String
    /// `PhysicsRigidBodyAPI` applied — this prim is a dynamic body.
    public var isRigidBody: Bool = false
    /// `PhysicsArticulationRootAPI` applied.
    public var isArticulationRoot: Bool = false
    /// `PhysicsCollisionAPI` applied on this prim or a descendant gprim.
    public var hasCollision: Bool = false
    /// `physics:rigidBodyEnabled = false` — present but disabled.
    public var rigidBodyEnabled: Bool = true
    /// `physics:kinematicEnabled` — animated, not dynamically simulated.
    public var isKinematic: Bool = false

    /// `physics:mass`, in kilograms. USD masses are absolute, so this needs no
    /// unit conversion.
    public var mass: Double?
    /// `physics:density`, in mass per cubic *stage unit*. Dividing by
    /// `metersPerUnit³` converts it to kg/m³.
    public var density: Double?
    /// `physics:centerOfMass`, in stage units, in the prim's local frame.
    public var centerOfMass: Vec3?
    /// `physics:diagonalInertia`, in mass · stage-unit².
    public var diagonalInertia: Vec3?
    /// `physics:principalAxes`, the frame `diagonalInertia` is expressed in.
    public var principalAxes: Quat?

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public enum USDPhysicsJointKind: String, Sendable {
    case revolute
    case prismatic
    case fixed
    case spherical
}

/// A recovered joint prim. Positions are in stage units and angular limits are
/// in degrees, exactly as USD authors them.
public struct USDPhysicsJoint: Sendable {
    public var path: String
    public var name: String
    public var kind: USDPhysicsJointKind
    /// `physics:body0` — the parent side. `nil` or empty means the joint is
    /// anchored to the world.
    public var body0: String?
    /// `physics:body1` — the child side.
    public var body1: String?
    /// `physics:axis`, resolved from the `"X"`, `"Y"` or `"Z"` token. USD's
    /// default when the attribute is absent is X.
    public var axis: Vec3 = Vec3(1, 0, 0)
    public var axisToken: String?
    /// `physics:localPos0` / `physics:localRot0` — the joint frame in body0.
    public var localPos0: Vec3 = .zero
    public var localRot0: Quat = .identity
    /// `physics:localPos1` / `physics:localRot1` — the joint frame in body1.
    public var localPos1: Vec3 = .zero
    public var localRot1: Quat = .identity
    /// Degrees for revolute and spherical joints, stage units for prismatic.
    /// USD signals "unlimited" with a lower bound above the upper bound, or with
    /// ±inf; both are reported here as `isLimited == false`.
    public var lowerLimit: Double?
    public var upperLimit: Double?
    public var jointEnabled: Bool = true
    /// `PhysicsDriveAPI` gains, when authored. Kinetic only creates an actuator
    /// for a joint whose drive the stage actually declared.
    public var driveStiffness: Double?
    public var driveDamping: Double?
    public var driveMaxForce: Double?
    public var driveTargetPosition: Double?

    public var isLimited: Bool {
        guard let lower = lowerLimit, let upper = upperLimit else { return false }
        return lower.isFinite && upper.isFinite && lower <= upper
    }

    public init(path: String, name: String, kind: USDPhysicsJointKind) {
        self.path = path
        self.name = name
        self.kind = kind
    }
}

/// Everything the parser managed to recover, plus an honest account of what it
/// did not.
public struct USDPhysicsScene: Sendable {
    public var stage: USDStageInfo = USDStageInfo()
    public var bodies: [USDPhysicsBody] = []
    public var joints: [USDPhysicsJoint] = []

    /// Total prims seen in this layer.
    public var primCount: Int = 0
    /// Prims whose type and applied API schemas were all recognised.
    public var understoodPrimCount: Int = 0

    /// `understoodPrimCount / primCount`, or 1 for an empty layer. A low value
    /// means this file is doing something the parser does not model; read
    /// `unsupported` before trusting the result.
    public var coverage: Double {
        primCount == 0 ? 1 : Double(understoodPrimCount) / Double(primCount)
    }

    /// One line per thing that was seen and deliberately not modelled, prefixed
    /// with the prim path it came from.
    public var unsupported: [String] = []

    /// UsdPhysics type and schema names that were actually encountered.
    public var recognisedSchemaNames: [String] = []

    public init() {}
}

// MARK: - Parser

public enum USDPhysics {

    // MARK: Known vocabulary

    /// Prim types this parser understands. Geometry types are listed because
    /// ModelIO handles them, so encountering one is not a gap.
    private static let knownPrimTypes: Set<String> = [
        "", "Xform", "Scope", "Mesh", "Cube", "Sphere", "Cylinder", "Capsule", "Cone", "Plane",
        "Points", "BasisCurves", "NurbsPatch", "GeomSubset", "Material", "Shader", "NodeGraph",
        "Camera", "DomeLight", "DistantLight", "SphereLight", "RectLight", "DiskLight",
        "CylinderLight", "PhysicsScene", "PhysicsMaterial", "PhysicsCollisionGroup",
        "PhysicsRevoluteJoint", "PhysicsPrismaticJoint", "PhysicsFixedJoint",
        "PhysicsSphericalJoint",
    ]

    private static let jointTypes: [String: USDPhysicsJointKind] = [
        "PhysicsRevoluteJoint": .revolute,
        "PhysicsPrismaticJoint": .prismatic,
        "PhysicsFixedJoint": .fixed,
        "PhysicsSphericalJoint": .spherical,
    ]

    /// API schemas whose attributes this parser reads.
    private static let knownSchemas: Set<String> = [
        "PhysicsRigidBodyAPI", "PhysicsMassAPI", "PhysicsCollisionAPI",
        "PhysicsArticulationRootAPI", "PhysicsDriveAPI", "PhysicsJointStateAPI",
        "PhysicsMaterialAPI",
    ]

    /// Prim metadata that composes other layers into this one. ModelIO follows
    /// these for geometry; this text parser does not.
    private static let compositionArcs = [
        "references", "payload", "inherits", "specializes", "variantSets", "variants",
    ]

    // MARK: Entry points

    /// Reads the stage metadata block at the top of an ASCII layer.
    ///
    /// Deliberately independent of the prim walk: `metersPerUnit` is needed by
    /// the geometry importer before any physics question is asked.
    public static func stageInfo(_ text: String) -> USDStageInfo {
        var info = USDStageInfo()
        // Stage metadata precedes the first prim, so stop at the first
        // specifier keyword at the start of a line.
        var header = text
        if let stop = firstPrimSpecifierIndex(text) { header = String(text[text.startIndex..<stop]) }

        info.metersPerUnit = doubleAssignment(named: "metersPerUnit", in: header)
        info.kilogramsPerUnit = doubleAssignment(named: "kilogramsPerUnit", in: header)
        info.upAxis = stringAssignment(named: "upAxis", in: header)
        info.defaultPrim = stringAssignment(named: "defaultPrim", in: header)
        return info
    }

    /// Parses the UsdPhysics content of an ASCII USD layer.
    ///
    /// Never throws and never fails: a file it does not understand yields an
    /// empty scene with a low `coverage` and a populated `unsupported`, which is
    /// the honest report.
    public static func parse(_ text: String) -> USDPhysicsScene {
        var scene = USDPhysicsScene()
        scene.stage = stageInfo(text)

        var stack: [PrimFrame] = []
        var bodies: [String: USDPhysicsBody] = [:]
        var bodyOrder: [String] = []
        var joints: [String: USDPhysicsJoint] = [:]
        var jointOrder: [String] = []
        var schemas = Set<String>()

        /// Marks the nearest enclosing body prim as carrying collision geometry,
        /// which is how `PhysicsCollisionAPI` on a child Mesh is usually
        /// authored.
        func markCollisionOnAncestor() {
            // `dropLast` skips the prim that carries the schema itself; the
            // point is to tell the enclosing rigid body that it has collision
            // geometry, which is how Isaac assets usually author it.
            for frame in stack.dropLast().reversed() where bodies[frame.path] != nil {
                bodies[frame.path]?.hasCollision = true
                return
            }
        }

        scan(text) { event in
            switch event {
            case .prim(let header):
                let prim = parsePrimHeader(header, parentPath: stack.last?.path ?? "")
                stack.append(prim)
                scene.primCount += 1

                var understood = knownPrimTypes.contains(prim.type)
                if !understood {
                    scene.unsupported.append("\(prim.path): prim type '\(prim.type)' is not modelled")
                }
                for schema in prim.appliedSchemas {
                    // Multiple-apply schemas are namespaced, e.g.
                    // "PhysicsDriveAPI:angular"; compare on the base name.
                    let base = String(schema.split(separator: ":").first ?? "")
                    if knownSchemas.contains(base) {
                        schemas.insert(base)
                    } else {
                        understood = false
                        scene.unsupported.append(
                            "\(prim.path): API schema '\(schema)' is not modelled")
                    }
                }
                for arc in prim.compositionArcs {
                    understood = false
                    scene.unsupported.append(
                        "\(prim.path): composes '\(arc)' from another layer, which this text "
                        + "parser does not follow — ModelIO resolved it for geometry, but any "
                        + "physics it contributes is invisible here")
                }
                if understood { scene.understoodPrimCount += 1 }

                if let kind = jointTypes[prim.type] {
                    schemas.insert(prim.type)
                    joints[prim.path] = USDPhysicsJoint(path: prim.path, name: prim.name,
                                                        kind: kind)
                    jointOrder.append(prim.path)
                } else if prim.type.hasPrefix("Physics") && prim.type.hasSuffix("Joint") {
                    scene.unsupported.append(
                        "\(prim.path): '\(prim.type)' has no single-degree-of-freedom equivalent "
                        + "in Kinetic; model it with World.connect or World.weld")
                }

                // Joint prims routinely apply PhysicsDriveAPI and friends, but
                // they are joints, not bodies; recording them as both would
                // send every joint attribute through the body handler too.
                let physicsSchemas = joints[prim.path] == nil
                    ? prim.appliedSchemas.filter { $0.hasPrefix("Physics") }
                    : []
                if !physicsSchemas.isEmpty {
                    var body = USDPhysicsBody(path: prim.path, name: prim.name)
                    body.isRigidBody = physicsSchemas.contains { $0.hasPrefix("PhysicsRigidBodyAPI") }
                    body.isArticulationRoot = physicsSchemas.contains {
                        $0.hasPrefix("PhysicsArticulationRootAPI")
                    }
                    body.hasCollision = physicsSchemas.contains {
                        $0.hasPrefix("PhysicsCollisionAPI")
                    }
                    bodies[prim.path] = body
                    bodyOrder.append(prim.path)
                    if body.hasCollision && !body.isRigidBody { markCollisionOnAncestor() }
                }

            case .close:
                if !stack.isEmpty { stack.removeLast() }

            case .statement(let text):
                guard let current = stack.last,
                      let assignment = parseAssignment(text) else { return }
                if joints[current.path] != nil {
                    apply(assignment, to: &joints[current.path], scene: &scene, path: current.path)
                } else if bodies[current.path] != nil {
                    apply(assignment, to: &bodies[current.path], scene: &scene, path: current.path)
                } else if assignment.name.hasPrefix("physics:")
                            && !current.type.hasPrefix("Physics") {
                    // A physics attribute on a prim that applied no physics
                    // schema. Legal in USD but unusual; surface it rather than
                    // drop it.
                    scene.unsupported.append(
                        "\(current.path): '\(assignment.name)' is authored on a prim that applies "
                        + "no UsdPhysics schema and was not read")
                }
            }
        }

        scene.bodies = bodyOrder.compactMap { bodies[$0] }
        scene.joints = jointOrder.compactMap { joints[$0] }
        scene.recognisedSchemaNames = schemas.sorted()
        return scene
    }

    /// Reads a file, refusing binary layers explicitly rather than producing
    /// garbage from crate bytes.
    public static func parse(contentsOf url: URL) throws -> USDPhysicsScene {
        let encoding = USDImporter.encoding(of: url)
        guard encoding == .ascii else {
            throw USDImportError.binaryPhysicsUnreadable(url: url, encoding: encoding)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { throw USDImportError.unreadable(url) }
        return parse(text)
    }

    // MARK: Attribute application

    private static func apply(_ a: Assignment, to joint: inout USDPhysicsJoint?,
                              scene: inout USDPhysicsScene, path: String) {
        guard joint != nil else { return }
        switch a.name {
        case "physics:axis":
            let token = a.tokenValue
            joint?.axisToken = token
            switch token.uppercased() {
            case "X": joint?.axis = Vec3(1, 0, 0)
            case "Y": joint?.axis = Vec3(0, 1, 0)
            case "Z": joint?.axis = Vec3(0, 0, 1)
            default:
                scene.unsupported.append("\(path): unrecognised physics:axis '\(token)'")
            }
        case "physics:body0": joint?.body0 = a.pathValue
        case "physics:body1": joint?.body1 = a.pathValue
        case "physics:localPos0": if let v = a.vec3Value { joint?.localPos0 = v }
        case "physics:localPos1": if let v = a.vec3Value { joint?.localPos1 = v }
        case "physics:localRot0": if let q = a.quatValue { joint?.localRot0 = q }
        case "physics:localRot1": if let q = a.quatValue { joint?.localRot1 = q }
        case "physics:lowerLimit": joint?.lowerLimit = a.doubleValue
        case "physics:upperLimit": joint?.upperLimit = a.doubleValue
        case "physics:jointEnabled": joint?.jointEnabled = a.boolValue ?? true
        case "physics:excludeFromArticulation":
            if a.boolValue == true {
                scene.unsupported.append(
                    "\(path): physics:excludeFromArticulation is set; this joint would need a "
                    + "World equality constraint rather than an articulation joint")
            }
        default:
            // PhysicsDriveAPI attributes are namespaced by the drive axis, e.g.
            // "drive:angular:physics:stiffness".
            if a.name.hasPrefix("drive:") {
                if a.name.hasSuffix(":physics:stiffness") { joint?.driveStiffness = a.doubleValue }
                else if a.name.hasSuffix(":physics:damping") { joint?.driveDamping = a.doubleValue }
                else if a.name.hasSuffix(":physics:maxForce") { joint?.driveMaxForce = a.doubleValue }
                else if a.name.hasSuffix(":physics:targetPosition") {
                    joint?.driveTargetPosition = a.doubleValue
                }
            } else if a.name.hasPrefix("physics:") {
                scene.unsupported.append("\(path): joint attribute '\(a.name)' was not read")
            }
        }
    }

    private static func apply(_ a: Assignment, to body: inout USDPhysicsBody?,
                              scene: inout USDPhysicsScene, path: String) {
        guard body != nil else { return }
        switch a.name {
        case "physics:mass": body?.mass = a.doubleValue
        case "physics:density": body?.density = a.doubleValue
        case "physics:centerOfMass": body?.centerOfMass = a.vec3Value
        case "physics:diagonalInertia": body?.diagonalInertia = a.vec3Value
        case "physics:principalAxes": body?.principalAxes = a.quatValue
        case "physics:rigidBodyEnabled": body?.rigidBodyEnabled = a.boolValue ?? true
        case "physics:kinematicEnabled": body?.isKinematic = a.boolValue ?? false
        case "physics:collisionEnabled":
            if a.boolValue == false { body?.hasCollision = false }
        case "physics:approximation":
            // Convex decomposition, SDF meshes and the rest have no equivalent
            // here; Kinetic collides against one convex hull per mesh.
            let value = a.tokenValue
            if value != "convexHull" && !value.isEmpty {
                scene.unsupported.append(
                    "\(path): collision approximation '\(value)' is not available; Kinetic uses a "
                    + "single convex hull per mesh")
            }
        default:
            if a.name.hasPrefix("physics:") {
                scene.unsupported.append("\(path): body attribute '\(a.name)' was not read")
            }
        }
    }

    // MARK: Building an articulation

    /// Assembles a kinematic tree from a recovered scene.
    ///
    /// `geometry` should be the output of `USDImporter.loadGeometry` for the
    /// same file: bodies are matched to geometry by prim path, so the two must
    /// come from the same stage.
    ///
    /// Throws `USDImportError.kinematicLoop` when the joint graph is not a tree.
    /// Kinetic articulations are trees by construction; a loop has to be closed
    /// afterwards with an equality constraint, which `World.connect` (ball) and
    /// `World.weld` (rigid) provide.
    ///
    /// Everything read from the stage is used as authored. Only two things are
    /// ever derived, and both are announced through `onWarning`:
    ///   * a mass, when neither `physics:mass` nor `physics:density` was set;
    ///   * an inertia tensor, when `physics:diagonalInertia` was not set — and
    ///     that one is integrated exactly over the body's convex hulls.
    @discardableResult
    public static func buildArticulation(_ scene: USDPhysicsScene, geometry: [USDNode],
                                         world: World,
                                         unitScale: Double? = nil,
                                         upAxisRotation: Quat = USDImporter.yUpToZUp,
                                         density: Double = 1000,
                                         material: SurfaceMaterial = .default,
                                         appearance: Appearance = .default,
                                         selfCollision: Bool = false,
                                         onWarning: (@Sendable (String) -> Void)? = nil) throws
        -> Robot
    {
        let scale = unitScale ?? scene.stage.metersPerUnit ?? 1.0
        if unitScale == nil && scene.stage.metersPerUnit == nil {
            onWarning?("the stage declares no metersPerUnit; joint frames are being read as metres")
        }

        let bodies = scene.bodies.filter { $0.isRigidBody && $0.rigidBodyEnabled }
        guard !bodies.isEmpty else {
            throw USDImportError.noRigidBodies(URL(fileURLWithPath: scene.stage.defaultPrim ?? "/"))
        }
        let bodyByPath = Dictionary(bodies.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        // Index geometry by prim path so each body can claim its own subtree.
        let flat = geometry.flattened
        let nodeByPath = Dictionary(flat.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        // ── Joint graph ────────────────────────────────────────────────────
        // A joint's body1 is the child. A body with two incoming joints, or a
        // cycle, means the graph is not a tree.
        var incoming: [String: [USDPhysicsJoint]] = [:]
        var childrenOf: [String: [USDPhysicsJoint]] = [:]
        for joint in scene.joints where joint.jointEnabled {
            guard let child = joint.body1, bodyByPath[child] != nil else {
                if joint.body1 != nil {
                    onWarning?("joint '\(joint.path)' targets '\(joint.body1 ?? "")', which is not "
                               + "a PhysicsRigidBodyAPI prim in this layer; skipped")
                }
                continue
            }
            incoming[child, default: []].append(joint)
            if let parent = joint.body0, !parent.isEmpty, bodyByPath[parent] != nil {
                childrenOf[parent, default: []].append(joint)
            }
        }
        if let (path, all) = incoming.first(where: { $0.value.count > 1 }) {
            throw USDImportError.kinematicLoop(
                "'\(path)' is the child of \(all.count) joints "
                + "(\(all.map(\.name).joined(separator: ", ")))")
        }

        // ── Roots ──────────────────────────────────────────────────────────
        // A body is a root if nothing drives it, or if its only joint anchors it
        // to the world (body0 absent or not a body in this layer).
        var roots: [USDPhysicsBody] = []
        for body in bodies {
            let joints = incoming[body.path] ?? []
            if joints.isEmpty {
                roots.append(body)
            } else if let parent = joints[0].body0, !parent.isEmpty, bodyByPath[parent] != nil {
                continue
            } else {
                roots.append(body)
            }
        }
        guard !roots.isEmpty else {
            throw USDImportError.kinematicLoop(
                "every rigid body is the child of a joint, so the graph has no root")
        }

        let articulationRoot = scene.bodies.first(where: \.isArticulationRoot)
        // `??` binds tighter than the ternary, so the fallback needs its own
        // parentheses or the whole expression types as Bool.
        let name = articulationRoot.map { lastComponent($0.path) }
            ?? (roots[0].name.isEmpty ? "usd" : roots[0].name)
        let articulation = world.addArticulation(name: name)

        var linkNames: [String] = []
        var actuators: [Int] = []
        var defaultPose: [Double] = []
        var visited = Set<String>()

        /// Recursively lays down one link per body, depth first.
        func addBody(_ body: USDPhysicsBody, parent: Int, joint: USDPhysicsJoint?) throws {
            if visited.contains(body.path) {
                throw USDImportError.kinematicLoop("'\(body.path)' is reachable twice")
            }
            visited.insert(body.path)

            let linkName = uniqueName(body.path, taken: linkNames)
            let link = world.addLink(articulation: articulation, parent: parent, name: linkName)
            linkNames.append(linkName)

            // ── Joint frame ────────────────────────────────────────────────
            // USD defines the joint frame twice: as (localPos0, localRot0) in
            // body0 and as (localPos1, localRot1) in body1. Kinetic's joint
            // origin is the joint frame in the parent link, and the child link
            // frame IS the joint frame, so:
            //   origin  = T0                          (joint frame in parent)
            //   axis    = the USD axis, unrotated     (already in the joint frame)
            //   geoms   = T1⁻¹ · (geom in body frame) (body frame = J · T1⁻¹)
            // Using T0 rather than T0·T1⁻¹ is what puts the rotation axis
            // through the joint's own origin instead of the body's.
            var spec = JointSpec()
            var childFromJoint = Pose.identity

            if let joint {
                let t0 = USDImporter.convertLocalPose(
                    Pose(position: joint.localPos0 * scale, orientation: joint.localRot0.normalized),
                    by: upAxisRotation)
                let t1 = USDImporter.convertLocalPose(
                    Pose(position: joint.localPos1 * scale, orientation: joint.localRot1.normalized),
                    by: upAxisRotation)
                childFromJoint = t1.inverse
                spec.origin = t0
                spec.axis = upAxisRotation.rotate(joint.axis)

                switch joint.kind {
                case .revolute:
                    spec.kind = .revolute
                    // USD authors revolute limits in DEGREES.
                    if joint.isLimited, let lower = joint.lowerLimit, let upper = joint.upperLimit {
                        spec.limited = true
                        spec.lower = lower * .pi / 180
                        spec.upper = upper * .pi / 180
                    }
                case .prismatic:
                    spec.kind = .prismatic
                    // Prismatic limits are lengths, in stage units.
                    if joint.isLimited, let lower = joint.lowerLimit, let upper = joint.upperLimit {
                        spec.limited = true
                        spec.lower = lower * scale
                        spec.upper = upper * scale
                    }
                case .fixed:
                    spec.kind = .fixed
                case .spherical:
                    spec.kind = .spherical
                    if joint.lowerLimit != nil || joint.upperLimit != nil {
                        onWarning?("'\(joint.path)': USD cone limits on a spherical joint have no "
                                   + "Kinetic equivalent and were dropped")
                    }
                }
                if let damping = joint.driveDamping { spec.damping = damping }
                if let stiffness = joint.driveStiffness { spec.stiffness = stiffness }
                if let maxForce = joint.driveMaxForce, maxForce.isFinite {
                    spec.effortLimit = maxForce
                }
            } else {
                // A root body with no joint to anything is free-floating; a root
                // whose joint anchors it to the world is bolted down.
                let anchored = (incoming[body.path] ?? []).contains { j in
                    j.kind == .fixed || (j.body0 ?? "").isEmpty
                }
                spec.kind = body.isKinematic || anchored ? .fixed : .free
                if let worldPose = nodeByPath[body.path]?.worldTransform {
                    if spec.kind == .fixed {
                        spec.origin = worldPose
                    } else {
                        defaultPose += [worldPose.position.x, worldPose.position.y,
                                        worldPose.position.z, worldPose.orientation.w,
                                        worldPose.orientation.x, worldPose.orientation.y,
                                        worldPose.orientation.z]
                    }
                } else if spec.kind == .free {
                    defaultPose += [0, 0, 0, 1, 0, 0, 0]
                }
            }
            world.setJoint(articulation: articulation, link: link, spec)
            if spec.kind == .revolute || spec.kind == .prismatic { defaultPose.append(0) }
            else if spec.kind == .spherical { defaultPose += [1, 0, 0, 0] }

            // ── Geometry ───────────────────────────────────────────────────
            // Every geometry node at or under the body's prim path belongs to
            // it, placed relative to the body frame and then re-expressed in
            // the link (joint) frame.
            let owned = ownedNodes(of: body, in: flat, bodyPaths: Set(bodyByPath.keys))
            let bodyPose = nodeByPath[body.path]?.worldTransform ?? .identity
            var meshes: [(pose: Pose, mesh: LoadedMesh)] = []
            for node in owned {
                let inBody = bodyPose.inverse * node.worldTransform
                for mesh in node.meshes { meshes.append((childFromJoint * inBody, mesh)) }
            }
            if meshes.isEmpty {
                onWarning?("'\(body.path)' declares a rigid body but no geometry could be matched "
                           + "to it; it has no collision shape")
            }
            for entry in meshes where !entry.mesh.hullVertices.isEmpty {
                let index = world.addMesh(vertices: entry.mesh.hullVertices,
                                          indices: entry.mesh.hullIndices,
                                          name: "\(entry.mesh.name).hull")
                world.addGeom(articulation: articulation, link: link,
                              GeomSpec(shape: .convexHull(mesh: index,
                                                          boundingRadius: entry.mesh.boundingRadius),
                                       localPose: entry.pose, material: material,
                                       appearance: appearance,
                                       collidable: body.hasCollision, visible: true,
                                       name: entry.mesh.name))
            }

            // ── Inertial ───────────────────────────────────────────────────
            applyInertial(body: body, meshes: meshes, childFromJoint: childFromJoint,
                          scale: scale, rotation: upAxisRotation, density: density,
                          articulation: articulation, link: link, world: world,
                          onWarning: onWarning)

            // ── Actuator ───────────────────────────────────────────────────
            // Only for a joint whose PhysicsDriveAPI the stage authored. A joint
            // with no drive gets no motor, because the asset did not ask for one.
            if let joint, spec.kind == .revolute || spec.kind == .prismatic,
               joint.driveStiffness != nil || joint.driveDamping != nil {
                let range: ClosedRange<Double>? = spec.limited ? spec.lower...spec.upper : nil
                let force: ClosedRange<Double>? = (joint.driveMaxForce?.isFinite ?? false)
                    ? -(joint.driveMaxForce ?? 0)...(joint.driveMaxForce ?? 0)
                    : nil
                actuators.append(world.addActuator(ActuatorSpec(
                    name: joint.name, kind: .position, articulation: articulation, link: link,
                    gear: 1, kp: joint.driveStiffness ?? 0, kd: joint.driveDamping ?? 0,
                    controlRange: range, forceRange: force)))
            }

            for outgoing in childrenOf[body.path] ?? [] {
                guard let childPath = outgoing.body1, let child = bodyByPath[childPath] else {
                    continue
                }
                try addBody(child, parent: link, joint: outgoing)
            }
        }

        for root in roots { try addBody(root, parent: -1, joint: nil) }

        let unreached = bodies.filter { !visited.contains($0.path) }
        if !unreached.isEmpty {
            throw USDImportError.kinematicLoop(
                "\(unreached.count) rigid bodies are unreachable from any root "
                + "(\(unreached.prefix(4).map(\.name).joined(separator: ", "))), which means the "
                + "joint graph contains a cycle")
        }

        if !defaultPose.isEmpty {
            world.setDefaultPose(articulation: articulation, q: defaultPose)
        }
        world.setSelfCollision(articulation: articulation, enabled: selfCollision)
        return Robot(articulation: articulation, name: name, links: linkNames,
                     actuators: actuators)
    }

    /// Geometry nodes belonging to a body: the body's own prim and every
    /// descendant, minus any subtree that is itself another rigid body — that
    /// geometry belongs to the nested body's link, not to this one.
    private static func ownedNodes(of body: USDPhysicsBody, in flat: [USDNode],
                                   bodyPaths: Set<String>) -> [USDNode] {
        let prefix = body.path + "/"
        // Rigid bodies nested strictly beneath this one.
        let nested = bodyPaths.filter { $0 != body.path && $0.hasPrefix(prefix) }
        return flat.filter { node in
            guard node.path == body.path || node.path.hasPrefix(prefix) else { return false }
            return !nested.contains { node.path == $0 || node.path.hasPrefix($0 + "/") }
        }
    }

    private static func applyInertial(body: USDPhysicsBody,
                                      meshes: [(pose: Pose, mesh: LoadedMesh)],
                                      childFromJoint: Pose, scale: Double, rotation: Quat,
                                      density: Double, articulation: Int, link: Int, world: World,
                                      onWarning: (@Sendable (String) -> Void)?) {
        // Volume of everything attached, used for both density-derived mass and
        // the fallback inertia.
        let volume = meshes.reduce(0.0) { $0 + max($1.mesh.volume, 0) }

        // ── Mass ───────────────────────────────────────────────────────────
        let mass: Double
        if let authored = body.mass, authored > 0 {
            mass = authored
        } else if let authoredDensity = body.density, authoredDensity > 0, volume > 1e-12 {
            // physics:density is per cubic stage unit.
            let siDensity = authoredDensity / (scale * scale * scale)
            mass = volume * siDensity
            onWarning?("'\(body.path)': mass derived from the authored physics:density "
                       + "(\(authoredDensity) per unit³ = \(siDensity) kg/m³) × \(volume) m³ of "
                       + "convex hull")
        } else if volume > 1e-12 {
            mass = volume * density
            onWarning?("'\(body.path)': the stage authored neither physics:mass nor "
                       + "physics:density, so its mass is \(volume) m³ of convex hull × "
                       + "\(density) kg/m³ = \(volume * density) kg. This number is Kinetic's, "
                       + "not the asset's.")
        } else {
            mass = 1e-3
            onWarning?("'\(body.path)': no authored mass and no geometry to derive one from; "
                       + "using a 1 g placeholder so the mass matrix stays positive definite")
        }

        // ── Centre of mass ─────────────────────────────────────────────────
        // physics:centerOfMass is in the BODY frame, so it goes through the same
        // frame conversion the geometry did.
        var com: Vec3
        if let authored = body.centerOfMass {
            com = childFromJoint.apply(rotation.rotate(authored * scale))
        } else {
            var weighted = Vec3.zero
            var total = 0.0
            for entry in meshes where entry.mesh.volume > 1e-12 {
                weighted += entry.pose.apply(entry.mesh.centroid) * entry.mesh.volume
                total += entry.mesh.volume
            }
            com = total > 1e-12 ? weighted / total : .zero
        }

        // ── Inertia ────────────────────────────────────────────────────────
        if let diagonal = body.diagonalInertia {
            // Authored in mass · stage-unit²; the length term scales twice.
            let s2 = scale * scale
            let principal = Vec3(diagonal.x * s2, diagonal.y * s2, diagonal.z * s2)
            let frame = childFromJoint.orientation
                * rotation
                * (body.principalAxes?.normalized ?? .identity)
            world.setInertial(articulation: articulation, link: link, mass: mass, com: com,
                              inertia: USDInertia.rotate(principal.diagonalInertia, by: frame))
            return
        }

        // No authored tensor: integrate the hulls. Exact for the hulls given the
        // mass, which is the best that can be done without the stage's help.
        guard volume > 1e-12 else {
            world.setInertial(articulation: articulation, link: link, mass: mass, com: com,
                              inertia: Inertia.sphere(mass: mass, radius: 0.01))
            return
        }
        onWarning?("'\(body.path)': no physics:diagonalInertia was authored; the inertia tensor "
                   + "has been integrated over the body's convex hulls")

        var inertia = [Double](repeating: 0, count: 9)
        for entry in meshes where entry.mesh.volume > 1e-12 {
            let share = mass * entry.mesh.volume / volume
            guard let solid = USDInertia.hull(vertices: entry.mesh.hullVertices,
                                              indices: entry.mesh.hullIndices,
                                              mass: share) else { continue }
            let centre = entry.pose.apply(solid.centerOfMass)
            let rotated = USDInertia.rotate(solid.inertia, by: entry.pose.orientation)
            let d = centre - com
            let d2 = d.dot(d)
            inertia[0] += rotated[0] + share * (d2 - d.x * d.x)
            inertia[1] += rotated[1] - share * d.x * d.y
            inertia[2] += rotated[2] - share * d.x * d.z
            inertia[3] += rotated[3] - share * d.y * d.x
            inertia[4] += rotated[4] + share * (d2 - d.y * d.y)
            inertia[5] += rotated[5] - share * d.y * d.z
            inertia[6] += rotated[6] - share * d.z * d.x
            inertia[7] += rotated[7] - share * d.z * d.y
            inertia[8] += rotated[8] + share * (d2 - d.z * d.z)
        }
        world.setInertial(articulation: articulation, link: link, mass: mass, com: com,
                          inertia: inertia)
    }

    private static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "usd")
    }

    private static func uniqueName(_ path: String, taken: [String]) -> String {
        let base = path.isEmpty
            ? "link"
            : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: ".")
        guard taken.contains(base) else { return base }
        var i = 1
        while taken.contains("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }

    // MARK: - ASCII USD scanner
    //
    // USDA is close enough to a C-style block language that a byte scanner is
    // enough, provided four things are tracked: quotes, comments, grouping
    // (`(...)` and `[...]`, which may span lines), and dictionary values, whose
    // braces are not prim bodies.

    private struct PrimFrame {
        var name: String
        var type: String
        var path: String
        var appliedSchemas: [String]
        var compositionArcs: [String]
    }

    private enum Event {
        /// Text between the previous delimiter and a `{` that opens a prim body.
        case prim(header: String)
        case close
        /// A complete top-level statement, typically one attribute assignment.
        case statement(String)
    }

    private static func scan(_ text: String, emit: (Event) -> Void) {
        let bytes = Array(text.utf8)
        let n = bytes.count
        var buffer = [UInt8]()
        var i = 0
        var inQuote = false
        var quoteByte: UInt8 = 0
        var groupDepth = 0   // ( ) and [ ]
        var dictDepth = 0    // { } that belong to a value, not to a prim

        // A completed line is held back rather than emitted, because USDA
        // conventionally puts a prim's opening brace on the FOLLOWING line:
        //
        //     def Xform "World"
        //     {
        //
        // Only the next delimiter reveals whether that line was a prim header or
        // a standalone statement.
        var pending: String?

        func flush() -> String {
            let s = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
            return s
        }

        /// The text that a `{` or `}` terminates: whatever is still buffered on
        /// this line, else the line held back from before.
        func takeHeader() -> String {
            let current = flush()
            if !current.isEmpty {
                if let held = pending { emit(.statement(held)) }
                pending = nil
                return current
            }
            let held = pending ?? ""
            pending = nil
            return held
        }

        func emitPending() {
            if let held = pending, !held.isEmpty { emit(.statement(held)) }
            pending = nil
        }

        while i < n {
            let c = bytes[i]

            if inQuote {
                buffer.append(c)
                if c == 0x5C, i + 1 < n {          // backslash escape
                    buffer.append(bytes[i + 1])
                    i += 2
                    continue
                }
                if c == quoteByte { inQuote = false }
                i += 1
                continue
            }

            switch c {
            case 0x22, 0x27:                       // " '
                inQuote = true
                quoteByte = c
                buffer.append(c)
            case 0x23:                             // # comment
                while i < n && bytes[i] != 0x0A { i += 1 }
                continue
            case 0x28, 0x5B:                       // ( [
                groupDepth += 1
                buffer.append(c)
            case 0x29, 0x5D:                       // ) ]
                groupDepth = max(0, groupDepth - 1)
                buffer.append(c)
            case 0x7B:                             // {
                if groupDepth > 0 {
                    buffer.append(c)
                } else if dictDepth > 0 {
                    dictDepth += 1
                } else {
                    let header = takeHeader()
                    // A `{` preceded by a top-level `=` opens a dictionary or
                    // variant-set value, not a prim body. Testing the header
                    // rather than tracking a flag is what keeps the `=` inside a
                    // prim's `( … )` metadata from being mistaken for one.
                    if topLevelEquals(in: header) != nil {
                        if !header.isEmpty { emit(.statement(header)) }
                        dictDepth = 1
                    } else {
                        emit(.prim(header: header))
                    }
                }
            case 0x7D:                             // }
                if groupDepth > 0 {
                    buffer.append(c)
                } else if dictDepth > 0 {
                    dictDepth -= 1
                    if dictDepth == 0 { buffer.removeAll(keepingCapacity: true) }
                } else {
                    emitPending()
                    let s = flush()
                    if !s.isEmpty { emit(.statement(s)) }
                    emit(.close)
                }
            case 0x0A:                             // newline
                if groupDepth > 0 {
                    buffer.append(0x20)            // fold a grouped value onto one line
                } else if dictDepth == 0 {
                    let s = flush()
                    if !s.isEmpty {
                        emitPending()
                        pending = s
                    }
                }
            default:
                if dictDepth == 0 { buffer.append(c) }
            }
            i += 1
        }
        emitPending()
        let tail = flush()
        if !tail.isEmpty { emit(.statement(tail)) }
    }

    // MARK: Header and statement parsing

    /// `def PhysicsRevoluteJoint "hip" ( prepend apiSchemas = ["PhysicsDriveAPI:angular"] )`
    private static func parsePrimHeader(_ header: String, parentPath: String) -> PrimFrame {
        // Split off the prim metadata group, which starts at the first `(` that
        // is not inside the quoted name.
        var declaration = header
        var metadata = ""
        var depth = 0
        var inQuote = false
        var split: String.Index?
        for index in header.indices {
            let ch = header[index]
            if ch == "\"" { inQuote.toggle() }
            guard !inQuote else { continue }
            if ch == "(" {
                if depth == 0 { split = index }
                depth += 1
            } else if ch == ")" {
                depth = max(0, depth - 1)
            }
        }
        if let split {
            declaration = String(header[header.startIndex..<split])
            metadata = String(header[split...])
        }

        // The name is the first quoted token; the type is the token before it,
        // once the specifier keyword is dropped.
        var name = ""
        var type = ""
        let tokens = declaration.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var rest: [String] = []
        for token in tokens {
            if ["def", "over", "class", "variantSet"].contains(token) { continue }
            rest.append(token)
        }
        if let quoted = rest.first(where: { $0.hasPrefix("\"") }) {
            name = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let position = rest.firstIndex(of: quoted), position > 0 { type = rest[position - 1] }
        } else if let only = rest.first {
            type = only
        }

        var schemas: [String] = []
        if let list = bracketList(named: "apiSchemas", in: metadata) {
            schemas = quotedStrings(in: list)
        }
        let arcs = compositionArcs.filter { metadata.contains($0 + " ") || metadata.contains($0 + "=") }

        let path = parentPath.isEmpty ? "/\(name)" : "\(parentPath)/\(name)"
        return PrimFrame(name: name, type: type, path: path, appliedSchemas: schemas,
                         compositionArcs: arcs)
    }

    /// One attribute or relationship assignment.
    struct Assignment {
        var name: String
        var raw: String
        var isRelationship: Bool

        var doubleValue: Double? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "inf" { return .infinity }
            if trimmed == "-inf" { return -.infinity }
            return Double(trimmed)
        }

        var boolValue: Bool? {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }

        var tokenValue: String {
            raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }

        /// `(x, y, z)` — USD writes float3/point3f this way.
        var vec3Value: Vec3? {
            let numbers = numberList
            guard numbers.count >= 3 else { return nil }
            return Vec3(numbers[0], numbers[1], numbers[2])
        }

        /// `(w, x, y, z)` — USD stores a quaternion real part first.
        var quatValue: Quat? {
            let numbers = numberList
            guard numbers.count >= 4 else { return nil }
            return Quat(w: numbers[0], x: numbers[1], y: numbers[2], z: numbers[3]).normalized
        }

        /// `</World/link0>`, or the first entry of `[</a>, </b>]`.
        var pathValue: String? {
            guard let open = raw.firstIndex(of: "<"), let close = raw[open...].firstIndex(of: ">")
            else { return nil }
            let value = String(raw[raw.index(after: open)..<close])
            return value.isEmpty ? nil : value
        }

        private var numberList: [Double] {
            raw.split(whereSeparator: { "(),[] \t".contains($0) }).compactMap { Double($0) }
        }
    }

    private static let declarationQualifiers: Set<String> = [
        "custom", "uniform", "varying", "prepend", "append", "add", "delete", "reorder", "config",
    ]

    private static func parseAssignment(_ statement: String) -> Assignment? {
        guard let equals = topLevelEquals(in: statement) else { return nil }
        let declaration = String(statement[statement.startIndex..<equals])
            .trimmingCharacters(in: .whitespaces)
        let raw = String(statement[statement.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)

        var tokens = declaration.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        tokens.removeAll { declarationQualifiers.contains($0) }
        guard var name = tokens.last else { return nil }
        let isRelationship = tokens.contains("rel")
        // `physics:mass.timeSamples` and `.connect` are not plain values.
        if let dot = name.firstIndex(of: ".") { name = String(name[name.startIndex..<dot]) }
        guard !name.isEmpty, name != "rel" else { return nil }
        return Assignment(name: name, raw: raw, isRelationship: isRelationship)
    }

    private static func topLevelEquals(in statement: String) -> String.Index? {
        var depth = 0
        var inQuote = false
        for index in statement.indices {
            let ch = statement[index]
            if ch == "\"" { inQuote.toggle() }
            guard !inQuote else { continue }
            if ch == "(" || ch == "[" { depth += 1 }
            else if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            else if ch == "=" && depth == 0 { return index }
        }
        return nil
    }

    // MARK: Small text helpers

    private static func firstPrimSpecifierIndex(_ text: String) -> String.Index? {
        for keyword in ["\ndef ", "\nclass ", "\nover "] {
            if let range = text.range(of: keyword) { return range.lowerBound }
        }
        return nil
    }

    private static func doubleAssignment(named name: String, in text: String) -> Double? {
        guard let value = valueAfter(name, in: text) else { return nil }
        return Double(value.prefix(while: { "0123456789+-.eE".contains($0) }))
    }

    private static func stringAssignment(named name: String, in text: String) -> String? {
        guard let value = valueAfter(name, in: text) else { return nil }
        if let open = value.firstIndex(of: "\""),
           let close = value[value.index(after: open)...].firstIndex(of: "\"") {
            return String(value[value.index(after: open)..<close])
        }
        if let open = value.firstIndex(of: "<"), let close = value.firstIndex(of: ">") {
            return String(value[value.index(after: open)..<close])
        }
        return String(value.prefix(while: { !$0.isWhitespace }))
    }

    private static func valueAfter(_ name: String, in text: String) -> Substring? {
        guard let range = text.range(of: name) else { return nil }
        var rest = text[range.upperBound...]
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return nil }
        return rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
    }

    /// The `[ ... ]` that follows `name =`.
    private static func bracketList(named name: String, in text: String) -> Substring? {
        guard let value = valueAfter(name, in: text),
              let open = value.firstIndex(of: "["),
              let close = value[open...].firstIndex(of: "]")
        else { return nil }
        return value[value.index(after: open)..<close]
    }

    private static func quotedStrings(in text: Substring) -> [String] {
        var result: [String] = []
        var current: String?
        for ch in text {
            if ch == "\"" {
                if let value = current {
                    result.append(value)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return result
    }
}
