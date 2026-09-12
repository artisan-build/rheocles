// Spike S3 — time-of-day timecode in a MOV, matching TimeReference in a BWF.
//
//   s3 record --seconds N --out-dir DIR [--mic name] [--fps 30] [--beep-at 3] [--audio-delay 0]
//
// --audio-delay starts the microphone that many seconds after the first video
// frame, so the two files carry different start stamps and an NLE's
// sync-by-timecode has a real offset to get right (a late join, §6).
//
// Writes, from one process and one host clock:
//
//   DIR/video.mov   1920x1080 HEVC, generated frames with the host
//                   time-of-day burned in, plus a `tmcd` track stamped with
//                   the time-of-day frame number of the first frame
//                   (AVAssetWriter, movieFragmentInterval 1 s, per S2).
//   DIR/audio.wav   Broadcast Wave from the microphone, 48 kHz 24-bit mono,
//                   `bext` TimeReference = samples since local midnight at
//                   the first captured sample.
//
// At --beep-at seconds (rounded up to the next whole second of host time) the
// frames flash white for 200 ms and a 1 kHz tone plays through the default
// output. With a mic in front of the speakers, the flash and the tone are one
// event seen by two files: after a sync-by-timecode in an NLE they should sit
// on the same frame, and `analyze.sh` measures the same thing from the files.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.endIndex else { return nil }
    return args[i + 1]
}

// MARK: - Host clock

/// Host-time (mach) → wall-clock. Sample buffers carry host-time PTS; the
/// offset lets a PTS be turned into a Date more precisely than reading
/// Date() inside a callback that ran some milliseconds after the sample.
let hostClockOffset: TimeInterval = {
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let wall = Date().timeIntervalSince1970
    return wall - host
}()

func wallDate(hostSeconds: Double) -> Date {
    Date(timeIntervalSince1970: hostSeconds + hostClockOffset)
}

/// Seconds since local midnight, with fraction.
func secondsSinceMidnight(_ date: Date) -> Double {
    let cal = Calendar.current
    let midnight = cal.startOfDay(for: date)
    return date.timeIntervalSince(midnight)
}

func timecodeString(frames: Int, fps: Int) -> String {
    let s = frames / fps
    return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, frames % fps)
}

// MARK: - Video with tmcd

final class VideoWriter {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let timecode: AVAssetWriterInput
    let tcFormat: CMTimeCodeFormatDescription
    let fps: Int
    let width = 1920, height = 1080
    var started = false
    var frames = 0
    var startTC = 0
    var startHost = 0.0
    var lastTCSampleFrame = 0

    init(url: URL, fps: Int) throws {
        self.fps = fps
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])

        // 30 fps non-drop, 24-hour wrap: what a camera writes. The frame
        // number in each sample is frames since midnight.
        var desc: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameQuanta: UInt32(fps),
            flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { throw NSError(domain: "s3", code: Int(status)) }
        tcFormat = desc
        timecode = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: desc)
        timecode.expectsMediaDataInRealTime = true

        writer.add(video)
        writer.add(timecode)
        video.addTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "s3", code: 2) }
    }

    /// One timecode sample covering [fromFrame, toFrame) of this recording.
    func appendTimecode(fromFrame: Int, toFrame: Int) {
        guard toFrame > fromFrame, timecode.isReadyForMoreMediaData else { return }
        var value = UInt32(startTC + fromFrame).bigEndian
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        withUnsafeBytes(of: &value) { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(toFrame - fromFrame), timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMTime(value: CMTimeValue(fromFrame), timescale: CMTimeScale(fps)),
            decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: tcFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        if let sample { _ = timecode.append(sample) }
        lastTCSampleFrame = toFrame
    }

    /// Draw and append one frame for host time `host`. Returns the frame's timecode.
    func appendFrame(host: Double, flash: Bool) -> String {
        if !started {
            started = true
            startHost = host
            let tod = secondsSinceMidnight(wallDate(hostSeconds: host))
            startTC = Int((tod * Double(fps)).rounded(.down))
            writer.startSession(atSourceTime: .zero)
            log("video first frame: host tod=\(String(format: "%.3f", tod))s -> start timecode \(timecodeString(frames: startTC, fps: fps)) (frame \(startTC))")
        }
        let pts = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps))
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return "" }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return "" }
        let tc = timecodeString(frames: startTC + frames, fps: fps)
        let wall = wallDate(hostSeconds: host)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        draw(pb, lines: ["host \(f.string(from: wall))", "tc   \(tc)", "frame \(frames)"], flash: flash, frame: frames)
        adaptor.append(pb, withPresentationTime: pts)
        frames += 1
        if frames % fps == 0 { appendTimecode(fromFrame: lastTCSampleFrame, toFrame: frames) }
        return tc
    }

    func draw(_ pb: CVPixelBuffer, lines: [String], flash: Bool, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(flash ? CGColor(gray: 1, alpha: 1) : CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A bar that sweeps once a second, so motion (and a dropped frame) is visible.
        let x = CGFloat(frame % fps) / CGFloat(fps) * CGFloat(width - 40)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: x, y: 80, width: 40, height: 120))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 110, nil)
        for (i, line) in lines.enumerated() {
            let attr = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: flash ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 0.95, alpha: 1),
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 100, y: CGFloat(height - 260 - i * 150))
            CTLineDraw(ctLine, ctx)
        }
    }

    func finish() {
        if frames > lastTCSampleFrame { appendTimecode(fromFrame: lastTCSampleFrame, toFrame: frames) }
        video.markAsFinished()
        timecode.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        log("video finished status=\(writer.status.rawValue) (2 completed, 3 failed) error=\(writer.error.map { "\($0)" } ?? "none") frames=\(frames) startTC=\(timecodeString(frames: startTC, fps: fps))")
    }
}

