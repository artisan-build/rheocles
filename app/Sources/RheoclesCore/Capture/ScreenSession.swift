import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// A display or a window held live through ScreenCaptureKit.
///
/// Frames are 420v at up to the display's refresh rate, delivered only when
/// the content changes — the writer (S2) follows presentation timestamps,
/// not a frame count. Only complete frames are passed on; idle and blank
/// ones are bookkeeping.
final class ScreenSession: NSObject, StreamSession, SCStreamDelegate, SCStreamOutput,
    @unchecked Sendable
{
    let info: StreamInfo
    private var stream: SCStream?
    private var size = (0, 0)
    private var rate = 60.0
    private let queue = DispatchQueue(label: "rheocles.capture.screen")
    private let sinkLock = OSAllocatedUnfairLock<(any FrameSink)?>(initialState: nil)
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    var sink: (any FrameSink)? {
        get { sinkLock.withLock { $0 } }
        set { sinkLock.withLock { $0 = newValue } }
    }

    var framesSeen: Int { frames.withLock { $0 } }

    init(_ stream: StreamInfo) {
        info = stream
    }

    var active: StreamInfo.Capabilities {
        .init(video: .init(width: size.0, height: size.1, maxFrameRate: rate))
    }

    func start() async throws {
        // A process that has never touched AppKit has no window-server
        // connection, and a window filter asserts without one (S2).
        _ = await MainActor.run { NSApplication.shared }
        guard CGPreflightScreenCaptureAccess() else {
            // The prompt is the system's; asking again is the only way to ask.
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.permissionDenied("screen recording is not granted for this app")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied("screen recording: \(error.localizedDescription)")
        }

        let filter: SCContentFilter
        var refresh = 60.0
        switch info.kind {
        case .display:
            guard
                let display = content.displays.first(where: { d in
                    let uuid = CGDisplayCreateUUIDFromDisplayID(d.displayID)?.takeRetainedValue()
                    let raw =
                        uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(d.displayID)
                    return StreamInfo.makeID(.display, raw) == info.id
                })
            else { throw CaptureError.deviceUnavailable("\(info.name) is not connected") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.refreshRate > 0 {
                refresh = mode.refreshRate
            }
        case .window:
            guard
                let window = content.windows.first(where: {
                    StreamInfo.makeID(.window, String($0.windowID)) == info.id
                })
            else { throw CaptureError.deviceUnavailable("\(info.name) is no longer on screen") }
            filter = SCContentFilter(desktopIndependentWindow: window)
        default:
            throw CaptureError.unsupported("\(info.kind.rawValue) is not a screen stream")
        }

        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(filter.contentRect.width * scale)
        let height = Int(filter.contentRect.height * scale)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(refresh.rounded()))
        configuration.showsCursor = true
        configuration.queueDepth = 6
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw CaptureError.deviceUnavailable("\(info.name): \(error.localizedDescription)")
        }
        self.stream = stream
        size = (width, height)
        rate = refresh
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The window closed or the display went away; the registry will see
        // the session gone when the next command touches it.
        self.stream = nil
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: status) == .complete
        else { return }
        frames.withLock { $0 += 1 }
        sink?.handle(sampleBuffer)
    }
}
