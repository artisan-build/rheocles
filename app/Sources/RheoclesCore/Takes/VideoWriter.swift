import AVFoundation
import CoreMedia
import Foundation
import os

/// One video stream to one QuickTime movie: HEVC or ProRes 422, 1 s
/// fragments, a time-of-day `tmcd` track (S2, S3), and a **constant frame
/// rate** on disk.
///
/// Every frame is stamped by the host clock at arrival — the clock the audio,
/// `started`, and the `tmcd` stamp already use — not the card's own PTS, which
/// on a "60" card fed a 59.94 signal drifts half a second against the audio
/// over a few minutes. Those host times are snapped to a nominal-rate grid;
/// when the source runs slow or the encoder drops a frame, the gap is filled
/// with the last frame, so the file is CFR (N frames × 1/fps == the span) and
/// no NLE has to conform VFR. The timecode track keeps one sample per frame,
/// sparse or not, so a SIGKILLed take keeps its timecode in the fragments that
/// survive.
///
/// `@unchecked Sendable`: every mutable member is touched under `lock`.
public final class VideoWriter: Writer, @unchecked Sendable {
    public let url: URL
    private let codec: Manifest.Codec
    private let frameRate: Double
    private let tcRate: Int
    private let clock: HostClock
    /// The video track's media timescale. QuickTime defaults to 600, which is
    /// too coarse; 60000 gives ~16 µs, divides the common frame rates, and is
    /// an exact multiple of every `tcRate` we use so the CFR grid lands on
    /// whole ticks.
    private let mediaTimescale: CMTimeScale = 60000
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var timecodeInput: AVAssetWriterInput?
    private var tcFormat: CMTimeCodeFormatDescription?
    /// Grid origin: the first frame's host time, in `mediaTimescale` ticks.
    private var firstPTS: CMTime?
    private var firstHostSeconds: Double?
    private var lastHostSeconds: Double?
    private var startFrames = 0
    private var tcSamplesWritten = 0
    /// The last CFR slot appended (real or padded); -1 before the first frame.
    private var lastSlot = -1
    /// The last real frame, re-submitted to pad gaps.
    private var lastSample: CMSampleBuffer?
    /// Frames appended to the file — real plus padding — i.e. the CFR count.
    private var frames = 0
    /// Padding frames synthesised to keep the rate constant.
    private var padded = 0
    /// Frames the source handed us, for the measured rate.
    private var delivered = 0
    private var dropped = 0
    private var failure: String?
    private var finished = false
    /// Drift and rate as measured before stop pads out the tail.
    private var finalDrift: Double?
    private var finalRate: Double?

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
    public var framesDelivered: Int { lock.withLock { delivered } }
    public func sampleLevelDb() -> Double? { nil }

    /// Delivered frames × nominal frame duration versus the timeline they
    /// span, in seconds: zero for a camera delivering exactly its rate,
    /// negative when the device runs under it (a 4K card fed a 59.94 signal).
    /// Meaningless for a screen that only sends changes, so `measuresDrift` is
    /// false there and nothing is reported.
    public var measuresDrift = true

    public var drift: Double? {
        lock.withLock { finished ? finalDrift : measureDrift() }
    }

    /// The true incoming rate — delivered frames over the host span — to the
    /// hundredth (so a 59.94 source reads 59.94, not 60). Computed for any
    /// video stream, screens included, once there are two frames to span.
    public var measuredFrameRate: Double? {
        lock.withLock { finished ? finalRate : measureRate() }
    }

    private func measureDrift() -> Double? {
        guard measuresDrift, frameRate > 0, let first = firstHostSeconds,
            let last = lastHostSeconds, delivered > 1
        else { return nil }
        let span = last - first + 1 / frameRate
        return ((Double(delivered) / frameRate - span) * 1000).rounded() / 1000
    }

