import Foundation
import Testing

@testable import RheoclesCore

/// Real devices on this machine. Skipped unless RHEOCLES_DEVICE_TESTS is set:
/// CI has no camera, no screen grant and no system audio, and a test that
/// passes because it heard nothing would be worse than none.
@Suite(
    "Real devices",
    .enabled(if: ProcessInfo.processInfo.environment["RHEOCLES_DEVICE_TESTS"] != nil))
struct DeviceTests {
    @Test("System audio: the tap delivers buffers while armed")
    func systemAudio() async throws {
        let registry = Registry(catalog: DeviceCatalog.standard, factory: DeviceSessionFactory())
        let armed = try await registry.arm(SystemAudioSource.id)
        #expect(armed.armed)
        try await Task.sleep(for: .seconds(2))
        let live = await registry.stream(SystemAudioSource.id)
        #expect(
            (live?.framesSeen ?? 0) > 50,
            "expected ~190 IO callbacks in 2 s, saw \(live?.framesSeen ?? 0)")
        try await registry.disarm(SystemAudioSource.id)
    }

    @Test("Every armable kind on this machine delivers frames while armed")
    func everything() async throws {
        let registry = Registry(catalog: DeviceCatalog.standard, factory: DeviceSessionFactory())
        // Only what this process is allowed to open: the test host's grants
        // are not the daemon's (see Scripts/dev-core.sh for the real thing).
        let permissions = DeviceCatalog.permissions()
        let allowed: [StreamInfo.Kind] = [
            permissions.camera == .authorized ? .camera : nil,
            permissions.microphone == .authorized ? .microphone : nil,
            permissions.screen == .authorized ? .display : nil,
            permissions.screen == .authorized ? .window : nil,
            .systemAudio,
        ].compactMap { $0 }
        let streams = await registry.streams()
        var picked: [StreamInfo] = []
        for kind in allowed {
            if let first = streams.first(where: { $0.kind == kind && !$0.name.contains("Virtual") })
            {
                picked.append(first)
            }
        }
        print("device test arming:", picked.map { "\($0.kind.rawValue) \($0.name)" })
        for stream in picked { try await registry.arm(stream.id) }
        try await Task.sleep(for: .seconds(2))
        for stream in picked {
            let live = await registry.stream(stream.id)
            #expect((live?.framesSeen ?? 0) > 0, "\(stream.kind) \(stream.name) delivered nothing")
        }
        await registry.disarmAll()
    }
}
