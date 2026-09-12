import AVFoundation
import CoreMedia
import Foundation
import os

/// The daemon's session factory: real devices, one session type per kind.
public struct DeviceSessionFactory: SessionFactory {
    /// Preview sessions are polite second openers: no config lock, no format
    /// change, so grabbing a frame never disturbs an armed or recording take.
    public let preview: Bool

    public init(preview: Bool = false) {
        self.preview = preview
    }

    public func makeSession(for stream: StreamInfo) throws -> any StreamSession {
        switch stream.kind {
        case .camera: try CameraSession(stream, preview: preview)
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
/// Holds `lockForConfiguration` for the whole armed period: S1 showed that
/// whoever configures last owns the format, that a second opener silently
/// changes what the first receives, and that the lock prevents it. "Native"
/// is deterministic — the device's largest format, at the signal's rate
/// where the device reports one and otherwise the format's maximum capped
/// at 60 — never whatever the last app left the device set to.
final class CameraSession: AVCaptureStreamSession, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private var locked = false
    /// Preview sessions do not hold the configuration lock or force the
    /// native format — they are polite second openers that take whatever the
    /// device is already giving (S1), so a preview never disturbs a take.
    private let previewMode: Bool

    init(_ stream: StreamInfo, preview: Bool = false) throws {
        previewMode = preview
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

        let native = Self.nativeFormat(of: device)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.deviceUnavailable("\(info.name) refused the capture configuration")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        // After the session's preset has had its say, and held from here on.
        do {
            try device.lockForConfiguration()
            locked = true
        } catch {
            throw CaptureError.deviceUnavailable(
                "\(info.name): could not hold the configuration lock")
        }
        if let native {
            device.activeFormat = native.format
            device.activeVideoMinFrameDuration = native.frameDuration
            device.activeVideoMaxFrameDuration = native.frameDuration
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

    /// The largest format by pixels; among equals, uncompressed over
    /// compressed and the higher rate. The rate is the format's maximum
    /// capped at 60 — a capture card advertises 120 and duplicates a 30 fps
    /// signal to fill it (S1), and AVFoundation cannot see the signal's own
    /// rate, so 60 is the honest ceiling until step 5 measures delivery.
    static func nativeFormat(of device: AVCaptureDevice) -> (
        format: AVCaptureDevice.Format, frameDuration: CMTime
    )? {
        func pixels(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        func rate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        func uncompressed(_ f: AVCaptureDevice.Format) -> Bool {
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sub == kCVPixelFormatType_422YpCbCr8
                || sub == kCVPixelFormatType_422YpCbCr8_yuvs || sub == kCVPixelFormatType_32BGRA
        }
        guard
            let best = device.formats.max(by: { a, b in
                (pixels(a), uncompressed(a) ? 1 : 0, rate(a)) < (
                    pixels(b), uncompressed(b) ? 1 : 0, rate(b)
                )
            })
        else { return nil }
        // Ranges are discrete on UVC devices (144, 120, 60, 59.94, 50, 30…):
        // take the fastest one at or under 60 and use its own duration.
        let chosen =
            best.videoSupportedFrameRateRanges.filter { $0.maxFrameRate <= 60.5 }
            .max { $0.maxFrameRate < $1.maxFrameRate }
            ?? best.videoSupportedFrameRateRanges.min { $0.maxFrameRate < $1.maxFrameRate }
        let duration = chosen?.minFrameDuration ?? CMTime(value: 1, timescale: 30)
        return (best, duration)
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
