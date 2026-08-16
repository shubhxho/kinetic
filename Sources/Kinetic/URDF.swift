//
//  URDF.swift
//  Kinetic
//
//  URDF importer. Handles the parts of the format that describe physics —
//  links, inertials, joints, visual and collision geometry, materials — and
//  resolves `package://` and relative mesh paths against a search path.
//

import Foundation

public struct URDFImportOptions: Sendable {
    /// Extra directories searched when resolving `package://` mesh URIs.
    public var packageRoots: [URL] = []
    /// Attach the root link to the world with a fixed joint instead of a free one.
    public var fixedBase: Bool = false
    /// Fill in a small inertia for links that declare none (common in URDFs that
    /// were authored for visualisation only).
    public var defaultLinkMass: Double = 0.001
    public var selfCollision: Bool = false
    /// Joint damping applied when the URDF omits `<dynamics>`.
    public var defaultJointDamping: Double = 0.1
    public var defaultArmature: Double = 0.01
    /// Create a position actuator per movable joint.
    public var addPositionActuators: Bool = true
    public var actuatorGainP: Double = 400
    public var actuatorGainD: Double = 20
    public var loadVisualMeshes: Bool = true
    /// Shared mesh cache; supply one to reuse decoded meshes across imports.
    public var meshLibrary: MeshLibrary? = nil
    /// Report meshes that could not be resolved instead of failing the import.
    public var onWarning: (@Sendable (String) -> Void)? = nil

    public init() {}
}

public enum URDFError: Error, CustomStringConvertible {
    case unreadable(URL)
    case malformed(String)
    case noRobotElement
    case cycle(String)

    public var description: String {
        switch self {
        case .unreadable(let url): return "cannot read URDF at \(url.path)"
        case .malformed(let detail): return "malformed URDF: \(detail)"
        case .noRobotElement: return "no <robot> element found"
        case .cycle(let link): return "kinematic loop detected at link '\(link)'"
        }
    }
}

public enum URDF {
    // MARK: Parsing helpers

    private struct ParsedInertial {
        var origin = Pose.identity
        var mass: Double = 0
        var inertia: [Double] = Array(repeating: 0, count: 9)
        var present = false
    }

    private struct ParsedGeom {
        var shape: Shape
        var origin: Pose
        var color: Vec4?
        var isCollision: Bool
        var meshURI: String?
        var meshScale: Vec3 = Vec3(1, 1, 1)
    }

    private struct ParsedLink {
        var name: String
        var inertial = ParsedInertial()
        var geoms: [ParsedGeom] = []
    }

    private struct ParsedJoint {
        var name: String
        var type: String
        var parent: String
        var child: String
        var origin = Pose.identity
        var axis = Vec3(1, 0, 0)
        var lower: Double = 0
        var upper: Double = 0
        var effort: Double = 0
        var velocity: Double = 0
        var hasLimit = false
        var damping: Double?
        var friction: Double?
    }

    private static func doubles(_ s: String?) -> [Double] {
        guard let s else { return [] }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," })
            .compactMap { Double($0) }
    }

