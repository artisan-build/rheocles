import Foundation
import Testing

@testable import RheoclesCore

/// The contract test (spec §14, task 4.8): start the real server, hit every
/// path in `docs/openapi.yaml`, and validate the live responses against the
/// schemas the YAML declares. Drift either way — an undocumented field, a
/// missing one, a wrong type, a path the server serves but the YAML omits —
/// fails here, so "current with the code" is enforced, not aspired to.
///
/// The YAML is the source of truth. macOS ships Ruby with a YAML and JSON
/// library, so the test converts it to JSON with a one-liner rather than
/// taking a Swift YAML dependency.
@Suite("OpenAPI contract", .serialized)
struct ContractTests {
    // MARK: Load the spec

    static func specURL() -> URL {
        // Tests run from the package root's .build; docs is two up from app/.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("docs/openapi.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: "docs/openapi.yaml")
    }

    static func loadSpec() throws -> [String: Any] {
        let yaml = specURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-ryaml", "-rjson", "-e", "print JSON.dump(YAML.load_file(ARGV[0]))", yaml.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ContractError.specUnreadable }
        return json
    }

    enum ContractError: Error { case specUnreadable }

    // MARK: A tiny JSON Schema validator (the subset the spec uses)

    struct Validator {
        let spec: [String: Any]

        func resolve(_ schema: [String: Any]) -> [String: Any] {
            guard let ref = schema["$ref"] as? String else { return schema }
            // "#/components/schemas/Name"
            var node: Any = spec
            for part in ref.split(separator: "/").dropFirst() {
                node = (node as? [String: Any])?[String(part)] ?? [:]
            }
            return (node as? [String: Any]).map(resolve) ?? [:]
        }

        /// Returns a failure description, or nil if `value` matches `schema`.
        func check(_ value: Any, against rawSchema: [String: Any], path: String) -> String? {
            let schema = resolve(rawSchema)
            if let const = schema["const"] {
                if "\(const)" != "\(value)" {
                    return "\(path): expected const \(const), got \(value)"
                }
            }
            if let type = schema["type"] as? String {
                if let mismatch = typeMismatch(value, type: type, path: path) { return mismatch }
            }
            if let enumValues = schema["enum"] as? [Any] {
                let strings = enumValues.map { "\($0)" }
                if !strings.contains("\(value)") {
                    return "\(path): \(value) not in enum \(strings)"
                }
            }
            if let type = schema["type"] as? String, type == "object",
                let object = value as? [String: Any]
            {
                let properties = (schema["properties"] as? [String: Any]) ?? [:]
                for required in (schema["required"] as? [String]) ?? []
                where object[required] == nil {
                    return "\(path): missing required '\(required)'"
                }
                if (schema["additionalProperties"] as? Bool) == false {
                    for key in object.keys where properties[key] == nil {
                        return "\(path): undocumented property '\(key)'"
                    }
                }
                for (key, sub) in properties {
                    guard let present = object[key], !(present is NSNull) else { continue }
                    if let subSchema = sub as? [String: Any],
                        let fail = check(present, against: subSchema, path: "\(path).\(key)")
                    {
                        return fail
                    }
                }
            }
            if let type = schema["type"] as? String, type == "array", let array = value as? [Any],
                let items = schema["items"] as? [String: Any]
            {
                for (i, element) in array.enumerated() {
                    if let fail = check(element, against: items, path: "\(path)[\(i)]") {
                        return fail
                    }
                }
            }
            return nil
        }

        private func typeMismatch(_ value: Any, type: String, path: String) -> String? {
            switch type {
            case "object": return value is [String: Any] ? nil : "\(path): expected object"
            case "array": return value is [Any] ? nil : "\(path): expected array"
            case "string": return value is String ? nil : "\(path): expected string, got \(value)"
            case "boolean": return value is Bool ? nil : "\(path): expected boolean"
            case "integer":
                return
                    (value is Int || (value as? NSNumber).map { !CFNumberIsFloatType($0) } == true)
                    ? nil : "\(path): expected integer, got \(value)"
            case "number": return value is NSNumber ? nil : "\(path): expected number"
            default: return nil
            }
        }
    }

    // MARK: The server under test

