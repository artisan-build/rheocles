import Foundation

/// The daemon in one object: token, command table, both transports.
///
/// `rheocles-core`'s `main` builds one of these and waits; tests build one on
/// spare ports and talk to it. Everything the engine grows — streams, takes,
/// writers — hangs off this and registers its routes in `routes()`.
public final class Server: Sendable {
    public struct Configuration: Sendable {
        public var host = Rheocles.defaultBindHost
        public var httpPort = Rheocles.defaultHTTPPort
        public var wsPort = Rheocles.defaultWebSocketPort
        public var outputRoot = Rheocles.defaultOutputRoot
        public var tokenStore = TokenStore.standard
        public var settingsFileURL =
            Rheocles.applicationSupport.appendingPathComponent("settings.json")
        /// Where streams come from. The daemon uses the real devices; tests
        /// hand in a fake.
        public var catalog: any StreamSource = DeviceCatalog.standard
        public var permissions: @Sendable () -> Permissions = { DeviceCatalog.permissions() }
        /// How arming opens a device. Tests hand in sessions that only
        /// remember what they were told.
        public var sessionFactory: any SessionFactory = DeviceSessionFactory()
        /// How preview opens a device for a single frame — a polite second
        /// opener that never disturbs an armed take. Tests hand in a fake.
        public var previewFactory: any SessionFactory = DeviceSessionFactory(preview: true)
        /// How a take's files get written. Tests hand in fakes.
        public var writerFactory: any WriterFactory = DeviceWriterFactory()
        /// Free space on a volume, for the disk pre-flight. Tests fake it.
        public var freeBytes: @Sendable (URL) -> Int64? = { Discovery.freeBytes(at: $0) }
        /// Reveal a file/folder in Finder. The daemon opens it via
        /// NSWorkspace on the main actor; tests inject a recorder so no
        /// Finder window opens.
        public var reveal: @Sendable (URL) -> Void = { url in
            Task { @MainActor in Reveal.reveal(url) }
        }

        public init() {}
    }

    public let configuration: Configuration
    public let token: String
    public let dispatcher: Dispatcher
    public let http: HTTPServer
    public let ws: WebSocketServer

