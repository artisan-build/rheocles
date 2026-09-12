import Foundation
import Testing

@testable import RheoclesCore

/// A real server on spare ports, spoken to over real sockets: the same thing
/// a front end does, minus the popover.
@Suite("Server", .serialized)
struct ServerTests {
    /// Both transports up, both handed the same dispatcher.
    private func running() throws -> Server {
        var configuration = Server.Configuration()
        // Spare ports, away from the real 7447/7448 in case a daemon is up.
        let base = UInt16.random(in: 20000...60000)
        configuration.httpPort = base
        configuration.wsPort = base + 1
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheocles-tests-\(UUID().uuidString)", isDirectory: true)
        configuration.tokenStore = TokenStore(fileURL: dir.appendingPathComponent("token"))
        configuration.outputRoot = dir
        let server = try Server(configuration: configuration)
        try server.start()
        return server
    }

    private func get(_ server: Server, _ path: String, token: String?) async throws -> (Int, Data) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    /// Spec §11, rule 7: one command table, two encoders. This is the test
    /// that says so.
    @Test("Both transports expose exactly the same command set")
    func parity() throws {
        let server = try running()
        defer { server.stop() }
        #expect(server.http.commands == server.ws.commands)
        #expect(server.http.commands == server.dispatcher.commands)
        #expect(server.http.commands.contains(Route("GET", "/")))
    }

    @Test("GET / answers discovery with the bearer token")
    func discovery() async throws {
        let server = try running()
        defer { server.stop() }
        let (status, data) = try await get(server, "/", token: server.token)
        #expect(status == 200)
        let discovery = try JSONDecoder().decode(Discovery.self, from: data)
        #expect(discovery.name == "Rheocles")
        #expect(discovery.version == Rheocles.version)
        #expect(discovery.auth == "bearer")
        #expect(discovery.ports.http == server.configuration.httpPort)
        #expect(discovery.ports.ws == server.configuration.wsPort)
        #expect(discovery.outputRoot == server.configuration.outputRoot.path)
        // The root does not exist yet; free space is still measured, on the volume.
        #expect((discovery.freeBytes ?? 0) > 0)
        #expect(!discovery.hostname.isEmpty)
        #expect(discovery.machineId.count == 36)
    }

    @Test("No token, or the wrong token, is 401 with the error shape")
    func unauthorized() async throws {
        let server = try running()
        defer { server.stop() }
        let (status, data) = try await get(server, "/", token: nil)
        #expect(status == 401)
        #expect(
            try JSONDecoder().decode([String: String].self, from: data)["code"] == "unauthorized")
        #expect(try await get(server, "/", token: "nope").0 == 401)
    }

    @Test("Unknown routes are 404 and wrong methods 405, still behind the token")
    func routing() async throws {
        let server = try running()
        defer { server.stop() }
        #expect(try await get(server, "/nope", token: server.token).0 == 404)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)/")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 405)
        #expect(try await get(server, "/nope", token: nil).0 == 401)
    }

    @Test("The token file is created by the server on first start")
    func tokenFile() throws {
        let server = try running()
        defer { server.stop() }
        let path = server.configuration.tokenStore.fileURL.path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(
            try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .newlines)
                == server.token)
    }

    private func socket(_ server: Server) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(server.configuration.wsPort)/")!)
        task.resume()
        return task
    }

    private func roundTrip(_ task: URLSessionWebSocketTask, _ json: String) async throws -> [String:
        JSONValue]
    {
        try await task.send(.string(json))
        guard case .string(let reply) = try await task.receive() else {
            throw APIError.badRequest("not text")
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(reply.utf8))
    }

    @Test("WebSocket: after the auth frame, GET / answers the same discovery as HTTP")
    func wsDiscovery() async throws {
        let server = try running()
        defer { server.stop() }
        let task = socket(server)
        #expect(
            try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)["status"] == .number(200))
        let reply = try await roundTrip(task, #"{"id": 7, "method": "GET", "path": "/"}"#)
        #expect(reply["id"] == .number(7))
        #expect(reply["status"] == .number(200))
        guard case .object(let body)? = reply["body"] else { Issue.record("no body"); return }
        #expect(body["name"] == .string("Rheocles"))
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test("WebSocket: commands are 401 until the auth frame, and a wrong token stays 401")
    func wsAuthFrame() async throws {
        let server = try running()
        defer { server.stop() }
        let task = socket(server)
        let refused = try await roundTrip(task, #"{"id": "a", "method": "GET", "path": "/"}"#)
        #expect(refused["status"] == .number(401))
        #expect(refused["id"] == .string("a"))
        let wrong = try await roundTrip(task, #"{"auth": "nope"}"#)
        #expect(wrong["status"] == .number(401))
        let ok = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        #expect(ok["status"] == .number(200))
        let reply = try await roundTrip(task, #"{"id": 1, "method": "GET", "path": "/"}"#)
        #expect(reply["status"] == .number(200))
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test("WebSocket: the same 404 and error shape as HTTP")
    func wsErrors() async throws {
        let server = try running()
        defer { server.stop() }
        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        let reply = try await roundTrip(task, #"{"id": 2, "method": "GET", "path": "/nope"}"#)
        #expect(reply["status"] == .number(404))
        #expect(
            reply["body"]
                == .object(["error": .string("no such route"), "code": .string("not_found")]))
        let junk = try await roundTrip(task, "not json")
        #expect(junk["status"] == .number(400))
        task.cancel(with: .normalClosure, reason: nil)
    }
}
