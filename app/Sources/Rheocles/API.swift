import Foundation
import RheoclesCore

/// The daemon's HTTP transport, from the client side.
///
/// Everything the app shows comes out of this and everything it does goes in
/// through it (brief, rule 1). Nothing here knows about devices — it knows
/// paths, a token, and the one error shape `docs/PROTOCOL.md` promises on
/// every route.
struct API: Sendable {
    enum Failure: Error, Equatable {
        /// Nothing is listening, or the connection was refused or reset.
        case unreachable(String)
        /// The daemon answered 401: our token is stale or missing.
        case unauthorized
        /// Any other non-2xx, with the protocol's stable `code`.
        case rejected(status: Int, code: String, message: String)
        case malformed(String)
    }

    /// `{ "error": "...", "code": "..." }`, on every route and both transports.
    struct ErrorBody: Decodable {
        let error: String
        let code: String
    }

    var host = Rheocles.defaultBindHost
    var port = Rheocles.defaultHTTPPort
    var token: String?

    private var base: URL {
        URL(string: "http://\(host):\(port)")!
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Loopback: an answer that takes longer than this is a daemon that
        // is not going to answer.
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get<T: Decodable>(
        _ path: String, as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        try await send("GET", path, body: nil, decoder: decoder)
    }

    @discardableResult
    func post<T: Decodable>(
        _ path: String, _ body: (some Encodable)?, as type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        try await send(
            "POST", path, body: body.map { try JSONEncoder().encode($0) } ?? nil, decoder: decoder)
    }

    /// A POST whose answer the caller does not need — the app re-reads the
    /// state it changed rather than trusting an echo (brief, rule 1).
    func post(_ path: String, _ body: some Encodable) async throws {
        _ =
            try await send(
                "POST", path, body: try JSONEncoder().encode(body), decoder: JSONDecoder())
            as Data
    }

    /// The event stream's URL. `EventSource`-style clients cannot set a
    /// header, so the token goes in the query (PROTOCOL § Authentication).
    var eventsURL: URL? {
        guard let token else { return nil }
        var components = URLComponents(
            url: base.appending(path: "/events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        return components?.url
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, body: Data?, decoder: JSONDecoder
    ) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("not an HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            if T.self == Data.self { return data as! T }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw Failure.malformed("\(method) \(path): \(error)")
            }
        case 401:
            throw Failure.unauthorized
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw Failure.rejected(
                status: http.statusCode,
                code: body?.code ?? "unknown",
                message: body?.error ?? String(decoding: data, as: UTF8.self))
        }
    }
}

extension API.Failure: CustomStringConvertible {
    var description: String {
        switch self {
        case .unreachable(let why): "unreachable — \(why)"
        case .unauthorized: "token refused (401)"
        case .rejected(let status, let code, let message): "\(status) \(code): \(message)"
        case .malformed(let why): "malformed answer — \(why)"
        }
    }
}
