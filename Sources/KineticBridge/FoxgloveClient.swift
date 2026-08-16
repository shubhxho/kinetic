//
//  FoxgloveClient.swift
//  KineticBridge
//
//  The consuming half of the bridge. FoxgloveBridge lets any Foxglove client
//  watch a Kinetic world; this lets Kinetic Studio be the client — pointing at a
//  simulation running on another machine, a robot on the bench, or any other
//  server that speaks `foxglove.websocket.v1`.
//
//  INTEGRATION TEST: pointing this client at Studio's own server is the test.
//  Start FoxgloveBridge on 8765, call `connect(to: ws://localhost:8765)`, and a
//  correct implementation shows six channels, streams `/kinetic/state` into
//  `latest`, and moves the simulation when `publishControl` is called. That loop
//  exercises exactly the pieces that are easy to get wrong: the client masks its
//  frames (the server's decoder honours the mask bit, so an unmasked frame would
//  decode as garbage), the client verifies `Sec-WebSocket-Accept` against the
//  SHA-1 the server computes, and both sides agree that server-to-client message
//  data is [0x01][uint32 subId][uint64 ns][payload] while client-to-server
//  publishes drop the timestamp: [0x01][uint32 channelId][payload].
//
//  Everything decoded here is typed. The bridge's own topics get small Codable
//  structs; anything else is kept as opaque `Data` so an unknown schema is
//  passed through intact rather than smeared into a dictionary of `Any`.
//

import Combine
import Foundation

// MARK: - Values

public struct RemoteChannel: Identifiable, Hashable, Sendable {
    public let id: Int
    public let topic: String
    public let encoding: String
    public let schemaName: String

    public init(id: Int, topic: String, encoding: String, schemaName: String) {
        self.id = id
        self.topic = topic
        self.encoding = encoding
        self.schemaName = schemaName
    }
}

public struct RemoteServerInfo: Equatable, Sendable {
    public let name: String
    public let capabilities: [String]
    public let supportedEncodings: [String]
    public let sessionID: String?
    public let metadata: [String: String]

    /// A server that advertises `clientPublish` will accept `publishControl`.
    public var acceptsClientPublish: Bool { capabilities.contains("clientPublish") }
}

/// A 3-vector as the bridge writes it. Deliberately local to KineticBridge's
/// wire types: the client can be pointed at a server that is not Kinetic, so
/// nothing here should imply the engine's own math types.
public struct RemoteVector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        z = try container.decodeIfPresent(Double.self, forKey: .z) ?? 0
    }

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// `/kinetic/state`, schema `kinetic.State`.
///
/// Every field decodes with a default. A remote Kinetic may be a different build
/// that adds or drops a field, and losing the whole frame because one number
/// moved is worse than showing the rest of it.
public struct RemoteState: Codable, Equatable, Sendable {
    public var time: Double = 0
    public var positions: [Double] = []
    public var velocities: [Double] = []
    public var control: [Double] = []
    public var actuatorForces: [Double] = []
    public var centerOfMass = RemoteVector3()
    public var kineticEnergy: Double = 0
    public var potentialEnergy: Double = 0

    public var totalEnergy: Double { kineticEnergy + potentialEnergy }

    private enum CodingKeys: String, CodingKey {
        case time
        case positions = "qpos"
        case velocities = "qvel"
        case control = "ctrl"
        case actuatorForces = "actuator_force"
        case centerOfMass = "com"
        case kineticEnergy = "kinetic_energy"
        case potentialEnergy = "potential_energy"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(Double.self, forKey: .time) ?? 0
        positions = try container.decodeIfPresent([Double].self, forKey: .positions) ?? []
        velocities = try container.decodeIfPresent([Double].self, forKey: .velocities) ?? []
        control = try container.decodeIfPresent([Double].self, forKey: .control) ?? []
        actuatorForces = try container.decodeIfPresent([Double].self, forKey: .actuatorForces) ?? []
        centerOfMass = try container.decodeIfPresent(RemoteVector3.self, forKey: .centerOfMass)
            ?? RemoteVector3()
        kineticEnergy = try container.decodeIfPresent(Double.self, forKey: .kineticEnergy) ?? 0
        potentialEnergy = try container.decodeIfPresent(Double.self, forKey: .potentialEnergy) ?? 0
    }
}

