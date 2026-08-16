//
//  FoxgloveBridge.swift
//  KineticBridge
//
//  Serves the Foxglove WebSocket protocol (`foxglove.websocket.v1`) directly
//  from a running simulation. Any Foxglove client — desktop or web — can point
//  at ws://localhost:8765 and get the live scene in its 3D panel, transforms in
//  its TF tree, and every joint, sensor and solver statistic as plottable
//  topics. No ROS, no bag conversion, no bridge process.
//
//  Kinetic's own Studio consumes the same socket, so what you debug locally and
//  what a teammate sees remotely are byte-identical.
//

import Foundation
import Kinetic

public struct BridgeChannel: Sendable {
    public let id: Int
    public let topic: String
    public let schemaName: String
    let schema: String
}

public final class FoxgloveBridge {
    public private(set) var server = WebSocketServer()
    public let world: World
    public var publishRate: Double = 30 {
        didSet { publishInterval = publishRate > 0 ? 1.0 / publishRate : 0 }
    }
    public var onLog: ((String) -> Void)?
    public private(set) var publishedFrameCount = 0

    private var publishInterval: Double = 1.0 / 30.0
    private var lastPublishTime: Double = -1
    private let lock = NSLock()
    /// channelId -> [subscriptionId] per connection
    private var subscriptions: [Int: [(connection: WebSocketConnectionID, subscription: UInt32)]] = [:]
    private var clientChannels: [WebSocketConnectionID: [UInt32: String]] = [:]

    private let channels: [BridgeChannel]
    private var cachedGeomInfo: [GeomInfo] = []

    public enum Topic: Int, CaseIterable {
        case scene = 1
        case contacts = 2
        case transforms = 3
        case state = 4
        case profile = 5
        case sensors = 6
    }

    public init(world: World) {
        self.world = world
        self.channels = [
            BridgeChannel(id: Topic.scene.rawValue, topic: "/kinetic/scene",
                          schemaName: "foxglove.SceneUpdate", schema: Schemas.sceneUpdate),
            BridgeChannel(id: Topic.contacts.rawValue, topic: "/kinetic/contacts",
                          schemaName: "foxglove.SceneUpdate", schema: Schemas.sceneUpdate),
            BridgeChannel(id: Topic.transforms.rawValue, topic: "/kinetic/tf",
                          schemaName: "foxglove.FrameTransforms", schema: Schemas.frameTransforms),
            BridgeChannel(id: Topic.state.rawValue, topic: "/kinetic/state",
                          schemaName: "kinetic.State", schema: Schemas.state),
            BridgeChannel(id: Topic.profile.rawValue, topic: "/kinetic/profile",
                          schemaName: "kinetic.StepProfile", schema: Schemas.profile),
            BridgeChannel(id: Topic.sensors.rawValue, topic: "/kinetic/sensors",
                          schemaName: "kinetic.Sensors", schema: Schemas.sensors),
        ]
        server.supportedSubprotocols = ["foxglove.websocket.v1"]
        server.delegate = self
    }

    public var isRunning: Bool {
        if case .listening = server.state { return true }
        return false
    }

    public var connectionCount: Int { server.connectionCount }

    public func start(port: UInt16 = 8765) throws {
        cachedGeomInfo = world.geomInfo
        try server.start(port: port)
    }

    public func stop() {
        server.stop()
        lock.lock()
        subscriptions.removeAll()
        lock.unlock()
    }

    /// Publishes one frame if enough wall-clock time has passed. Safe to call
    /// after every simulation step.
    public func publishIfNeeded(now: Double = CACurrentMediaTimeShim()) {
        guard isRunning else { return }
        if lastPublishTime >= 0 && now - lastPublishTime < publishInterval { return }
        lastPublishTime = now
        publish()
    }

