import Foundation
import Network
import os

/// The HTTP surface: every command, plus the SSE event stream, on one port.
///
/// Follows Sonocles' transport, and keeps its two hard-won rules: the server
/// outlives everything underneath it (sockets are infrastructure, capture is
/// a session that comes and goes), and it never `sync`s onto its own queue.
///
/// `@unchecked Sendable`: every mutable member is only touched on `queue`.
public final class HTTPServer: Transport, @unchecked Sendable {
    public let label = "http"
    public let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "rheocles.http")
    private let dispatcher: any Dispatching
    private let auth: BearerAuth
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private let liveCount = OSAllocatedUnfairLock(initialState: 0)
    private let ready = DispatchSemaphore(value: 0)
    private let startError = OSAllocatedUnfairLock<Error?>(initialState: nil)

    public init(host: String, port: UInt16, dispatcher: any Dispatching, auth: BearerAuth) throws {
        self.port = port
        self.dispatcher = dispatcher
        self.auth = auth

        // No Nagle: responses are small and the SSE stream is many small
        // writes that must not wait for company.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    /// Bind, and return only once the port is actually held — or throw.
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
            for (_, conn) in self.streams { conn.cancel() }
            self.streams.removeAll()
            self.liveCount.withLock { $0 = 0 }
        }
        listener.cancel()
    }

    public var clientCount: Int { liveCount.withLock { $0 } }

    /// The commands this transport serves: exactly the dispatcher's table.
    public var commands: [Route] { dispatcher.commands }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn, buffered: Data())
    }

    /// Read until the head is complete and the body, if any, is all here.
    private func receive(on conn: NWConnection, buffered: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let request = Request.parse(buffer) {
                self.route(request, on: conn)
            } else if isComplete || error != nil || buffer.count > (4 << 20) {
                conn.cancel()
            } else {
                self.receive(on: conn, buffered: buffer)
            }
        }
    }

    private func route(_ request: Request, on conn: NWConnection) {
        // Preflight, so a page in the user's browser can call the API.
        if request.method == "OPTIONS" {
            respond(conn, status: 204, body: nil)
            return
        }

        guard auth.authorizes(request) else {
            respond(
                conn, status: 401, body: APIError.unauthorized.response.body,
                extra: "WWW-Authenticate: Bearer realm=\"Rheocles\"\r\n")
            return
        }

        if request.method == "GET" && request.path == "/events" {
            openStream(on: conn)
            return
        }

        Task {
            let response = await dispatcher.dispatch(request)
            self.respond(conn, status: response.status, body: response.body)
        }
    }

    private func openStream(on conn: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK", "Content-Type: text/event-stream", "Cache-Control: no-cache",
            "Connection: keep-alive", "Access-Control-Allow-Origin: *", "", "",
        ].joined(separator: "\r\n")
        conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
        conn.send(content: Data(": connected\n\n".utf8), completion: .contentProcessed { _ in })

        queue.async {
            self.streams[ObjectIdentifier(conn)] = conn
            self.liveCount.withLock { $0 = self.streams.count }
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    self.streams[ObjectIdentifier(conn)] = nil
                    self.liveCount.withLock { $0 = self.streams.count }
                }
            default:
                break
            }
        }
    }

    private static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error",
        507: "Insufficient Storage",
    ]

    private func respond(_ conn: NWConnection, status: Int, body: Data?, extra: String = "") {
        let reason = Self.reasons[status] ?? "Status"
        let head =
            [
                "HTTP/1.1 \(status) \(reason)", "Content-Type: application/json",
                "Content-Length: \(body?.count ?? 0)", "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Authorization, Content-Type",
            ].joined(separator: "\r\n") + "\r\n" + extra + "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Push one event to every SSE client.
    public func broadcast(_ json: String) {
        let data = Data("data: \(json)\n\n".utf8)
        queue.async {
            for (_, conn) in self.streams {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }
}

extension Request {
    /// Parse a complete HTTP/1.1 request, or return nil if more bytes are
    /// needed. Internal so the parser — the one pure part of the server — can
    /// be tested on its own.
    static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let target = String(parts[1])
        let path: String
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first?.removingPercentEncoding else { continue }
                query[key] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            }
        } else {
            path = target
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = length > 0 ? Data(data[bodyStart..<(bodyStart + length)]) : nil

        return Request(
            method: String(parts[0]), path: path, query: query, headers: headers, body: body)
    }
}