/// `/kinetic/profile`, schema `kinetic.StepProfile`. Milliseconds throughout.
public struct RemoteProfile: Codable, Equatable, Sendable {
    public var totalMilliseconds: Double = 0
    public var collisionMilliseconds: Double = 0
    public var solveMilliseconds: Double = 0
    public var inertiaMilliseconds: Double = 0
    public var constraintSetupMilliseconds: Double = 0
    public var integrateMilliseconds: Double = 0
    public var contacts: Int = 0
    public var constraints: Int = 0
    public var broadphasePairs: Int = 0
    public var solverIterations: Int = 0
    public var solverResidual: Double = 0

    private enum CodingKeys: String, CodingKey {
        case totalMilliseconds = "total_ms"
        case collisionMilliseconds = "collision_ms"
        case solveMilliseconds = "solve_ms"
        case inertiaMilliseconds = "inertia_ms"
        case constraintSetupMilliseconds = "constraint_setup_ms"
        case integrateMilliseconds = "integrate_ms"
        case contacts
        case constraints
        case broadphasePairs = "broadphase_pairs"
        case solverIterations = "solver_iterations"
        case solverResidual = "solver_residual"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalMilliseconds = try container.decodeIfPresent(Double.self,
                                                          forKey: .totalMilliseconds) ?? 0
        collisionMilliseconds = try container.decodeIfPresent(Double.self,
                                                              forKey: .collisionMilliseconds) ?? 0
        solveMilliseconds = try container.decodeIfPresent(Double.self,
                                                          forKey: .solveMilliseconds) ?? 0
        inertiaMilliseconds = try container.decodeIfPresent(Double.self,
                                                            forKey: .inertiaMilliseconds) ?? 0
        constraintSetupMilliseconds = try container
            .decodeIfPresent(Double.self, forKey: .constraintSetupMilliseconds) ?? 0
        integrateMilliseconds = try container.decodeIfPresent(Double.self,
                                                              forKey: .integrateMilliseconds) ?? 0
        contacts = try container.decodeIfPresent(Int.self, forKey: .contacts) ?? 0
        constraints = try container.decodeIfPresent(Int.self, forKey: .constraints) ?? 0
        broadphasePairs = try container.decodeIfPresent(Int.self, forKey: .broadphasePairs) ?? 0
        solverIterations = try container.decodeIfPresent(Int.self, forKey: .solverIterations) ?? 0
        solverResidual = try container.decodeIfPresent(Double.self, forKey: .solverResidual) ?? 0
    }
}

/// One sensor's reading. The bridge writes a bare number for 1-D sensors and an
/// array for everything else, so the type has to admit both without falling back
/// to `Any`.
public enum RemoteSensorReading: Codable, Equatable, Sendable {
    case scalar(Double)
    case vector([Double])

    public var values: [Double] {
        switch self {
        case .scalar(let value): return [value]
        case .vector(let values): return values
        }
    }

    public var scalarValue: Double { values.first ?? 0 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .scalar(value)
        } else {
            self = .vector(try container.decode([Double].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .scalar(let value): try container.encode(value)
        case .vector(let values): try container.encode(values)
        }
    }
}

/// `/kinetic/sensors`, schema `kinetic.Sensors`.
public struct RemoteSensors: Codable, Equatable, Sendable {
    public var time: Double = 0
    public var values: [String: RemoteSensorReading] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(Double.self, forKey: .time) ?? 0
        values = try container.decodeIfPresent([String: RemoteSensorReading].self,
                                               forKey: .values) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case time, values
    }
}

/// What arrived on a topic. `.opaque` is not a failure mode — it is the correct
/// answer for `/kinetic/scene`, for a third-party server's topics, and for
/// anything whose shape this build does not know.
public enum RemotePayload: Equatable, Sendable {
    case state(RemoteState)
    case profile(RemoteProfile)
    case sensors(RemoteSensors)
    case opaque(Data)

    public var state: RemoteState? {
        if case .state(let value) = self { return value }
        return nil
    }

    public var profile: RemoteProfile? {
        if case .profile(let value) = self { return value }
        return nil
    }

    public var sensors: RemoteSensors? {
        if case .sensors(let value) = self { return value }
        return nil
    }

    /// The bytes as they arrived, whatever the case. Useful for a raw-message
    /// panel that wants to show JSON for a topic it cannot type.
    public var rawData: Data? {
        if case .opaque(let data) = self { return data }
        return nil
    }
}

public struct RemoteMessage: Equatable, Sendable {
    public let topic: String
    /// Wall-clock time this process received the frame.
    public let receivedAt: Date
    /// The publisher's own timestamp, in seconds, from the frame header.
    public let logTime: Double
    public let byteCount: Int
    public let payload: RemotePayload
}

// MARK: - Client

