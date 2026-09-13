import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import RheoclesCore

/// A catalog of two video streams, for the ≤1-video combine rule.
struct TwoVideos: StreamSource {
    func streams() async -> [StreamInfo] {
        [
            StreamInfo(
                id: "display:a", kind: .display, name: "Display A", model: "Test",
                capabilities: .init(video: .init(width: 320, height: 240, maxFrameRate: 30))),
            StreamInfo(
                id: "display:b", kind: .display, name: "Display B", model: "Test",
                capabilities: .init(video: .init(width: 320, height: 240, maxFrameRate: 30))),
        ]
    }
}

@Suite("Reveal path resolution")
struct RevealTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheo-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("An empty or nil path resolves to the base folder itself")
    func base() throws {
        let dir = try tempDir()
        #expect(Reveal.resolve(nil, under: dir) == dir)
        #expect(Reveal.resolve("", under: dir) == dir)
        #expect(Reveal.resolve("  ", under: dir) == dir)
    }

    @Test("A relative path to an existing file resolves within the base")
    func within() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("combined.mov")
        try Data("x".utf8).write(to: file)
        #expect(Reveal.resolve("combined.mov", under: dir) == file)
        // A leading slash reads as an absolute path and is refused.
        #expect(Reveal.resolve("/combined.mov", under: dir) == nil)
    }

    @Test("Absolute paths, .. traversal and missing files are refused")
    func refused() throws {
        let dir = try tempDir()
        #expect(Reveal.resolve("/etc/passwd", under: dir) == nil)
        #expect(Reveal.resolve("../secret", under: dir) == nil)
        #expect(Reveal.resolve("sub/../../secret", under: dir) == nil)
        #expect(Reveal.resolve("does-not-exist.mov", under: dir) == nil)
    }

    @Test("A subfolder that exists resolves; one that does not is refused")
    func subfolder() throws {
        let dir = try tempDir()
        let sub = dir.appendingPathComponent("takes/2026-09-11", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(Reveal.resolve("takes/2026-09-11", under: dir) == sub)
        #expect(Reveal.resolve("takes/nope", under: dir) == nil)
    }
}

@Suite("Combine")
struct CombineTests {
    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var manifests: [Manifest] = []
        func record(_ m: Manifest) { lock.withLock { manifests.append(m) } }
        func combinedStates(for id: String) -> [Manifest.Combined.State] {
            lock.withLock { manifests.filter { $0.id == id }.compactMap { $0.combined?.state } }
        }
    }

    struct World {
        let root: URL
        let registry: Registry
        let engine: TakeEngine
        let events: Events
    }

    private func world(catalog: any StreamSource) throws -> World {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheo-combine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = Registry(catalog: catalog, factory: FakeFactory())
        let events = Events()
        let engine = TakeEngine(
            registry: registry, outputRoot: { root }, writerFactory: FakeWriterFactory(),
            machine: .init(hostname: "test.local", machineId: "TEST"),
            freeBytes: { _ in 1 << 40 }
        ) { events.record($0) }
        return World(root: root, registry: registry, engine: engine, events: events)
    }

    // MARK: Validation and manifest state

    @Test("A combine take with two video streams is refused with combine_requires_single_video")
    func twoVideosRefused() async throws {
        let w = try world(catalog: TwoVideos())
        try await w.registry.arm("display:a")
        try await w.registry.arm("display:b")
        do {
            _ = try await w.engine.create(.init(combine: true))
            Issue.record("expected the two-video combine take to be refused")
        } catch let error as APIError {
            #expect(error.status == 400 && error.code == "combine_requires_single_video")
        }
    }

    @Test("One video plus audio is allowed and the manifest carries combined pending")
    func pendingOnCreate() async throws {
        let w = try world(catalog: TwoStreams())  // camera:fake + microphone:fake
        try await w.registry.arm("camera:fake")
        try await w.registry.arm("microphone:fake")
        let created = try await w.engine.create(.init(combine: true))
        #expect(created.take.combined?.state == .pending)
        #expect(created.take.combined?.path == "combined.mov")
    }

    @Test("Without combine the manifest has no combined block")
    func absentByDefault() async throws {
        let w = try world(catalog: TwoStreams())
        try await w.registry.arm("microphone:fake")
        let created = try await w.engine.create(.init())
        #expect(created.take.combined == nil)
    }

    @Test("combine after the fact on a take with no files is nothing_to_combine")
    func nothingToCombine() async throws {
        let w = try world(catalog: TwoStreams())
        try await w.registry.arm("microphone:fake")
        let created = try await w.engine.create(.init())  // FakeWriter writes nothing
        _ = try await w.engine.start(created.take.id)
        _ = try await w.engine.stop(created.take.id)
        do {
            _ = try await w.engine.combine(created.take.id)
            Issue.record("expected nothing_to_combine")
        } catch let error as APIError {
            #expect(error.status == 400 && error.code == "nothing_to_combine")
        }
    }

    // MARK: The real thing — a passthrough mux of real media

    @Test("A real video plus two audio files mux to a three-track combined.mov, tmcd kept")
    func realFileMux() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheo-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seconds = 1.0
        try SyntheticMedia.writeVideo(
            to: dir.appendingPathComponent("screen.mov"), seconds: seconds, fps: 30)
        try SyntheticMedia.writeWav(
            to: dir.appendingPathComponent("mic-a.wav"), seconds: seconds, sampleRate: 48000)
        try SyntheticMedia.writeWav(
            to: dir.appendingPathComponent("mic-b.wav"), seconds: seconds, sampleRate: 48000)

        let combined = await Combiner.combine(
            in: dir, videoPath: "screen.mov", audioPaths: ["mic-a.wav", "mic-b.wav"])
        #expect(combined.state == .complete, "combine failed: \(combined.reason ?? "")")

        let output = dir.appendingPathComponent("combined.mov")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let timecode = try await asset.loadTracks(withMediaType: .timecode)
        #expect(video.count == 1, "expected one video track, got \(video.count)")
        #expect(audio.count == 2, "expected two audio tracks, got \(audio.count)")
        #expect(timecode.count == 1, "tmcd not preserved; got \(timecode.count) timecode tracks")

        // Durations are equal to the source, to a frame or two.
        let total = try await asset.load(.duration).seconds
        #expect(abs(total - seconds) < 0.2, "combined duration \(total) not ~\(seconds)")
        for track in video + audio {
            let d = try await track.load(.timeRange).duration.seconds
            #expect(
                abs(d - seconds) < 0.2, "track \(track.mediaType) duration \(d) not ~\(seconds)")
        }
    }
}