    private func running() throws -> Server {
        var lastError: Error?
        for _ in 0..<5 {
            var c = Server.Configuration()
            c.catalog = ContractCatalog()
            c.sessionFactory = PushingFactory()
            c.previewFactory = PushingFactory()
            c.writerFactory = NullWriterFactory()
            c.freeBytes = { _ in 1 << 40 }
            c.permissions = {
                Permissions(camera: .authorized, microphone: .authorized, screen: .authorized)
            }
            let base = UInt16.random(in: 20000...60000)
            c.httpPort = base
            c.wsPort = base + 1
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "rheo-contract-\(UUID().uuidString)")
            c.tokenStore = TokenStore(fileURL: dir.appendingPathComponent("token"))
            c.settingsFileURL = dir.appendingPathComponent("settings.json")
            c.outputRoot = dir.appendingPathComponent("out")
            do {
                let server = try Server(configuration: c)
                try server.start()
                return server
            } catch { lastError = error }
        }
        throw lastError!
    }

    private func request(
        _ server: Server, _ method: String, _ path: String, body: String? = nil
    ) async throws -> (Int, String, Data) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.configuration.httpPort)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", data)
    }

    /// The response schema a spec operation declares for a status code.
    private func responseSchema(
        _ spec: [String: Any], path: String, method: String, status: Int, contentType: String
    ) -> [String: Any]? {
        guard let paths = spec["paths"] as? [String: Any],
            let op = (paths[path] as? [String: Any])?[method] as? [String: Any],
            let responses = op["responses"] as? [String: Any],
            let response = responses["\(status)"] as? [String: Any],
            let content = response["content"] as? [String: Any],
            let media = content[
                contentType.split(separator: ";").first.map(String.init) ?? contentType]
                as? [String: Any]
        else { return nil }
        return media["schema"] as? [String: Any]
    }

    @Test("Every documented path's live response validates against its schema")
    func contract() async throws {
        let spec = try Self.loadSpec()
        let validator = Validator(spec: spec)
        let server = try running()
        defer { server.stop() }

        // Drive the server through a full take so every path has a valid
        // state to answer from, recording each (method, path, status, body).
        var seen = Set<String>()
        func validate(_ method: String, _ path: String, _ specPath: String, body: String? = nil)
            async throws
        {
            let (status, contentType, data) = try await request(server, method, path, body: body)
            seen.insert("\(method) \(specPath)")
            guard contentType.hasPrefix("application/json") else {
                // A non-JSON 2xx (a preview JPEG) — the schema is binary; the
                // status and content type are the contract, checked by caller.
                return
            }
            guard
                let schema = responseSchema(
                    spec, path: specPath, method: method.lowercased(), status: status,
                    contentType: "application/json")
            else {
                Issue.record(Comment(rawValue: "\(method) \(specPath): no schema for \(status)"))
                return
            }
            let json = try JSONSerialization.jsonObject(with: data)
            if let fail = validator.check(json, against: schema, path: "\(method) \(specPath)") {
                Issue.record(Comment(rawValue: fail))
            }
        }

        try await validate("GET", "/", "/")
        try await validate("GET", "/streams", "/streams")
        try await validate(
            "POST", "/streams/camera:fake/arm", "/streams/{id}/arm", body: #"{"armed": true}"#)
        _ = try await request(
            server, "POST", "/streams/microphone:fake/arm", body: #"{"armed": true}"#)

        let created = try Manifest.decoder.decode(
            TakeEngine.Created.self,
            from: try await request(server, "POST", "/takes", body: #"{"name": "c"}"#).2)
        let id = created.take.id
        try await validate("POST", "/takes", "/takes", body: #"{"name": "d"}"#)
        // The above created a second take, superseding the first; use its id.
        let active = try #require(await server.takes.activeManifest)
        try await validate("GET", "/takes/\(active.id)", "/takes/{id}")
        try await validate("POST", "/takes/\(active.id)/start", "/takes/{id}/start")
        try await validate(
            "POST", "/takes/\(active.id)/join", "/takes/{id}/join",
            body: #"{"stream": "microphone:fake"}"#)
        try await validate(
            "POST", "/takes/\(active.id)/markers", "/takes/{id}/markers", body: #"{"label": "m"}"#)
        try await validate(
            "POST", "/takes/\(active.id)/leave", "/takes/{id}/leave",
            body: #"{"stream": "microphone:fake"}"#)
        try await validate("POST", "/takes/\(active.id)/stop", "/takes/{id}/stop")
        try await validate("GET", "/takes", "/takes")
        _ = id

        let recorded = try Manifest.decoder.decode(
            TakeEngine.Created.self,
            from: try await request(server, "POST", "/record", body: "{}").2)
        try await validate("POST", "/record", "/record", body: "{}")
        _ = try await request(server, "POST", "/takes/\(recorded.take.id)/stop")
        // The /record above left a fresh active take; stop whatever is active.
        if let stillActive = await server.takes.activeManifest, stillActive.state == .recording {
            _ = try await request(server, "POST", "/takes/\(stillActive.id)/stop")
        }

        try await validate("GET", "/settings", "/settings")
        try await validate("PATCH", "/settings", "/settings", body: #"{"codec": "prores"}"#)

        // Preview: a JPEG for video, JSON level for audio.
        let (pStatus, pType, _) = try await request(server, "GET", "/preview/camera:fake")
        seen.insert("GET /preview/{stream}")
        #expect(pStatus == 200)
        #expect(pType.hasPrefix("image/jpeg"))
        let (aStatus, aType, aData) = try await request(server, "GET", "/preview/microphone:fake")
        #expect(aStatus == 200 && aType.hasPrefix("application/json"))
        if let schema = responseSchema(
            spec, path: "/preview/{stream}", method: "get", status: 200,
            contentType: "application/json")
        {
            let json = try JSONSerialization.jsonObject(with: aData)
            if let fail = validator.check(json, against: schema, path: "GET /preview audio") {
                Issue.record(Comment(rawValue: fail))
            }
        }

        // SSE: headers only.
        let url = URL(
            string:
                "http://127.0.0.1:\(server.configuration.httpPort)/events?access_token=\(server.token)"
        )!
        let (bytes, eventsResponse) = try await URLSession.shared.bytes(from: url)
        #expect((eventsResponse as! HTTPURLResponse).statusCode == 200)
        #expect(
            (eventsResponse as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Type")
                == "text/event-stream")
        seen.insert("GET /events")
        for try await _ in bytes.lines { break }

        // Token rotate last (it invalidates the token).
        try await validate("POST", "/token/rotate", "/token/rotate")

        // Coverage: every path in the YAML was exercised.
        let documented = Set(
            ((spec["paths"] as? [String: Any]) ?? [:]).flatMap { path, ops in
                ((ops as? [String: Any]) ?? [:]).keys
                    .filter { ["get", "post", "patch", "put", "delete"].contains($0) }
                    .map { "\($0.uppercased()) \(path)" }
            })
        let missing = documented.subtracting(seen)
        #expect(missing.isEmpty, "documented but not exercised: \(missing.sorted())")
    }
}

/// A catalog with one stream of every kind the contract needs.
struct ContractCatalog: StreamSource {
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
