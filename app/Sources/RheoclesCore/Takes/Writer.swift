import CoreMedia
import Foundation

/// Writes one stream's frames to one file. Step 5 fills these in per kind;
/// the take engine only needs the shape.
public protocol Writer: FrameSink {
    /// The first frame's time-of-day timecode, once there is one.
    var timecode: String? { get }
    var framesWritten: Int { get }
    /// Frames the writer had to drop because the encoder was not ready. A
    /// count, not an error: a few under load is life, and the file's
    /// timeline is still right.
    var framesDropped: Int { get }
    /// Frames the source has handed the writer (written + dropped, excluding
    /// the writer's own CFR padding), for a true drop-rate and incoming rate.
    var framesDelivered: Int { get }
    /// Frames × frame duration versus host elapsed, once measurable.
    var drift: Double? { get }
    /// The true incoming rate, delivered frames over the host span they cover
    /// — a 59.94 source behind a "60" card reads ~59.94. Video only; nil for
    /// audio, for a screen with too few frames to measure, and before the
    /// second frame.
    var measuredFrameRate: Double? { get }
    /// Peak level since the last call, in dBFS, for audio streams; nil for
    /// video and before any samples. Reading resets the peak, so the `levels`
    /// event shows the loudest moment of each interval. A protocol
    /// requirement, not an extension default — an extension default is
    /// statically dispatched and would hide AudioWriter's real level behind
    /// nil when the writer is held as `any Writer`.
    func sampleLevelDb() -> Double?
    /// Close the file. The manifest is written after this returns.
    func finish() async -> String?
}

public protocol WriterFactory: Sendable {
    /// A writer for this stream's file at this absolute URL.
    func makeWriter(
        for stream: StreamInfo, active: StreamInfo.Capabilities, codec: Manifest.Codec, url: URL
    ) throws
        -> any Writer
}

/// Records nothing: the take engine's shape without the files. Replaced by
/// real writers in step 5; kept for tests that only care about state.
public final class NullWriter: Writer, @unchecked Sendable {
    public var timecode: String? { nil }
    public var framesWritten: Int { 0 }
    public var framesDropped: Int { 0 }
    public var framesDelivered: Int { 0 }
    public var drift: Double? { nil }
    public var measuredFrameRate: Double? { nil }
    public init() {}
    public func handle(_ sampleBuffer: CMSampleBuffer) {}
    public func sampleLevelDb() -> Double? { nil }
    public func finish() async -> String? { nil }
}

public struct NullWriterFactory: WriterFactory {
    public init() {}
    public func makeWriter(
        for stream: StreamInfo, active: StreamInfo.Capabilities, codec: Manifest.Codec, url: URL
    ) throws -> any Writer {
        NullWriter()
    }
}
