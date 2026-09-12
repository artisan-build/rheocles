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

        public init() {}
    }

    public let configuration: Configuration
    public let token: String
    public let dispatcher: Dispatcher
    public let http: HTTPServer
    public let ws: WebSocketServer

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        token = try configuration.tokenStore.loadOrCreate()
        let auth = BearerAuth(token: token)
        dispatcher = Dispatcher(Server.routes(configuration: configuration))
        http = try HTTPServer(
            host: configuration.host, port: configuration.httpPort, dispatcher: dispatcher,
            auth: auth)
        ws = try WebSocketServer(
            host: configuration.host, port: configuration.wsPort, dispatcher: dispatcher, auth: auth
        )
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

    /// The command table. Order is the order `commands` lists them in.
    static func routes(configuration: Configuration) -> [Command] {
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
                        streams: await configuration.catalog.streams(),
                        permissions: configuration.permissions()))
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

    public func stop() {
        http.stop()
        ws.stop()
    }

    /// Push one event to every client on every transport.
    public func broadcast(_ json: String) {
        http.broadcast(json)
        ws.broadcast(json)
    }
}