    public func publish() {
        guard isRunning else { return }
        lock.lock()
        let snapshot = subscriptions
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        let timestamp = world.time
        for (channelID, subscribers) in snapshot {
            guard let topic = Topic(rawValue: channelID) else { continue }
            let payload: Data
            switch topic {
            case .scene: payload = Data(encodeScene(time: timestamp).utf8)
            case .contacts: payload = Data(encodeContacts(time: timestamp).utf8)
            case .transforms: payload = Data(encodeTransforms(time: timestamp).utf8)
            case .state: payload = Data(encodeState().utf8)
            case .profile: payload = Data(encodeProfile().utf8)
            case .sensors: payload = Data(encodeSensors().utf8)
            }
            for subscriber in subscribers {
                var message = Data()
                message.append(0x01)
                appendLittleEndian(&message, UInt32(subscriber.subscription))
                appendLittleEndian(&message, UInt64(max(timestamp, 0) * 1_000_000_000))
                message.append(payload)
                server.sendBinary(message, to: subscriber.connection)
            }
        }
        publishedFrameCount += 1
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // MARK: Encoders

    private func timestampJSON(_ time: Double) -> String {
        let sec = Int(time)
        let nsec = Int((time - Double(sec)) * 1_000_000_000)
        return "{\"sec\":\(sec),\"nsec\":\(nsec)}"
    }

    /// foxglove.SceneUpdate carrying every visible geom as a primitive. This is
    /// what makes a Kinetic world render inside Foxglove's own 3D panel.
    private func encodeScene(time: Double) -> String {
        if cachedGeomInfo.count != world.geomCount { cachedGeomInfo = world.geomInfo }
        let poses = world.geomPoses()
        var out = "{\"deletions\":[],\"entities\":["
        var first = true

        for (index, geom) in cachedGeomInfo.enumerated() {
            guard geom.visible, index < poses.count else { continue }
            if case .plane = geom.shape { continue }
            let pose = poses[index]
            let color = geom.appearance.color
            let colorJSON = "{\"r\":\(f(color.x)),\"g\":\(f(color.y)),\"b\":\(f(color.z)),\"a\":\(f(color.w))}"
            let poseJSON = "{\"position\":{\"x\":\(f(pose.position.x)),\"y\":\(f(pose.position.y)),\"z\":\(f(pose.position.z))},"
                + "\"orientation\":{\"x\":\(f(pose.orientation.x)),\"y\":\(f(pose.orientation.y)),"
                + "\"z\":\(f(pose.orientation.z)),\"w\":\(f(pose.orientation.w))}}"

            var cubes = "", spheres = "", cylinders = ""
            switch geom.shape {
            case .box(let h):
                cubes = "{\"pose\":\(poseJSON),\"size\":{\"x\":\(f(h.x * 2)),\"y\":\(f(h.y * 2)),\"z\":\(f(h.z * 2))},\"color\":\(colorJSON)}"
            case .sphere(let r):
                spheres = "{\"pose\":\(poseJSON),\"size\":{\"x\":\(f(r * 2)),\"y\":\(f(r * 2)),\"z\":\(f(r * 2))},\"color\":\(colorJSON)}"
            case .cylinder(let r, let hl):
                cylinders = "{\"pose\":\(poseJSON),\"size\":{\"x\":\(f(r * 2)),\"y\":\(f(r * 2)),\"z\":\(f(hl * 2))},\"bottom_scale\":1,\"top_scale\":1,\"color\":\(colorJSON)}"
            case .capsule(let r, let hl):
                // Foxglove has no capsule primitive: a cylinder plus two end
                // spheres reproduces the silhouette exactly.
                cylinders = "{\"pose\":\(poseJSON),\"size\":{\"x\":\(f(r * 2)),\"y\":\(f(r * 2)),\"z\":\(f(hl * 2))},\"bottom_scale\":1,\"top_scale\":1,\"color\":\(colorJSON)}"
                let top = pose.apply(Vec3(0, 0, hl))
                let bottom = pose.apply(Vec3(0, 0, -hl))
                spheres = capSphere(top, r, colorJSON) + "," + capSphere(bottom, r, colorJSON)
            case .plane, .convexHull:
                continue
            }

            if !first { out += "," }
            first = false
            out += "{\"timestamp\":\(timestampJSON(time)),\"frame_id\":\"world\","
            out += "\"id\":\"\(geom.name.isEmpty ? "geom\(index)" : geom.name)_\(index)\","
            out += "\"lifetime\":{\"sec\":0,\"nsec\":0},\"frame_locked\":false,"
            out += "\"metadata\":[],\"arrows\":[],\"lines\":[],\"triangles\":[],\"texts\":[],\"models\":[],"
            out += "\"cubes\":[\(cubes)],\"spheres\":[\(spheres)],\"cylinders\":[\(cylinders)]}"
        }
        out += "]}"
        return out
    }

    private func capSphere(_ position: Vec3, _ radius: Double, _ color: String) -> String {
        "{\"pose\":{\"position\":{\"x\":\(f(position.x)),\"y\":\(f(position.y)),\"z\":\(f(position.z))},"
            + "\"orientation\":{\"x\":0,\"y\":0,\"z\":0,\"w\":1}},"
            + "\"size\":{\"x\":\(f(radius * 2)),\"y\":\(f(radius * 2)),\"z\":\(f(radius * 2))},"
            + "\"color\":\(color)}"
    }

    private func encodeContacts(time: Double) -> String {
        let contacts = world.contacts()
        var spheres = ""
        var arrows = ""
        for (i, contact) in contacts.enumerated() {
            if i > 0 {
                spheres += ","
                arrows += ","
            }
            let color = "{\"r\":1,\"g\":0.42,\"b\":0.21,\"a\":0.95}"
            spheres += capSphere(contact.point, 0.012, color)
            let magnitude = contact.force.length
            let scale = min(0.4, magnitude * 0.004)
            let dir = magnitude > 1e-6 ? contact.force / magnitude : Vec3(0, 0, 1)
            let rotation = quaternionFromZ(to: dir)
            arrows += "{\"pose\":{\"position\":{\"x\":\(f(contact.point.x)),\"y\":\(f(contact.point.y)),\"z\":\(f(contact.point.z))},"
                + "\"orientation\":{\"x\":\(f(rotation.x)),\"y\":\(f(rotation.y)),\"z\":\(f(rotation.z)),\"w\":\(f(rotation.w))}},"
                + "\"shaft_length\":\(f(scale * 0.75)),\"shaft_diameter\":0.006,"
                + "\"head_length\":\(f(scale * 0.25)),\"head_diameter\":0.014,"
                + "\"color\":{\"r\":1,\"g\":0.75,\"b\":0.35,\"a\":0.9}}"
        }
        return "{\"deletions\":[],\"entities\":[{\"timestamp\":\(timestampJSON(time)),"
            + "\"frame_id\":\"world\",\"id\":\"contacts\",\"lifetime\":{\"sec\":0,\"nsec\":100000000},"
            + "\"frame_locked\":false,\"metadata\":[],\"cubes\":[],\"cylinders\":[],\"lines\":[],"
            + "\"triangles\":[],\"texts\":[],\"models\":[],"
            + "\"spheres\":[\(spheres)],\"arrows\":[\(arrows)]}]}"
    }

    /// Arrow primitives point along +X in Foxglove, so this maps +Z (the
    /// direction Kinetic reports forces in) onto that convention.
    private func quaternionFromZ(to direction: Vec3) -> Quat {
        let from = Vec3(1, 0, 0)
        let d = direction.normalized
        let dot = from.dot(d)
        if dot > 0.99999 { return .identity }
        if dot < -0.99999 { return Quat(axis: Vec3(0, 0, 1), angle: .pi) }
        let axis = from.cross(d)
        return Quat(axis: axis, angle: acos(max(-1, min(1, dot))))
    }

    private func encodeTransforms(time: Double) -> String {
        let poses = world.linkPoses()
        var names: [String] = []
        for a in 0..<world.articulationCount {
            let articulation = world.name(articulation: a)
            for l in 0..<world.linkCount(articulation: a) {
                names.append("\(articulation)/\(world.name(articulation: a, link: l))")
            }
        }
        var out = "{\"transforms\":["
        for (index, pose) in poses.enumerated() {
            if index > 0 { out += "," }
            let child = index < names.count ? names[index] : "link\(index)"
            out += "{\"timestamp\":\(timestampJSON(time)),\"parent_frame_id\":\"world\","
            out += "\"child_frame_id\":\"\(child)\","
            out += "\"translation\":{\"x\":\(f(pose.position.x)),\"y\":\(f(pose.position.y)),\"z\":\(f(pose.position.z))},"
            out += "\"rotation\":{\"x\":\(f(pose.orientation.x)),\"y\":\(f(pose.orientation.y)),"
            out += "\"z\":\(f(pose.orientation.z)),\"w\":\(f(pose.orientation.w))}}"
        }
        out += "]}"
        return out
    }

    private func encodeState() -> String {
        var out = "{\"time\":\(f(world.time)),"
        out += "\"qpos\":[\(world.positions.map { f($0) }.joined(separator: ","))],"
        out += "\"qvel\":[\(world.velocities.map { f($0) }.joined(separator: ","))],"
        out += "\"ctrl\":[\(world.control.map { f($0) }.joined(separator: ","))],"
        out += "\"actuator_force\":[\(world.actuatorForces.map { f($0) }.joined(separator: ","))],"
        let com = world.centerOfMass
        out += "\"com\":{\"x\":\(f(com.x)),\"y\":\(f(com.y)),\"z\":\(f(com.z))},"
        out += "\"kinetic_energy\":\(f(world.kineticEnergy)),"
        out += "\"potential_energy\":\(f(world.potentialEnergy))}"
        return out
    }

    private func encodeProfile() -> String {
        let p = world.profile
        return "{\"total_ms\":\(f(p.total)),\"collision_ms\":\(f(p.collision)),"
            + "\"solve_ms\":\(f(p.solve)),\"inertia_ms\":\(f(p.inertia)),"
            + "\"constraint_setup_ms\":\(f(p.constraintSetup)),\"integrate_ms\":\(f(p.integrate)),"
            + "\"contacts\":\(p.contactCount),\"constraints\":\(p.constraintCount),"
            + "\"broadphase_pairs\":\(p.broadphasePairs),\"solver_iterations\":\(p.solverIterations),"
            + "\"solver_residual\":\(f(p.solverResidual))}"
    }

    private func encodeSensors() -> String {
        var out = "{\"time\":\(f(world.time)),\"values\":{"
        var index = 0
        var first = true
        for (i, name) in world.sensorNames.enumerated() {
            let dimension = i < world.sensorKinds.count ? world.sensorKinds[i].dimension : 1
            var values: [String] = []
            for k in 0..<dimension {
                let flat = index + k
                values.append(flat < world.sensorReadings.count ? f(world.sensorReadings[flat]) : "0")
            }
            index += dimension
            if !first { out += "," }
            first = false
            let key = name.isEmpty ? "sensor\(i)" : name
            out += dimension == 1 ? "\"\(key)\":\(values[0])"
                                  : "\"\(key)\":[\(values.joined(separator: ","))]"
        }
        out += "}}"
        return out
    }

    private func f(_ value: Double) -> String {
        if !value.isFinite { return "0" }
        return String(format: "%.6g", value)
    }
}

// MARK: - Protocol handling

extension FoxgloveBridge: WebSocketServerDelegate {
    public func webSocket(_ server: WebSocketServer, didConnect id: WebSocketConnectionID,
                          subprotocol: String?) {
        onLog?("client connected (\(subprotocol ?? "no subprotocol"))")
        let info = """
        {"op":"serverInfo","name":"Kinetic","capabilities":["clientPublish"],\
        "supportedEncodings":["json"],"metadata":{"engine":"\(World.versionString)"},\
        "sessionId":"\(UInt64(Date().timeIntervalSince1970))"}
        """
        server.sendText(info, to: id)

        let channelJSON = channels.map { channel in
            "{\"id\":\(channel.id),\"topic\":\"\(channel.topic)\",\"encoding\":\"json\","
                + "\"schemaName\":\"\(channel.schemaName)\",\"schemaEncoding\":\"jsonschema\","
                + "\"schema\":\(escapeJSONString(channel.schema))}"
        }.joined(separator: ",")
        server.sendText("{\"op\":\"advertise\",\"channels\":[\(channelJSON)]}", to: id)
    }

