import AVFoundation
import Foundation

/// Somewhere streams come from. The daemon has one real catalog; tests hand
/// the server a fake.
public protocol StreamSource: Sendable {
    func streams() async -> [StreamInfo]
}

/// The system's answer to "what can I record": every source, in a fixed
/// order, plus what the OS is letting us see.
public struct DeviceCatalog: StreamSource, Sendable {
    public let sources: [any StreamSource]

    public init(sources: [any StreamSource]) {
        self.sources = sources
    }

    /// Displays, windows, cameras, microphones, system audio — in that order
    /// so a list is stable between calls even when a device comes and goes.
    public static var standard: DeviceCatalog {
        DeviceCatalog(sources: [
            ScreenSource(), CameraSource(), MicrophoneSource(), SystemAudioSource(),
        ])
    }

    public func streams() async -> [StreamInfo] {
        var all: [StreamInfo] = []
        for source in sources { all += await source.streams() }
        return all
    }

    public static func permissions() -> Permissions {
        Permissions(
            camera: status(for: .video),
            microphone: status(for: .audio),
            screen: CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined)
    }

    private static func status(for media: AVMediaType) -> Permissions.Status {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

/// Every video `AVCaptureDevice`: built-in, Continuity, external UVC, and
/// virtual cameras. Listing needs no permission; opening one does.
public struct CameraSource: StreamSource {
    public init() {}

    public func streams() async -> [StreamInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { device in
            // The largest format at its highest rate: what "native" will mean
            // once arming picks a format (S1: the format is ours to hold).
            let best = device.formats.max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
            let dims = best.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            let fps = best?.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return StreamInfo(
                id: StreamInfo.makeID(.camera, device.uniqueID), kind: .camera,
                name: device.localizedName, model: device.modelID,
                capabilities: .init(
                    video: dims.map {
                        .init(width: Int($0.width), height: Int($0.height), maxFrameRate: fps)
                    }))
        }
    }
}

/// Every audio input device.
public struct MicrophoneSource: StreamSource {
    public init() {}

    public func streams() async -> [StreamInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.filter { device in
            // Our own system-audio tap surfaces as a private aggregate device
            // named "Rheocles system audio" while armed; it is not a real
            // input and must not be offered as a second microphone.
            !device.localizedName.hasPrefix("Rheocles system audio")
                && !device.uniqueID.contains("build.artisan.rheocles.systemaudio")
        }.map { device in
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                device.activeFormat.formatDescription)
            return StreamInfo(
                id: StreamInfo.makeID(.microphone, device.uniqueID), kind: .microphone,
                name: device.localizedName, model: device.modelID,
                capabilities: .init(
                    audio: asbd.map {
                        .init(
                            sampleRate: $0.pointee.mSampleRate,
                            channels: Int($0.pointee.mChannelsPerFrame))
                    }))
        }
    }
}

/// One stream for the whole system mix, via a Core Audio tap (per-process
/// later). Recorded as the rest of the audio is: 48 kHz BWF.
public struct SystemAudioSource: StreamSource {
    public static let id = "systemAudio:system"

    public init() {}

    public func streams() async -> [StreamInfo] {
        [
            StreamInfo(
                id: Self.id, kind: .systemAudio, name: "System audio", model: "Core Audio tap",
                capabilities: .init(audio: .init(sampleRate: 48000, channels: 2)))
        ]
    }
}
