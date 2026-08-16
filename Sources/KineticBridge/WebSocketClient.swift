//
//  WebSocketClient.swift
//  KineticBridge
//
//  The mirror image of WebSocketServer: a hand-written RFC 6455 *client* on
//  Network.framework. It exists for the same reason the server does — the
//  Foxglove protocol negotiates a subprotocol (`foxglove.websocket.v1`) and
//  URLSessionWebSocketTask gives us no way to verify what the peer actually
//  agreed to, nor to see the raw handshake when it goes wrong.
//
//  Framing is shared with the server rather than duplicated: `decodeFrame` is
//  used verbatim (it already honours the mask bit), and outgoing frames are the
//  server's `encodeFrame` output with the client-only masking transform applied
//  on top, so the 7/16/64-bit length rules live in exactly one place.
//
//  The direction that is *not* symmetric is masking. RFC 6455 §5.1 requires
//  every client-to-server frame to be masked and permits a server to fail the
//  connection if one is not; the server path never masks. That asymmetry is
//  handled here in `maskedFrame`.
//

import CryptoKit
import Foundation
import Network

public final class WebSocketClient {

    // MARK: Types

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case open(subprotocol: String?)
        case closed(reason: String)
    }

    /// Exponential backoff with jitter. Capped because a Studio window left open
    /// overnight against a machine that is off should keep retrying cheaply, and
    /// jittered so a room full of Studios does not resynchronise into a herd
    /// every time the robot reboots.
    public struct Backoff: Sendable {
        public var initialDelay: TimeInterval = 0.5
        public var multiplier: Double = 2
        public var maximumDelay: TimeInterval = 15
        /// Fraction of the computed delay that is randomised, ±.
        public var jitter: Double = 0.25

        public init(initialDelay: TimeInterval = 0.5,
                    multiplier: Double = 2,
                    maximumDelay: TimeInterval = 15,
                    jitter: Double = 0.25) {
            self.initialDelay = initialDelay
            self.multiplier = multiplier
            self.maximumDelay = maximumDelay
            self.jitter = jitter
        }

        func delay(forAttempt attempt: Int) -> TimeInterval {
            let raw = initialDelay * pow(multiplier, Double(attempt))
            let capped = min(raw, maximumDelay)
            guard jitter > 0 else { return capped }
            return capped * (1 + Double.random(in: -jitter...jitter))
        }
    }

    // MARK: Callbacks
    //
    // Deliberately the same shape as WebSocketServerDelegate, minus the
    // connection id: a client has exactly one peer. All four are invoked on the
    // client's private queue, never on the main queue — callers that drive
    // SwiftUI state hop themselves, which keeps the socket free of UI latency.

    public var onOpen: ((String?) -> Void)?
    public var onText: ((String) -> Void)?
    public var onBinary: ((Data) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onStateChange: ((State) -> Void)?

    // MARK: Configuration

    public let url: URL
    /// Offered in `Sec-WebSocket-Protocol`, in priority order.
    public let subprotocols: [String]
    public var backoff = Backoff()
    /// A TCP connection that opens but never answers the upgrade would otherwise
    /// hang forever, and no reconnect would ever be scheduled.
    public var handshakeTimeout: TimeInterval = 10

    public private(set) var state: State = .idle

    // MARK: Private state — all touched only on `queue`

    private let queue = DispatchQueue(label: "com.kinetic.websocket.client", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = Data()
    private var handshakeComplete = false
    private var expectedAccept = ""
    private var isActive = false
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?

    /// Reassembly of fragmented data frames. Our own server never fragments, but
    /// a third-party `foxglove.websocket.v1` server is free to.
    private var fragmentOpcode: UInt8 = 0
    private var fragmentPayload = Data()

    /// A frame is only decodable once fully buffered, so a hostile or broken peer
    /// could otherwise make us buffer without bound.
    private let maximumBufferBytes = 32 << 20

    public init(url: URL, subprotocols: [String] = []) {
        self.url = url
        self.subprotocols = subprotocols
    }

    deinit {
        connection?.cancel()
        reconnectWork?.cancel()
        handshakeWork?.cancel()
    }

    // MARK: Lifecycle

    public var isOpen: Bool { queue.sync { handshakeComplete } }

    /// Connects, and keeps reconnecting until `disconnect()` is called.
    public func connect() {
        queue.async {
            self.shouldReconnect = true
            self.reconnectAttempt = 0
            guard self.connection == nil else { return }
            self.openConnection()
        }
    }

    /// Cancels the socket *and* any pending retry. This is the "cancellable" half
    /// of the backoff: a scheduled reconnect must not resurrect a connection the
    /// user has switched off.
    public func disconnect() {
        queue.async {
            self.shouldReconnect = false
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.teardown(reason: "closed by client", sendClose: true)
        }
    }

    public func sendText(_ text: String) {
        send(opcode: 0x1, payload: Data(text.utf8))
    }

    public func sendBinary(_ data: Data) {
        send(opcode: 0x2, payload: data)
    }

    // MARK: Connection

    private func openConnection() {
        guard let host = url.host, !host.isEmpty else {
            fail("no host in \(url.absoluteString)", retry: false)
            return
        }
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            fail("invalid port \(portNumber)", retry: false)
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = isSecure ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
                                  : NWParameters(tls: nil, tcp: tcp)

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        isActive = true
        buffer.removeAll(keepingCapacity: true)
        handshakeComplete = false
        fragmentPayload.removeAll(keepingCapacity: true)
        fragmentOpcode = 0
        update(.connecting)

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self, self.connection === connection else { return }
            switch newState {
            case .ready:
                self.sendHandshake(on: connection, host: host)
            case .failed(let error):
                self.fail(error.localizedDescription)
            case .waiting(let error):
                // `.waiting` means Network.framework will retry on its own
                // schedule, which is not the capped schedule we promised the
                // caller; take the connection back and drive the retry here.
                self.fail(error.localizedDescription)
            default:
                break
            }
        }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.handshakeComplete, self.connection === connection else { return }
            self.fail("handshake timed out after \(Int(self.handshakeTimeout))s")
        }
        handshakeWork = deadline
        queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: deadline)

        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.buffer.count <= self.maximumBufferBytes else {
                    self.fail("frame larger than \(self.maximumBufferBytes) bytes")
                    return
                }
                self.process(on: connection)
                guard self.connection === connection else { return }
            }
            if isComplete {
                self.fail("server ended the stream")
                return
            }
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            self.receive(on: connection)
        }
    }

    // MARK: Handshake

    private func sendHandshake(on connection: NWConnection, host: String) {
        // A fresh 16-byte nonce per connection, base64 encoded, is what makes the
        // server's `Sec-WebSocket-Accept` meaningful: it proves the 101 we get
        // back was computed for *this* handshake and is not a cached or replayed
        // response from an intermediary.
        let key = Data(WebSocketClient.randomBytes(16)).base64EncodedString()
        expectedAccept = WebSocketClient.acceptToken(for: key)

        var request = "GET \(resourceName) HTTP/1.1\r\n"
        request += "Host: \(hostHeader(host))\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        if !subprotocols.isEmpty {
            request += "Sec-WebSocket-Protocol: \(subprotocols.joined(separator: ", "))\r\n"
        }
        request += "\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }

    /// Consumes the 101 response, then every frame behind it. Same two-phase
    /// shape as `WebSocketServer.process`.
    private func process(on connection: NWConnection) {
        if !handshakeComplete {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.upperBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let response = String(data: headerData, encoding: .utf8) else {
                fail("upgrade response was not valid UTF-8")
                return
            }
            guard completeHandshake(response) else { return }
        }
        decodeFrames()
    }

    /// Returns false once it has already reported the failure.
    private func completeHandshake(_ response: String) -> Bool {
        let lines = response.split(separator: "\r\n")
        guard let status = lines.first else {
            fail("empty upgrade response")
            return false
        }
        guard status.contains("101") else {
            fail("server refused the upgrade: \(status)")
            return false
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard headers["upgrade"]?.lowercased() == "websocket" else {
            fail("upgrade header missing from the 101 response")
            return false
        }
        guard let accept = headers["sec-websocket-accept"] else {
            fail("Sec-WebSocket-Accept missing from the 101 response")
            return false
        }
        // Loud on purpose. A mismatch means whatever answered is not speaking
        // RFC 6455 — an HTTP proxy, a captive portal, the wrong port — and
        // continuing would feed garbage into the frame decoder instead of
        // telling the operator what is actually in front of them.
        guard accept == expectedAccept else {
            fail("Sec-WebSocket-Accept mismatch: expected \(expectedAccept), got \(accept)")
            return false
        }

        let negotiated = headers["sec-websocket-protocol"]
        if let negotiated, !subprotocols.isEmpty, !subprotocols.contains(negotiated) {
            fail("server chose subprotocol '\(negotiated)', which we never offered")
            return false
        }

        handshakeWork?.cancel()
        handshakeWork = nil
        handshakeComplete = true
        // A completed handshake is the only evidence that the endpoint is real,
        // so backoff resets here rather than on TCP connect.
        reconnectAttempt = 0
        update(.open(subprotocol: negotiated))
        onOpen?(negotiated)
        return true
    }

    // MARK: Frames

    private func decodeFrames() {
        while true {
            // `decodeFrame` does not surface FIN, and fragment reassembly needs
            // it, so read that one bit here and leave the rest to the shared
            // decoder.
            guard let firstByte = buffer.first else { return }
            let isFinal = (firstByte & 0x80) != 0
            guard let frame = WebSocketServer.decodeFrame(from: buffer) else { return }
            buffer.removeSubrange(buffer.startIndex
                                  ..< buffer.index(buffer.startIndex, offsetBy: frame.consumed))

            switch frame.opcode {
            case 0x0:
                fragmentPayload.append(frame.payload)
                if isFinal {
                    deliver(opcode: fragmentOpcode, payload: fragmentPayload)
                    fragmentPayload.removeAll(keepingCapacity: true)
                    fragmentOpcode = 0
                }
            case 0x1, 0x2:
                if isFinal {
                    deliver(opcode: frame.opcode, payload: frame.payload)
                } else {
                    fragmentOpcode = frame.opcode
                    fragmentPayload = frame.payload
                }
            case 0x8:
                // Echo the close and let the reconnect policy decide what next:
                // a server restarting mid-session should come back on its own.
                teardown(reason: "server closed the connection", sendClose: true)
                scheduleReconnect()
                return
            case 0x9:
                // A pong must carry the ping's payload back unchanged, masked
                // like everything else we send.
                send(opcode: 0xA, payload: frame.payload)
            default:
                // Pongs and reserved opcodes: liveness here is TCP's job, so an
                // unsolicited pong needs no reply.
                break
            }
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1:
            if let text = String(data: payload, encoding: .utf8) { onText?(text) }
        case 0x2:
            onBinary?(payload)
        default:
            break
        }
    }

    private func send(opcode: UInt8, payload: Data) {
        queue.async {
            guard let connection = self.connection, self.handshakeComplete else { return }
            let frame = WebSocketClient.maskedFrame(opcode: opcode, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Teardown and retry

    private func fail(_ reason: String, retry: Bool = true) {
        teardown(reason: reason, sendClose: false)
        if retry { scheduleReconnect() }
    }

    private func teardown(reason: String, sendClose: Bool) {
        handshakeWork?.cancel()
        handshakeWork = nil
        if let connection {
            if sendClose && handshakeComplete {
                connection.send(content: WebSocketClient.maskedFrame(opcode: 0x8, payload: Data()),
                                completion: .contentProcessed { _ in })
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        buffer.removeAll(keepingCapacity: true)
        fragmentPayload.removeAll(keepingCapacity: true)
        fragmentOpcode = 0
        handshakeComplete = false

        guard isActive else { return }  // one close report per connection attempt
        isActive = false
        update(.closed(reason: reason))
        onClose?(reason)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectWork?.cancel()
        let delay = backoff.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect, self.connection == nil else { return }
            self.openConnection()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func update(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: URL pieces

    private var isSecure: Bool { url.scheme?.lowercased() == "wss" }

    private var defaultPort: UInt16 { isSecure ? 443 : 80 }

    private var portNumber: UInt16 {
        guard let port = url.port, port > 0, port <= Int(UInt16.max) else { return defaultPort }
        return UInt16(port)
    }

    private var resourceName: String {
        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty { path += "?\(query)" }
        return path
    }

    private func hostHeader(_ host: String) -> String {
        portNumber == defaultPort ? host : "\(host):\(portNumber)"
    }

    // MARK: Framing helpers

    /// The server's frame, plus the mask RFC 6455 §5.3 demands of a client.
    ///
    /// Reusing `WebSocketServer.encodeFrame` rather than re-deriving the header
    /// keeps one implementation of the 7/16/64-bit payload-length rules; the
    /// header length is known exactly (total minus payload), so lifting it back
    /// off is safe.
    static func maskedFrame(opcode: UInt8, payload: Data) -> Data {
        let unmasked = WebSocketServer.encodeFrame(opcode: opcode, payload: payload)
        let headerLength = unmasked.count - payload.count
        var frame = Data(unmasked.prefix(headerLength))
        guard frame.count >= 2 else { return unmasked }
        frame[frame.startIndex + 1] |= 0x80  // MASK bit

        let key = randomBytes(4)
        frame.append(contentsOf: key)
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= key[index % 4] }
        frame.append(contentsOf: masked)
        return frame
    }

    /// RFC 6455 §4.1: the server proves it understood the upgrade by hashing our
    /// key with this fixed GUID. The constant is duplicated from
    /// `WebSocketServer.performHandshake`, where it is a local — the two sides
    /// must agree on it, and the RFC guarantees they always will.
    static func acceptToken(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The one place in this package where nondeterminism is required rather
    /// than merely tolerated.
    ///
    /// The handshake key must be an unpredictable nonce (§4.1) or a cached 101
    /// could be replayed at us, and every frame mask must be unpredictable
    /// (§5.3) so that a compromised sender cannot choose the bytes that appear
    /// on the wire and poison a proxy's cache. Both therefore need a CSPRNG:
    /// `SystemRandomNumberGenerator` is documented to be cryptographically
    /// secure on Apple platforms, drawing from the same kernel entropy as
    /// `arc4random_buf`. Seeding this for reproducibility would be a security
    /// bug, not a testability win — the reproducible parts of Kinetic are the
    /// physics, not the transport.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }
}
