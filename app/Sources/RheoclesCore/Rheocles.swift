import Foundation

/// Identity and defaults shared by the daemon and its clients.
public enum Rheocles {
    /// The engine version reported on `GET /`, written into every manifest, and
    /// printed by `--version`. It comes from the build, not a hand-typed
    /// constant: `Scripts/generate-version.sh` stamps `Version.generated.swift`
    /// from the release tag (bundle.sh and the release workflow run it), so the
    /// wire version can never drift from `Info.plist`. A plain `swift build`
    /// reports the `0.0.0-dev` fallback checked in there.
    public static let version = GeneratedVersion.value

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
