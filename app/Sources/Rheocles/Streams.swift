import Foundation
import RheoclesCore

/// The stream list, as `GET /streams` last reported it, and arming.
///
/// Nothing here is state the app owns. `streams` is a copy of the daemon's
/// answer, refreshed on every pulse and immediately after every arm call;
/// `arm(_:_:)` is one `POST` and a re-read. If the app and the NativePHP
/// front end disagree about what is armed, the daemon is right and the next
/// pulse says so.
extension DaemonModel {
    /// One `POST /streams/{id}/arm` in flight. The switch shows the value
    /// being asked for until the daemon answers, then whatever it answered.
    struct Pending: Equatable {
        let id: String
        let armed: Bool
    }

    var armedStreams: [StreamInfo] { streams.filter(\.armed) }

    /// The `showWindows` setting (spec §5): the window list is long and
    /// volatile, so it is hidden unless asked for. Persisted, so the
    /// preference survives a relaunch; the list itself is never persisted.
    var showWindows: Bool {
        get { showWindowsOverride ?? UserDefaults.standard.bool(forKey: "showWindows") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showWindows")
            settingsVersion &+= 1
        }
    }

    /// The streams the popover lists: everything, or everything but windows.
    var visibleStreams: [StreamInfo] {
        _ = settingsVersion
        return showWindows ? streams : streams.filter { $0.kind != .window }
    }

    /// Re-read the list. Called from the pulse; a failure here is not a
    /// daemon failure — `GET /` just succeeded — so it is shown, not acted on.
    func refreshStreams() async {
        streamsRequest &+= 1
        let sequence = streamsRequest
        do {
            let list: Server.StreamList = try await api.get("/streams")
            // Only the newest read may land. The pulse and an arm's own
            // re-read overlap, and the older answer — issued before the arm
            // — would put the switch back until the next pulse.
            guard sequence == streamsRequest else { return }
            streams = list.streams
            permissions = list.permissions
            streamsError = nil
        } catch {
            guard sequence == streamsRequest else { return }
            streamsError = "\(error)"
        }
    }

    /// Arm or disarm one stream (spec §6): device live or not, never a
    /// write. Optimistic in the switch only; the list is the daemon's.
    func arm(_ id: String, _ armed: Bool) {
        guard pending == nil else { return }
        pending = Pending(id: id, armed: armed)
        armError = nil
        Task {
            do {
                try await api.post("/streams/\(id)/arm", ArmBody(armed: armed))
                Log.info("\(armed ? "armed" : "disarmed") \(id)")
            } catch {
                armError = "POST /streams/\(id)/arm → \(error)"
                Log.info("arm \(id) → \(armed) failed: \(error)")
            }
            await refreshStreams()
            pending = nil
        }
    }

    struct ArmBody: Encodable {
        let armed: Bool
    }
}

extension StreamInfo.Kind {
    /// Section headings, in the daemon's fixed order.
    var heading: String {
        switch self {
        case .display: "Displays"
        case .window: "Windows"
        case .camera: "Cameras"
        case .microphone: "Microphones"
        case .systemAudio: "System audio"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .camera: "video"
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        }
    }
}

extension StreamInfo.Capabilities {
    /// "3840×2160 · 60" or "48 kHz · 2 ch": what the file will be.
    var summary: String {
        if let video {
            let rate = video.maxFrameRate
            let shown =
                abs(rate - rate.rounded()) < 0.01
                ? String(Int(rate.rounded())) : String(format: "%.2f", rate)
            return "\(video.width)×\(video.height) · \(shown)"
        }
        if let audio {
            let khz = audio.sampleRate / 1000
            let shown =
                abs(khz - khz.rounded()) < 0.01
                ? String(Int(khz.rounded())) : String(format: "%.1f", khz)
            return "\(shown) kHz · \(audio.channels) ch"
        }
        return "··"
    }
}
