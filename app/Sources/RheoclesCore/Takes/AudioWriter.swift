import AVFoundation
import CoreMedia
import Foundation

/// One audio stream to one Broadcast Wave file: 24-bit LPCM with a `bext`
/// chunk whose `TimeReference` is samples since local midnight at the first
/// captured sample (S3). Sizes are patched every second so a killed take
/// still leaves a readable file.
///
/// Input formats seen in the wild and handled here: 24-in-32 aligned high
/// from `AVCaptureAudioDataOutput`, packed 24, and Float32 from the system
/// audio tap. Anything else is refused with an error in the manifest.
///
/// `@unchecked Sendable`: every mutable member is touched under `lock`.
public final class AudioWriter: Writer, @unchecked Sendable {
    public let url: URL
    private let clock: HostClock
    private let lock = NSLock()
    private var handle: FileHandle?
    private var sampleRate = 48000.0
    private var channels = 1
    private var headerSize = 0
    private var dataBytes = 0
    private var samplesWritten = 0
    private var timeReference: UInt64 = 0
    private var firstDate: Date?
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var lastPatch = Date.distantPast
    private var peak: Int32 = 0
    private var failure: String?
    private var finished = false

    public init(url: URL, clock: HostClock = .shared) {
        self.url = url
        self.clock = clock
    }

    /// Time-of-day of the first sample as 30 fps timecode. The sample-exact
    /// value is the BWF `TimeReference`, reported alongside.
    public var timecode: String? {
        lock.withLock {
            firstDate.map {
                HostClock.timecode(frames: HostClock.frames(sinceMidnightOf: $0, fps: 30), fps: 30)
            }
        }
    }

    /// Samples since local midnight at the first sample, at the file's rate.
    public var bwfTimeReference: Int? {
        lock.withLock { firstDate == nil ? nil : Int(timeReference) }
    }

    public var framesWritten: Int { lock.withLock { samplesWritten } }
    public var framesDropped: Int { 0 }

    /// Samples ÷ rate versus the host time they span: the audio clock's
    /// drift against the host, in seconds. Positive means the file runs
    /// long.
    public var drift: Double? {
        lock.withLock {
            guard let first = firstPTS, let last = lastPTS, samplesWritten > 0, last > first else {
                return nil
            }
            return ((Double(samplesWritten) / sampleRate - (last - first)) * 1000).rounded() / 1000
        }
    }

    public func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, failure == nil else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if handle == nil {
            do {
                try open(asbd: asbd, firstPTS: pts)
            } catch {
                failure = "could not start writing: \(error)"
                return
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &pointer) == noErr,
            let pointer, length > 0
        else { return }
        let packed = Self.pack(UnsafeRawBufferPointer(start: pointer, count: length), asbd: asbd)
        guard let packed else {
            failure =
                "unsupported audio format: \(asbd.mBitsPerChannel)-bit, flags 0x\(String(asbd.mFormatFlags, radix: 16))"
            return
        }
        do {
            try handle?.write(contentsOf: packed)
        } catch {
            failure = "write failed: \(error)"
            return
        }
        dataBytes += packed.count
        let frameCount = packed.count / (3 * channels)
        samplesWritten += frameCount
        updatePeak(packed)
        lastPTS = pts + Double(frameCount) / sampleRate
        if Date().timeIntervalSince(lastPatch) > 1 { patchSizes() }
    }

    /// 24-bit little-endian packed frames from whatever arrived.
    ///
    /// Internal so the preview sampler can reuse it — a hand-rolled copy got
    /// the Scarlett's 24-in-32 alignment wrong and read peak as full scale.
    static func pack(_ bytes: UnsafeRawBufferPointer, asbd: AudioStreamBasicDescription) -> Data? {
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard !isBigEndian, !nonInterleaved else { return nil }
        let bytesPerSample = Int(asbd.mBytesPerFrame) / Int(max(asbd.mChannelsPerFrame, 1))
        var out = Data(capacity: bytes.count / bytesPerSample * 3)
        func append24(_ v: Int32) {
            let c = max(-8_388_608, min(8_388_607, v))
            out.append(UInt8(truncatingIfNeeded: c))
            out.append(UInt8(truncatingIfNeeded: c >> 8))
            out.append(UInt8(truncatingIfNeeded: c >> 16))
        }
        switch (isFloat, bytesPerSample, Int(asbd.mBitsPerChannel)) {
        case (true, 4, 32):
            for i in stride(from: 0, to: bytes.count - 3, by: 4) {
                let f = bytes.loadUnaligned(fromByteOffset: i, as: Float32.self)
                append24(Int32((max(-1, min(1, f)) * 8_388_607).rounded()))
            }
        case (false, 4, 24), (false, 4, 32):
            // 24 aligned high in 32, or full 32-bit: the top three bytes either way.
            for i in stride(from: 0, to: bytes.count - 3, by: 4) {
                out.append(bytes[i + 1])
                out.append(bytes[i + 2])
                out.append(bytes[i + 3])
            }
        case (false, 3, 24):
            out.append(contentsOf: bytes)
        case (false, 2, 16):
            for i in stride(from: 0, to: bytes.count - 1, by: 2) {
                out.append(0)
                out.append(bytes[i])
                out.append(bytes[i + 1])
            }
        default:
            return nil
        }
        return out
    }

