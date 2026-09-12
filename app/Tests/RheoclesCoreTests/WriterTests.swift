import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import RheoclesCore

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
@Suite("Writers")
struct WriterTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "rheocles-writer-\(UUID().uuidString)-\(name)")
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

    @Test(
        "Video: HEVC MOV with a tmcd track, one timecode sample per frame, timecode from the host clock"
    )
    func video() async throws {
        let url = temp("video.mov")
        let clock = HostClock.shared
        let writer = VideoWriter(url: url, codec: .hevc, frameRate: 30, clock: clock)
        let start = clock.nowHostSeconds
        // 2.5 s at 30 fps, paced: the input is real-time and drops what it
        // cannot take.
        for i in 0..<75 {
            writer.handle(
                try frame(width: 320, height: 240, pts: start + Double(i) / 30, shade: UInt8(i * 3))
            )
            try await Task.sleep(for: .milliseconds(33))
        }
        #expect(await writer.finish() == nil)
        // 75, plus the last frame re-appended at the stop time when the
        // paced loop ran long.
        #expect(writer.framesWritten == 75 || writer.framesWritten == 76)
        #expect(abs(writer.drift ?? 1) < 0.1)
        let expected = HostClock.timecode(
            frames: HostClock.frames(sinceMidnightOf: clock.date(forHostSeconds: start), fps: 30),
            fps: 30)
        #expect(writer.timecode == expected)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType).contains(.video))
        #expect(tracks.map(\.mediaType).contains(.timecode))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.5) < 0.3)
        let tc = try #require(tracks.first { $0.mediaType == .timecode })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tc, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [UInt32] = []
        while let sb = output.copyNextSampleBuffer() {
            // The reader hands out an empty marker buffer first; skip those.
            guard CMSampleBufferGetNumSamples(sb) > 0, let block = CMSampleBufferGetDataBuffer(sb)
            else {
                continue
            }
            var value: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value)
            samples.append(UInt32(bigEndian: value))
        }
        #expect(reader.status == .completed, "reader: \(reader.error.map { "\($0)" } ?? "ok")")
        #expect(samples.count == 75, "one timecode sample per frame")
        let startFrames = HostClock.frames(
            sinceMidnightOf: clock.date(forHostSeconds: start), fps: 30)
        #expect(samples.map { Int($0) } == (0..<75).map { startFrames + $0 })
    }

    @Test("Video: ProRes 422 is the alternative, same shape")
    func prores() async throws {
        let url = temp("prores.mov")
        let writer = VideoWriter(url: url, codec: .prores, frameRate: 30)
        let start = HostClock.shared.nowHostSeconds
        for i in 0..<15 {
            writer.handle(
                try frame(width: 320, height: 240, pts: start + Double(i) / 30, shade: 40))
            try await Task.sleep(for: .milliseconds(33))
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
