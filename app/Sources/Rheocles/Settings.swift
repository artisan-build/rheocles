import AppKit
import Foundation
import RheoclesCore

/// Settings (spec §12): output root, codec, show windows, the bearer token.
///
/// Two of the four are the daemon's, not the app's. The output root is one
/// field on `GET /` and there is no command to change it yet; the token is
/// the daemon's file and rotating it is planned over the API. Both are
/// shown truthfully and left alone until the protocol says how — the app
/// does not fork it (brief). Codec is a request field on every take, so it
/// is a preference here and travels with `POST /record`; show windows is
/// purely the app's.
extension DaemonModel {
    /// `hevc` or `prores`, one setting for the whole take (spec §8).
    var codec: Manifest.Codec {
        get {
            Manifest.Codec(rawValue: UserDefaults.standard.string(forKey: "codec") ?? "") ?? .hevc
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "codec")
            settingsVersion &+= 1
        }
    }

    /// The pairing code, for anything that cannot read the file (spec §11).
    var token: String? { api.token }

    /// The token, masked to its ends: enough to compare, not enough to use.
    var maskedToken: String? {
        guard let token, token.count > 12 else { return token }
        return "\(token.prefix(6))…\(token.suffix(6))"
    }

    func copyToken() {
        guard let token else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        Log.info("token copied to the pasteboard")
    }

    /// Rotation invalidates the old token on the daemon's next request
    /// (PROTOCOL § Authentication) — which is why it must be the daemon's
    /// call, not a rewrite of the file behind its back. Planned over the
    /// API; nil until the route exists.
    static let rotateTokenPath: String? = nil

    /// Whether the output root can be changed over the API. Not yet: it is
    /// `rheocles-core --output-root` and one field on `GET /`.
    static let outputRootPath: String? = nil

    func revealOutputRoot() {
        guard let root = discovery?.outputRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
    }
}