    public let registry: Registry
    public let takes: TakeEngine
    public let settings: Settings
    public let preview: PreviewService
    private let auth: BearerAuth
    private let tokenStore: TokenStore

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        token = try configuration.tokenStore.loadOrCreate()
        let auth = BearerAuth(token: token)
        self.auth = auth
        self.tokenStore = configuration.tokenStore
        // The transports exist before the dispatcher so the registry can
        // broadcast through them; the dispatcher only needs them by reference.
        let router = Router()
        let http = try HTTPServer(
            host: configuration.host, port: configuration.httpPort, dispatcher: router, auth: auth)
        let ws = try WebSocketServer(
            host: configuration.host, port: configuration.wsPort, dispatcher: router, auth: auth)
        let settings = Settings(
            fileURL: configuration.settingsFileURL,
            defaults: .init(outputRoot: configuration.outputRoot.path, codec: .hevc)
        ) { values in
            let event = Event.settings(values)
            http.broadcast(event)
            ws.broadcast(event)
        }
        self.settings = settings
        // Recover any take a previous daemon left mid-recording on disk before
        // serving anything: mark it incomplete "daemon died" so it is never
        // treated as the live take.
        TakeEngine.recoverStaleManifests(in: settings.outputRoot)
        let registry = Registry(
            catalog: configuration.catalog, factory: configuration.sessionFactory
        ) { stream in
            let event = Event.stream(stream)
            http.broadcast(event)
            ws.broadcast(event)
        }
        let takes = TakeEngine(
            registry: registry, outputRoot: { settings.outputRoot },
            writerFactory: configuration.writerFactory,
            machine: .init(
                hostname: ProcessInfo.processInfo.hostName, machineId: Discovery.machineIdentifier()
            ),
            defaultCodec: { settings.codec },
            defaultCombine: { settings.combine },
            freeBytes: configuration.freeBytes
        ) { manifest in
            let event = Event.take(manifest)
            http.broadcast(event)
            ws.broadcast(event)
        } onEvent: { event in
            http.broadcast(event)
            ws.broadcast(event)
        }
        let preview = PreviewService(
            catalog: configuration.catalog, factory: configuration.previewFactory)
        self.http = http
        self.ws = ws
        self.registry = registry
        self.takes = takes
        self.preview = preview
        dispatcher = Dispatcher(
            Server.routes(
                registry: registry, takes: takes, settings: settings, auth: auth,
                tokenStore: configuration.tokenStore, permissions: configuration.permissions,
                preview: preview, reveal: configuration.reveal, httpPort: configuration.httpPort,
                wsPort: configuration.wsPort))
        router.dispatcher = dispatcher
    }

    /// `GET /streams`.
    public struct StreamList: Codable, Sendable, Equatable {
        public var streams: [StreamInfo]
        public var permissions: Permissions

        public init(streams: [StreamInfo], permissions: Permissions) {
            self.streams = streams
            self.permissions = permissions
        }
    }

    /// `POST /streams/{id}/arm`.
    public struct ArmRequest: Codable, Sendable {
        public var armed: Bool

        public init(armed: Bool) {
            self.armed = armed
        }
    }

    /// `POST /takes/{id}/join` and `/leave`.
    public struct StreamRef: Codable, Sendable {
        public var stream: String
        public init(stream: String) { self.stream = stream }
    }

    /// `POST /takes/{id}/markers`.
    public struct MarkerRequest: Codable, Sendable {
        public var label: String
        public init(label: String) { self.label = label }
    }

    /// `PATCH /settings`.
    public struct SettingsPatch: Codable, Sendable {
        public var outputRoot: String?
        public var codec: Manifest.Codec?
        public var combine: Bool?
    }

    /// `POST /takes/{id}/reveal` and `POST /reveal`.
    public struct RevealRequest: Codable, Sendable {
        public var path: String?
    }

    /// The command table. Order is the order `commands` lists them in.
    static func routes(
        registry: Registry, takes: TakeEngine, settings: Settings, auth: BearerAuth,
        tokenStore: TokenStore, permissions: @escaping @Sendable () -> Permissions,
        preview: PreviewService, reveal: @escaping @Sendable (URL) -> Void, httpPort: UInt16,
        wsPort: UInt16
    ) -> [Command] {
        [
            Command("GET", "/") { _ in
                Response(
                    json: Discovery.current(
                        outputRoot: settings.outputRoot, httpPort: httpPort, wsPort: wsPort))
            },
            Command("GET", "/streams") { _ in
                Response(
                    json: StreamList(streams: await registry.streams(), permissions: permissions()))
            },
            Command("POST", "/streams/{id}/arm") { request in
                let body = try request.decode(ArmRequest.self)
                let id = request.params["id"] ?? ""
                let stream = body.armed ? try await registry.arm(id) : try await registry.disarm(id)
                return Response(json: stream)
            },
            Command("POST", "/takes") { request in
                let body =
                    request.body == nil
                    ? TakeEngine.CreateRequest() : try request.decode(TakeEngine.CreateRequest.self)
                return Response(status: 201, json: try await takes.create(body))
            },
            Command("GET", "/takes") { _ in
                Response(json: await takes.list())
            },
            Command("GET", "/takes/{id}") { request in
                Response(json: try await takes.manifest(request.params["id"] ?? ""))
            },
            Command("POST", "/takes/{id}/start") { request in
                Response(json: try await takes.start(request.params["id"] ?? ""))
            },
            Command("POST", "/takes/{id}/stop") { request in
                Response(json: try await takes.stop(request.params["id"] ?? ""))
            },
            Command("POST", "/record") { request in
                let body =
                    request.body == nil
                    ? TakeEngine.CreateRequest() : try request.decode(TakeEngine.CreateRequest.self)
                return Response(status: 201, json: try await takes.record(body))
            },
            Command("POST", "/takes/{id}/join") { request in
                let body = try request.decode(StreamRef.self)
                return Response(
                    json: try await takes.join(request.params["id"] ?? "", stream: body.stream))
            },
            Command("POST", "/takes/{id}/leave") { request in
                let body = try request.decode(StreamRef.self)
                return Response(
                    json: try await takes.leave(request.params["id"] ?? "", stream: body.stream))
            },
            Command("POST", "/takes/{id}/markers") { request in
                let body = try request.decode(MarkerRequest.self)
                guard !body.label.isEmpty else {
                    throw APIError.badRequest("a marker label is required")
                }
                return Response(
                    json: try await takes.addMarker(request.params["id"] ?? "", label: body.label))
            },
            Command("GET", "/settings") { _ in
                Response(json: settings.values)
            },
            Command("PATCH", "/settings") { request in
                let patch = try request.decode(SettingsPatch.self)
                if let root = patch.outputRoot {
                    // The output root cannot move under a live take: a take's
                    // files are already reserved beneath the old root.
                    if let active = await takes.activeManifest,
                        active.state == .created || active.state == .recording
                    {
                        throw APIError.conflict(
                            "cannot change the output root while take \(active.id) is active")
                    }
                    guard root.hasPrefix("/") else {
                        throw APIError.badRequest("outputRoot must be an absolute path")
                    }
                    settings.update(outputRoot: root)
                }
                if let codec = patch.codec { settings.update(codec: codec) }
                if let combine = patch.combine { settings.update(combine: combine) }
                return Response(json: settings.values)
            },
            Command("POST", "/takes/{id}/reveal") { request in
                let body =
                    request.body == nil ? RevealRequest() : try request.decode(RevealRequest.self)
                let manifest = try await takes.manifest(request.params["id"] ?? "")
                let folder = URL(fileURLWithPath: manifest.outputRoot)
                    .appendingPathComponent(manifest.destination)
                guard let url = Reveal.resolve(body.path, under: folder) else {
                    throw APIError.notFound("no such path in take \(manifest.id)")
                }
                reveal(url)
                return Response(status: 204, body: Data())
            },
            Command("POST", "/reveal") { request in
                let body =
                    request.body == nil ? RevealRequest() : try request.decode(RevealRequest.self)
                guard let url = Reveal.resolve(body.path, under: settings.outputRoot) else {
                    throw APIError.notFound("no such path under the output root")
                }
                reveal(url)
                return Response(status: 204, body: Data())
            },
            Command("POST", "/takes/{id}/combine") { request in
                Response(json: try await takes.combine(request.params["id"] ?? ""))
            },
            Command("GET", "/preview/{stream}") { request in
                let result = try await preview.preview(request.params["stream"] ?? "")
                return Response(body: result.body, contentType: result.contentType)
            },
            Command("POST", "/token/rotate") { _ in
                let new = try tokenStore.rotate()
                auth.update(to: new)
                return Response(json: ["token": new])
            },
        ]
    }

    /// Bring both transports up. Both, always: a client that reaches one port
    /// must be able to assume the other (spec §11).
    public func start() throws {
        try http.start()
        do {
            try ws.start()
        } catch {
            http.stop()
            throw error
        }
    }

    /// Stop any take, release every device and drop every client.
    public func stop() {
        let armed = self.registry
        let takes = self.takes
        let done = DispatchSemaphore(value: 0)
        Task {
            await takes.shutdown()
            await armed.disarmAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)  // finishing many large writers can take a few seconds
        http.stop()
        ws.stop()
    }

    /// Push one event to every client on every transport.
    public func broadcast(_ json: String) {
        http.broadcast(json)
        ws.broadcast(json)
    }
}
