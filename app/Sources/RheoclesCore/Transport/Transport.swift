import Foundation

/// A way in and a way out: commands arrive, events leave.
///
/// Both transports carry the same commands (one `Dispatcher`) and the same
/// events (one `broadcast`). SSE is one-way and reconnects itself, which
/// suits a browser page; WebSocket is full duplex, which suits a tool holding
/// a socket. Both are up from launch, before any capture exists — Sonocles
/// learned that stopping capture must never take the listeners down with it.
public protocol Transport: Sendable {
    var label: String { get }
    /// Bind; throws if the port cannot be held.
    func start() throws
    /// Cancel the listener and drop every client. Not optional: a dropped
    /// listener that was never cancelled keeps the port and answers nothing.
    func stop()
    /// Push one event to every connected client.
    func broadcast(_ json: String)
    var clientCount: Int { get }
    /// The commands this transport can deliver.
    var commands: [Route] { get }
}
