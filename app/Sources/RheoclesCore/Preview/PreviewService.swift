import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os

/// One preview frame, on demand (spec §11, §12). No capture runs when nobody
/// is looking: each request opens the device, grabs one frame, and closes it.
///
/// One preview at a time — this is an actor, so `preview(_:)` serializes.
/// Video streams answer a small JPEG; audio streams answer the current level
/// as JSON, which is what the popover's meter shows.
public actor PreviewService {
    public struct Result: Sendable {
        public let body: Data
        public let contentType: String
    }

    private let catalog: any StreamSource
    private let factory: any SessionFactory
    /// Longest side of a preview JPEG. Low-rate by design.
    private let maxDimension = 640
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    public init(catalog: any StreamSource, factory: any SessionFactory) {
        self.catalog = catalog
        self.factory = factory
    }

    public func preview(_ id: String) async throws -> Result {
        guard let info = await catalog.streams().first(where: { $0.id == id }) else {
            throw APIError.notFound("no such stream: \(id)")
        }
        let session: any StreamSession
        do {
            session = try factory.makeSession(for: info)
        } catch let error as CaptureError {
            throw error.apiError
        }
        let shot = OneShot(wantsVideo: info.capabilities.video != nil)
        session.sink = shot
        do {
            try await session.start()
        } catch let error as CaptureError {
            throw error.apiError
        }
        // A screen or a static camera may take a beat to deliver the first
        // frame; audio needs a moment to measure a level.
        let sample = await shot.wait(timeout: info.capabilities.video != nil ? 2.0 : 0.4)
        await session.stop()

        if info.capabilities.video != nil {
            guard let sample, let jpeg = jpeg(from: sample) else {
                throw APIError(
                    status: 503, code: "no_frame",
                    message: "\(info.name) delivered no frame to preview")
            }
            return Result(body: jpeg, contentType: "image/jpeg")
        } else {
            let body = Response(json: ["levelDb": shot.peakDb()]).body
            return Result(body: body, contentType: "application/json")
        }
    }

    private func jpeg(from sample: CMSampleBuffer) -> Data? {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var image = CIImage(cvImageBuffer: pixels)
        let extent = image.extent
        let scale = min(1, CGFloat(maxDimension) / max(extent.width, extent.height))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let color = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(
            of: image, colorSpace: color,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7
            ])
    }
}

/// Captures the first complete video frame, or accumulates audio peak, then
/// releases anyone waiting.
final class OneShot: FrameSink, @unchecked Sendable {
    private let wantsVideo: Bool
    private let lock = NSLock()
    nonisolated(unsafe) private var frame: CMSampleBuffer?
    private var peak: Int32 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var done = false

    init(wantsVideo: Bool) {
        self.wantsVideo = wantsVideo
    }

    func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        if wantsVideo {
            if frame == nil, CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
                frame = sampleBuffer
                finishLocked()
            }
        } else if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            updatePeak(block)
        }
        lock.unlock()
    }

    private func updatePeak(_ block: CMBlockBuffer) {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &pointer) == noErr, let pointer, length >= 4
        else { return }
        pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            var i = 0
            while i + 4 <= length {
                let v = Int32(bytes[i + 1]) | Int32(bytes[i + 2]) << 8 | Int32(bytes[i + 3]) << 16
                let s = v >= 0x800000 ? v - 0x1000000 : v
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
                i += 4
            }
        }
    }

    private func finishLocked() {
        guard !done else { return }
        done = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    /// Sync helpers so the async `wait` never touches the lock directly.
    private func timeout() {
        lock.lock()
        finishLocked()
        lock.unlock()
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let alreadyDone = done
        if !alreadyDone { waiters.append(continuation) }
        lock.unlock()
        if alreadyDone { continuation.resume() }
    }

    private func takeFrame() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func wait(timeout seconds: TimeInterval) async -> CMSampleBuffer? {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.timeout()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(continuation)
        }
        timer.cancel()
        return takeFrame()
    }

    func peakDb() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard peak > 0 else { return -120 }
        return (20 * log10(Double(peak) / 8_388_607.0) * 10).rounded() / 10
    }
}