    public func webSocket(_ server: WebSocketServer, didDisconnect id: WebSocketConnectionID) {
        lock.lock()
        for (channel, subscribers) in subscriptions {
            subscriptions[channel] = subscribers.filter { $0.connection != id }
            if subscriptions[channel]?.isEmpty == true { subscriptions[channel] = nil }
        }
        clientChannels[id] = nil
        lock.unlock()
        onLog?("client disconnected")
    }

    public func webSocket(_ server: WebSocketServer, didReceiveText text: String,
                          from id: WebSocketConnectionID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? String
        else { return }

        switch op {
        case "subscribe":
            guard let items = json["subscriptions"] as? [[String: Any]] else { return }
            lock.lock()
            for item in items {
                guard let subscriptionID = item["id"] as? Int,
                      let channelID = item["channelId"] as? Int else { continue }
                subscriptions[channelID, default: []].append((id, UInt32(subscriptionID)))
            }
            lock.unlock()
            publish()
        case "unsubscribe":
            guard let ids = json["subscriptionIds"] as? [Int] else { return }
            let removal = Set(ids.map { UInt32($0) })
            lock.lock()
            for (channel, subscribers) in subscriptions {
                subscriptions[channel] = subscribers.filter {
                    !($0.connection == id && removal.contains($0.subscription))
                }
                if subscriptions[channel]?.isEmpty == true { subscriptions[channel] = nil }
            }
            lock.unlock()
        case "advertise":
            guard let items = json["channels"] as? [[String: Any]] else { return }
            lock.lock()
            for item in items {
                if let channelID = item["id"] as? Int, let topic = item["topic"] as? String {
                    clientChannels[id, default: [:]][UInt32(channelID)] = topic
                }
            }
            lock.unlock()
        default:
            break
        }
    }