// MARK: - Broadcast Wave

/// WAV with a `bext` chunk (EBU Tech 3285 v1), 48 kHz 24-bit mono PCM.
/// Sizes are patched every second so a killed process still leaves a
/// readable header.
final class BWFWriter {
    let handle: FileHandle
    let sampleRate = 48000
    let channels = 1
    let bits = 24
    var dataBytes = 0
    var started = false
    var timeReference: UInt64 = 0
    var headerSize = 0
    var lastPatch = Date()
    let url: URL

    init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    static func fixed(_ s: String, _ n: Int) -> Data {
        var d = Data(s.utf8.prefix(n))
        d.append(Data(repeating: 0, count: n - d.count))
        return d
    }

    func start(firstSampleDate: Date) {
        started = true
        let tod = secondsSinceMidnight(firstSampleDate)
        timeReference = UInt64((tod * Double(sampleRate)).rounded())
        log("audio first sample: tod=\(String(format: "%.3f", tod))s -> bext TimeReference \(timeReference) samples (= \(timecodeString(frames: Int(tod * 30), fps: 30)) at 30 fps)")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        var bext = Data()
        bext.append(Self.fixed("Rheocles S3 spike", 256))       // Description
        bext.append(Self.fixed("Rheocles", 32))                  // Originator
        bext.append(Self.fixed(UUID().uuidString, 32))           // OriginatorReference
        bext.append(Self.fixed(f.string(from: firstSampleDate), 10))
        bext.append(Self.fixed(t.string(from: firstSampleDate), 8))
        var lo = UInt32(timeReference & 0xffff_ffff).littleEndian
        var hi = UInt32(timeReference >> 32).littleEndian
        bext.append(Data(bytes: &lo, count: 4))
        bext.append(Data(bytes: &hi, count: 4))
        var version = UInt16(1).littleEndian
        bext.append(Data(bytes: &version, count: 2))
        bext.append(Data(repeating: 0, count: 64))               // UMID
        bext.append(Data(repeating: 0, count: 10))               // loudness fields
        bext.append(Data(repeating: 0, count: 180))              // Reserved
        let history = "A=PCM,F=48000,W=24,M=mono,T=Rheocles S3\r\n"
        bext.append(Data(history.utf8))
        if bext.count % 2 == 1 { bext.append(0) }

        var header = Data()
        header.append(Data("RIFF".utf8))
        header.append(contentsOf: [0, 0, 0, 0])                  // patched
        header.append(Data("WAVE".utf8))
        header.append(Data("bext".utf8))
        var bextSize = UInt32(bext.count).littleEndian
        header.append(Data(bytes: &bextSize, count: 4))
        header.append(bext)
        header.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        header.append(Data(bytes: &fmtSize, count: 4))
        var fmt = Data()
        var tag = UInt16(1).littleEndian, ch = UInt16(channels).littleEndian
        var rate = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * channels * bits / 8).littleEndian
        var align = UInt16(channels * bits / 8).littleEndian, bps = UInt16(bits).littleEndian
        fmt.append(Data(bytes: &tag, count: 2)); fmt.append(Data(bytes: &ch, count: 2))
        fmt.append(Data(bytes: &rate, count: 4)); fmt.append(Data(bytes: &byteRate, count: 4))
        fmt.append(Data(bytes: &align, count: 2)); fmt.append(Data(bytes: &bps, count: 2))
        header.append(fmt)
        header.append(Data("data".utf8))
        header.append(contentsOf: [0, 0, 0, 0])                  // patched
        headerSize = header.count
        handle.write(header)
    }

    func append(_ pcm: Data) {
        handle.write(pcm)
        dataBytes += pcm.count
        if Date().timeIntervalSince(lastPatch) > 1 { patchSizes() }
    }

    func patchSizes() {
        lastPatch = Date()
        var riff = UInt32(headerSize - 8 + dataBytes).littleEndian
        var data = UInt32(dataBytes).littleEndian
        handle.seek(toFileOffset: 4)
        handle.write(Data(bytes: &riff, count: 4))
        handle.seek(toFileOffset: UInt64(headerSize - 4))
        handle.write(Data(bytes: &data, count: 4))
        handle.seekToEndOfFile()
    }

    func finish() {
        patchSizes()
        try? handle.close()
        log("audio finished: \(dataBytes) bytes = \(String(format: "%.3f", Double(dataBytes / (channels * bits / 8)) / Double(sampleRate)))s, TimeReference=\(timeReference)")
    }
}