/// Small synthetic-media generators for the real-file combine test: a video
/// with a time-of-day-style `tmcd` track (AVAssetWriter, as the real writer
/// makes) and a plain LPCM WAV (as the real audio writer makes).
enum SyntheticMedia {
    static func writeVideo(to url: URL, seconds: Double, fps: Int32) throws {
        try? FileManager.default.removeItem(at: url)
        let width = 320, height = 240
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        var tc: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: fps), frameQuanta: UInt32(fps),
            flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &tc)
        guard status == noErr, let tc else {
            throw NSError(domain: "synthetic", code: Int(status))
        }
        let timecode = AVAssetWriterInput(
            mediaType: .timecode, outputSettings: nil, sourceFormatHint: tc)
        timecode.expectsMediaDataInRealTime = false

        writer.add(video)
        writer.add(timecode)
        video.addTrackAssociation(
            withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "synthetic", code: -1)
        }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        // One timecode sample covering the whole clip, starting at frame 0.
        appendTimecode(timecode, format: tc, fps: fps, spanFrames: frames)
        for i in 0..<frames {
            while !video.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(
                pixelBuffer(width: width, height: height),
                withPresentationTime: CMTime(value: Int64(i), timescale: fps))
        }
        video.markAsFinished()
        timecode.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw writer.error ?? NSError(domain: "synthetic", code: -2) }
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func appendTimecode(
        _ input: AVAssetWriterInput, format: CMTimeCodeFormatDescription, fps: Int32,
        spanFrames: Int
    ) {
        var value = UInt32(0).bigEndian
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0,
                blockBufferOut: &block) == noErr, let block
        else { return }
        withUnsafeBytes(of: &value) { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(spanFrames), timescale: fps),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr, let sample
        else { return }
        input.append(sample)
    }

    static func writeWav(to url: URL, seconds: Double, sampleRate: Int) throws {
        let channels = 1, bits = 16
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * channels * bits / 8
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8))
        le32(UInt32(36 + dataBytes))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8))
        le32(16)  // PCM chunk size
        le16(1)  // PCM
        le16(UInt16(channels))
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * channels * bits / 8))  // byte rate
        le16(UInt16(channels * bits / 8))  // block align
        le16(UInt16(bits))
        d.append(Data("data".utf8))
        le32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))  // silence
        try d.write(to: url)
    }
}