    private func open(asbd: AudioStreamBasicDescription, firstPTS pts: Double) throws {
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        let first = clock.date(forHostSeconds: pts)
        firstDate = first
        firstPTS = pts
        timeReference = UInt64((HostClock.secondsSinceMidnight(first) * sampleRate).rounded())

        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(
                domain: "rheocles.writer", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
        }
        let handle = try FileHandle(forWritingTo: url)
        let header = Self.header(
            sampleRate: Int(sampleRate), channels: channels, timeReference: timeReference,
            date: first)
        try handle.write(contentsOf: header)
        headerSize = header.count
        self.handle = handle
        lastPatch = Date()
    }

    static func fixed(_ s: String, _ n: Int) -> Data {
        var d = Data(s.utf8.prefix(n))
        d.append(Data(repeating: 0, count: n - d.count))
        return d
    }

    /// RIFF/WAVE with `bext` (EBU Tech 3285 v1), `fmt ` and an empty `data`
    /// chunk; the two sizes are patched as the file grows.
    static func header(sampleRate: Int, channels: Int, timeReference: UInt64, date: Date) -> Data {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var bext = Data()
        bext.append(fixed("Rheocles \(Rheocles.version)", 256))
        bext.append(fixed("Rheocles", 32))
        bext.append(fixed(UUID().uuidString, 32))
        bext.append(fixed(day.string(from: date), 10))
        bext.append(fixed(time.string(from: date), 8))
        var lo = UInt32(timeReference & 0xffff_ffff).littleEndian
        var hi = UInt32(timeReference >> 32).littleEndian
        bext.append(Data(bytes: &lo, count: 4))
        bext.append(Data(bytes: &hi, count: 4))
        var version = UInt16(1).littleEndian
        bext.append(Data(bytes: &version, count: 2))
        bext.append(Data(repeating: 0, count: 64))  // UMID
        bext.append(Data(repeating: 0, count: 10))  // loudness
        bext.append(Data(repeating: 0, count: 180))  // reserved
        bext.append(
            Data(
                "A=PCM,F=\(sampleRate),W=24,M=\(channels == 1 ? "mono" : "stereo"),T=Rheocles\r\n"
                    .utf8))
        if bext.count % 2 == 1 { bext.append(0) }

        var header = Data("RIFF".utf8)
        header.append(contentsOf: [0, 0, 0, 0])
        header.append(Data("WAVE".utf8))
        header.append(Data("bext".utf8))
        var bextSize = UInt32(bext.count).littleEndian
        header.append(Data(bytes: &bextSize, count: 4))
        header.append(bext)
        header.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        header.append(Data(bytes: &fmtSize, count: 4))
        var tag = UInt16(1).littleEndian
        var ch = UInt16(channels).littleEndian
        var rate = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * channels * 3).littleEndian
        var align = UInt16(channels * 3).littleEndian
        var bits = UInt16(24).littleEndian
        header.append(Data(bytes: &tag, count: 2))
        header.append(Data(bytes: &ch, count: 2))
        header.append(Data(bytes: &rate, count: 4))
        header.append(Data(bytes: &byteRate, count: 4))
        header.append(Data(bytes: &align, count: 2))
        header.append(Data(bytes: &bits, count: 2))
        header.append(Data("data".utf8))
        header.append(contentsOf: [0, 0, 0, 0])
        return header
    }

    private func patchSizes() {
        guard let handle else { return }
        lastPatch = Date()
        var riff = UInt32(headerSize - 8 + dataBytes).littleEndian
        var data = UInt32(dataBytes).littleEndian
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Data(bytes: &riff, count: 4))
            try handle.seek(toOffset: UInt64(headerSize - 4))
            try handle.write(contentsOf: Data(bytes: &data, count: 4))
            try handle.seekToEnd()
        } catch {
            failure = "write failed: \(error)"
        }
    }

    /// Peak absolute sample in `packed` (24-bit LE), tracked for the meter.
    private func updatePeak(_ packed: Data) {
        packed.withUnsafeBytes { raw in
            var i = 0
            let n = raw.count
            while i + 3 <= n {
                let v = Int32(raw[i]) | Int32(raw[i + 1]) << 8 | Int32(raw[i + 2]) << 16
                let s = v >= 0x800000 ? v - 0x1000000 : v
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
                i += 3
            }
        }
    }

    public func sampleLevelDb() -> Double? {
        lock.withLock {
            guard firstDate != nil else { return nil }
            let p = peak
            peak = 0
            guard p > 0 else { return -120.0 }
            return (20 * log10(Double(p) / 8_388_607.0) * 10).rounded() / 10
        }
    }

    public func finish() async -> String? {
        lock.withLock {
            finished = true
            guard handle != nil else { return failure ?? "no audio arrived" }
            patchSizes()
            try? handle?.close()
            handle = nil
            if let failure { return failure }
            // 4 GB is the format's ceiling (spec §8); a file that got there
            // was truncated by the size fields wrapping, and must say so.
            if dataBytes >= 0xffff_ffff - headerSize { return "hit the 4 GB WAV limit" }
            return nil
        }
    }
}
