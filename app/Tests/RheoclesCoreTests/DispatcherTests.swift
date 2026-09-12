import Foundation
import Testing

@testable import RheoclesCore

/// Parsing is the pure part of the HTTP server and the part that silently
/// drops a connection when it is wrong.
@Suite("HTTP request parsing")
struct RequestParseTests {
    @Test("Method, path, query, headers and body come through")
    func full() throws {
        let raw =
            "POST /takes/abc/markers?x=1&label=hello%20there HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer t\r\nContent-Length: 13\r\n\r\n{\"label\":\"a\"}"
        let request = try #require(Request.parse(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/takes/abc/markers")
        #expect(request.query == ["x": "1", "label": "hello there"])
        #expect(request.headers["authorization"] == "Bearer t")
        #expect(request.body == Data("{\"label\":\"a\"}".utf8))
    }

    @Test("An incomplete head or a short body asks for more bytes")
    func incomplete() {
        #expect(Request.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
        #expect(Request.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) == nil)
    }

    @Test("Garbage is refused rather than crashing")
    func garbage() {
        #expect(Request.parse(Data("\r\n\r\n".utf8)) == nil)
        #expect(Request.parse(Data([0xff, 0xfe, 0x0d, 0x0a, 0x0d, 0x0a])) == nil)
    }
}

@Suite("Dispatcher")
struct DispatcherTests {
    private func dispatcher() -> Dispatcher {
        Dispatcher([
            Command("GET", "/") { _ in Response(json: ["ok": true]) },
            Command("POST", "/takes/{id}/start") { r in Response(json: ["id": r.params["id"] ?? ""])
            },
            Command("POST", "/boom") { _ in throw APIError.conflict("taken") },
        ])
    }

    @Test("Routes match and path parameters are filled in")
    func params() async throws {
        let response = await dispatcher().dispatch(
            Request(method: "post", path: "/takes/abc/start"))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"id":"abc"}"#)
    }

    @Test("Path parameters are percent-decoded, and a bare id still works")
    func percentDecoding() async throws {
        // encodeURIComponent turns a stream id's colon into %3A.
        let encoded = await dispatcher().dispatch(
            Request(method: "POST", path: "/takes/camera%3A0x2300fd9009c/start"))
        #expect(String(decoding: encoded.body, as: UTF8.self) == #"{"id":"camera:0x2300fd9009c"}"#)
        // A bare colon is unchanged by decoding.
        let bare = await dispatcher().dispatch(
            Request(method: "POST", path: "/takes/camera:0x2300/start"))
        #expect(String(decoding: bare.body, as: UTF8.self) == #"{"id":"camera:0x2300"}"#)
    }

    @Test("An unknown path is 404 and a known path with the wrong method is 405")
    func misses() async {
        #expect(await dispatcher().dispatch(Request(method: "GET", path: "/nope")).status == 404)
        #expect(
            await dispatcher().dispatch(Request(method: "GET", path: "/takes/x/start")).status
                == 405)
        #expect(
            await dispatcher().dispatch(Request(method: "GET", path: "/takes/x/start/extra")).status
                == 404)
    }

    @Test("APIError becomes the documented error shape")
    func errorShape() async throws {
        let response = await dispatcher().dispatch(Request(method: "POST", path: "/boom"))
        #expect(response.status == 409)
        let body = try JSONDecoder().decode([String: String].self, from: response.body)
        #expect(body == ["error": "taken", "code": "conflict"])
    }
}
