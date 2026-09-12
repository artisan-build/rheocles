import AppKit
import Foundation
import RheoclesCore

/// Settings (spec §12): output root, codec, show windows, the bearer token.
///
/// Three of the four are the daemon's, not the app's (PROTOCOL § Settings,
/// § Token rotation): the output root and the default codec live in the
/// daemon's `settings.json` and change over `PATCH /settings`; the token is
/// the daemon's file and rotates over `POST /token/rotate`. Only show
/// windows is the app's own. The app holds no copy it could disagree with:
/// what it shows is the daemon's last answer or the `settings` event.
extension DaemonModel {
    struct SettingsPatch: Encodable {
        var outputRoot: String?
        var codec: Manifest.Codec?
    }

    /// `GET /settings`: the daemon's output root and default codec.
    func refreshSettings() async {
        do {
            settings = try await api.get("/settings", as: Settings.Values.self)
            settingsError = nil
        } catch {
            settingsError = "GET /settings → \(error)"
        }
    }

    /// `PATCH /settings`. The daemon validates — an absolute path, and no
    /// root change while a take is active (409) — and the answer is the
    /// full settings, which replace ours. A refusal is shown verbatim.
    func updateSettings(outputRoot: String? = nil, codec: Manifest.Codec? = nil) {
        settingsError = nil
        Task {
            do {
                settings = try await api.patch(
                    "/settings", SettingsPatch(outputRoot: outputRoot, codec: codec),
                    as: Settings.Values.self)
                Log.info("settings: \(settings.map { "\($0.outputRoot) \($0.codec)" } ?? "")")
            } catch {
                settingsError = "PATCH /settings → \(error)"
                Log.info("settings refused: \(error)")
            }
        }
    }

    /// The default codec is the daemon's (spec §8, one setting for the whole
    /// take); `hevc` until the daemon has answered.
    var codec: Manifest.Codec { settings?.codec ?? .hevc }

    /// Pick a folder for the output root. AppKit's panel; on the desktop
    /// only, never in --render-preview.
    func chooseOutputRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as output root"
        panel.message = "New takes land under this folder. It cannot move while a take is active."
        if let current = settings?.outputRoot {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        NSApplication.shared.activate()
        if panel.runModal() == .OK, let url = panel.url {
            updateSettings(outputRoot: url.path)
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

    /// `POST /token/rotate`: the daemon rewrites its file and the old token
    /// is dead for every request after the answer — including ours, so the
    /// new one goes straight into the client. Every other paired client
    /// (ptero, the NativePHP app) has to read the file again; that is what
    /// rotation is for, and why it takes two clicks.
    func rotateToken() {
        guard rotateArmed else {
            rotateArmed = true
            Task {
                try? await Task.sleep(for: .seconds(6))
                rotateArmed = false
            }
            return
        }
        rotateArmed = false
        settingsError = nil
        Task {
            do {
                let answer: [String: String] = try await api.post("/token/rotate", EmptyBody())
                guard let new = answer["token"], !new.isEmpty else {
                    settingsError = "POST /token/rotate → no token in the answer"
                    return
                }
                api.token = new
                Log.info("token rotated")
            } catch {
                settingsError = "POST /token/rotate → \(error)"
            }
        }
    }

    func revealOutputRoot() {
        guard let root = settings?.outputRoot ?? discovery?.outputRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
    }
}