public final class FoxgloveClient: ObservableObject {

    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        /// Associated value is a human-readable description of the peer, e.g.
        /// "Kinetic — ws://localhost:8765".
        case connected(String)
        case failed(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// The subprotocol this client offers; a server that does not echo it back
    /// is not a Foxglove server and the handshake is failed by WebSocketClient.
    public static let subprotocol = "foxglove.websocket.v1"

    /// The topic a Kinetic server accepts control on. The server keys client
    /// publishes by channel id rather than topic, but naming it correctly is
    /// what makes the stream legible in someone else's Foxglove.
    public static let controlTopic = "/kinetic/control"

    /// Mirrors what `FoxgloveBridge` accepts on a client channel: a full control
    /// vector, applied element-wise to `world.control`.
    static let controlSchema = #"""
    {"type":"object","title":"kinetic.Control","properties":\#
    {"control":{"type":"array","items":{"type":"number"}}}}
    """#

    @Published public private(set) var channels: [RemoteChannel] = []
    @Published public private(set) var latest: [String: RemoteMessage] = [:]
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var subscribedTopics: Set<String> = []
    @Published public private(set) var serverInfo: RemoteServerInfo?
    @Published public private(set) var messagesReceived = 0

    public private(set) var url: URL?
    /// Diagnostics, mirroring `FoxgloveBridge.onLog`. Called on the socket queue.
    public var onLog: ((String) -> Void)?

    private var socket: WebSocketClient?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Guards everything below; the socket's callbacks land on its own queue
    /// while `subscribe`/`publishControl` are called from the UI.
    private let lock = NSLock()
    private var channelsByTopic: [String: RemoteChannel] = [:]
    private var subscriptionByTopic: [String: UInt32] = [:]
    private var topicBySubscription: [UInt32: String] = [:]
    /// Subscription intent, kept across reconnects and re-applied on `advertise`
    /// so a dropped link restores itself without the UI doing anything.
    private var desiredTopics: Set<String> = []
    private var nextSubscriptionID: UInt32 = 1
    private var intentionalDisconnect = false

    private let controlChannelID: UInt32 = 1

    public init() {}

    deinit {
        socket?.disconnect()
    }

    // MARK: Connection

    public func connect(to url: URL) {
        disconnect()

        self.url = url
        lock.lock()
        intentionalDisconnect = false
        lock.unlock()
        publish { client in
            client.connectionState = .connecting
            client.channels = []
            client.latest = [:]
            client.serverInfo = nil
            client.messagesReceived = 0
        }

        let socket = WebSocketClient(url: url, subprotocols: [FoxgloveClient.subprotocol])
        socket.onOpen = { [weak self] negotiated in
            self?.handleOpen(negotiated: negotiated, url: url)
        }
        socket.onText = { [weak self] text in
            self?.handleText(text)
        }
        socket.onBinary = { [weak self] data in
            self?.handleBinary(data)
        }
        socket.onClose = { [weak self] reason in
            self?.handleClose(reason: reason)
        }
        self.socket = socket
        socket.connect()
    }

    public func disconnect() {
        guard let socket else { return }
        lock.lock()
        intentionalDisconnect = true
        channelsByTopic.removeAll()
        subscriptionByTopic.removeAll()
        topicBySubscription.removeAll()
        lock.unlock()
        socket.disconnect()
        self.socket = nil
        publish { client in
            client.connectionState = .disconnected
            client.channels = []
            client.subscribedTopics = []
        }
    }

    public var isConnected: Bool { connectionState.isConnected }

    // MARK: Subscriptions

    /// Records intent and subscribes if the topic is already advertised.
    /// Subscribing to something the server has not advertised yet is legal here:
    /// the request is replayed the moment it appears.
    public func subscribe(to topic: String) {
        lock.lock()
        desiredTopics.insert(topic)
        var request: SubscribeRequest?
        if subscriptionByTopic[topic] == nil, let channel = channelsByTopic[topic] {
            let id = nextSubscriptionID
            nextSubscriptionID += 1
            subscriptionByTopic[topic] = id
            topicBySubscription[id] = topic
            request = SubscribeRequest(subscriptions: [.init(id: id, channelId: channel.id)])
        }
        lock.unlock()

        if let request { sendJSON(request) }
        publishSubscribedTopics()
    }

    public func unsubscribe(from topic: String) {
        lock.lock()
        desiredTopics.remove(topic)
        var request: UnsubscribeRequest?
        if let id = subscriptionByTopic.removeValue(forKey: topic) {
            topicBySubscription[id] = nil
            request = UnsubscribeRequest(subscriptionIds: [id])
        }
        lock.unlock()

        if let request { sendJSON(request) }
        publish { client in
            client.latest[topic] = nil
        }
        publishSubscribedTopics()
    }

    public func isSubscribed(to topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return desiredTopics.contains(topic)
    }

    /// Convenience for a checkbox: flips intent either way.
    public func setSubscribed(_ subscribed: Bool, to topic: String) {
        subscribed ? subscribe(to: topic) : unsubscribe(from: topic)
    }

    // MARK: Publishing

    /// Sends `{"control": [...]}` on the client channel advertised at open.
    /// A Kinetic server copies the vector straight into `world.control`, which
    /// is what lets Studio drive a simulation running somewhere else.
    public func publishControl(_ values: [Double]) {
        guard let socket, socket.isOpen else { return }
        guard let payload = try? encoder.encode(ControlPayload(control: values)) else { return }

        var message = Data()
        message.append(0x01)
        appendLittleEndian(&message, controlChannelID)
        message.append(payload)
        socket.sendBinary(message)
    }

    // MARK: Socket events

    private func handleOpen(negotiated: String?, url: URL) {
        onLog?("connected to \(url.absoluteString) (\(negotiated ?? "no subprotocol"))")
        publish { client in
            client.connectionState = .connected(url.absoluteString)
        }
        // Advertise the control channel unconditionally: it is one small message,
        // it must be re-sent after every reconnect, and a server that ignores
        // client publishes simply files it away.
        advertiseControlChannel()
    }

    private func handleClose(reason: String) {
        lock.lock()
        let wasIntentional = intentionalDisconnect
        channelsByTopic.removeAll()
        subscriptionByTopic.removeAll()
        topicBySubscription.removeAll()
        lock.unlock()

        onLog?("disconnected: \(reason)")
        publish { client in
            client.channels = []
            client.serverInfo = nil
            // The socket retries on its own, so a dropped link is a failure the
            // user should see rather than a quiet return to "disconnected".
            client.connectionState = wasIntentional ? .disconnected : .failed(reason)
        }
    }

    private func handleText(_ text: String) {
        let data = Data(text.utf8)
        guard let envelope = try? decoder.decode(OperationEnvelope.self, from: data) else { return }

        switch envelope.op {
        case "serverInfo":
            guard let info = try? decoder.decode(ServerInfoMessage.self, from: data) else { return }
            let resolved = RemoteServerInfo(name: info.name,
                                            capabilities: info.capabilities ?? [],
                                            supportedEncodings: info.supportedEncodings ?? [],
                                            sessionID: info.sessionId,
                                            metadata: info.metadata ?? [:])
            let address = url?.absoluteString ?? ""
            publish { client in
                client.serverInfo = resolved
                client.connectionState = .connected("\(resolved.name) — \(address)")
            }
        case "advertise":
            guard let message = try? decoder.decode(AdvertiseMessage.self, from: data) else { return }
            adopt(message.channels)
        case "unadvertise":
            guard let message = try? decoder.decode(UnadvertiseMessage.self, from: data) else { return }
            drop(channelIDs: Set(message.channelIds))
        case "status":
            if let message = try? decoder.decode(StatusMessage.self, from: data) {
                onLog?("server: \(message.message)")
            }
        default:
            // advertiseServices, parameterValues, connectionGraphUpdate … all
            // optional capabilities this client does not claim.
            break
        }
    }

    private func handleBinary(_ data: Data) {
        // [0x01][uint32 LE subscriptionId][uint64 LE log time ns][payload]
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x01 else { return }
        var subscription: UInt32 = 0
        for index in stride(from: 4, through: 1, by: -1) {
            subscription = (subscription << 8) | UInt32(bytes[index])
        }
        var nanoseconds: UInt64 = 0
        for index in stride(from: 12, through: 5, by: -1) {
            nanoseconds = (nanoseconds << 8) | UInt64(bytes[index])
        }

        lock.lock()
        let topic = topicBySubscription[subscription]
        lock.unlock()
        guard let topic else { return }

        let payload = Data(bytes[13...])
        let message = RemoteMessage(topic: topic,
                                    receivedAt: Date(),
                                    logTime: Double(nanoseconds) / 1_000_000_000,
                                    byteCount: payload.count,
                                    payload: decodePayload(topic: topic, data: payload))
        publish { client in
            client.latest[topic] = message
            client.messagesReceived += 1
        }
    }

    /// Typed where we know the schema, opaque where we do not. A decode failure
    /// falls through to `.opaque` rather than dropping the message: the stream
    /// keeps flowing and a raw panel can still show what arrived.
    private func decodePayload(topic: String, data: Data) -> RemotePayload {
        switch topic {
        case "/kinetic/state":
            if let value = try? decoder.decode(RemoteState.self, from: data) { return .state(value) }
        case "/kinetic/profile":
            if let value = try? decoder.decode(RemoteProfile.self, from: data) {
                return .profile(value)
            }
        case "/kinetic/sensors":
            if let value = try? decoder.decode(RemoteSensors.self, from: data) {
                return .sensors(value)
            }
        default:
            break
        }
        return .opaque(data)
    }

    // MARK: Channel bookkeeping

    private func adopt(_ descriptions: [ChannelDescription]) {
        var pending: [SubscribeRequest.Item] = []
        lock.lock()
        for description in descriptions {
            let channel = RemoteChannel(id: description.id,
                                        topic: description.topic,
                                        encoding: description.encoding ?? "json",
                                        schemaName: description.schemaName ?? "")
            channelsByTopic[channel.topic] = channel
            guard desiredTopics.contains(channel.topic),
                  subscriptionByTopic[channel.topic] == nil else { continue }
            let id = nextSubscriptionID
            nextSubscriptionID += 1
            subscriptionByTopic[channel.topic] = id
            topicBySubscription[id] = channel.topic
            pending.append(.init(id: id, channelId: channel.id))
        }
        let snapshot = channelsByTopic.values.sorted { $0.topic < $1.topic }
        lock.unlock()

        if !pending.isEmpty { sendJSON(SubscribeRequest(subscriptions: pending)) }
        publish { client in
            client.channels = snapshot
        }
        publishSubscribedTopics()
    }

    private func drop(channelIDs: Set<Int>) {
        lock.lock()
        for (topic, channel) in channelsByTopic where channelIDs.contains(channel.id) {
            channelsByTopic[topic] = nil
            if let id = subscriptionByTopic.removeValue(forKey: topic) {
                topicBySubscription[id] = nil
            }
        }
        let snapshot = channelsByTopic.values.sorted { $0.topic < $1.topic }
        lock.unlock()
        publish { client in
            client.channels = snapshot
        }
        publishSubscribedTopics()
    }

    private func advertiseControlChannel() {
        let channel = AdvertiseRequest.ClientChannel(
            id: controlChannelID,
            topic: FoxgloveClient.controlTopic,
            encoding: "json",
            schemaName: "kinetic.Control",
            schemaEncoding: "jsonschema",
            schema: Self.controlSchema)
        sendJSON(AdvertiseRequest(channels: [channel]))
    }

    // MARK: Plumbing

    private func sendJSON<T: Encodable>(_ value: T) {
        guard let socket, let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.sendText(text)
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// `@Published` properties feed SwiftUI, and every socket callback arrives on
    /// the transport's queue, so all mutation is funnelled to the main queue.
    private func publish(_ body: @escaping (FoxgloveClient) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    private func publishSubscribedTopics() {
        lock.lock()
        let topics = desiredTopics
        lock.unlock()
        publish { client in
            client.subscribedTopics = topics
        }
    }
}

// MARK: - Wire messages

private struct OperationEnvelope: Decodable {
    let op: String
}

private struct ServerInfoMessage: Decodable {
    let name: String
    let capabilities: [String]?
    let supportedEncodings: [String]?
    let sessionId: String?
    let metadata: [String: String]?
}

private struct ChannelDescription: Decodable {
    let id: Int
    let topic: String
    let encoding: String?
    let schemaName: String?
}

private struct AdvertiseMessage: Decodable {
    let channels: [ChannelDescription]
}

private struct UnadvertiseMessage: Decodable {
    let channelIds: [Int]
}

private struct StatusMessage: Decodable {
    let level: Int?
    let message: String
}

private struct SubscribeRequest: Encodable {
    struct Item: Encodable {
        let id: UInt32
        let channelId: Int
    }
    let op = "subscribe"
    let subscriptions: [Item]
}

private struct UnsubscribeRequest: Encodable {
    let op = "unsubscribe"
    let subscriptionIds: [UInt32]
}

private struct AdvertiseRequest: Encodable {
    struct ClientChannel: Encodable {
        let id: UInt32
        let topic: String
        let encoding: String
        let schemaName: String
        let schemaEncoding: String
        let schema: String
    }
    let op = "advertise"
    let channels: [ClientChannel]
}

private struct ControlPayload: Encodable {
    let control: [Double]
}
