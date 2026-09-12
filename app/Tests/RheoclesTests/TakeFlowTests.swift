import Foundation
import RheoclesCore
import Testing

@testable import Rheocles

/// The take flow, app against engine: a real `Server` in-process on spare
/// ports with fake devices, and the model driving it exactly as the popover
/// does — arm, Record, Stop — while the icon state follows.
@Suite("Take flow", .serialized)
@MainActor
struct TakeFlowTests {
    /// Sessions that only remember they were started.
    final class FakeSession: StreamSession, @unchecked Sendable {
        let info: StreamInfo
        var sink: (any FrameSink)?
        init(_ info: StreamInfo) { self.info = info }
        var active: StreamInfo.Capabilities { info.capabilities }
        var framesSeen: Int { 1 }
        func start() async throws {}
        func stop() async {}
    }

    struct FakeFactory: SessionFactory {
        func makeSession(for stream: StreamInfo) throws -> any StreamSession {
            FakeSession(stream)
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

    func engine() throws -> (Server, DaemonModel) {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        var server = Server.Configuration()
        server.httpPort = port
        server.wsPort = StubDaemon.freePort()
        server.catalog = TwoStreams()
        server.sessionFactory = FakeFactory()
        // The fake sessions deliver no frames, so a real writer would finish
        // the take `incomplete`. This suite tests the app's take flow, not the
        // writers (step 5) — record with a writer that completes on no frames.
        server.writerFactory = NullWriterFactory()
        server.permissions = {
            Permissions(camera: .authorized, microphone: .authorized, screen: .authorized)
        }
        server.tokenStore = TokenStore(fileURL: scratch.appendingPathComponent("token"))
        // Isolate settings from the real ~/Library file (step 6 added GET/PATCH
        // /settings backed by settings.json); shared, it pollutes parallel tests.
        server.settingsFileURL = scratch.appendingPathComponent("settings.json")
        server.outputRoot = scratch.appendingPathComponent("out", isDirectory: true)
        let daemon = try Server(configuration: server)
        try daemon.start()

        var app = DaemonModel.Configuration()
        app.port = port
        app.tokenFile = server.tokenStore.fileURL
        app.pulse = .milliseconds(200)
        return (daemon, DaemonModel(configuration: app))
    }

    private func icon(_ model: DaemonModel) -> MenuBarIcon.State {
        .derive(status: model.status, take: model.take, armedCount: model.armedStreams.count)
    }

    @Test("Arm, Record, Stop: the popover's three clicks against the engine")
    func armRecordStop() async throws {
        let (daemon, model) = try engine()
        defer { daemon.stop() }
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })
        #expect(model.startedByUs == false)
        #expect(await eventually { model.streams.count == 2 })
        #expect(icon(model) == .idle)
        #expect(model.armedStreams.isEmpty)

        // Nothing armed: Record is not on offer, and the daemon agrees.
        model.record()
        #expect(await eventually { !model.takeBusy })
        #expect(model.take == nil)
        #expect(model.takeError?.contains("400") == true)

        model.arm("camera:fake", true)
        #expect(await eventually { model.armedStreams.map(\.id) == ["camera:fake"] })
        #expect(model.pending == nil)
        #expect(icon(model) == .armed)

        model.takeName = "flow test"
        model.record()
        #expect(await eventually { model.take?.isRecording == true })
        #expect(model.take?.name == "flow test")
        #expect(model.take?.streams.map(\.id) == ["camera:fake"])
        #expect(model.take?.writing.count == 1)
        #expect(icon(model) == .recording(lateJoined: []))
        try await Task.sleep(for: .milliseconds(1100))
        #expect((model.take?.elapsed(at: model.now) ?? 0) >= 1)

        // A second Record while recording is refused, and says which take.
        model.record()
        #expect(await eventually { !model.takeBusy })
        #expect(model.takeError?.contains("take_active") == true)
        #expect(model.take?.isRecording == true)

        model.stop()
        #expect(await eventually { model.take?.isOver == true })
        #expect(model.take?.state == .complete)
        #expect(model.take?.stopped != nil)
        #expect(icon(model) == .armed)

        // The manifest the daemon wrote is the one the popover shows.
        let onDisk = try Manifest.decode(
            Data(
                contentsOf: URL(fileURLWithPath: model.take!.outputRoot)
                    .appending(path: model.take!.destination).appending(path: "manifest.json")))
        #expect(onDisk.id == model.take?.id)
        #expect(onDisk.state == .complete)

        model.arm("camera:fake", false)
        #expect(await eventually { model.armedStreams.isEmpty })
        #expect(icon(model) == .idle)
    }

    @Test("A take started by another client shows up without a click")
    func takeStartedElsewhere() async throws {
        let (daemon, model) = try engine()
        defer { daemon.stop() }
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })

        // Another client — ptero, curl — arms and records over the API.
        let token = try String(contentsOf: model.tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var api = API()
        api.port = model.configuration.port
        api.token = token
        try await api.post("/streams/microphone:fake/arm", DaemonModel.ArmBody(armed: true))
        let created: TakeEngine.Created = try await api.post(
            "/record", DaemonModel.RecordBody(name: "theirs"), decoder: Manifest.wireDecoder)

        #expect(await eventually { model.take?.id == created.take.id })
        #expect(await eventually { model.take?.isRecording == true })
        #expect(icon(model) == .recording(lateJoined: []))

        try await api.post("/takes/\(created.take.id)/stop", DaemonModel.EmptyBody())
        #expect(await eventually { model.take?.state == .complete })
        #expect(await eventually { icon(model) == .armed })
    }
}
