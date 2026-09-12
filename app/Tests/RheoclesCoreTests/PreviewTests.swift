import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import RheoclesCore

/// A session that pushes synthetic frames to its sink while running, so
/// preview has something to grab without a real device.
final class PushingSession: StreamSession, @unchecked Sendable {
    let info: StreamInfo
    var sink: (any FrameSink)?
    private var timer: DispatchSourceTimer?
    let deliversFrames: Bool

    init(_ info: StreamInfo, deliversFrames: Bool = true) {
        self.info = info
        self.deliversFrames = deliversFrames
    }

    var active: StreamInfo.Capabilities { info.capabilities }
    var framesSeen: Int { 0 }

    func start() async throws {
        guard deliversFrames else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "push"))
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self, let sink else { return }
            if info.capabilities.video != nil {
                if let f = Self.videoFrame(width: 320, height: 240) { sink.handle(f) }
            } else {
                if let a = Self.audioBuffer() { sink.handle(a) }
            }
        }
        t.resume()
        timer = t
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    static func videoFrame(width: Int, height: Int) -> CMSampleBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 120, CVPixelBufferGetBytesPerRow(pb) * height)
        CVPixelBufferUnlockBaseAddress(pb, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &sample)
        return sample
    }

    static func audioBuffer() -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 24, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var bytes = [UInt8]()
        for _ in 0..<480 { bytes += [0x00, 0x00, 0x00, 0x40] }  // ~0.5 FS aligned high
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
            blockBufferOut: &block)
        bytes.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                dataLength: bytes.count)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format, sampleCount: 480, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return sample
    }
}

struct PushingFactory: SessionFactory {
    var deliversFrames = true
    func makeSession(for stream: StreamInfo) throws -> any StreamSession {
        PushingSession(stream, deliversFrames: deliversFrames)
    }
}

@Suite("Preview")
struct PreviewTests {
    private let streams = ArmingTests.self  // reuse TwoStreams

    @Test("A video stream previews as a JPEG")
    func videoJPEG() async throws {
        let service = PreviewService(catalog: TwoStreams(), factory: PushingFactory())
        let result = try await service.preview("camera:fake")
        #expect(result.contentType == "image/jpeg")
        #expect(result.body.starts(with: [0xFF, 0xD8, 0xFF]), "JPEG magic")
        #expect(result.body.count > 100)
    }

    @Test("An audio stream previews as a JSON level")
    func audioLevel() async throws {
        let service = PreviewService(catalog: TwoStreams(), factory: PushingFactory())
        let result = try await service.preview("microphone:fake")
        #expect(result.contentType == "application/json")
        let level = try JSONDecoder().decode([String: Double].self, from: result.body)
        #expect(level["levelDb"] != nil)
        #expect((level["levelDb"] ?? 0) > -120, "the synthetic tone registers")
    }

    @Test("An unknown stream is 404")
    func unknown() async {
        let service = PreviewService(catalog: TwoStreams(), factory: PushingFactory())
        await #expect(throws: APIError.notFound("no such stream: nope")) {
            try await service.preview("nope")
        }
    }

    @Test("A video stream that delivers nothing is 503 no_frame")
    func noFrame() async {
        let service = PreviewService(
            catalog: TwoStreams(), factory: PushingFactory(deliversFrames: false))
        await #expect(throws: APIError.self) { try await service.preview("camera:fake") }
    }
}
