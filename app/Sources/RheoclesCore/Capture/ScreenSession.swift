import AppKit
import CoreMedia
import Foundation
import QuartzCore
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
    /// A ~1 fps floor while a writer is attached: ScreenCaptureKit delivers
    /// a frame only when the content changes, so a static screen (a prompter
    /// holding a page) would deliver nothing after the first — the file would
    /// never span the take, and on a crash no fragment would ever have
    /// flushed, leaving it unrecoverable. Re-feeding the last frame keeps the
    /// timeline moving and the fragments coming.
    private var keepalive: DispatchSourceTimer?
    private let sinkLock = OSAllocatedUnfairLock<(any FrameSink)?>(initialState: nil)
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    /// The most recent complete frame. ScreenCaptureKit delivers a frame
    /// only when the content changes, so a writer attached to a static
    /// screen (a prompter holding a page) would otherwise wait forever for
    /// its first frame; it gets this one, re-stamped with the time it
    /// joined.
    private let lastFrame = NSLock()
    /// Guarded by `lastFrame`; CMSampleBuffer is not Sendable, so no lock box.
    nonisolated(unsafe) private var lastComplete: CMSampleBuffer?
    /// `CACurrentMediaTime` of the last real (non-keepalive) frame.
    private var lastDelivered: Double = 0

    var sink: (any FrameSink)? {
        get { sinkLock.withLock { $0 } }
        set {
            sinkLock.withLock { $0 = newValue }
            if let newValue {
                lastFrame.lock()
                let last = lastComplete
                lastFrame.unlock()
                if let last, let restamped = Self.restamp(last) { newValue.handle(restamped) }
                startKeepalive()
            } else {
                stopKeepalive()
            }
        }
    }

    /// Re-feed the last complete frame if the device has sent nothing for a
    /// second, so a static screen still produces ~1 fps.
    private func startKeepalive() {
        queue.async { [weak self] in
            guard let self else { return }
            self.keepalive?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, let sink = self.sink else { return }
                self.lastFrame.lock()
                let last = self.lastComplete
                let stamp = self.lastDelivered
                self.lastFrame.unlock()
                // Only if the real device has gone quiet.
                if CACurrentMediaTime() - stamp > 0.75, let last, let restamped = Self.restamp(last)
                {
                    sink.handle(restamped)
                }
            }
            timer.resume()
            self.keepalive = timer
        }
    }

    private func stopKeepalive() {
        queue.async { [weak self] in
            self?.keepalive?.cancel()
            self?.keepalive = nil
        }
    }

    /// A copy of a frame carrying the current host time.
    static func restamp(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return copy
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
        stopKeepalive()
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
        lastFrame.lock()
        lastComplete = sampleBuffer
        lastDelivered = CACurrentMediaTime()
        lastFrame.unlock()
        sink?.handle(sampleBuffer)
    }
}
