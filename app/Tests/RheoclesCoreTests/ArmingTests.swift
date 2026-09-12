import Foundation
import Testing

@testable import RheoclesCore

/// Sessions that only remember what they were told.
final class FakeSession: StreamSession, @unchecked Sendable {
    let info: StreamInfo
    let lock = NSLock()
    var started = 0
    var stopped = 0
    var sink: (any FrameSink)?
    let failWith: CaptureError?

    init(_ info: StreamInfo, failWith: CaptureError? = nil) {
        self.info = info
        self.failWith = failWith
    }

    var active: StreamInfo.Capabilities {
        .init(video: .init(width: 640, height: 480, maxFrameRate: 15))
    }

    var framesSeen: Int { 42 }

    func start() async throws {
        if let failWith { throw failWith }
        lock.withLock { started += 1 }
    }

    func stop() async {
        lock.withLock { stopped += 1 }
    }
}

final class FakeFactory: SessionFactory, @unchecked Sendable {
    let lock = NSLock()
    var made: [String: FakeSession] = [:]
    var failing: [String: CaptureError] = [:]

    func makeSession(for stream: StreamInfo) throws -> any StreamSession {
        let session = FakeSession(stream, failWith: lock.withLock { failing[stream.id] })
        lock.withLock { made[stream.id] = session }
        return session
    }
}

struct TwoStreams: StreamSource {
    func streams() async -> [StreamInfo] {
        [
            StreamInfo(
                id: "camera:fake", kind: .camera, name: "Fake camera", model: "Test",
                capabilities: .init(video: .init(width: 1280, height: 720, maxFrameRate: 30))),
            StreamInfo(
                id: "microphone:fake", kind: .microphone, name: "Fake mic", model: "Test",
                capabilities: .init(audio: .init(sampleRate: 48000, channels: 1))),
        ]
    }
}

@Suite("Arming")
struct ArmingTests {
    @Test("Arm opens the device once and reports it live; disarm closes it")
    func armDisarm() async throws {
        let factory = FakeFactory()
        let registry = Registry(catalog: TwoStreams(), factory: factory)

        let armed = try await registry.arm("camera:fake")
        #expect(armed.armed)
        #expect(armed.active?.video?.width == 640)
        #expect(armed.framesSeen == 42)
        #expect(try await registry.arm("camera:fake").armed, "idempotent")
        #expect(factory.made["camera:fake"]?.started == 1)
        #expect(await registry.armedIDs == ["camera:fake"])
        #expect(await registry.streams().map(\.armed) == [true, false])

        let disarmed = try await registry.disarm("camera:fake")
        #expect(!disarmed.armed)
        #expect(disarmed.active == nil && disarmed.framesSeen == nil)
        #expect(factory.made["camera:fake"]?.stopped == 1)
        #expect(!(try await registry.disarm("camera:fake").armed), "idempotent")
        #expect(await registry.armedIDs.isEmpty)
    }

    @Test("A stream that fails to open is not left half-armed")
    func failure() async throws {
        let factory = FakeFactory()
        factory.failing["camera:fake"] = .permissionDenied("camera access is denied for this app")
        let registry = Registry(catalog: TwoStreams(), factory: factory)
        await #expect(throws: APIError.self) { try await registry.arm("camera:fake") }
        #expect(await registry.armedIDs.isEmpty)
        #expect(await registry.streams().allSatisfy { !$0.armed })
    }

    @Test("Unknown streams are 404 on both verbs")
    func unknown() async {
        let registry = Registry(catalog: TwoStreams(), factory: FakeFactory())
        await #expect(throws: APIError.notFound("no such stream: nope")) {
            try await registry.arm("nope")
        }
        await #expect(throws: APIError.notFound("no such stream: nope")) {
            try await registry.disarm("nope")
        }
    }

    @Test("Every change in armed state is announced")
    func announces() async throws {
        let seen = OSAllocatedUnfairLockBox<[String]>([])
        let registry = Registry(catalog: TwoStreams(), factory: FakeFactory()) { stream in
            seen.withLock { $0.append("\(stream.id):\(stream.armed)") }
        }
        try await registry.arm("microphone:fake")
        try await registry.arm("microphone:fake")
        try await registry.disarm("microphone:fake")
        #expect(seen.withLock { $0 } == ["microphone:fake:true", "microphone:fake:false"])
    }
}

/// `OSAllocatedUnfairLock` is not importable in tests without `os`; a lock box
/// is enough.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
