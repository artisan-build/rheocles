import Foundation

/// One thing that can be recorded: a display, a window, a camera, a
/// microphone, or the system audio tap.
///
/// Three identity fields — `id`, `name`, `model` — all go into the manifest
/// (spec §5), because display ids change across reconnects and a take must
/// stay legible after the hardware is gone.
public struct StreamInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case display, window, camera, microphone, systemAudio
    }

    /// Stable and URL-safe: `<kind>:<device identifier>`, with the
    /// identifier reduced to `[A-Za-z0-9._-]`. Cameras and microphones use
    /// `AVCaptureDevice.uniqueID`; displays their CoreGraphics UUID, which
    /// survives reconnects where the display id does not; windows their
    /// window number, which does not survive anything and is not meant to.
    public let id: String
    public let kind: Kind
    /// What the user calls it: "Elgato 4K X", "BenQ PD3220U", "Safari — Docs".
    public let name: String
    /// What the hardware calls itself: the model id, vendor/product, or the
    /// owning application for a window.
    public let model: String
    public let capabilities: Capabilities
    /// Whether the capture session is live (spec §6).
    public var armed: Bool
    /// What the device is actually delivering, present only while armed:
    /// the format the session holds (S1: the lock is ours), which is what a
    /// take will record.
    public var active: Capabilities?
    /// Frames the device has delivered since arming; present only while
    /// armed. A live device counts up; a stuck one does not.
    public var framesSeen: Int?

    public struct Capabilities: Codable, Sendable, Equatable {
        public var video: Video?
        public var audio: Audio?

        public struct Video: Codable, Sendable, Equatable {
            /// Native pixels, as the stream will be recorded.
            public var width: Int
            public var height: Int
            /// The highest rate the device advertises. The signal's real rate
            /// can be lower (S1: a 1080p30 HDMI source on a card that
            /// advertises 120); the writer follows the frames, not this.
            public var maxFrameRate: Double

            public init(width: Int, height: Int, maxFrameRate: Double) {
                self.width = width
                self.height = height
                self.maxFrameRate = maxFrameRate
            }
        }

        public struct Audio: Codable, Sendable, Equatable {
            public var sampleRate: Double
            public var channels: Int

            public init(sampleRate: Double, channels: Int) {
                self.sampleRate = sampleRate
                self.channels = channels
            }
        }

        public init(video: Video? = nil, audio: Audio? = nil) {
            self.video = video
            self.audio = audio
        }
    }

    public init(
        id: String, kind: Kind, name: String, model: String, capabilities: Capabilities,
        armed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.model = model
        self.capabilities = capabilities
        self.armed = armed
    }

    /// Build the id for a kind and a raw device identifier.
    public static func makeID(_ kind: Kind, _ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = raw.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return "\(kind.rawValue):\(safe)"
    }
}

/// What macOS has let this process do. Reported with `GET /streams` because
/// that is where a missing grant shows up as a missing stream.
///
/// `notDetermined` is "never asked", which the spec warns is easy to mistake
/// for denied: an app without the right entitlement never appears in
/// System Settings at all (spec §4).
public struct Permissions: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case authorized, denied, restricted, notDetermined
    }

    public var camera: Status
    public var microphone: Status
    /// Screen Recording gates displays and windows both. ScreenCaptureKit has
    /// no "ask" that returns a status; `notDetermined` here means the
    /// preflight said no and the user has not been shown the prompt yet.
    public var screen: Status

    public init(camera: Status, microphone: Status, screen: Status) {
        self.camera = camera
        self.microphone = microphone
        self.screen = screen
    }
}
