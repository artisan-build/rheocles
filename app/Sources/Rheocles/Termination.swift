import Foundation

/// Stops the daemon we started on any way out.
///
/// `applicationWillTerminate` runs on Quit and on a clean `terminate:`, and
/// on nothing else: `kill -TERM` (or ^C from a shell that launched the app)
/// ends the process without it, and the child daemon was left holding
/// :7447 — found the hard way. So SIGTERM and SIGINT are caught here and
/// routed through the same shutdown, then the process exits with the
/// conventional status for that signal.
///
/// Dispatch signal sources, not `signal()` handlers: the shutdown touches
/// the model on the main actor, which a raw signal handler cannot.
enum Termination {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// Install once. `onTerminate` runs on the main queue, then the process
    /// exits — unless `exits` is false, for a test that wants to survive.
    static func install(
        signals: [Int32] = [SIGTERM, SIGINT], exits: Bool = true,
        onTerminate: @escaping @MainActor () -> Void
    ) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Log.info("signal \(sig): shutting down")
                    onTerminate()
                }
                if exits { exit(128 + sig) }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// For tests: forget the handlers, restore the defaults.
    static func uninstall() {
        for source in sources { source.cancel() }
        sources.removeAll()
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
    }
}