    public func webSocket(_ server: WebSocketServer, didReceiveBinary data: Data,
                          from id: WebSocketConnectionID) {
        // Client message data: [0x01][uint32 channelId][payload]
        guard data.count > 5, data[data.startIndex] == 0x01 else { return }
        let payload = data.subdata(in: data.index(data.startIndex, offsetBy: 5)..<data.endIndex)
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return }

        // Remote control input: either a full vector or one indexed actuator.
        if let values = json["control"] as? [Double] {
            let control = world.control
            for (i, value) in values.enumerated() where i < control.count { control[i] = value }
        } else if let index = json["index"] as? Int, let value = json["value"] as? Double,
                  index >= 0, index < world.actuatorCount {
            world.control[index] = value
        }
    }

    private func escapeJSONString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string], options: [])
        guard let data, var text = String(data: data, encoding: .utf8) else { return "\"\"" }
        text.removeFirst()
        text.removeLast()
        return text
    }
}

/// CACurrentMediaTime without pulling QuartzCore into this target.
public func CACurrentMediaTimeShim() -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let nanos = Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom)
    return nanos / 1_000_000_000
}

enum Schemas {
    static let sceneUpdate = """
    {"type":"object","title":"foxglove.SceneUpdate","properties":{\
    "deletions":{"type":"array","items":{"type":"object"}},\
    "entities":{"type":"array","items":{"type":"object","properties":{\
    "timestamp":{"type":"object"},"frame_id":{"type":"string"},"id":{"type":"string"},\
    "lifetime":{"type":"object"},"frame_locked":{"type":"boolean"},\
    "cubes":{"type":"array","items":{"type":"object"}},\
    "spheres":{"type":"array","items":{"type":"object"}},\
    "cylinders":{"type":"array","items":{"type":"object"}},\
    "arrows":{"type":"array","items":{"type":"object"}},\
    "lines":{"type":"array","items":{"type":"object"}}}}}}}
    """

