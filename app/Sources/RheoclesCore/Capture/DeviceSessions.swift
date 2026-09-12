import AVFoundation
import CoreMedia
import Foundation
import os

/// The daemon's session factory: real devices, one session type per kind.
public struct DeviceSessionFactory: SessionFactory {
    public init() {}

    public func makeSession(for stream: StreamInfo) throws -> any StreamSession {
        switch stream.kind {
        case .camera: try CameraSession(stream)
        case .microphone: try MicrophoneSession(stream)
        case .display, .window: ScreenSession(stream)
        case .systemAudio: SystemAudioSession(stream)
        }
    }
}

/// Shared shape of the two AVCaptureSession-backed sessions.
///
/// `@unchecked Sendable`: `sink` is behind a lock; everything else is set in
/// `init`/`start` and read from the delegate queue.
class AVCaptureStreamSession: NSObject, StreamSession, @unchecked Sendable {
    let info: StreamInfo
    let device: AVCaptureDevice
    let session = AVCaptureSession()
    let queue: DispatchQueue
    private let sinkLock = OSAllocatedUnfairLock<(any FrameSink)?>(initialState: nil)
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    var sink: (any FrameSink)? {
        get { sinkLock.withLock { $0 } }
        set { sinkLock.withLock { $0 = newValue } }
    }

    var framesSeen: Int { frames.withLock { $0 } }

    var active: StreamInfo.Capabilities { info.capabilities }

    init(_ stream: StreamInfo, mediaType: AVMediaType, label: String) throws {
        info = stream
        queue = DispatchQueue(label: "rheocles.capture.\(label)")
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: mediaType == .video
                ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
                : [.microphone, .external],
            mediaType: mediaType, position: .unspecified
        ).devices
        guard
            let found = devices.first(where: {
                StreamInfo.makeID(stream.kind, $0.uniqueID) == stream.id
            })
        else { throw CaptureError.deviceUnavailable("\(stream.name) is not connected") }
        device = found
        super.init()
    }

    /// Ask, if never asked; refuse if refused. Under the hardened runtime a
    /// missing entitlement makes this return denied without a prompt and
    /// without the app ever appearing in System Settings (spec §4).
    static func ensureAccess(_ mediaType: AVMediaType, _ what: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: mediaType) else {
                throw CaptureError.permissionDenied("\(what) access was not granted")
            }
        default: throw CaptureError.permissionDenied("\(what) access is denied for this app")
        }
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        frames.withLock { $0 += 1 }
        sink?.handle(sampleBuffer)
    }

    func start() async throws { fatalError("subclass") }

    func stop() async {
        session.stopRunning()
    }
}

/// A camera held live.
///
/// Holds `lockForConfiguration` for the whole armed period and puts the
/// device's own format back after the session's preset has had its say, so
/// the device keeps the format it had: S1 showed that whoever configures
/// last owns the format, that a second opener silently changes what the
/// first receives, and that the lock prevents it. "Native" is therefore the
/// device's active format at arm time. (`inputPriority` is iOS-only.)
final class CameraSession: AVCaptureStreamSession, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private var locked = false

    init(_ stream: StreamInfo) throws {
        try super.init(stream, mediaType: .video, label: "camera")
    }

    override var active: StreamInfo.Capabilities {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = 1 / device.activeVideoMinFrameDuration.seconds
        return .init(
            video: .init(
                width: Int(dims.width), height: Int(dims.height),
                maxFrameRate: fps.isFinite ? fps : 0))
    }

    override func start() async throws {
        try await Self.ensureAccess(.video, "camera")
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.deviceUnavailable("\(info.name): \(error.localizedDescription)")
        }
        let output = AVCaptureVideoDataOutput()
        // A late frame is a device-side fact the writer should see, not a
        // gap the session hides.
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: queue)

        // What the device has now is what we record.
        let native = device.activeFormat
        let nativeInterval = device.activeVideoMinFrameDuration

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.deviceUnavailable("\(info.name) refused the capture configuration")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            locked = true
        } catch {
            throw CaptureError.deviceUnavailable(
                "\(info.name): could not hold the configuration lock")
        }
        if device.formats.contains(native) {
            device.activeFormat = native
            if nativeInterval.isValid, nativeInterval.seconds > 0 {
                device.activeVideoMinFrameDuration = nativeInterval
            }
        }
        session.startRunning()
        guard session.isRunning else {
            device.unlockForConfiguration()
            locked = false
            throw CaptureError.deviceUnavailable("\(info.name) did not start")
        }
    }

    override func stop() async {
        session.stopRunning()
        if locked {
            device.unlockForConfiguration()
            locked = false
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        deliver(sampleBuffer)
    }
}

/// A microphone held live, delivering 48 kHz 24-bit (in 32-bit containers,
/// aligned high — S3) mono or stereo LPCM as the device has channels.
final class MicrophoneSession: AVCaptureStreamSession, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    init(_ stream: StreamInfo) throws {
        try super.init(stream, mediaType: .audio, label: "microphone")
    }

    override var active: StreamInfo.Capabilities {
        .init(audio: .init(sampleRate: 48000, channels: info.capabilities.audio?.channels ?? 1))
    }

    override func start() async throws {
        try await Self.ensureAccess(.audio, "microphone")
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.deviceUnavailable("\(info.name): \(error.localizedDescription)")
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: info.capabilities.audio?.channels ?? 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.deviceUnavailable("\(info.name) refused the capture configuration")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else {
            throw CaptureError.deviceUnavailable("\(info.name) did not start")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        deliver(sampleBuffer)
    }
}