    private func measureRate() -> Double? {
        guard let first = firstHostSeconds, let last = lastHostSeconds, delivered > 1, last > first
        else { return nil }
        return ((Double(delivered - 1) / (last - first)) * 100).rounded() / 100
    }

    public func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, failure == nil else { return }
        // The frame's host-clock capture time — macOS stamps every capture
        // sample from `CMClockGetHostTimeClock`, the same clock the audio,
        // `started`, and the `tmcd` use (see HostClock). Snapping to it and
        // filling the gaps, rather than trusting the card's nominal frame
        // duration × count, is what keeps video and audio on one timeline and
        // the file constant-rate.
        let hostSeconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                try open(format: format, atHostSeconds: hostSeconds)
            } catch {
                failure = "could not start writing: \(error)"
                return
            }
        }
        guard let writer, let video, let firstHost = firstHostSeconds, writer.status == .writing
        else { return }
        delivered += 1
        lastHostSeconds = hostSeconds

        // The CFR slot this frame belongs to, on the nominal-rate grid anchored
        // at the first frame's host time. A slow source leaves gaps; a jittery
        // callback that lands on or before the last slot is nudged forward so
        // no frame is lost and the timeline stays monotonic.
        var slot = Int(((hostSeconds - firstHost) * Double(tcRate)).rounded())
        if slot <= lastSlot { slot = lastSlot + 1 }

        // Pad a short gap with the last frame so a dropped frame or a source a
        // touch under its rate stays constant-rate. The judgement is **per
        // gap**: a gap wider than ~1 s is a hold (a static screen, a stalled
        // source, a saturated encoder), so it is not padded at all — the real
        // frame is placed straight away and the previous frame's on-screen
        // duration, derived from this timestamp, covers the hold. Padding a
        // hold would queue up to a second of stale duplicates, fill the
        // encoder, and starve the frame that actually changed (the new slide
        // arriving late). Each append is guarded — appending to an unready
        // input throws an Objective-C exception that would abort the process.
        if lastSlot >= 0, slot - lastSlot > 1, slot - lastSlot <= tcRate, let last = lastSample {
            for gap in (lastSlot + 1)..<slot where video.isReadyForMoreMediaData {
                if appendFrame(last, at: gap) {
                    frames += 1
                    padded += 1
                    lastSlot = gap
                }
            }
        }
        // Re-check before the real frame: the padding above, or plain encoder
        // load, may have filled the queue. Drop rather than append to an
        // unready input (which aborts); the next frame continues the timeline.
        guard video.isReadyForMoreMediaData else {
            dropped += 1
            if let error = writer.error { failure = "write failed: \(error)" }
            return
        }
        if appendFrame(sampleBuffer, at: slot) {
            frames += 1
            lastSlot = slot
            lastSample = sampleBuffer
        } else {
            dropped += 1
            if let error = writer.error { failure = "write failed: \(error)" }
        }
    }

    /// Append one frame at a CFR slot: restamp to the grid tick and one
    /// nominal duration, write it, and give it its timecode sample.
    private func appendFrame(_ sample: CMSampleBuffer, at slot: Int) -> Bool {
        guard let video, let first = firstPTS else { return false }
        let ticksPerFrame = Int64(mediaTimescale) / Int64(tcRate)
        let stamp = CMTime(
            value: first.value + Int64(slot) * ticksPerFrame, timescale: mediaTimescale)
        // One nominal frame's duration, so consecutive slots are exactly
        // constant-rate; `endSession` at stop still spans the last frame past
        // this when a static tail holds.
        let frameDuration = CMTime(value: ticksPerFrame, timescale: mediaTimescale)
        guard let toAppend = Self.restamp(sample, to: stamp, duration: frameDuration),
            video.append(toAppend)
        else { return false }
        appendTimecodeSample(at: slot, stamp: stamp, duration: frameDuration)
        return true
    }

    /// A copy of a frame with a new presentation timestamp and duration.
    static func restamp(_ sample: CMSampleBuffer, to pts: CMTime, duration: CMTime)
        -> CMSampleBuffer?
    {
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return copy
    }

    private func open(format: CMFormatDescription, atHostSeconds hostSeconds: Double) throws {
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        var settings: [String: Any] = [
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
        ]
        switch codec {
        case .prores:
            // ProRes is intra-only — no bitrate, no queue to size, and it
            // throws on the HEVC compression keys, so leave its settings bare.
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            // 0.15 bits per pixel per frame — the HEVC tier measured in
            // docs/CAPTURE.md as visually transparent versus ProRes 422 at
            // both 1080p and 4K, and the figure the disk pre-flight uses.
            // Tell the encoder the source's rate so it sizes its queue, and no
            // frame reordering keeps latency down; the input's
            // `expectsMediaDataInRealTime` already selects VideoToolbox's
            // real-time (live) mode (see the drop-rate note in CAPTURE.md).
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey:
                    Int(Double(dims.width) * Double(dims.height) * max(frameRate, 1) * 0.15),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoAllowFrameReorderingKey: false,
            ]
        }
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: settings, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = mediaTimescale

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
        // Anchor the grid at the first frame's host time, on a whole tick.
        let firstStamp = CMTime(
            value: Int64((hostSeconds * Double(mediaTimescale)).rounded()),
            timescale: mediaTimescale)
        writer.startSession(atSourceTime: firstStamp)

        self.writer = writer
        self.video = video
        self.timecodeInput = timecodeInput
        self.tcFormat = tc
        firstPTS = firstStamp
        firstHostSeconds = hostSeconds
        lastHostSeconds = hostSeconds
        startFrames = HostClock.frames(
            sinceMidnightOf: clock.date(forHostSeconds: hostSeconds), fps: tcRate)
    }

    /// One four-byte time-of-day sample for a frame: the frame's slot is its
    /// offset from the first, so on a CFR grid the timecode counts by one.
    private func appendTimecodeSample(at slot: Int, stamp: CMTime, duration: CMTime) {
        guard let timecodeInput, let tcFormat, timecodeInput.isReadyForMoreMediaData else { return }
        var value = UInt32((startFrames + slot) % (24 * 3600 * tcRate)).bigEndian
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
            duration: duration, presentationTimeStamp: stamp, decodeTimeStamp: .invalid)
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

    /// Pad the grid out to the final slot with the last frame, so the file's
    /// duration is the take's, and close. Returns the writer parts to finish.
    private func close() -> (
        AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, String?, Int, Int
    ) {
        lock.withLock {
            finished = true
            finalDrift = measureDrift()
            finalRate = measureRate()
            // Span a static tail to stop with a single held frame at the stop
            // slot: AVAssetWriter derives the previous frame's on-screen
            // duration from this next timestamp, so a slide held to the end of
            // a talk lasts until stop instead of ending when it last changed —
            // one append, no burst of duplicates however long the hold.
            if let video, let last = lastSample, lastSlot >= 0, let firstHost = firstHostSeconds,
                video.isReadyForMoreMediaData
            {
                let stopSlot = Int(((clock.nowHostSeconds - firstHost) * Double(tcRate)).rounded())
                if stopSlot > lastSlot, appendFrame(last, at: stopSlot) {
                    frames += 1
                    padded += 1
                    lastSlot = stopSlot
                }
            }
            return (writer, video, timecodeInput, failure, frames, dropped)
        }
    }

    public func finish() async -> String? {
        let (writer, video, timecodeInput, failure, frames, dropped) = close()
        guard let writer else {
            return failure ?? "no frames arrived"
        }
        if writer.status == .writing {
            video?.markAsFinished()
            timecodeInput?.markAsFinished()
            // The completion-handler form wrapped in one continuation, not the
            // async `finishWriting()`: the latter's bridge intermittently
            // double-resumes its continuation under load and crashes (a
            // long-standing AVFoundation issue; see docs/known-issues.md).
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
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
