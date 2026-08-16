//
//  MJCF.swift
//  Kinetic
//
//  Importer for the MuJoCo XML dialect (MJCF). Covers the modelling subset that
//  describes rigid-body physics: options, class defaults, the worldbody tree,
//  joints, geoms, actuators and sensors.
//
//  Frame note: MuJoCo puts the body frame at `body/@pos` and expresses the joint
//  anchor inside that frame. Kinetic puts the link frame *at the joint anchor*.
//  The importer therefore shifts every geom, inertial and child body by the
//  anchor offset. The two conventions describe the same mechanism.
//

import Foundation

public struct MJCFImportOptions: Sendable {
    public var meshLibrary: MeshLibrary? = nil
    public var onWarning: (@Sendable (String) -> Void)? = nil
    public var defaultDensity: Double = 1000
    public var addActuators: Bool = true
    public var selfCollision: Bool = true
    public var applyOptions: Bool = true
    public init() {}
}

public enum MJCFError: Error, CustomStringConvertible {
    case unreadable(URL)
    case noMujocoElement
    case malformed(String)

    public var description: String {
        switch self {
        case .unreadable(let url): return "cannot read MJCF at \(url.path)"
        case .noMujocoElement: return "no <mujoco> root element"
        case .malformed(let d): return "malformed MJCF: \(d)"
        }
    }
}

public enum MJCF {
    private struct Defaults {
        var geomType = "sphere"
        var geomSize: [Double] = [0.05]
        var geomRGBA = Vec4(0.7, 0.72, 0.75, 1)
        var geomFriction: Double = 1.0
        var geomDensity: Double = 1000
        var jointDamping: Double = 0
        var jointArmature: Double = 0
        var jointStiffness: Double = 0
        var jointLimited = false
        var jointRange: ClosedRange<Double>? = nil
        var actuatorKp: Double = 100
        var actuatorKd: Double = 0
        var actuatorGear: Double = 1
    }

    private static func attr(_ e: XMLElement, _ n: String) -> String? {
        e.attribute(forName: n)?.stringValue
    }

    private static func numbers(_ s: String?) -> [Double] {
        guard let s else { return [] }
        return s.split(whereSeparator: { " \t\n,".contains($0) }).compactMap { Double($0) }
    }

    private static func vec3(_ s: String?, default def: Vec3 = .zero) -> Vec3 {
        let v = numbers(s)
        return v.count >= 3 ? Vec3(v[0], v[1], v[2]) : def
    }

    private static func orientation(of e: XMLElement) -> Quat {
        if let q = attr(e, "quat") {
            let v = numbers(q)
            if v.count >= 4 { return Quat(w: v[0], x: v[1], y: v[2], z: v[3]).normalized }
        }
        if let e2 = attr(e, "euler") {
            let v = numbers(e2)
            if v.count >= 3 { return Quat(roll: v[0], pitch: v[1], yaw: v[2]) }
        }
        if let a = attr(e, "axisangle") {
            let v = numbers(a)
            if v.count >= 4 { return Quat(axis: Vec3(v[0], v[1], v[2]), angle: v[3]) }
        }
        if let zaxis = attr(e, "zaxis") {
            let v = numbers(zaxis)
            if v.count >= 3 {
                let target = Vec3(v[0], v[1], v[2]).normalized
                let axis = Vec3(0, 0, 1).cross(target)
                let angle = acos(max(-1, min(1, Vec3(0, 0, 1).dot(target))))
                if axis.length < 1e-9 { return angle > 1 ? Quat(axis: Vec3(1, 0, 0), angle: .pi) : .identity }
                return Quat(axis: axis, angle: angle)
            }
        }
        return .identity
    }

    public static func load(contentsOf url: URL, into world: World? = nil,
                            options: MJCFImportOptions = MJCFImportOptions()) throws
        -> (world: World, robot: Robot)
    {
        guard let data = try? Data(contentsOf: url) else { throw MJCFError.unreadable(url) }
        return try load(data: data, into: world, options: options)
    }

    public static func load(data: Data, into existing: World? = nil,
                            options: MJCFImportOptions = MJCFImportOptions()) throws
        -> (world: World, robot: Robot)
    {
        let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "mujoco" else {
            throw MJCFError.noMujocoElement
        }
        let world = existing ?? World()
        let robot = try build(root: root, world: world, options: options)
        if existing == nil { world.compile() }
        return (world, robot)
    }

