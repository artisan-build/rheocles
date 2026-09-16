import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import RheoclesCore

/// The real-encode media tests (HEVC especially) are slow on a CI runner's
/// software VideoToolbox and, run in parallel, starve every other suite. The
/// heavy ones are gated: set `RHEOCLES_MEDIA_TESTS=1` to run them locally or
/// on a nightly. What stays in CI is `.serialized` and codec-cheap.
let rheoMediaTestsEnabled = ProcessInfo.processInfo.environment["RHEOCLES_MEDIA_TESTS"] == "1"

@Suite("Host clock")
struct HostClockTests {
    @Test("Time-of-day frames round to the nearest frame and wrap at 24 h")
    func frames() {
        var c = Calendar.current
        c.timeZone = .current
        let midnight = c.startOfDay(for: Date())
        #expect(HostClock.frames(sinceMidnightOf: midnight, fps: 30) == 0)
        #expect(HostClock.frames(sinceMidnightOf: midnight.addingTimeInterval(1.0), fps: 30) == 30)
        #expect(
            HostClock.frames(sinceMidnightOf: midnight.addingTimeInterval(0.99), fps: 30) == 30,
            "0.99 s is frame 29.7 → 30")
        #expect(HostClock.frames(sinceMidnightOf: midnight.addingTimeInterval(0.01), fps: 30) == 0)
        #expect(HostClock.timecode(frames: 30 * 3661 + 5, fps: 30) == "01:01:01:05")
        #expect(HostClock.timecodeRate(for: 59.94) == 60)
        #expect(HostClock.timecodeRate(for: 60.00024) == 60)
        #expect(HostClock.timecodeRate(for: 29.97) == 30)
    }

    @Test("A PTS maps to a wall time through one offset")
    func mapping() {
        let clock = HostClock(offset: 1_000_000)
        #expect(clock.date(forHostSeconds: 5).timeIntervalSince1970 == 1_000_005)
        #expect(
            abs(
                HostClock.shared.date(forHostSeconds: HostClock.shared.nowHostSeconds)
                    .timeIntervalSinceNow) < 0.05)
    }
}

/// Synthetic frames and buffers through the real writers, read back with
/// AVFoundation and by hand.
@Suite("Writers", .serialized)
struct WriterTests {
    private let scratch = Scratch("writer-tests")

    private func temp(_ name: String) -> URL {
        scratch.file(name)
    }

