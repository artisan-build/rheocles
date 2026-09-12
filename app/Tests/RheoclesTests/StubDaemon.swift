import Foundation

/// A stand-in for `rheocles-core`: a small Python HTTP server that speaks
/// just enough of the protocol for `DaemonModel` to find it, pair with it,
/// and notice when it dies.
///
/// It is a separate process on purpose. The behaviour under test — probe
/// the port, launch if nothing answers, relaunch on death, give up after a
/// crash loop, kill only what we started — is about processes and ports,
/// and a fake that lives inside the test would prove none of it. Python is
/// used because it is on every Mac with the command line tools and needs
/// no build step of its own.
///
/// `--die` exits immediately, for the crash-loop guard. The token file is
/// written by the stub, the way the daemon writes its own, unless one is
/// already there.
enum StubDaemon {
    static let script: String = """
        import http.server, json, os, sys, time
        args = sys.argv[1:]
        def opt(name, default=None):
            return args[args.index(name) + 1] if name in args else default
        port = int(opt("--port"))
        token_file = opt("--token-file")
        if "--die" in args:
            sys.exit(1)
        if not os.path.exists(token_file):
            os.makedirs(os.path.dirname(token_file), exist_ok=True)
            with open(token_file, "w") as f:
                f.write("ab" * 32 + "\\n")
        with open(token_file) as f:
            token = f.read().strip()

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *a): pass
            def send_json(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(data)
            def authorized(self):
                path, _, query = self.path.partition("?")
                if self.headers.get("Authorization") == "Bearer " + token:
                    return True
                if "access_token=" + token in query:
                    return True
                self.send_json(401, {"error": "no token", "code": "unauthorized"})
                return False
            def do_GET(self):
                path = self.path.partition("?")[0]
                if not self.authorized():
                    return
                if path == "/":
                    self.send_json(200, {
                        "name": "Rheocles", "version": "stub", "hostname": "stub.local",
                        "machineId": "STUB", "outputRoot": "/tmp/stub", "freeBytes": 1,
                        "auth": "bearer", "ports": {"http": port, "ws": port + 1}})
                elif path == "/streams":
                    self.send_json(200, {"streams": [], "permissions": {
                        "camera": "authorized", "microphone": "authorized", "screen": "authorized"}})
                elif path == "/takes":
                    self.send_json(200, [])
                elif path == "/events":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    self.wfile.write(b": connected\\n\\n")
                    self.wfile.flush()
                    try:
                        while True:
                            time.sleep(0.5)
                            self.wfile.write(b": ping\\n\\n")
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                else:
                    self.send_json(404, {"error": "no such route", "code": "not_found"})

        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        server.daemon_threads = True
        server.serve_forever()
        """

    /// The script on disk, written once per test process.
    static let scriptURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheocles-stub-\(ProcessInfo.processInfo.processIdentifier).py")
        try! script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    static let python = URL(fileURLWithPath: "/usr/bin/python3")

    /// A port nothing is listening on right now.
    static func freePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socket, pointer, length)
            }
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socket, pointer, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A scratch directory for one test: token file and core log live here.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheocles-app-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func arguments(port: UInt16, tokenFile: URL, die: Bool = false) -> [String] {
        [scriptURL.path, "--port", String(port), "--token-file", tokenFile.path]
            + (die ? ["--die"] : [])
    }

    /// Run a stub the test owns — the "something already answers" case.
    static func launch(port: UInt16, tokenFile: URL) throws -> Process {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments(port: port, tokenFile: tokenFile)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Answering `GET /` with the token, or not yet.
    static func answers(port: UInt16, token: String?) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

extension StubDaemon {
    /// Wait for a stub the test launched to bind and answer with `token`.
    static func waitUntilAnswers(port: UInt16, token: String) async -> Bool {
        for _ in 0..<80 {
            if await answers(port: port, token: token) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// Poll until a condition holds or the time is up.
@MainActor
func eventually(
    _ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
