import Foundation

/// Identity and defaults shared by the daemon and its clients.
public enum Rheocles {
    /// The engine version reported on `GET /` and written into every manifest.
    /// Bumped by hand with the release tag; the build number comes from git.
    public static let version = "0.1.0"

    /// Ports were chosen only to avoid Sonocles' 7357/7358 (spec §11).
    public static let defaultHTTPPort: UInt16 = 7447
    public static let defaultWebSocketPort: UInt16 = 7448

    /// Loopback only in the MVP. The bind address is one field so LAN (v0.2,
    /// TLS + approve-on-the-box pairing) is an addition, not a rewrite.
    public static let defaultBindHost = "127.0.0.1"

    /// `~/Library/Application Support/Rheocles/` — the token file lives here,
    /// and later the settings. Not the output root.
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rheocles", isDirectory: true)
    }

    /// Where takes land unless configured otherwise: `~/Movies/Rheocles`.
    public static var defaultOutputRoot: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rheocles", isDirectory: true)
    }
}
