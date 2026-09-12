import Foundation
import Network
import os

/// The WebSocket surface: every command and every event on one socket.
///
/// Network.framework speaks RFC 6455 itself; this class only decides who may
/// connect and turns text frames into `Request`s for the shared dispatcher.
///
/// Frames in:  `{"id": 1, "method": "POST", "path": "/takes", "body": {...}}`
/// Frames out: `{"id": 1, "status": 201, "body": {...}}` — and, unsolicited,
///             `{"event": "...", ...}` for everything `/events` would carry.
///
/// Auth: the first frame must be `{"auth": "<token>"}`; until it has arrived,
/// every command is answered 401 and no event is delivered. A header on the
/// upgrade request would be the HTTP-shaped way, but a browser `WebSocket`
/// cannot set one and Network.framework's upgrade handler cannot tell which
/// connection a request belongs to, so the frame is the one way that works
/// for every client and it is the only way.
public final class WebSocketServer: Transport, @unchecked Sendable {
    public let label = "ws"
    public let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "rheocles.ws")
    private let dispatcher: any Dispatching
    private let auth: BearerAuth
    /// Connected clients and whether each has authenticated.
    private var clients: [ObjectIdentifier: (NWConnection, Bool)] = [:]
    private let liveCount = OSAllocatedUnfairLock(initialState: 0)
    private let ready = DispatchSemaphore(value: 0)
    private let startError = OSAllocatedUnfairLock<Error?>(initialState: nil)

    public init(host: String, port: UInt16, dispatcher: any Dispatching, auth: BearerAuth) throws {
        self.port = port
        self.dispatcher = dispatcher
        self.auth = auth

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    public func start() throws {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case .failed(let error):
                self.startError.withLock { $0 = error }
                self.ready.signal()
            case .cancelled:
                self.ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let error = startError.withLock({ $0 }) { throw error }
    }

    public func stop() {
        queue.async {
            for (_, (conn, _)) in self.clients { conn.cancel() }
            self.clients.removeAll()
            self.liveCount.withLock { $0 = 0 }
        }
        listener.cancel()
    }

    public var clientCount: Int { liveCount.withLock { $0 } }
    public var commands: [Route] { dispatcher.commands }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.clients[ObjectIdentifier(conn)] = (conn, false)
                    self.liveCount.withLock { $0 = self.clients.count }
                }
            case .failed, .cancelled:
                self.queue.async {
                    self.clients[ObjectIdentifier(conn)] = nil
                    self.liveCount.withLock { $0 = self.clients.count }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.queue.async {
                    self.clients[ObjectIdentifier(conn)] = nil
                    self.liveCount.withLock { $0 = self.clients.count }
                }
                return
            }
            if let data, !data.isEmpty,
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                metadata.opcode == .text
            {
                self.handle(data, from: conn)
            }
            self.receive(on: conn)
        }
    }

    /// A command frame, or the auth frame.
    struct Frame: Decodable {
        var id: JSONValue?
        var auth: String?
        var method: String?
        var path: String?
        var query: [String: String]?
        var body: JSONValue?
    }

    private func handle(_ data: Data, from conn: NWConnection) {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else {
            send(
                conn, id: nil, status: 400,
                body: APIError.badRequest("frame is not JSON").response.body)
            return
        }
        let id = frame.id.map { (try? Response.encoder.encode($0)) ?? Data("null".utf8) }

        if let token = frame.auth {
            let ok = auth.matches(token: token)
            queue.async {
                if ok { self.clients[ObjectIdentifier(conn)]?.1 = true }
            }
            let reply =
                ok ? Data(#"{"authenticated":true}"#.utf8) : APIError.unauthorized.response.body
            send(conn, id: id, status: ok ? 200 : 401, body: reply)
            return
        }

        // `handle` runs on `queue`, so this read is serialized with the writes.
        guard clients[ObjectIdentifier(conn)]?.1 == true else {
            send(conn, id: id, status: 401, body: APIError.unauthorized.response.body)
            return
        }

        guard let method = frame.method, let path = frame.path else {
            send(
                conn, id: id, status: 400,
                body: APIError.badRequest("method and path are required").response.body)
            return
        }
        let body = frame.body.flatMap { try? Response.encoder.encode($0) }
        let request = Request(method: method, path: path, query: frame.query ?? [:], body: body)
        Task {
            let response = await dispatcher.dispatch(request)
            self.send(conn, id: id, response: response)
        }
    }

    private func send(_ conn: NWConnection, id: Data?, status: Int, body: Data) {
        var frame = Data(#"{"id":"#.utf8)
        frame.append(id ?? Data("null".utf8))
        frame.append(Data(#","status":\#(status),"body":"#.utf8))
        frame.append(body)
        frame.append(Data("}".utf8))
        sendText(conn, frame)
    }

    /// A non-JSON body (a preview JPEG) cannot go inline in the frame, so it
    /// is delivered base64 with its content type: the same bytes a browser
    /// would `data:`-URL. JSON bodies stay inline.
    private func send(_ conn: NWConnection, id: Data?, response: Response) {
        guard response.contentType != "application/json" else {
            send(conn, id: id, status: response.status, body: response.body)
            return
        }
        var frame = Data(#"{"id":"#.utf8)
        frame.append(id ?? Data("null".utf8))
        frame.append(
            Data(
                #","status":\#(response.status),"contentType":"\#(response.contentType)","base64":""#
                    .utf8))
        frame.append(Data(response.body.base64EncodedString().utf8))
        frame.append(Data(#""}"#.utf8))
        sendText(conn, frame)
    }

    private func sendText(_ conn: NWConnection, _ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        conn.send(content: data, contentContext: context, completion: .contentProcessed { _ in })
    }

    /// Events go only to authenticated clients: the token gates reading too.
    public func broadcast(_ json: String) {
        let data = Data(json.utf8)
        queue.async {
            for (_, (conn, authenticated)) in self.clients where authenticated {
                self.sendText(conn, data)
            }
        }
    }
}

/// Just enough JSON to carry a frame's `id` and `body` through untouched.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