/// Microphone → 48 kHz 24-bit LPCM sample buffers → BWFWriter.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let bwf: BWFWriter
    let lock = NSLock()
    var buffers = 0
    /// Bytes per frame as delivered. AVCaptureAudioDataOutput honours the
    /// 24-bit request as 24 bits *aligned high in 32-bit containers*
    /// (flags 0x14: signed integer + aligned high, not packed), so the top
    /// three bytes of each little-endian Int32 are the packed sample.
    var bytesPerFrame = 3

    init(deviceMatch: String?, bwf: BWFWriter) throws {
        self.bwf = bwf
        super.init()
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        for d in devices { log("mic: \(d.localizedName) | model=\(d.modelID) | id=\(d.uniqueID)") }
        let device = deviceMatch.flatMap { m in devices.first { $0.localizedName.localizedCaseInsensitiveContains(m) } }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw NSError(domain: "s3", code: 3, userInfo: [NSLocalizedDescriptionKey: "no audio device"]) }
        log("using mic: \(device.localizedName)")
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "s3.audio"))
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); defer { lock.unlock() }
        if !bwf.started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                log("audio format: \(asbd.pointee.mSampleRate) Hz, \(asbd.pointee.mChannelsPerFrame) ch, \(asbd.pointee.mBitsPerChannel) bit, \(bytesPerFrame) bytes/frame, flags 0x\(String(asbd.pointee.mFormatFlags, radix: 16))")
            }
            bwf.start(firstSampleDate: wallDate(hostSeconds: pts))
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr else { return }
        if bytesPerFrame == 4 {
            var packed = Data(capacity: length / 4 * 3)
            ptr.withMemoryRebound(to: UInt8.self, capacity: length) { b in
                var i = 0
                while i + 4 <= length {
                    packed.append(b[i + 1]); packed.append(b[i + 2]); packed.append(b[i + 3])
                    i += 4
                }
            }
            bwf.append(packed)
        } else {
            bwf.append(Data(bytes: ptr, count: length))
        }
        buffers += 1
    }
}

// MARK: - Beep

/// A 200 ms 1 kHz tone as a WAV on disk, played through the default output
/// with AVAudioPlayer.play(atTime:) for a scheduled start.
func makeBeep(url: URL) throws -> AVAudioPlayer {
    let rate = 48000, n = rate / 5
    var pcm = Data(capacity: n * 2)
    for i in 0..<n {
        let env = min(1.0, Double(min(i, n - i)) / 200.0)  // 4 ms ramps
        var v = Int16(sin(Double(i) / Double(rate) * 2 * .pi * 1000) * 32000 * env).littleEndian
        pcm.append(Data(bytes: &v, count: 2))
    }
    var d = Data("RIFF".utf8)
    var riff = UInt32(36 + pcm.count).littleEndian
    d.append(Data(bytes: &riff, count: 4)); d.append(Data("WAVEfmt ".utf8))
    var fmtSize = UInt32(16).littleEndian, tag = UInt16(1).littleEndian, ch = UInt16(1).littleEndian
    var r = UInt32(rate).littleEndian, br = UInt32(rate * 2).littleEndian, al = UInt16(2).littleEndian, bps = UInt16(16).littleEndian
    d.append(Data(bytes: &fmtSize, count: 4)); d.append(Data(bytes: &tag, count: 2)); d.append(Data(bytes: &ch, count: 2))
    d.append(Data(bytes: &r, count: 4)); d.append(Data(bytes: &br, count: 4)); d.append(Data(bytes: &al, count: 2)); d.append(Data(bytes: &bps, count: 2))
    d.append(Data("data".utf8))
    var ds = UInt32(pcm.count).littleEndian
    d.append(Data(bytes: &ds, count: 4)); d.append(pcm)
    try d.write(to: url)
    let p = try AVAudioPlayer(contentsOf: url)
    p.prepareToPlay()
    return p
}

