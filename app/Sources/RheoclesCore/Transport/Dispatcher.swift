import Foundation

/// One command, however it arrived.
///
/// HTTP fills this from the request line, headers and body; WebSocket fills
/// it from a JSON frame. Handlers never know which, and that is the point:
/// one command table, two encoders (spec §11).
public struct Request: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?
    /// Path parameters, filled in by the dispatcher once a route matched:
    /// `/takes/{id}/start` against `/takes/abc/start` gives `["id": "abc"]`.
    public var params: [String: String] = [:]

    public init(
        method: String, path: String, query: [String: String] = [:],
        headers: [String: String] = [:], body: Data? = nil
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Decode the JSON body, or throw the 400 the client deserves.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let body, !body.isEmpty else {
            throw APIError.badRequest("a JSON body is required")
        }
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw APIError.badRequest("invalid body: \(error.localizedDescription)")
        }
    }
}

/// What a handler answers with. The body is JSON on every route.
public struct Response: Sendable {
    public var status: Int
    public var body: Data
    /// The media type of `body`. JSON on every route but preview, which
    /// answers `image/jpeg` bytes.
    public var contentType: String

    public init(status: Int = 200, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public init<T: Encodable>(status: Int = 200, json value: T) {
        self.status = status
        self.body = (try? Response.encoder.encode(value)) ?? Data("{}".utf8)
        self.contentType = "application/json"
    }

    /// Sorted keys so responses are stable across runs — the contract test
    /// and any client diffing two payloads rely on that. Dates carry
    /// milliseconds (ISO 8601 with fractional seconds), the same as the
    /// on-disk manifest, so a marker `t` plus a take's `started` lands on a
    /// frame — the default `.iso8601` strategy truncated to the second.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Manifest.iso8601.string(from: date))
        }
        return e
    }()
}

/// The error shape, on every route and both transports:
///
///     { "error": "no such route", "code": "not_found" }
///
/// `error` is for humans and follows Sonocles; `code` is for programs and is
/// stable. HTTP carries the status in the status line, WebSocket in the frame.
public struct APIError: Error, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }
    public static let unauthorized = APIError(
        status: 401, code: "unauthorized", message: "authentication required")
    public static func notFound(_ message: String = "no such route") -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    public static func methodNotAllowed(_ allowed: [String]) -> APIError {
        APIError(
            status: 405, code: "method_not_allowed",
            message: "method not allowed; try \(allowed.joined(separator: ", "))")
    }
    public static func conflict(_ message: String) -> APIError {
        APIError(status: 409, code: "conflict", message: message)
    }
    public static func internalError(_ message: String) -> APIError {
        APIError(status: 500, code: "internal", message: message)
    }

    struct Body: Encodable {
        let error: String
        let code: String
    }

    public var response: Response {
        Response(status: status, json: Body(error: message, code: code))
    }
}

/// A method and a path pattern. Patterns use `{name}` segments.
public struct Route: Sendable, Hashable, CustomStringConvertible {
    public let method: String
    public let pattern: String

    public init(_ method: String, _ pattern: String) {
        self.method = method.uppercased()
        self.pattern = pattern
    }

    public var description: String { "\(method) \(pattern)" }

    /// Match a concrete path, yielding the path parameters.
    func match(_ path: String) -> [String: String]? {
        let want = pattern.split(separator: "/", omittingEmptySubsequences: true)
        let have = path.split(separator: "/", omittingEmptySubsequences: true)
        guard want.count == have.count else { return nil }
        var params: [String: String] = [:]
        for (w, h) in zip(want, have) {
            if w.hasPrefix("{") && w.hasSuffix("}") {
                // Percent-decode the captured value: a stream id's colon comes
                // over the wire as %3A from `encodeURIComponent`, and a bare
                // colon must keep working too (decoding a value with no escapes
                // returns it unchanged). Fall back to the raw segment if the
                // encoding is malformed rather than dropping the route.
                params[String(w.dropFirst().dropLast())] =
                    String(h).removingPercentEncoding ?? String(h)
            } else if w != h {
                return nil
            }
        }
        return params
    }
}

public typealias Handler = @Sendable (Request) async throws -> Response

/// A route and what runs when it matches.
public struct Command: Sendable {
    public let route: Route
    public let handler: Handler

    public init(_ method: String, _ pattern: String, handler: @escaping Handler) {
        self.route = Route(method, pattern)
        self.handler = handler
    }
}

/// What a transport routes through. `Dispatcher` is the real one; `Router`
/// is a late-bound handle so the transports can exist before the table does.
public protocol Dispatching: Sendable {
    var commands: [Route] { get }
    func dispatch(_ request: Request) async -> Response
}

/// Forwards to a dispatcher set after construction. Before that, everything
/// is "service not ready" rather than a crash.
public final class Router: Dispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var target: Dispatcher?

    public init() {}

    public var dispatcher: Dispatcher? {
        get { lock.withLock { target } }
        set { lock.withLock { target = newValue } }
    }

    public var commands: [Route] { dispatcher?.commands ?? [] }

    public func dispatch(_ request: Request) async -> Response {
        guard let dispatcher else {
            return APIError(status: 503, code: "not_ready", message: "service not ready").response
        }
        return await dispatcher.dispatch(request)
    }
}

/// The one command table.
///
/// Every command reachable over HTTP is reachable over WebSocket by
/// construction: both transports hand their requests here, and a test asserts
/// that the two transports advertise exactly this table.
public final class Dispatcher: Dispatching, Sendable {
    private let table: [Command]

    public init(_ table: [Command]) {
        self.table = table
    }

    /// Every route, in table order.
    public var commands: [Route] { table.map(\.route) }

    public func dispatch(_ request: Request) async -> Response {
        var allowed: [String] = []
        for command in table {
            guard let params = command.route.match(request.path) else { continue }
            if command.route.method != request.method {
                allowed.append(command.route.method)
                continue
            }
            var matched = request
            matched.params = params
            do {
                return try await command.handler(matched)
            } catch let error as APIError {
                return error.response
            } catch {
                return APIError.internalError("\(error)").response
            }
        }
        if !allowed.isEmpty { return APIError.methodNotAllowed(allowed).response }
        return APIError.notFound().response
    }
}