    private static func build(root: XMLElement, world: World,
                              options: MJCFImportOptions) throws -> Robot {
        let modelName = attr(root, "model") ?? "mjcf"

        if options.applyOptions, let opt = root.elements(forName: "option").first {
            var sim = world.options
            if let ts = attr(opt, "timestep").flatMap(Double.init) { sim.timestep = ts }
            let g = numbers(attr(opt, "gravity"))
            if g.count >= 3 { sim.gravity = Vec3(g[0], g[1], g[2]) }
            if let iter = attr(opt, "iterations").flatMap({ Int($0) }) { sim.solverIterations = iter }
            world.options = sim
        }

        var defaults = Defaults()
        defaults.geomDensity = options.defaultDensity
        var classDefaults: [String: Defaults] = [:]
        if let defaultRoot = root.elements(forName: "default").first {
            defaults = applyDefaults(defaultRoot, base: defaults)
            for sub in defaultRoot.elements(forName: "default") {
                guard let className = attr(sub, "class") else { continue }
                classDefaults[className] = applyDefaults(sub, base: defaults)
            }
        }

        guard let worldbody = root.elements(forName: "worldbody").first else {
            throw MJCFError.malformed("missing <worldbody>")
        }

        // <asset><mesh name file scale/></asset>
        let meshes = options.meshLibrary ?? MeshLibrary()
        if let compiler = root.elements(forName: "compiler").first,
           let dir = attr(compiler, "meshdir") {
            meshes.addSearchPath(URL(fileURLWithPath: dir))
        }
        var meshShapes: [String: Shape] = [:]
        if let assets = root.elements(forName: "asset").first {
            for element in assets.elements(forName: "mesh") {
                guard let name = attr(element, "name") ?? attr(element, "file") else { continue }
                let file = attr(element, "file") ?? name
                let scaleValues = numbers(attr(element, "scale"))
                let scale = scaleValues.count >= 3
                    ? Vec3(scaleValues[0], scaleValues[1], scaleValues[2])
                    : Vec3(1, 1, 1)
                guard let mesh = try? meshes.load(file, scale: scale) else {
                    options.onWarning?("could not resolve mesh '\(file)'")
                    continue
                }
                let index = world.addMesh(vertices: mesh.hullVertices, indices: mesh.hullIndices,
                                          name: mesh.name)
                meshShapes[name] = .convexHull(mesh: index, boundingRadius: mesh.boundingRadius)
            }
        }

        let articulation = world.addArticulation(name: modelName)
        var linkNames: [String] = []
        var jointLinkByName: [String: Int] = [:]

        // Static geoms attached directly to the worldbody become a fixed root link.
        let rootLink = world.addLink(articulation: articulation, parent: -1, name: "world")
        world.setJoint(articulation: articulation, link: rootLink, .fixed)
        world.setInertial(articulation: articulation, link: rootLink, mass: 0, com: .zero,
                          inertia: Array(repeating: 0, count: 9))
        linkNames.append("world")
        for geom in worldbody.elements(forName: "geom") {
            addGeom(geom, to: world, articulation: articulation, link: rootLink,
                    anchorOffset: .zero, defaults: resolve(geom, defaults, classDefaults),
                    meshShapes: meshShapes)
        }

        func addBody(_ element: XMLElement, parentLink: Int, parentAnchor: Vec3) throws {
            let name = attr(element, "name") ?? "body\(linkNames.count)"
            let bodyPos = vec3(attr(element, "pos"))
            let bodyQuat = orientation(of: element)

            var joints = element.elements(forName: "joint")
            let freeJoints = element.elements(forName: "freejoint")
            let isFree = !freeJoints.isEmpty
                || joints.contains { attr($0, "type") == "free" }
            if isFree { joints = joints.filter { attr($0, "type") == "free" } }

            // Position of this body's frame expressed in the parent's link frame.
            let bodyOriginInParentLink = bodyPos - parentAnchor

            var currentParent = parentLink
            var currentLink = -1
            var anchorOffset = Vec3.zero
            let originForNext = Pose(position: bodyOriginInParentLink, orientation: bodyQuat)

            if isFree {
                currentLink = world.addLink(articulation: articulation, parent: currentParent,
                                            name: name)
                var spec = JointSpec(kind: .free)
                spec.origin = originForNext
                world.setJoint(articulation: articulation, link: currentLink, spec)
                linkNames.append(name)
                anchorOffset = .zero
            } else if joints.isEmpty {
                currentLink = world.addLink(articulation: articulation, parent: currentParent,
                                            name: name)
                var spec = JointSpec(kind: .fixed)
                spec.origin = originForNext
                world.setJoint(articulation: articulation, link: currentLink, spec)
                linkNames.append(name)
                anchorOffset = .zero
            } else {
                for (i, jointElement) in joints.enumerated() {
                    let jointName = attr(jointElement, "name") ?? "\(name)_j\(i)"
                    let anchor = vec3(attr(jointElement, "pos"))
                    let axis = vec3(attr(jointElement, "axis"), default: Vec3(0, 0, 1))
                    let d = resolve(jointElement, defaults, classDefaults)

                    var spec = JointSpec()
                    switch attr(jointElement, "type") ?? "hinge" {
                    case "slide": spec.kind = .prismatic
                    case "ball": spec.kind = .spherical
                    default: spec.kind = .revolute
                    }
                    spec.axis = axis
                    // Each successive joint's frame sits at its own anchor.
                    let origin = i == 0
                        ? Pose(position: originForNext.position + bodyQuat.rotate(anchor),
                               orientation: bodyQuat)
                        : Pose(position: anchor - anchorOffset)
                    spec.origin = origin
                    spec.damping = d.jointDamping
                    spec.armature = d.jointArmature
                    spec.stiffness = d.jointStiffness
                    let range = numbers(attr(jointElement, "range"))
                    if range.count >= 2 {
                        spec.limited = attr(jointElement, "limited") != "false"
                        spec.lower = range[0]
                        spec.upper = range[1]
                    } else if let r = d.jointRange {
                        spec.limited = d.jointLimited
                        spec.lower = r.lowerBound
                        spec.upper = r.upperBound
                    }

                    let linkName = joints.count == 1 ? name : "\(name)__\(jointName)"
                    let link = world.addLink(articulation: articulation, parent: currentParent,
                                             name: linkName)
                    world.setJoint(articulation: articulation, link: link, spec)
                    linkNames.append(linkName)
                    jointLinkByName[jointName] = link

                    if i < joints.count - 1 {
                        // Intermediate links carry no mass; the last one owns the body.
                        world.setInertial(articulation: articulation, link: link, mass: 1e-6,
                                          com: .zero,
                                          inertia: Inertia.sphere(mass: 1e-6, radius: 0.01))
                    }
                    currentParent = link
                    currentLink = link
                    anchorOffset = i == 0 ? anchor : anchorOffset + anchor
                }
            }

            // Inertial and geometry live on the final link of the chain.
            var totalMass = 0.0
            var comAccum = Vec3.zero
            var geomShapes: [(Shape, Pose, Double)] = []
            for geomElement in element.elements(forName: "geom") {
                let d = resolve(geomElement, defaults, classDefaults)
                if let (shape, pose, mass) = geomDescription(geomElement, defaults: d,
                                                            meshShapes: meshShapes) {
                    geomShapes.append((shape, pose, mass))
                    totalMass += mass
                    comAccum += pose.position * mass
                }
                addGeom(geomElement, to: world, articulation: articulation, link: currentLink,
                        anchorOffset: anchorOffset, defaults: d, meshShapes: meshShapes)
            }

            if let inertial = element.elements(forName: "inertial").first {
                let mass = attr(inertial, "mass").flatMap(Double.init) ?? totalMass
                let pos = vec3(attr(inertial, "pos")) - anchorOffset
                let diag = numbers(attr(inertial, "diaginertia"))
                var inertia: [Double]
                if diag.count >= 3 {
                    inertia = Vec3(diag[0], diag[1], diag[2]).diagonalInertia
                } else {
                    let full = numbers(attr(inertial, "fullinertia"))
                    if full.count >= 6 {
                        inertia = [full[0], full[3], full[4],
                                   full[3], full[1], full[5],
                                   full[4], full[5], full[2]]
                    } else {
                        inertia = Inertia.sphere(mass: mass, radius: 0.05)
                    }
                }
                inertia = URDF.rotateInertia(inertia, by: orientation(of: inertial))
                world.setInertial(articulation: articulation, link: currentLink, mass: mass,
                                  com: pos, inertia: inertia)
            } else if totalMass > 0 {
                let com = comAccum / totalMass - anchorOffset
                var inertia = [Double](repeating: 0, count: 9)
                for (shape, pose, mass) in geomShapes {
                    let local = shape.inertia(mass: mass)
                    let offset = pose.position - anchorOffset - com
                    // Parallel-axis transfer of each geom's tensor to the body com.
                    let d2 = offset.dot(offset)
                    for i in 0..<3 {
                        for j in 0..<3 {
                            let delta = (i == j ? d2 : 0) - offset[i] * offset[j]
                            inertia[i * 3 + j] += local[i * 3 + j] + mass * delta
                        }
                    }
                }
                world.setInertial(articulation: articulation, link: currentLink, mass: totalMass,
                                  com: com, inertia: inertia)
            } else {
                world.setInertial(articulation: articulation, link: currentLink, mass: 1e-5,
                                  com: .zero, inertia: Inertia.sphere(mass: 1e-5, radius: 0.02))
            }

            for childBody in element.elements(forName: "body") {
                try addBody(childBody, parentLink: currentLink, parentAnchor: anchorOffset)
            }
        }

        for body in worldbody.elements(forName: "body") {
            try addBody(body, parentLink: rootLink, parentAnchor: .zero)
        }

        var actuators: [Int] = []
        if options.addActuators, let actuatorRoot = root.elements(forName: "actuator").first {
            for element in actuatorRoot.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard let jointName = attr(element, "joint"),
                      let link = jointLinkByName[jointName] else { continue }
                let d = resolve(element, defaults, classDefaults)
                var spec = ActuatorSpec(name: attr(element, "name") ?? jointName,
                                        kind: .motor, articulation: articulation, link: link)
                switch element.name {
                case "position":
                    spec.kind = .position
                    spec.kp = attr(element, "kp").flatMap(Double.init) ?? d.actuatorKp
                    spec.kd = attr(element, "kv").flatMap(Double.init) ?? d.actuatorKd
                case "velocity":
                    spec.kind = .velocity
                    spec.kp = attr(element, "kv").flatMap(Double.init) ?? d.actuatorKp
                case "damper":
                    spec.kind = .damper
                default:
                    spec.kind = .motor
                }
                let gear = numbers(attr(element, "gear"))
                spec.gear = gear.first ?? d.actuatorGear
                let ctrl = numbers(attr(element, "ctrlrange"))
                if ctrl.count >= 2 { spec.controlRange = ctrl[0]...ctrl[1] }
                let force = numbers(attr(element, "forcerange"))
                if force.count >= 2 { spec.forceRange = force[0]...force[1] }
                actuators.append(world.addActuator(spec))
            }
        }

