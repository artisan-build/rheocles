import Foundation

/// The daemon's writers: video kinds to `VideoWriter`, audio kinds to
/// `AudioWriter`. One Writer shape for every stream (S1–S3).
public struct DeviceWriterFactory: WriterFactory {
    public init() {}

    public func makeWriter(
        for stream: StreamInfo, active: StreamInfo.Capabilities, codec: Manifest.Codec, url: URL
    ) throws -> any Writer {
        switch stream.kind {
        case .camera:
            return VideoWriter(url: url, codec: codec, frameRate: active.video?.maxFrameRate ?? 30)
        case .display, .window:
            let writer = VideoWriter(
                url: url, codec: codec, frameRate: active.video?.maxFrameRate ?? 60)
            writer.measuresDrift = false
            return writer
        case .microphone, .systemAudio:
            return AudioWriter(url: url)
        }
    }
}
