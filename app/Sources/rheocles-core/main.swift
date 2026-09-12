import Foundation
import RheoclesCore

// rheocles-core — the headless daemon.
//
//   rheocles-core [--http-port 7447] [--ws-port 7448] [--output-root DIR]
//                 [--token-file FILE] [--settings-file FILE]
//
// Binds both transports on loopback, provisions the bearer token, and waits.
// Front ends launch this if nothing answers on the port and share it if
// something does (spec §3). SIGINT/SIGTERM stop it cleanly.

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.endIndex else { return nil }
    return args[i + 1]
}

if args.contains("--help") || args.contains("-h") {
    print(
        "usage: rheocles-core [--http-port N] [--ws-port N] [--output-root DIR] "
            + "[--token-file FILE] [--settings-file FILE]"
    )
    exit(0)
}
if args.contains("--version") {
    print(Rheocles.version)
    exit(0)
}
if args.contains("--list-streams") {
    // What GET /streams would answer, without binding anything: the quick
    // way to see what this process is allowed to see.
    let list = Server.StreamList(
        streams: await DeviceCatalog.standard.streams(), permissions: DeviceCatalog.permissions())
    print(String(decoding: Response(json: list).body, as: UTF8.self))
    exit(0)
}

var configuration = Server.Configuration()
if let p = opt("--http-port").flatMap(UInt16.init) { configuration.httpPort = p }
if let p = opt("--ws-port").flatMap(UInt16.init) { configuration.wsPort = p }
if let root = opt("--output-root") { configuration.outputRoot = URL(fileURLWithPath: root) }
if let file = opt("--token-file") {
    configuration.tokenStore = TokenStore(fileURL: URL(fileURLWithPath: file))
}
if let file = opt("--settings-file") {
    configuration.settingsFileURL = URL(fileURLWithPath: file)
}

let server: Server
do {
    server = try Server(configuration: configuration)
    // An explicit --output-root is authoritative: it overrides (and persists
    // to) settings.json, rather than being silently ignored when a previous
    // run left an outputRoot behind.
    if let root = opt("--output-root") { server.settings.update(outputRoot: root) }
    try server.start()
} catch {
    FileHandle.standardError.write(Data("rheocles-core: \(error)\n".utf8))
    exit(1)
}

print(
    "rheocles-core \(Rheocles.version) listening on http://\(configuration.host):\(configuration.httpPort) "
        + "and ws://\(configuration.host):\(configuration.wsPort); token in \(configuration.tokenStore.fileURL.path)"
)
fflush(stdout)

// Stop on the usual signals so the ports are released promptly rather than
// on whatever schedule the kernel reclaims them.
let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        server.stop()
        print("rheocles-core: stopped")
        exit(0)
    }
    source.resume()
    return source
}
_ = signals

dispatchMain()