    private static func attr(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func parseOrigin(_ element: XMLElement?) -> Pose {
        guard let element else { return .identity }
        let xyz = doubles(attr(element, "xyz"))
        let rpy = doubles(attr(element, "rpy"))
        let position = xyz.count >= 3 ? Vec3(xyz[0], xyz[1], xyz[2]) : .zero
        let orientation = rpy.count >= 3
            ? Quat(roll: rpy[0], pitch: rpy[1], yaw: rpy[2])
            : Quat.identity
        return Pose(position: position, orientation: orientation)
    }

    private static func child(_ element: XMLElement, _ name: String) -> XMLElement? {
        element.elements(forName: name).first
    }

    // MARK: Entry points

    public static func load(contentsOf url: URL, into world: World? = nil,
                            options: URDFImportOptions = URDFImportOptions()) throws
        -> (world: World, robot: Robot)
    {
        guard let data = try? Data(contentsOf: url) else { throw URDFError.unreadable(url) }
        var opts = options
        opts.packageRoots.append(url.deletingLastPathComponent())
        opts.packageRoots.append(url.deletingLastPathComponent().deletingLastPathComponent())
        return try load(data: data, into: world, options: opts)
    }

    public static func load(data: Data, into existing: World? = nil,
                            options: URDFImportOptions = URDFImportOptions()) throws
        -> (world: World, robot: Robot)
    {
        let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "robot" else {
            throw URDFError.noRobotElement
        }
        let world = existing ?? World()
        let robot = try build(root: root, world: world, options: options)
        if existing == nil { world.compile() }
        return (world, robot)
    }

    // MARK: Build

    /// Registers a mesh with the world and returns the geom shape that uses it.
    /// Collision geoms get the convex hull (a linear support scan, so vertex
    /// count matters); visual geoms keep the authored triangles.
    private static func resolveMesh(_ uri: String, scale: Vec3, world: World, collidable: Bool,
                                    library: MeshLibrary,
                                    options: URDFImportOptions) -> Shape? {
        guard let mesh = try? library.load(uri, scale: scale) else { return nil }
        let vertices = collidable ? mesh.hullVertices : mesh.vertices
        let indices = collidable ? mesh.hullIndices : mesh.indices
        guard !vertices.isEmpty else { return nil }
        let index = world.addMesh(vertices: vertices, indices: indices, name: mesh.name)
        return .convexHull(mesh: index, boundingRadius: mesh.boundingRadius)
    }

    private static func build(root: XMLElement, world: World,
                              options: URDFImportOptions) throws -> Robot {
        let robotName = attr(root, "name") ?? "robot"
        let meshes = options.meshLibrary ?? MeshLibrary(searchPaths: options.packageRoots)
        for root in options.packageRoots { meshes.addSearchPath(root) }

        // Named <material> blocks declared at robot scope.
        var palette: [String: Vec4] = [:]
        for material in root.elements(forName: "material") {
            guard let name = attr(material, "name"),
                  let color = child(material, "color"),
                  case let rgba = doubles(attr(color, "rgba")), rgba.count >= 4
            else { continue }
            palette[name] = Vec4(rgba[0], rgba[1], rgba[2], rgba[3])
        }

        var links: [String: ParsedLink] = [:]
        var order: [String] = []
        for element in root.elements(forName: "link") {
            guard let name = attr(element, "name") else { continue }
            var link = ParsedLink(name: name)

            if let inertial = child(element, "inertial") {
                var parsed = ParsedInertial()
                parsed.present = true
                parsed.origin = parseOrigin(child(inertial, "origin"))
                if let m = child(inertial, "mass"), let v = Double(attr(m, "value") ?? "") {
                    parsed.mass = v
                }
                if let i = child(inertial, "inertia") {
                    let ixx = Double(attr(i, "ixx") ?? "0") ?? 0
                    let ixy = Double(attr(i, "ixy") ?? "0") ?? 0
                    let ixz = Double(attr(i, "ixz") ?? "0") ?? 0
                    let iyy = Double(attr(i, "iyy") ?? "0") ?? 0
                    let iyz = Double(attr(i, "iyz") ?? "0") ?? 0
                    let izz = Double(attr(i, "izz") ?? "0") ?? 0
                    parsed.inertia = [ixx, ixy, ixz, ixy, iyy, iyz, ixz, iyz, izz]
                }
                link.inertial = parsed
            }

            _ = 0
        for (tag, isCollision) in [("visual", false), ("collision", true)] {
                for node in element.elements(forName: tag) {
                    guard let geometry = child(node, "geometry") else { continue }
                    let origin = parseOrigin(child(node, "origin"))
                    var color: Vec4?
                    if let material = child(node, "material") {
                        if let c = child(material, "color") {
                            let rgba = doubles(attr(c, "rgba"))
                            if rgba.count >= 4 { color = Vec4(rgba[0], rgba[1], rgba[2], rgba[3]) }
                        } else if let name = attr(material, "name") {
                            color = palette[name]
                        }
                    }
                    guard let parsed = parseGeometry(geometry, origin: origin, color: color,
                                                     isCollision: isCollision)
                    else { continue }
                    link.geoms.append(parsed)
                }
            }

            links[name] = link
            order.append(name)
        }

        var joints: [ParsedJoint] = []
        for element in root.elements(forName: "joint") {
            guard let name = attr(element, "name"),
                  let type = attr(element, "type"),
                  let parent = child(element, "parent").flatMap({ attr($0, "link") }),
                  let childLink = child(element, "child").flatMap({ attr($0, "link") })
            else { continue }
            var joint = ParsedJoint(name: name, type: type, parent: parent, child: childLink)
            joint.origin = parseOrigin(child(element, "origin"))
            if let axis = child(element, "axis") {
                let v = doubles(attr(axis, "xyz"))
                if v.count >= 3 { joint.axis = Vec3(v[0], v[1], v[2]) }
            }
            if let limit = child(element, "limit") {
                joint.hasLimit = true
                joint.lower = Double(attr(limit, "lower") ?? "0") ?? 0
                joint.upper = Double(attr(limit, "upper") ?? "0") ?? 0
                joint.effort = Double(attr(limit, "effort") ?? "0") ?? 0
                joint.velocity = Double(attr(limit, "velocity") ?? "0") ?? 0
            }
            if let dynamics = child(element, "dynamics") {
                joint.damping = Double(attr(dynamics, "damping") ?? "")
                joint.friction = Double(attr(dynamics, "friction") ?? "")
            }
            joints.append(joint)
        }

        // Root = the link that is never a child.
        let childNames = Set(joints.map(\.child))
        let roots = order.filter { !childNames.contains($0) }
        guard let rootName = roots.first else {
            throw URDFError.malformed("every link is a child; the model has no root")
        }

        // Breadth-first ordering guarantees parents are created before children.
        var childrenOf: [String: [ParsedJoint]] = [:]
        for j in joints { childrenOf[j.parent, default: []].append(j) }

        let articulation = world.addArticulation(name: robotName)
        var linkIndex: [String: Int] = [:]
        var createdOrder: [String] = []
        var actuators: [Int] = []

        func addLink(_ name: String, parent: Int, joint: ParsedJoint?) throws {
            guard let parsed = links[name] else {
                throw URDFError.malformed("joint references unknown link '\(name)'")
            }
            if linkIndex[name] != nil { throw URDFError.cycle(name) }
            let index = world.addLink(articulation: articulation, parent: parent, name: name)
            linkIndex[name] = index
            createdOrder.append(name)

            var spec = JointSpec()
            if let joint {
                spec.origin = joint.origin
                spec.axis = joint.axis
                switch joint.type {
                case "revolute":
                    spec.kind = .revolute
                    spec.limited = joint.hasLimit
                    spec.lower = joint.lower
                    spec.upper = joint.upper
                case "continuous":
                    spec.kind = .revolute
                case "prismatic":
                    spec.kind = .prismatic
                    spec.limited = joint.hasLimit
                    spec.lower = joint.lower
                    spec.upper = joint.upper
                case "floating":
                    spec.kind = .free
                case "planar":
                    // Not representable as a single joint; treat as fixed and let
                    // the caller know through the link name.
                    spec.kind = .fixed
                default:
                    spec.kind = .fixed
                }
                spec.effortLimit = joint.effort
                spec.velocityLimit = joint.velocity
                spec.damping = joint.damping ?? options.defaultJointDamping
                spec.friction = joint.friction ?? 0
                spec.armature = options.defaultArmature
            } else {
                spec.kind = options.fixedBase ? .fixed : .free
            }
            world.setJoint(articulation: articulation, link: index, spec)

            // Inertial
            if parsed.inertial.present && parsed.inertial.mass > 0 {
                let inertia = rotateInertia(parsed.inertial.inertia,
                                            by: parsed.inertial.origin.orientation)
                world.setInertial(articulation: articulation, link: index,
                                  mass: parsed.inertial.mass,
                                  com: parsed.inertial.origin.position,
                                  inertia: inertia)
            } else {
                // Derive something plausible from the collision geometry so the
                // mass matrix stays positive definite.
                let shape = parsed.geoms.first(where: { $0.isCollision })?.shape
                    ?? parsed.geoms.first?.shape
                let mass = max(options.defaultLinkMass, 1e-6)
                world.setInertial(articulation: articulation, link: index, mass: mass,
                                  com: .zero,
                                  inertia: shape?.inertia(mass: mass)
                                      ?? Inertia.sphere(mass: mass, radius: 0.05))
            }

            // Geometry
            let hasCollision = parsed.geoms.contains(where: \.isCollision)
            for geom in parsed.geoms {
                if geom.isCollision == false && hasCollision == false {
                    // Visual-only URDF: use the visual shapes for collision too.
                } else if geom.isCollision == false && !options.loadVisualMeshes {
                    continue
                }
                let collidable = geom.isCollision || !hasCollision
                let visible = !geom.isCollision || !parsed.geoms.contains(where: { !$0.isCollision })
                var shape = geom.shape
                if let uri = geom.meshURI {
                    if let resolved = resolveMesh(uri, scale: geom.meshScale, world: world,
                                                  collidable: collidable, library: meshes,
                                                  options: options) {
                        shape = resolved
                    } else {
                        options.onWarning?("could not resolve mesh '\(uri)' for link '\(name)'")
                    }
                }
                var spec = GeomSpec(shape: shape, localPose: geom.origin,
                                    collidable: collidable, visible: visible,
                                    name: geom.meshURI.map {
                                        URL(fileURLWithPath: $0).lastPathComponent
                                    } ?? name)
                if let color = geom.color {
                    spec.appearance = Appearance(color: color, roughness: 0.5)
                }
                world.addGeom(articulation: articulation, link: index, spec)
            }

            if let joint, options.addPositionActuators,
               spec.kind == .revolute || spec.kind == .prismatic {
                let range: ClosedRange<Double>? = spec.limited ? spec.lower...spec.upper : nil
                let force = joint.effort > 0 ? -joint.effort...joint.effort : nil
                actuators.append(world.addActuator(ActuatorSpec(
                    name: joint.name, kind: .position, articulation: articulation, link: index,
                    gear: 1, kp: options.actuatorGainP, kd: options.actuatorGainD,
                    controlRange: range, forceRange: force)))
            }

            for outgoing in childrenOf[name] ?? [] {
                try addLink(outgoing.child, parent: index, joint: outgoing)
            }
        }

        try addLink(rootName, parent: -1, joint: nil)
        world.setSelfCollision(articulation: articulation, enabled: options.selfCollision)

        return Robot(articulation: articulation, name: robotName, links: createdOrder,
                     actuators: actuators)
    }

    private static func parseGeometry(_ geometry: XMLElement, origin: Pose, color: Vec4?,
                                      isCollision: Bool) -> ParsedGeom? {
        if let box = child(geometry, "box") {
            let s = doubles(attr(box, "size"))
            guard s.count >= 3 else { return nil }
            return ParsedGeom(shape: .box(halfExtents: Vec3(s[0], s[1], s[2]) * 0.5),
                              origin: origin, color: color, isCollision: isCollision)
        }
        if let sphere = child(geometry, "sphere") {
            guard let r = Double(attr(sphere, "radius") ?? "") else { return nil }
            return ParsedGeom(shape: .sphere(radius: r), origin: origin, color: color,
                              isCollision: isCollision)
        }
        if let cylinder = child(geometry, "cylinder") {
            guard let r = Double(attr(cylinder, "radius") ?? ""),
                  let l = Double(attr(cylinder, "length") ?? "") else { return nil }
            return ParsedGeom(shape: .cylinder(radius: r, halfLength: l * 0.5), origin: origin,
                              color: color, isCollision: isCollision)
        }
        if let mesh = child(geometry, "mesh") {
            let filename = attr(mesh, "filename") ?? ""
            let scale = doubles(attr(mesh, "scale"))
            let s = scale.count >= 3 ? Vec3(scale[0], scale[1], scale[2]) : Vec3(1, 1, 1)
            // The actual geometry is resolved during build(), where the world is
            // available to register the mesh. Until then it carries a placeholder
            // shape so a failed resolve still yields a simulable model.
            return ParsedGeom(shape: .box(halfExtents: Vec3(0.02, 0.02, 0.02)),
                              origin: origin, color: color, isCollision: isCollision,
                              meshURI: filename, meshScale: s)
        }
        return nil
    }

    /// Rotates a 3x3 inertia tensor into the link frame: `R I Rᵀ`.
    static func rotateInertia(_ inertia: [Double], by q: Quat) -> [Double] {
        if q == .identity { return inertia }
        let c0 = q.rotate(Vec3(1, 0, 0))
        let c1 = q.rotate(Vec3(0, 1, 0))
        let c2 = q.rotate(Vec3(0, 0, 1))
        let r: [Double] = [c0.x, c1.x, c2.x,
                           c0.y, c1.y, c2.y,
                           c0.z, c1.z, c2.z]
        let rt: [Double] = [r[0], r[3], r[6],
                            r[1], r[4], r[7],
                            r[2], r[5], r[8]]
        func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
            var m = [Double](repeating: 0, count: 9)
            for i in 0..<3 {
                for j in 0..<3 {
                    m[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
                }
            }
            return m
        }
        return multiply(multiply(r, inertia), rt)
    }
}
