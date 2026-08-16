//
//  WebSocketServer.swift
//  KineticBridge
//
//  Minimal RFC 6455 server built directly on Network.framework TCP. Written by
//  hand rather than layered on NWProtocolWebSocket so that subprotocol
//  negotiation (which the Foxglove protocol requires) and per-connection
//  backpressure are both fully under our control.
//

import CryptoKit
import Foundation
import Network

public struct WebSocketConnectionID: Hashable, Sendable {
    let value: UInt64
}

public protocol WebSocketServerDelegate: AnyObject {
    func webSocket(_ server: WebSocketServer, didConnect id: WebSocketConnectionID,
                   subprotocol: String?)
    func webSocket(_ server: WebSocketServer, didDisconnect id: WebSocketConnectionID)
    func webSocket(_ server: WebSocketServer, didReceiveText text: String,
                   from id: WebSocketConnectionID)
    func webSocket(_ server: WebSocketServer, didReceiveBinary data: Data,
                   from id: WebSocketConnectionID)
}

public final class WebSocketServer {
    public enum State: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public weak var delegate: WebSocketServerDelegate?
    /// Subprotocols the server will accept, in priority order.
    public var supportedSubprotocols: [String] = []
    public var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.kinetic.websocket", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [WebSocketConnectionID: Client] = [:]
    private var nextID: UInt64 = 1

    public init() {}

    public var connectionCount: Int {
        queue.sync { connections.count }
    }

    public func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener = try NWListener(using: parameters,
                                      on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                let bound = listener.port?.rawValue ?? port
                self.state = .listening(port: bound)
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
            case .cancelled:
                self.state = .idle
            default:
                break
            }
            self.onStateChange?(self.state)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            for (_, client) in connections { client.connection.cancel() }
            connections.removeAll()
        }
        listener?.cancel()
        listener = nil
        state = .idle
    }

    public func sendText(_ text: String, to id: WebSocketConnectionID? = nil) {
        let payload = Data(text.utf8)
        send(opcode: 0x1, payload: payload, to: id)
    }

    public func sendBinary(_ data: Data, to id: WebSocketConnectionID? = nil) {
        send(opcode: 0x2, payload: data, to: id)
    }

    private func send(opcode: UInt8, payload: Data, to id: WebSocketConnectionID?) {
        let frame = WebSocketServer.encodeFrame(opcode: opcode, payload: payload)
        queue.async {
            if let id {
                self.connections[id]?.write(frame)
            } else {
                for (_, client) in self.connections { client.write(frame) }
            }
        }
    }

    // MARK: Connection handling

    private final class Client {
        let id: WebSocketConnectionID
        let connection: NWConnection
        var handshakeComplete = false
        var buffer = Data()
        var negotiatedSubprotocol: String?
        var pendingBytes = 0
        /// Frames are dropped rather than queued without bound when a client
        /// falls behind; telemetry is better late-free than backlogged.
        let maximumPendingBytes = 8 << 20

        init(id: WebSocketConnectionID, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }

        func write(_ data: Data) {
            guard handshakeComplete else { return }
            guard pendingBytes < maximumPendingBytes else { return }
            pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.pendingBytes -= data.count
            })
        }

        func writeRaw(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = WebSocketConnectionID(value: nextID)
        nextID += 1
        let client = Client(id: id, connection: connection)
        connections[id] = client

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    if self.connections.removeValue(forKey: id) != nil {
                        self.delegate?.webSocket(self, didDisconnect: id)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
                self.process(client)
            }
            if isComplete || error != nil {
                client.connection.cancel()
                if self.connections.removeValue(forKey: client.id) != nil {
                    self.delegate?.webSocket(self, didDisconnect: client.id)
                }
                return
            }
            self.receive(client)
        }
    }

    private func process(_ client: Client) {
        if !client.handshakeComplete {
            guard let range = client.buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = client.buffer.subdata(in: client.buffer.startIndex..<range.upperBound)
            client.buffer.removeSubrange(client.buffer.startIndex..<range.upperBound)
            guard let request = String(data: headerData, encoding: .utf8) else {
                client.connection.cancel()
                return
            }
            performHandshake(client, request: request)
            if !client.handshakeComplete { return }
        }
        decodeFrames(client)
    }

    private func performHandshake(_ client: Client, request: String) {
        var headers: [String: String] = [:]
        for line in request.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard let key = headers["sec-websocket-key"],
              headers["upgrade"]?.lowercased() == "websocket"
        else {
            client.writeRaw(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
            client.connection.cancel()
            return
        }

        let requested = (headers["sec-websocket-protocol"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let chosen = supportedSubprotocols.first(where: { requested.contains($0) })
            ?? (supportedSubprotocols.isEmpty ? nil : supportedSubprotocols.first)

        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(digest).base64EncodedString()

        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(accept)\r\n"
        if let chosen, requested.contains(chosen) {
            response += "Sec-WebSocket-Protocol: \(chosen)\r\n"
        }
        response += "\r\n"

        client.writeRaw(Data(response.utf8))
        client.handshakeComplete = true
        client.negotiatedSubprotocol = chosen
        delegate?.webSocket(self, didConnect: client.id, subprotocol: chosen)
    }

    private func decodeFrames(_ client: Client) {
        while true {
            guard let frame = WebSocketServer.decodeFrame(from: client.buffer) else { return }
            client.buffer.removeSubrange(client.buffer.startIndex
                                         ..< client.buffer.index(client.buffer.startIndex,
                                                                 offsetBy: frame.consumed))
            switch frame.opcode {
            case 0x1:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    delegate?.webSocket(self, didReceiveText: text, from: client.id)
                }
            case 0x2:
                delegate?.webSocket(self, didReceiveBinary: frame.payload, from: client.id)
            case 0x8:
                client.writeRaw(WebSocketServer.encodeFrame(opcode: 0x8, payload: Data()))
                client.connection.cancel()
                return
            case 0x9:
                client.writeRaw(WebSocketServer.encodeFrame(opcode: 0xA, payload: frame.payload))
            default:
                break
            }
        }
    }

    // MARK: Framing

    static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)  // FIN + opcode
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    struct DecodedFrame {
        var opcode: UInt8
        var payload: Data
        var consumed: Int
    }

    static func decodeFrame(from buffer: Data) -> DecodedFrame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2

        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            length = 0
            for i in 0..<8 { length = (length << 8) | Int(bytes[offset + i]) }
            offset += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }

        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }
        return DecodedFrame(opcode: opcode, payload: Data(payload), consumed: offset + length)
    }
}
