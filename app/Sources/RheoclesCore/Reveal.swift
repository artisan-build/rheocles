import AppKit
import Foundation

/// "Open in Finder", on the daemon (spec §2: if it can be clicked it can be
/// called). A browser front end (ptero) cannot open Finder, and two native
/// apps should not each reimplement it — so the daemon reveals paths on
/// their behalf and they all call one route.
public enum Reveal {
    /// Reveal a file or folder in Finder, selecting it. Must run on the main
    /// actor; the daemon has a window-server connection from startup.
    @MainActor
    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Resolve a client-supplied relative path under `base`, refusing
    /// absolute paths and `..` traversal, and requiring the result to exist.
    /// An empty path is `base` itself. Returns nil for anything invalid.
    public static func resolve(_ path: String?, under base: URL) -> URL? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains("..") else {
            return nil
        }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = cleaned.isEmpty ? base : base.appendingPathComponent(cleaned)
        // Physical containment: resolve symlinks on both sides so a symlink
        // planted under the root that points outside it (e.g. `link -> /etc`)
        // cannot be used to reveal a path outside the root.
        let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == basePath || target.hasPrefix(basePath + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: target) else { return nil }
        return url
    }
}
