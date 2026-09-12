import AppKit
import Foundation
import ScreenCaptureKit
import os

/// Displays and windows, from `SCShareableContent`.
///
/// Needs Screen Recording; without it the query throws and this source
/// answers with nothing, which `Permissions.screen` explains. The window
/// list is long and volatile by nature — the popover hides it behind a
/// setting (spec §5) — so it is filtered to on-screen, titled, normal-layer
/// windows of real applications.
public struct ScreenSource: StreamSource {
    private static let asked = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func streams() async -> [StreamInfo] {
        // A process that has never touched AppKit has no window-server
        // connection, and SCContentFilter for a window asserts without one
        // (S2). Cheap, idempotent, and required before any SCK call.
        // The window-server connection is established once at daemon startup
        // (rheocles-core's main); no per-call AppKit hop is needed.

        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else { return [] }

        // NSScreen is main-thread only; read what we need in one hop.
        let screens = await MainActor.run { Self.screenInfo() }

        let displays = content.displays.map { display -> StreamInfo in
            let id = display.displayID
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let raw = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let width = mode?.pixelWidth ?? display.width
            let height = mode?.pixelHeight ?? display.height
            let refresh = mode?.refreshRate ?? 0
            return StreamInfo(
                id: StreamInfo.makeID(.display, raw), kind: .display,
                name: screens.first { $0.id == id }?.name ?? "Display \(id)",
                model: "vendor \(CGDisplayVendorNumber(id)) model \(CGDisplayModelNumber(id))",
                capabilities: .init(
                    // 0 Hz is what CoreGraphics reports for a display it cannot
                    // time (some virtual ones); 60 is the honest floor.
                    video: .init(
                        width: width, height: height, maxFrameRate: refresh > 0 ? refresh : 60)))
        }

        let windows = content.windows.filter { window in
            window.isOnScreen && window.windowLayer == 0 && !(window.title ?? "").isEmpty
                && window.owningApplication != nil && window.frame.width >= 64
                && window.frame.height >= 64
        }.map { window -> StreamInfo in
            let app = window.owningApplication?.applicationName ?? ""
            // SCK frames are in points, files are in pixels: scale by the
            // screen the window mostly sits on.
            let scale =
                screens.first { $0.frame.intersects(window.frame) }?.scale ?? screens.first?.scale
                ?? 1
            return StreamInfo(
                id: StreamInfo.makeID(.window, String(window.windowID)), kind: .window,
                name: "\(app) — \(window.title ?? "")",
                model: window.owningApplication?.bundleIdentifier ?? app,
                capabilities: .init(
                    video: .init(
                        width: Int(window.frame.width * scale),
                        height: Int(window.frame.height * scale),
                        maxFrameRate: 60)))
        }

        return displays + windows
    }

    struct ScreenInfo: Sendable {
        let id: CGDirectDisplayID
        /// The name the user sees in System Settings.
        let name: String
        let frame: CGRect
        let scale: CGFloat
    }

    @MainActor
    private static func screenInfo() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID
            else { return nil }
            return ScreenInfo(
                id: id, name: screen.localizedName, frame: screen.frame,
                scale: screen.backingScaleFactor)
        }
    }
}
