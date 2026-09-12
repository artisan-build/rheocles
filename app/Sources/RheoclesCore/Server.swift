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
        /// Where streams come from. The daemon uses the real devices; tests
        /// hand in a fake.
        public var catalog: any StreamSource = DeviceCatalog.standard
        public var permissions: @Sendable () -> Permissions = { DeviceCatalog.permissions() }
        /// How arming opens a device. Tests hand in sessions that only
        /// remember what they were told.
        public var sessionFactory: any SessionFactory = DeviceSessionFactory()
        /// How a take's files get written. Tests hand in fakes.
        public var writerFactory: any WriterFactory = DeviceWriterFactory()
        /// Free space on a volume, for the disk pre-flight. Tests fake it.
        public var freeBytes: @Sendable (URL) -> Int64? = { Discovery.freeBytes(at: $0) }

        public init() {}
    }

    public let configuration: Configuration
    public let token: String
    public let dispatcher: Dispatcher
    public let http: HTTPServer
    public let ws: WebSocketServer

    public let registry: Registry
    public let takes: TakeEngine

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        token = try configuration.tokenStore.loadOrCreate()
        let auth = BearerAuth(token: token)
        // The transports exist before the dispatcher so the registry can
        // broadcast through them; the dispatcher only needs them by reference.
        let router = Router()
        let http = try HTTPServer(
            host: configuration.host, port: configuration.httpPort, dispatcher: router, auth: auth)
        let ws = try WebSocketServer(
            host: configuration.host, port: configuration.wsPort, dispatcher: router, auth: auth)
        let registry = Registry(
            catalog: configuration.catalog, factory: configuration.sessionFactory
        ) { stream in
            let event = Event.stream(stream)
            http.broadcast(event)
            ws.broadcast(event)
        }
        let takes = TakeEngine(
            registry: registry, outputRoot: configuration.outputRoot,
            writerFactory: configuration.writerFactory,
            machine: .init(
                hostname: ProcessInfo.processInfo.hostName, machineId: Discovery.machineIdentifier()
            ),
            freeBytes: configuration.freeBytes
        ) { manifest in
            let event = Event.take(manifest)
            http.broadcast(event)
            ws.broadcast(event)
        }
        self.http = http
        self.ws = ws
        self.registry = registry
        self.takes = takes
        dispatcher = Dispatcher(
            Server.routes(configuration: configuration, registry: registry, takes: takes))
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

    /// The command table. Order is the order `commands` lists them in.
    static func routes(configuration: Configuration, registry: Registry, takes: TakeEngine)
        -> [Command]
    {
        [
            Command("GET", "/") { _ in
                Response(
                    json: Discovery.current(
                        outputRoot: configuration.outputRoot,
                        httpPort: configuration.httpPort, wsPort: configuration.wsPort))
            },
            Command("GET", "/streams") { _ in
                Response(
                    json: StreamList(
                        streams: await registry.streams(),
                        permissions: configuration.permissions()))
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
            if let active = await takes.activeManifest, active.state == .recording {
                _ = try? await takes.stop(active.id)
            }
            await armed.disarmAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        http.stop()
        ws.stop()
    }

    /// Push one event to every client on every transport.
    public func broadcast(_ json: String) {
        http.broadcast(json)
        ws.broadcast(json)
    }
}
