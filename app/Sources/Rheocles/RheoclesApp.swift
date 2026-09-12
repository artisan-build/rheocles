import AppKit
import SwiftUI

/// The menu bar app.
///
/// `MenuBarExtra` in `.window` style — the popover-from-the-icon shape rather
/// than a list of menu items, which is the right frame for a list of streams
/// with toggles and a Record button.
///
/// `LSUIElement` in the bundle's Info.plist keeps it out of the Dock and the
/// app switcher. That plist is also what gives the bundle a stable TCC
/// identity: the daemon that touches the devices runs as this bundle's child,
/// so the usage strings that let it ask live in this bundle's plist.
@main
struct RheoclesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var daemon = DaemonModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(daemon: daemon)
        } label: {
            // The mark, as a template image. See MenuBarIcon for why a bare
            // SwiftUI view here renders nothing at all.
            Image(nsImage: MenuBarIcon.image(for: iconState))
        }
        .menuBarExtraStyle(.window)
    }

    /// Armed and recording arrive with the streams and takes (tasks 2–3);
    /// until then the icon is idle whenever there is a daemon at all.
    private var iconState: MenuBarIcon.State {
        .idle
    }
}

/// Finds or launches the daemon at launch.
///
/// This cannot live in the popover's `onAppear`: a `MenuBarExtra` in window
/// style does not build its content until someone clicks the icon, and the
/// daemon should be up before anyone does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // A design feedback loop that needs no human and no screen.
            // Renders every popover state to PNG and exits.
            if Preview.renderIfRequested() {
                NSApplication.shared.terminate(nil)
                return
            }

            Log.info("Rheocles launched, pid \(ProcessInfo.processInfo.processIdentifier)")
            DaemonModel.shared.connect()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            DaemonModel.shared.shutdown()
            Log.info("Rheocles quit")
        }
    }
}
