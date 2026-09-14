import CoreMedia
import Foundation
import Testing

@testable import RheoclesCore

@Suite("Join, leave, markers")
struct JoinLeaveTests {
    private func world() async throws -> TakeTests.World {
        try await TakeTests().world()
    }

    @Test("Join a stream not armed at the cue starts it late and stamps the offset")
    func lateJoin() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init()).take.id
        // The mic was not armed at the cue.
        try await Task.sleep(for: .milliseconds(60))
        let m = try await w.engine.join(id, stream: "microphone:fake")
        #expect(m.streams.map(\.id).sorted() == ["camera:fake", "microphone:fake"])
        let mic = try #require(m.streams.first { $0.id == "microphone:fake" })
        #expect(mic.started != nil)
        #expect(mic.events.first?.type == .join)
        #expect((mic.events.first?.t ?? 0) > 0, "stamped at the offset it actually began")
        #expect(await w.registry.armedIDs.contains("microphone:fake"), "join arms a cold stream")
        #expect(w.writers.made["microphone:fake"] != nil)
        _ = try await w.engine.stop(id)
    }

    @Test("Leave finalizes one file; the stream stays armed and the take continues")
    func leave() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        try await w.registry.arm("microphone:fake")
        let id = try await w.engine.record(.init()).take.id
        let m = try await w.engine.leave(id, stream: "microphone:fake")
        let mic = try #require(m.streams.first { $0.id == "microphone:fake" })
        #expect(mic.stopped != nil)
        #expect(mic.events.last?.type == .leave)
        #expect(w.writers.made["microphone:fake"]?.1.finished == true)
        #expect(
            await w.registry.armedIDs.contains("microphone:fake"), "leave keeps the stream armed")
        // The take is still recording for the camera.
        #expect(await w.engine.activeManifest?.state == .recording)
        let final = try await w.engine.stop(id)
        #expect(final.state == .complete)
    }

    @Test("The manifest is live while recording: framesWritten reflects the writer, not the cue")
    func liveManifest() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init()).take.id
        // Push frames through the take's writer, as a device would.
        let writer = try #require(w.writers.made["camera:fake"]?.1)
        for _ in 0..<7 { writer.handle(Self.dummyFrame()) }
        let live = try await w.engine.manifest(id)
        #expect(live.state == .recording)
        #expect(live.streams.first?.framesWritten == 7, "GET /takes/{id} shows live frames, not 0")
        _ = try await w.engine.stop(id)
    }

    private static func dummyFrame() -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: .init(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
            extensions: nil,
            formatDescriptionOut: &format)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: nil, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        return sample!
    }

    @Test("Join on a stream already recording is 409")
    func doubleJoin() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init()).take.id
        await #expect(throws: APIError.self) { try await w.engine.join(id, stream: "camera:fake") }
        _ = try await w.engine.stop(id)
    }

    @Test("Markers append at the cue offset and are announced")
    func markers() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init()).take.id
        try await Task.sleep(for: .milliseconds(50))
        let m = try await w.engine.addMarker(id, label: "hello")
        #expect(m.markers.count == 1)
        #expect(m.markers[0].label == "hello")
        #expect(m.markers[0].t > 0)
        #expect(
            w.events.withLock { $0 }.contains { $0.contains("marker") } == false,
            "marker uses onEvent, not onChange")
        _ = try await w.engine.stop(id)
    }

    @Test("Join, leave and markers are refused outside a recording take")
    func notRecording() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        await #expect(throws: APIError.self) {
            try await w.engine.join("nope", stream: "camera:fake")
        }
        let id = try await w.engine.create(.init()).take.id  // created, not recording
        await #expect(throws: APIError.self) { try await w.engine.addMarker(id, label: "x") }
        await #expect(throws: APIError.self) { try await w.engine.leave(id, stream: "camera:fake") }
    }
}

@Suite("Settings and token")
struct SettingsTests {
    private let scratch = Scratch()

    private func temp() -> URL {
        scratch.directory()
    }

    @Test("Settings persist and reload, and update announces")
    func persistence() throws {
        let dir = temp()
        let announced = OSAllocatedUnfairLockBox<[Settings.Values]>([])
        let s = Settings(
            fileURL: dir.appendingPathComponent("settings.json"),
            defaults: .init(outputRoot: "/a", codec: .hevc)
        ) { values in announced.withLock { $0.append(values) } }
        s.update(codec: .prores)
        s.update(outputRoot: "/b")
        #expect(s.values == .init(outputRoot: "/b", codec: .prores))
        // A fresh instance over the same file sees the persisted values.
        let again = Settings(
            fileURL: dir.appendingPathComponent("settings.json"),
            defaults: .init(outputRoot: "/z", codec: .hevc))
        #expect(again.values == .init(outputRoot: "/b", codec: .prores))
    }

    @Test("Rotating the token invalidates the old one for later checks")
    func rotation() throws {
        let dir = temp()
        let store = TokenStore(fileURL: dir.appendingPathComponent("token"))
        let first = try store.loadOrCreate()
        let auth = BearerAuth(token: first)
        #expect(auth.matches(header: "Bearer \(first)"))
        let second = try store.rotate()
        auth.update(to: second)
        #expect(!auth.matches(header: "Bearer \(first)"))
        #expect(auth.matches(header: "Bearer \(second)"))
    }
}