    private func frame(width: Int, height: Int, pts: Double, shade: UInt8) throws -> CMSampleBuffer
    {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let pb = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(pb, [])
        memset(
            CVPixelBufferGetBaseAddress(pb), Int32(shade), CVPixelBufferGetBytesPerRow(pb) * height)
        CVPixelBufferUnlockBaseAddress(pb, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: try #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        return try #require(sample)
    }

    /// Every timecode sample's frame value, in order.
    private func timecodes(in asset: AVURLAsset) async throws -> [UInt32] {
        let tc = try #require(try await asset.load(.tracks).first { $0.mediaType == .timecode })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tc, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [UInt32] = []
        while let sb = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0, let block = CMSampleBufferGetDataBuffer(sb)
            else { continue }
            var value: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value)
            samples.append(UInt32(bigEndian: value))
        }
        #expect(reader.status == .completed, "reader: \(reader.error.map { "\($0)" } ?? "ok")")
        return samples
    }

    // These real-encode tests are the CI runner's software-VideoToolbox
    // bottleneck, so they are gated (RHEOCLES_MEDIA_TESTS=1) and run
    // locally/nightly.

    @Test(
        "CFR: a 59.94 source is written at a constant 60, one tmcd sample per frame from the host clock",
        .enabled(if: rheoMediaTestsEnabled))
    func constantFrameRate() async throws {
        let url = temp("cfr.mov")
        let clock = HostClock.shared
        let writer = VideoWriter(url: url, codec: .hevc, frameRate: 60, clock: clock)
        let start = clock.nowHostSeconds
        let sourceRate = 59.94
        let count = 240  // ~4 s
        for i in 0..<count {
            writer.handle(
                try frame(
                    width: 320, height: 240, pts: start + Double(i) / sourceRate,
                    shade: UInt8(i & 0xff)))
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(await writer.finish() == nil)
        // The measured rate is the true incoming rate, not the nominal 60.
        #expect(abs((writer.measuredFrameRate ?? 0) - 59.94) < 0.2)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.load(.tracks).first { $0.mediaType == .video })
        let span = Double(count - 1) / sourceRate
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - span) < 3.0 / 60, "CFR duration within a frame of the span")
        // Constant 60: frame count is the span × 60, within a frame or two.
        let expectedFrames = Int((span * 60).rounded())
        #expect(
            abs(writer.framesWritten - expectedFrames) <= 2,
            "\(writer.framesWritten) vs \(expectedFrames)")
        // One timecode sample per frame, counting up by one with no gaps.
        let samples = try await timecodes(in: asset)
        #expect(samples.count == writer.framesWritten)
        let startFrames = HostClock.frames(
            sinceMidnightOf: clock.date(forHostSeconds: start), fps: 60)
        #expect(samples.map { Int($0) } == (0..<samples.count).map { startFrames + $0 })
    }

    @Test(
        "CFR: gaps in a 59.94 source are padded, so the file is still constant 60 and spans the take",
        .enabled(if: rheoMediaTestsEnabled))
    func paddedOverGaps() async throws {
        let url = temp("cfr-gaps.mov")
        let clock = HostClock.shared
        let writer = VideoWriter(url: url, codec: .hevc, frameRate: 60, clock: clock)
        let start = clock.nowHostSeconds
        let sourceRate = 59.94
        let count = 300  // ~5 s
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            // 15% of frames never arrive — the writer pads the gap with the
            // last frame, so the file stays CFR against the host timeline.
            if i > 0, i < count - 1, Double.random(in: 0..<1, using: &rng) < 0.15 { continue }
            writer.handle(
                try frame(
                    width: 320, height: 240, pts: start + Double(i) / sourceRate,
                    shade: UInt8(i & 0xff)))
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await writer.finish() == nil)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.load(.tracks).first { $0.mediaType == .video })
        let span = Double(count - 1) / sourceRate
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - span) < 3.0 / 60, "gaps padded: duration still spans the take")
        let expectedFrames = Int((span * 60).rounded())
        #expect(abs(writer.framesWritten - expectedFrames) <= 2, "constant 60 across the gaps")
        let samples = try await timecodes(in: asset)
        #expect(samples.count == writer.framesWritten, "one tmcd sample per frame, pads included")
    }

    @Test("Video: ProRes 422 is the alternative codec", .enabled(if: rheoMediaTestsEnabled))
    func prores() async throws {
        let url = temp("prores.mov")
        let clock = HostClock.shared
        let writer = VideoWriter(url: url, codec: .prores, frameRate: 60, clock: clock)
        let start = clock.nowHostSeconds
        for i in 0..<60 {
            writer.handle(
                try frame(width: 320, height: 240, pts: start + Double(i) / 60, shade: 40))
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(await writer.finish() == nil)
        let track = try #require(
            try await AVURLAsset(url: url).load(.tracks).first { $0.mediaType == .video })
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422)
    }

    @Test("Video: nothing arriving is an error, not an empty file")
    func nothing() async {
        let writer = VideoWriter(url: temp("empty.mov"), codec: .hevc, frameRate: 30)
        #expect(await writer.finish() == "no frames arrived")
    }

    private func audio(
        _ bytes: [UInt8], asbd: AudioStreamBasicDescription, frames: Int, pts: Double
    ) throws -> CMSampleBuffer {
        var desc = asbd
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &desc, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        try bytes.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: try #require(block), offsetIntoDestination: 0,
                dataLength: bytes.count)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return try #require(sample)
    }

    private func readWav(_ url: URL) throws -> (
        rate: Int, channels: Int, bits: Int, timeReference: UInt64, data: Data
    ) {
        let raw = try Data(contentsOf: url)
        func chunk(_ id: String) -> Range<Int>? {
            guard let r = raw.range(of: Data(id.utf8)) else { return nil }
            let size = Int(
                raw[r.upperBound..<r.upperBound + 4].withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)
                })
            return (r.upperBound + 4)..<(r.upperBound + 4 + size)
        }
        let bext = try #require(chunk("bext"))
        let lo = raw[bext.lowerBound + 338..<bext.lowerBound + 342].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let hi = raw[bext.lowerBound + 342..<bext.lowerBound + 346].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let fmt = try #require(chunk("fmt "))
        let channels = Int(
            raw[fmt.lowerBound + 2..<fmt.lowerBound + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            })
        let rate = Int(
            raw[fmt.lowerBound + 4..<fmt.lowerBound + 8].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            })
        let bits = Int(
            raw[fmt.lowerBound + 14..<fmt.lowerBound + 16].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            })
        let data = try #require(chunk("data"))
        return (rate, channels, bits, UInt64(hi) << 32 | UInt64(lo), Data(raw[data]))
    }

    @Test(
        "Audio: 24-in-32 aligned-high mono becomes packed 24-bit BWF with a TimeReference from the host clock"
    )
    func alignedHigh() async throws {
        let url = temp("mic.wav")
        let clock = HostClock.shared
        let writer = AudioWriter(url: url, clock: clock)
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 24,
            mReserved: 0)
        // Sample value 0x123456 aligned high in 32 bits, little-endian: 00 56 34 12.
        var bytes: [UInt8] = []
        for _ in 0..<480 { bytes += [0x00, 0x56, 0x34, 0x12] }
        let start = clock.nowHostSeconds
        for i in 0..<100 {
            writer.handle(try audio(bytes, asbd: asbd, frames: 480, pts: start + Double(i) * 0.01))
        }
        #expect(await writer.finish() == nil)
        #expect(writer.framesWritten == 48000)
        let wav = try readWav(url)
        #expect(wav.rate == 48000 && wav.channels == 1 && wav.bits == 24)
        #expect(wav.data.count == 48000 * 3)
        #expect(Array(wav.data.prefix(3)) == [0x56, 0x34, 0x12])
        let expected = UInt64(
            (HostClock.secondsSinceMidnight(clock.date(forHostSeconds: start)) * 48000).rounded())
        #expect(wav.timeReference == expected)
        #expect(writer.bwfTimeReference == Int(expected))
        #expect(try await AVURLAsset(url: url).load(.duration).seconds == 1.0)
    }

    @Test("Audio: Float32 stereo from the system tap is converted and clipped")
    func float() async throws {
        let url = temp("tap.wav")
        let writer = AudioWriter(url: url)
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var bytes: [UInt8] = []
        for f in [Float32(0.5), Float32(-1.5), Float32(0), Float32(1)] {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { bytes += $0 }
        }
        writer.handle(try audio(bytes, asbd: asbd, frames: 2, pts: HostClock.shared.nowHostSeconds))
        #expect(await writer.finish() == nil)
        let wav = try readWav(url)
        #expect(wav.channels == 2 && wav.data.count == 12)
        func sample(_ i: Int) -> Int32 {
            let b = Array(wav.data[i * 3..<i * 3 + 3])
            let v = Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16
            return v >= 0x800000 ? v - 0x1000000 : v
        }
        #expect(sample(0) == 4_194_304)  // 0.5
        #expect(sample(1) == -8_388_607)  // -1.5 clipped
        #expect(sample(2) == 0)
        #expect(sample(3) == 8_388_607)
    }

    @Test("Audio: sampleLevelDb dispatches through `any Writer` (not the nil default)")
    func levelThroughProtocol() async throws {
        let url = temp("level.wav")
        let writer: any Writer = AudioWriter(url: url)
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 24, mReserved: 0)
        var bytes: [UInt8] = []
        for _ in 0..<480 { bytes += [0x00, 0x00, 0x00, 0x40] }  // ~0.5 FS
        writer.handle(
            try audio(bytes, asbd: asbd, frames: 480, pts: HostClock.shared.nowHostSeconds))
        let level = writer.sampleLevelDb()
        #expect(level != nil, "held as `any Writer`, the audio level must not be the nil default")
        #expect((level ?? -200) > -12 && (level ?? 0) < 0, "about -6 dBFS")
        _ = await writer.finish()
    }

    @Test("Audio: an unsupported format is refused with a reason")
    func unsupported() async throws {
        let writer = AudioWriter(url: temp("bad.wav"))
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian,
            mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        writer.handle(try audio([0, 0, 0, 0], asbd: asbd, frames: 2, pts: 1))
        #expect(await writer.finish()?.hasPrefix("unsupported audio format") == true)
    }
}