    static let frameTransforms = """
    {"type":"object","title":"foxglove.FrameTransforms","properties":{\
    "transforms":{"type":"array","items":{"type":"object","properties":{\
    "timestamp":{"type":"object"},"parent_frame_id":{"type":"string"},\
    "child_frame_id":{"type":"string"},"translation":{"type":"object"},\
    "rotation":{"type":"object"}}}}}}
    """

    static let state = """
    {"type":"object","title":"kinetic.State","properties":{\
    "time":{"type":"number"},"qpos":{"type":"array","items":{"type":"number"}},\
    "qvel":{"type":"array","items":{"type":"number"}},\
    "ctrl":{"type":"array","items":{"type":"number"}},\
    "actuator_force":{"type":"array","items":{"type":"number"}},\
    "com":{"type":"object"},"kinetic_energy":{"type":"number"},\
    "potential_energy":{"type":"number"}}}
    """

    static let profile = """
    {"type":"object","title":"kinetic.StepProfile","properties":{\
    "total_ms":{"type":"number"},"collision_ms":{"type":"number"},\
    "solve_ms":{"type":"number"},"contacts":{"type":"integer"},\
    "constraints":{"type":"integer"},"solver_iterations":{"type":"integer"},\
    "solver_residual":{"type":"number"}}}
    """

    static let sensors = """
    {"type":"object","title":"kinetic.Sensors","properties":{\
    "time":{"type":"number"},"values":{"type":"object"}}}
    """
}