        world.setSelfCollision(articulation: articulation, enabled: options.selfCollision)
        return Robot(articulation: articulation, name: modelName, links: linkNames,
                     actuators: actuators)
    }

    private static func applyDefaults(_ element: XMLElement, base: Defaults) -> Defaults {
        var d = base
        if let geom = element.elements(forName: "geom").first {
            if let t = attr(geom, "type") { d.geomType = t }
            let size = numbers(attr(geom, "size"))
            if !size.isEmpty { d.geomSize = size }
            let rgba = numbers(attr(geom, "rgba"))
            if rgba.count >= 4 { d.geomRGBA = Vec4(rgba[0], rgba[1], rgba[2], rgba[3]) }
            if let f = numbers(attr(geom, "friction")).first { d.geomFriction = f }
            if let den = attr(geom, "density").flatMap(Double.init) { d.geomDensity = den }
        }
        if let joint = element.elements(forName: "joint").first {
            if let v = attr(joint, "damping").flatMap(Double.init) { d.jointDamping = v }
            if let v = attr(joint, "armature").flatMap(Double.init) { d.jointArmature = v }
            if let v = attr(joint, "stiffness").flatMap(Double.init) { d.jointStiffness = v }
            let range = numbers(attr(joint, "range"))
            if range.count >= 2 {
                d.jointRange = range[0]...range[1]
                d.jointLimited = true
            }
        }
        if let position = element.elements(forName: "position").first {
            if let v = attr(position, "kp").flatMap(Double.init) { d.actuatorKp = v }
            if let v = attr(position, "kv").flatMap(Double.init) { d.actuatorKd = v }
        }
        return d
    }

    private static func resolve(_ element: XMLElement, _ base: Defaults,
                                _ classes: [String: Defaults]) -> Defaults {
        if let className = attr(element, "class"), let d = classes[className] { return d }
        return base
    }

    private static func geomDescription(_ element: XMLElement, defaults: Defaults,
                                        meshShapes: [String: Shape] = [:])
        -> (Shape, Pose, Double)? {
        let type = attr(element, "type") ?? defaults.geomType
        var size = numbers(attr(element, "size"))
        if size.isEmpty { size = defaults.geomSize }
        let pos = vec3(attr(element, "pos"))
        let quat = orientation(of: element)
        var pose = Pose(position: pos, orientation: quat)

        // fromto describes capsules/cylinders by their end points.
        let fromto = numbers(attr(element, "fromto"))
        var halfLength: Double? = nil
        if fromto.count >= 6 {
            let a = Vec3(fromto[0], fromto[1], fromto[2])
            let b = Vec3(fromto[3], fromto[4], fromto[5])
            let mid = (a + b) * 0.5
            let dir = (b - a)
            halfLength = dir.length * 0.5
            let axis = Vec3(0, 0, 1).cross(dir.normalized)
            let angle = acos(max(-1, min(1, Vec3(0, 0, 1).dot(dir.normalized))))
            let rot = axis.length < 1e-9 ? Quat.identity : Quat(axis: axis, angle: angle)
            pose = Pose(position: mid, orientation: rot)
        }

        let shape: Shape
        switch type {
        case "box":
            guard size.count >= 3 else { return nil }
            shape = .box(halfExtents: Vec3(size[0], size[1], size[2]))
        case "capsule":
            guard let r = size.first else { return nil }
            shape = .capsule(radius: r, halfLength: halfLength ?? (size.count > 1 ? size[1] : r))
        case "cylinder":
            guard let r = size.first else { return nil }
            shape = .cylinder(radius: r, halfLength: halfLength ?? (size.count > 1 ? size[1] : r))
        case "plane":
            shape = .plane(extent: size.first ?? 40)
        case "mesh":
            guard let name = attr(element, "mesh"), let resolved = meshShapes[name] else {
                return nil
            }
            shape = resolved
        case "ellipsoid":
            shape = .sphere(radius: size.first ?? 0.05)
        default:
            shape = .sphere(radius: size.first ?? 0.05)
        }

        let explicitMass = attr(element, "mass").flatMap(Double.init)
        let density = attr(element, "density").flatMap(Double.init) ?? defaults.geomDensity
        let mass = explicitMass ?? shape.volume * density
        return (shape, pose, mass)
    }

    private static func addGeom(_ element: XMLElement, to world: World, articulation: Int,
                                link: Int, anchorOffset: Vec3, defaults: Defaults,
                                meshShapes: [String: Shape] = [:]) {
        guard let (shape, pose, _) = geomDescription(element, defaults: defaults,
                                                     meshShapes: meshShapes) else { return }
        var appearance = Appearance(color: defaults.geomRGBA)
        let rgba = numbers(attr(element, "rgba"))
        if rgba.count >= 4 { appearance.color = Vec4(rgba[0], rgba[1], rgba[2], rgba[3]) }

        var material = SurfaceMaterial()
        if let f = numbers(attr(element, "friction")).first { material.friction = f }
        else { material.friction = defaults.geomFriction }
        let solref = numbers(attr(element, "solref"))
        if solref.count >= 2 {
            material.stiffnessTimeConstant = abs(solref[0])
            material.dampingRatio = abs(solref[1])
        }

        let contype = attr(element, "contype").flatMap { UInt32($0) } ?? 1
        let conaffinity = attr(element, "conaffinity").flatMap { UInt32($0) } ?? 1

        var spec = GeomSpec(shape: shape,
                            localPose: Pose(position: pose.position - anchorOffset,
                                            orientation: pose.orientation),
                            material: material, appearance: appearance,
                            name: attr(element, "name") ?? "")
        spec.collidable = contype != 0
        spec.group = max(contype, 1)
        spec.mask = conaffinity == 0 ? 0 : .max
        world.addGeom(articulation: articulation, link: link, spec)
    }
}
