import AVFoundation
import CoreMedia
import Foundation
import os

/// One video stream to one QuickTime movie: HEVC or ProRes 422, 1 s
/// fragments, and a time-of-day `tmcd` track (S2, S3).
///
/// Frames are appended with their own presentation timestamps, so the
/// file's timeline is the host clock's: a display that delivers a frame
/// only when something changes makes a sparse, correct file. The timecode
/// track gets one four-byte sample per frame at the frame's own timestamp,
/// so its timeline is exactly the video's — sparse or not — every fragment
/// is stamped, and a SIGKILLed take keeps its timecode in the fragments
/// that survive.
///
/// `@unchecked Sendable`: every mutable member is touched under `lock`.
public final class VideoWriter: Writer, @unchecked Sendable {
    public let url: URL
    private let codec: Manifest.Codec
    private let frameRate: Double
    private let tcRate: Int
    private let clock: HostClock
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var timecodeInput: AVAssetWriterInput?
    private var tcFormat: CMTimeCodeFormatDescription?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var startFrames = 0
    private var tcSamplesWritten = 0
    private var frames = 0
    private var dropped = 0
    private var failure: String?
    private var finished = false
    /// Drift as measured before the stop re-appends the last frame.
    private var finalDrift: Double?

    public init(url: URL, codec: Manifest.Codec, frameRate: Double, clock: HostClock = .shared) {
        self.url = url
        self.codec = codec
        self.frameRate = frameRate
        self.tcRate = HostClock.timecodeRate(for: frameRate)
        self.clock = clock
    }

    public var timecode: String? {
        lock.withLock {
            firstPTS == nil ? nil : HostClock.timecode(frames: startFrames, fps: tcRate)
        }
    }

    public var framesWritten: Int { lock.withLock { frames } }
    public var framesDropped: Int { lock.withLock { dropped } }

    /// Delivered frames × nominal frame duration versus the timeline they
    /// span, in seconds: zero for a camera delivering exactly its rate,
    /// negative when the device runs under it (a 4K capture card fed a
    /// 30 fps signal). Meaningless for a screen that only sends changes, so
    /// `measuresDrift` is false there and nothing is reported.
    public var measuresDrift = true

    public var drift: Double? {
        lock.withLock { finished ? finalDrift : measureDrift() }
    }

    private func measureDrift() -> Double? {
        guard measuresDrift, frameRate > 0, let first = firstPTS, let last = lastPTS, frames > 1
        else { return nil }
        let span = last.seconds - first.seconds + 1 / frameRate
        return ((Double(frames + dropped) / frameRate - span) * 1000).rounded() / 1000
    }

    public func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, failure == nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                try open(format: format, at: pts)
            } catch {
                failure = "could not start writing: \(error)"
                return
            }
        }
        guard let writer, let video, writer.status == .writing else { return }
        // A timestamp that does not advance would corrupt the track's
        // timeline; ScreenCaptureKit occasionally repeats one.
        if let last = lastPTS, pts.seconds - last.seconds < 0.001 {
            dropped += 1
            return
        }
        if video.isReadyForMoreMediaData, video.append(sampleBuffer) {
            if let first = firstPTS { appendTimecodeSample(at: pts, from: first) }
            frames += 1
            lastPTS = pts
        } else {
            dropped += 1
            if let error = writer.error { failure = "write failed: \(error)" }
        }
    }

    private func open(format: CMFormatDescription, at pts: CMTime) throws {
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        var settings: [String: Any] = [
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
        ]
        switch codec {
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            // Provisional tier until step 9 measures: 0.15 bits per pixel per
            // frame, the same figure the disk pre-flight uses.
            let bitrate = Double(dims.width) * Double(dims.height) * max(frameRate, 1) * 0.15
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoAllowFrameReorderingKey: false,
            ]
        }
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: settings, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true

        var tc: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(tcRate)),
            frameQuanta: UInt32(tcRate),
            flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &tc)
        guard status == noErr, let tc else {
            throw NSError(domain: "rheocles.writer", code: Int(status))
        }
        let timecodeInput = AVAssetWriterInput(
            mediaType: .timecode, outputSettings: nil, sourceFormatHint: tc)
        timecodeInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(timecodeInput) else {
            throw NSError(
                domain: "rheocles.writer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "inputs refused"])
        }
        writer.add(video)
        writer.add(timecodeInput)
        video.addTrackAssociation(
            withTrackOf: timecodeInput, type: AVAssetTrack.AssociationType.timecode.rawValue)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "rheocles.writer", code: -2)
        }
        writer.startSession(atSourceTime: pts)

        self.writer = writer
        self.video = video
        self.timecodeInput = timecodeInput
        self.tcFormat = tc
        firstPTS = pts
        startFrames = HostClock.frames(sinceMidnightOf: clock.date(for: pts), fps: tcRate)
    }

    /// The time-of-day frame number at this frame's timestamp, as a
    /// timecode sample with the frame's own timestamp and one frame's
    /// duration; the writer sets the real durations from the timestamps.
    private func appendTimecodeSample(at pts: CMTime, from first: CMTime) {
        guard let timecodeInput, let tcFormat, timecodeInput.isReadyForMoreMediaData else { return }
        let elapsedFrames = Int(((pts.seconds - first.seconds) * Double(tcRate)).rounded())
        var value = UInt32((startFrames + elapsedFrames) % (24 * 3600 * tcRate)).bigEndian
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block) == noErr,
            let block
        else { return }
        withUnsafeBytes(of: &value) { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(tcRate)), presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: tcFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else { return }
        if timecodeInput.append(sample) { tcSamplesWritten += 1 }
    }

    private func close() -> (
        AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, String?, Int, Int
    ) {
        lock.withLock {
            finished = true
            finalDrift = measureDrift()
            return (writer, video, timecodeInput, failure, frames, dropped)
        }
    }

    public func finish() async -> String? {
        let (writer, video, timecodeInput, failure, frames, dropped) = close()
        guard let writer else {
            return failure ?? "no frames arrived"
        }
        if writer.status == .writing {
            // The last frame lasts until now, not one nominal frame: a
            // static screen's single frame must span the take.
            writer.endSession(
                atSourceTime: CMTime(
                    seconds: clock.nowHostSeconds, preferredTimescale: 1_000_000_000))
            video?.markAsFinished()
            timecodeInput?.markAsFinished()
            await writer.finishWriting()
        }
        if let failure { return failure }
        if writer.status == .failed {
            return "finish failed: \(writer.error.map { "\($0)" } ?? "unknown")"
        }
        if frames == 0 { return "no frames written" }
        _ = dropped
        return nil
    }
}