// MARK: - Main

switch args.first {
case "record":
    let seconds = Double(opt("--seconds") ?? "15") ?? 15
    let fps = Int(opt("--fps") ?? "30") ?? 30
    let beepAt = Double(opt("--beep-at") ?? "3") ?? 3
    let dir = URL(fileURLWithPath: opt("--out-dir") ?? "out")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    log("pid \(ProcessInfo.processInfo.processIdentifier) out=\(dir.path) seconds=\(seconds) fps=\(fps) bundle=\(Bundle.main.bundleIdentifier ?? "none")")
    log("mic authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("mic access granted: \(ok)"); sem.signal() }
        sem.wait()
    }

    let bwf = try BWFWriter(url: dir.appendingPathComponent("audio.wav"))
    let mic = try MicCapture(deviceMatch: opt("--mic"), bwf: bwf)
    let video = try VideoWriter(url: dir.appendingPathComponent("video.mov"), fps: fps)
    let beep = try makeBeep(url: dir.appendingPathComponent("beep.wav"))

    let audioDelay = Double(opt("--audio-delay") ?? "0") ?? 0
    if audioDelay == 0 {
        mic.session.startRunning()
        log("mic session running=\(mic.session.isRunning)")
    }

    // Frames on a strict 1/fps cadence from host time. The flash covers the
    // whole host-clock second boundary at `beepAt` (rounded up), so its first
    // frame is the :00 frame of that second in time-of-day timecode.
    let t0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let wall0 = wallDate(hostSeconds: t0)
    let flashWall = ceil(wall0.timeIntervalSince1970 + beepAt)
    let flashHost = flashWall - hostClockOffset
    log("flash+beep scheduled for host tod \(String(format: "%.3f", secondsSinceMidnight(Date(timeIntervalSince1970: flashWall))))s = \(timecodeString(frames: Int(secondsSinceMidnight(Date(timeIntervalSince1970: flashWall)) * Double(fps)), fps: fps))")
    var beepScheduled = false
    var frameIndex = 0
    let frameDur = 1.0 / Double(fps)
    var flashTC = ""
    while true {
        let target = t0 + Double(frameIndex) * frameDur
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if target > now { Thread.sleep(forTimeInterval: target - now) }
        if target - t0 >= seconds { break }
        let flash = target >= flashHost && target < flashHost + 0.2
        let tc = video.appendFrame(host: target, flash: flash)
        if flash && flashTC.isEmpty { flashTC = tc; log("first flash frame at tc \(tc) (frame \(frameIndex))") }
        if !beepScheduled && flashHost - now < 1.0 {
            beepScheduled = true
            let delta = flashHost - CMClockGetTime(CMClockGetHostTimeClock()).seconds
            beep.play(atTime: beep.deviceCurrentTime + delta)
            log("beep scheduled in \(String(format: "%.3f", delta))s via AVAudioPlayer.play(atTime:)")
        }
        if audioDelay > 0 && !mic.session.isRunning && target - t0 >= audioDelay {
            mic.session.startRunning()
            log("mic session started late by design: running=\(mic.session.isRunning) at video frame \(frameIndex)")
        }
        if frameIndex % fps == 0 { log("t=\(frameIndex / fps) frames=\(video.frames) audioBuffers=\(mic.buffers) audioBytes=\(bwf.dataBytes)") }
        frameIndex += 1
    }
    mic.session.stopRunning()
    video.finish()
    bwf.finish()
    log("done")

default:
    print("usage: s3 record --seconds N --out-dir DIR [--mic name] [--fps 30] [--beep-at 3]")
    exit(1)
}
