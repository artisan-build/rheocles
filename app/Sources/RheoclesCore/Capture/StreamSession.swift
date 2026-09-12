import CoreMedia
import Foundation

/// Where a live session's frames go. Arming installs nothing here — frames
/// are discarded — and a take's join swaps a writer in without touching the
/// device (spec §6: the writer starts on frames that already exist).
public protocol FrameSink: AnyObject, Sendable {
    /// A video frame or an audio buffer, as the device delivered it, with a
    /// host-time presentation timestamp.
    func handle(_ sampleBuffer: CMSampleBuffer)
}

/// A device held live. One per armed stream, of the right kind.
///
/// `start` opens the device and begins delivering frames to `sink`, if any;
/// `stop` releases it. Sessions are class-bound so the registry can hand out
/// the same instance to a join later.
public protocol StreamSession: AnyObject, Sendable {
    var info: StreamInfo { get }
    /// What the device is actually delivering once started, for the manifest
    /// and for `GET /streams` while armed.
    var active: StreamInfo.Capabilities { get }
    /// Frames (or audio buffers) the device has delivered since arming —
    /// the proof that "armed" means live, and the number a UI shows.
    var framesSeen: Int { get }
    var sink: (any FrameSink)? { get set }
    func start() async throws
    func stop() async
}

/// Builds the right session for a stream. The daemon uses the real devices;
/// tests hand in something that only remembers what it was told.
public protocol SessionFactory: Sendable {
    func makeSession(for stream: StreamInfo) throws -> any StreamSession
}

/// What went wrong opening a device.
public enum CaptureError: Error, Sendable, Equatable {
    /// macOS has not granted this process the device class.
    case permissionDenied(String)
    /// The device is gone, busy, or refused the configuration.
    case deviceUnavailable(String)
    /// This kind is not capturable yet.
    case unsupported(String)

    var apiError: APIError {
        switch self {
        case .permissionDenied(let what):
            APIError(status: 403, code: "permission_denied", message: what)
        case .deviceUnavailable(let what):
            APIError(status: 503, code: "device_unavailable", message: what)
        case .unsupported(let what):
            APIError(status: 501, code: "unsupported", message: what)
        }
    }
}
