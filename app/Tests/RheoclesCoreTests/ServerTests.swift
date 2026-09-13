import Foundation
import Testing

@testable import RheoclesCore

/// A real server on spare ports, spoken to over real sockets: the same thing
/// a front end does, minus the popover.
@Suite("Server", .serialized)
struct ServerTests {
    struct FakeCatalog: StreamSource {
        func streams() async -> [StreamInfo] {
            [
                StreamInfo(
                    id: "camera:fake", kind: .camera, name: "Fake camera", model: "Test",
                    capabilities: .init(video: .init(width: 1280, height: 720, maxFrameRate: 30))),
                StreamInfo(
                    id: "microphone:fake", kind: .microphone, name: "Fake mic", model: "Test",
                    capabilities: .init(audio: .init(sampleRate: 48000, channels: 1))),
            ]
        }
    }

    /// Both transports up, both handed the same dispatcher, fake devices.
    /// Random spare ports, retried: something else on the machine may hold
    /// the pair.
    private func running() throws -> Server {
        var lastError: Error?
        for _ in 0..<5 {
            var configuration = Server.Configuration()
            configuration.catalog = FakeCatalog()
            configuration.sessionFactory = FakeFactory()
            configuration.writerFactory = FakeWriterFactory()
            configuration.previewFactory = PushingFactory()
            configuration.freeBytes = { _ in 1 << 40 }
            configuration.reveal = { _ in }  // never open the Finder in a test
            configuration.permissions = {
                Permissions(camera: .authorized, microphone: .denied, screen: .notDetermined)
            }
            let base = UInt16.random(in: 20000...60000)
            configuration.httpPort = base
            configuration.wsPort = base + 1
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rheocles-tests-\(UUID().uuidString)", isDirectory: true)
            configuration.tokenStore = TokenStore(fileURL: dir.appendingPathComponent("token"))
            configuration.settingsFileURL = dir.appendingPathComponent("settings.json")
            configuration.outputRoot = dir
            do {
                let server = try Server(configuration: configuration)
                try server.start()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError!
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

    @Test("GET /streams lists every stream with armed state and the permissions")
    func streams() async throws {
        let server = try running()
        defer { server.stop() }
        let (status, data) = try await get(server, "/streams", token: server.token)
        #expect(status == 200)
        let list = try JSONDecoder().decode(Server.StreamList.self, from: data)
        #expect(list.streams.map(\.id) == ["camera:fake", "microphone:fake"])
        #expect(list.streams.allSatisfy { !$0.armed })
        #expect(
            list.permissions
                == Permissions(camera: .authorized, microphone: .denied, screen: .notDetermined))
        #expect(try await get(server, "/streams", token: nil).0 == 401)
    }

    private func post(_ server: Server, _ path: String, _ json: String) async throws -> (Int, Data)
    {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test("POST /streams/{id}/arm arms and disarms, and GET /streams agrees")
    func arm() async throws {
        let server = try running()
        defer { server.stop() }
        let (status, data) = try await post(server, "/streams/camera:fake/arm", #"{"armed": true}"#)
        #expect(status == 200)
        let armed = try JSONDecoder().decode(StreamInfo.self, from: data)
        #expect(armed.id == "camera:fake" && armed.armed && armed.active != nil)

        let list = try JSONDecoder().decode(
            Server.StreamList.self, from: try await get(server, "/streams", token: server.token).1)
        #expect(list.streams.first { $0.id == "camera:fake" }?.armed == true)
        #expect(list.streams.first { $0.id == "microphone:fake" }?.armed == false)

        let (status2, data2) = try await post(
            server, "/streams/camera:fake/arm", #"{"armed": false}"#)
        #expect(status2 == 200)
        #expect(try JSONDecoder().decode(StreamInfo.self, from: data2).armed == false)

        #expect(try await post(server, "/streams/nope/arm", #"{"armed": true}"#).0 == 404)
        #expect(try await post(server, "/streams/camera:fake/arm", "").0 == 400)
        #expect(try await post(server, "/streams/camera:fake/arm", #"{"armed": "yes"}"#).0 == 400)
    }

    @Test("Takes over HTTP: create 201, start, stop, read back, list; take events on WebSocket")
    func takes() async throws {
        let server = try running()
        defer { server.stop() }
        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        _ = try await post(server, "/streams/camera:fake/arm", #"{"armed": true}"#)
        _ = try await task.receive()  // the stream event

        let (status, data) = try await post(
            server, "/takes", #"{"name": "Ep 1", "expectedDuration": 60}"#)
        #expect(status == 201)
        let created = try Manifest.decoder.decode(TakeEngine.Created.self, from: data)
        #expect(
            created.take.state == .created && created.take.streams.first?.path == "fake-camera.mov")
        let id = created.take.id
        guard case .string(let createdEvent) = try await task.receive() else {
            Issue.record("no event"); return
        }
        #expect(
            createdEvent.contains(#""event":"take""#)
                && createdEvent.contains(#""state":"created""#))

        let (s2, d2) = try await post(server, "/takes/\(id)/start", "")
        #expect(s2 == 200)
        #expect(try Manifest.decode(d2).state == .recording)
        let (s3, d3) = try await get(server, "/takes/\(id)", token: server.token)
        #expect(s3 == 200)
        #expect(try Manifest.decode(d3).state == .recording)
        #expect(try await post(server, "/takes", "{}").0 == 409, "one active take")
        let (s4, d4) = try await post(server, "/takes/\(id)/stop", "")
        #expect(s4 == 200)
        #expect(try Manifest.decode(d4).state == .complete)
        #expect(try await post(server, "/takes/\(id)/stop", "").0 == 409, "already stopped")
        let (s5, d5) = try await get(server, "/takes", token: server.token)
        #expect(s5 == 200)
        #expect(try Manifest.decoder.decode([TakeEngine.Summary].self, from: d5).map(\.id) == [id])
        #expect(try await get(server, "/takes/nope", token: server.token).0 == 404)

        let (s6, d6) = try await post(server, "/record", #"{"name": "one click"}"#)
        #expect(s6 == 201)
        #expect(
            try Manifest.decoder.decode(TakeEngine.Created.self, from: d6).take.state == .recording)
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func patch(_ server: Server, _ path: String, _ json: String) async throws -> (Int, Data)
    {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)\(path)")!)
        request.httpMethod = "PATCH"
        request.httpBody = Data(json.utf8)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test("A percent-encoded stream id works on arm and preview, HTTP and WebSocket")
    func encodedStreamId() async throws {
        let server = try running()
        defer { server.stop() }
        // "camera:fake" as encodeURIComponent would send it.
        let encoded = "camera%3Afake"
        let (armStatus, armBody) = try await post(
            server, "/streams/\(encoded)/arm", #"{"armed": true}"#)
        #expect(armStatus == 200)
        #expect(try JSONDecoder().decode(StreamInfo.self, from: armBody).id == "camera:fake")

        let (previewStatus, previewType, _) = try await request(
            server, "GET", "/preview/\(encoded)")
        #expect(previewStatus == 200 && previewType.hasPrefix("image/jpeg"))

        // Over WebSocket too — the path comes from the frame.
        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        let reply = try await roundTrip(
            task,
            #"{"id": 1, "method": "POST", "path": "/streams/camera%3Afake/arm", "body": {"armed": false}}"#
        )
        #expect(reply["status"] == .number(200))
        guard case .object(let body)? = reply["body"] else { Issue.record("no body"); return }
        #expect(body["id"] == .string("camera:fake"))
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// A GET/DELETE-style request with a content type check, reused by the
    /// encoded-id and preview tests.
    private func request(
        _ server: Server, _ method: String, _ path: String
    ) async throws -> (Int, String, Data) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", data)
    }

    @Test("GET /preview returns JPEG bytes over HTTP and base64 over WebSocket")
    func previewImage() async throws {
        let server = try running()
        defer { server.stop() }
        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(server.configuration.httpPort)/preview/camera:fake")!)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]))

        // WebSocket: the binary body comes base64 with its content type.
        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        let reply = try await roundTrip(
            task, #"{"id": 9, "method": "GET", "path": "/preview/camera:fake"}"#)
        #expect(reply["status"] == .number(200))
        #expect(reply["contentType"] == .string("image/jpeg"))
        guard case .string(let base64)? = reply["base64"] else { Issue.record("no base64"); return }
        #expect(Data(base64Encoded: base64)?.starts(with: [0xFF, 0xD8, 0xFF]) == true)
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test("Settings: GET, PATCH codec and root, root refused while a take is active")
    func settings() async throws {
        let server = try running()
        defer { server.stop() }
        let (s0, d0) = try await get(server, "/settings", token: server.token)
        #expect(s0 == 200)
        #expect(try JSONDecoder().decode(Settings.Values.self, from: d0).codec == .hevc)

        let (s1, d1) = try await patch(server, "/settings", #"{"codec": "prores"}"#)
        #expect(s1 == 200)
        #expect(try JSONDecoder().decode(Settings.Values.self, from: d1).codec == .prores)

        let newRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        ).path
        #expect(try await patch(server, "/settings", #"{"outputRoot": "\#(newRoot)"}"#).0 == 200)
        #expect(server.settings.outputRoot.path == newRoot)
        #expect(try await patch(server, "/settings", #"{"outputRoot": "relative"}"#).0 == 400)

        // A take is active → the root cannot move.
        _ = try await post(server, "/streams/camera:fake/arm", #"{"armed": true}"#)
        _ = try await post(server, "/record", "{}")
        #expect(try await patch(server, "/settings", #"{"outputRoot": "/tmp/x"}"#).0 == 409)
    }

    @Test("Token rotation returns a new token and invalidates the old one")
    func tokenRotate() async throws {
        let server = try running()
        defer { server.stop() }
        let old = server.token
        let (status, data) = try await post(server, "/token/rotate", "")
        #expect(status == 200)
        let new = try JSONDecoder().decode([String: String].self, from: data)["token"]
        #expect(new != nil && new != old)
        #expect(try await get(server, "/", token: old).0 == 401, "old token no longer works")
        #expect(try await get(server, "/", token: new).0 == 200)
    }

    @Test("Join, leave and markers over HTTP, and a levels event on SSE while recording")
    func joinLeaveMarkers() async throws {
        let server = try running()
        defer { server.stop() }
        #expect(try await post(server, "/streams/camera:fake/arm", #"{"armed": true}"#).0 == 200)
        let recordResponse = try await post(server, "/record", "{}")
        #expect(
            recordResponse.0 == 201, "record: \(String(decoding: recordResponse.1, as: UTF8.self))")
        let created = try Manifest.decoder.decode(TakeEngine.Created.self, from: recordResponse.1)
        let id = created.take.id

        // SSE, authenticated by query as a browser would.
        let url = URL(
            string:
                "http://127.0.0.1:\(server.configuration.httpPort)/events?access_token=\(server.token)"
        )!
        let (bytes, _) = try await URLSession.shared.bytes(from: url)

        let joined = try Manifest.decode(
            try await post(server, "/takes/\(id)/join", #"{"stream": "microphone:fake"}"#).1)
        #expect(joined.streams.contains { $0.id == "microphone:fake" })
        let marked = try Manifest.decode(
            try await post(server, "/takes/\(id)/markers", #"{"label": "cue"}"#).1)
        #expect(marked.markers.first?.label == "cue")
        #expect(try await post(server, "/takes/\(id)/markers", #"{"label": ""}"#).0 == 400)
        let left = try Manifest.decode(
            try await post(server, "/takes/\(id)/leave", #"{"stream": "microphone:fake"}"#).1)
        #expect(left.streams.first { $0.id == "microphone:fake" }?.events.last?.type == .leave)

        // A levels or marker event should arrive on the stream.
        var sawEvent = false
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            let event = try JSONDecoder().decode(
                [String: JSONValue].self, from: Data(line.dropFirst(6).utf8))
            if event["event"] == .string("levels") || event["event"] == .string("marker") {
                sawEvent = true
                break
            }
        }
        #expect(sawEvent)
        _ = try await post(server, "/takes/\(id)/stop", "")
    }

    @Test("Arming is announced on SSE and on WebSocket")
    func armEvents() async throws {
        let server = try running()
        defer { server.stop() }

        // SSE, authenticated by query parameter as a browser would.
        let url = URL(
            string:
                "http://127.0.0.1:\(server.configuration.httpPort)/events?access_token=\(server.token)"
        )!
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        #expect((response as! HTTPURLResponse).statusCode == 200)
        #expect(
            (response as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Type")
                == "text/event-stream")

        // WebSocket, authenticated by the auth frame.
        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)

        try await Task.sleep(for: .milliseconds(100))
        _ = try await post(server, "/streams/microphone:fake/arm", #"{"armed": true}"#)

        var sse: String?
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            sse = String(line.dropFirst(6))
            break
        }
        let event = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data((sse ?? "{}").utf8))
        #expect(event["event"] == .string("stream"))
        guard case .object(let stream)? = event["stream"] else {
            Issue.record("no stream in event"); return
        }
        #expect(stream["id"] == .string("microphone:fake") && stream["armed"] == .bool(true))

        guard case .string(let wsText) = try await task.receive() else {
            Issue.record("no ws event"); return
        }
        #expect(wsText == sse, "both transports carry the same bytes")
        task.cancel(with: .normalClosure, reason: nil)
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
        // Command replies and broadcast events share the socket: arming, for
        // one, pushes a `stream` event. A reply carries `status`; an event
        // carries `event` and none. Skip events and return the command reply,
        // so the reply is never mistaken for whichever frame arrived first.
        while true {
            guard case .string(let frame) = try await task.receive() else {
                throw APIError.badRequest("not text")
            }
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(frame.utf8))
            if decoded["status"] != nil { return decoded }
        }
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

    @Test("WebSocket: a 204 reveal is valid JSON (body null), parseable like any reply")
    func wsRevealNoContent() async throws {
        let server = try running()
        defer { server.stop() }
        // A take, so its folder (and the output root) exists to be revealed.
        _ = try await post(server, "/streams/camera:fake/arm", #"{"armed": true}"#)
        let (createStatus, _) = try await post(server, "/takes", #"{"name": "r"}"#)
        #expect(createStatus == 201)

        let task = socket(server)
        _ = try await roundTrip(task, #"{"auth": "\#(server.token)"}"#)
        // POST /reveal {} reveals the output root — 204, no body. Before the
        // fix this frame was `{"id":1,"status":204,"body":}` and roundTrip's
        // JSON decode would throw here.
        let reply = try await roundTrip(
            task, #"{"id": 1, "method": "POST", "path": "/reveal", "body": {}}"#)
        #expect(reply["status"] == .number(204))
        #expect(reply["body"] == .null)
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
        let streams = try await roundTrip(task, #"{"id": 2, "method": "GET", "path": "/streams"}"#)
        guard case .object(let body)? = streams["body"], case .array(let items)? = body["streams"]
        else {
            Issue.record("no streams in the WebSocket reply")
            return
        }
        #expect(items.count == 2)
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
