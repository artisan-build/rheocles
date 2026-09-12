import AppKit
import Foundation
import RheoclesCore
import Testing

@testable import Rheocles

/// Task 4's surfaces: levels from events, preview on demand, and the codec
/// preference travelling with Record.
@Suite("Levels, preview, settings", .serialized)
@MainActor
struct PanelTests {
    private func message(_ json: String) throws -> EventStream.Message {
        let data = Data(json.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return EventStream.Message(kind: object["event"] as! String, json: object, raw: data)
    }

    @Test("Levels are read in either planned shape, and absent until said")
    func levels() throws {
        let model = DaemonModel()
        #expect(model.levels.isEmpty)
        model.handle(
            try message(
                #"{ "event": "levels", "levels": { "microphone:a": -18.5, "systemAudio:system": { "peak": -2 } } }"#
            ))
        #expect(model.levels["microphone:a"] == -18.5)
        #expect(model.levels["systemAudio:system"] == -2)
        model.handle(try message(#"{ "event": "levels", "stream": "microphone:b", "db": -40 }"#))
        #expect(model.levels["microphone:b"] == -40)
        #expect(model.levels["microphone:never"] == nil)
    }

    @Test("Preview polls one stream, shows its frame, and stops when asked")
    func preview() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let stub = try StubDaemon.launch(
            port: port, tokenFile: scratch.appendingPathComponent("token"))
        defer { stub.terminate() }
        #expect(await StubDaemon.waitUntilAnswers(port: port, token: "ab" * 32))

        var configuration = DaemonModel.Configuration()
        configuration.port = port
        configuration.tokenFile = scratch.appendingPathComponent("token")
        configuration.pulse = .milliseconds(200)
        let model = DaemonModel(configuration: configuration)
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })

        model.togglePreview("camera:stub")
        #expect(model.previewing == "camera:stub")
        #expect(await eventually { model.previewFrame != nil })
        #expect(model.previewFrame?.size == NSSize(width: 2, height: 2))
        #expect(model.previewError == nil)

        // One at a time: switching streams drops the old frame.
        model.togglePreview("camera:none")
        #expect(model.previewing == "camera:none")
        #expect(model.previewFrame == nil)
        #expect(await eventually { model.previewError?.contains("404") == true })

        model.togglePreview("camera:none")
        #expect(model.previewing == nil)
        #expect(model.previewError == nil)
    }

    @Test("The codec preference is a request field on Record, and the manifest keeps it")
    func codecTravels() async throws {
        let flow = TakeFlowTests()
        let (daemon, model) = try flow.engine()
        defer { daemon.stop() }
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })

        model.codec = .prores
        model.arm("camera:fake", true)
        #expect(await eventually { model.armedStreams.count == 1 })
        model.record()
        #expect(await eventually { model.take?.isRecording == true })
        #expect(model.take?.settings.codec == .prores)
        #expect(model.take?.streams.first?.codec == "prores")
        model.codec = .hevc
        model.stop()
        #expect(await eventually { model.take?.isOver == true })
    }

    @Test("The pairing code is masked to its ends and copied whole")
    func token() {
        let model = DaemonModel.staged(.running)
        #expect(model.token?.count == 64)
        #expect(model.maskedToken == "3f9a1c…a2b3c4")
        model.copyToken()
        #expect(NSPasteboard.general.string(forType: .string) == model.token)
    }
}

extension String {
    fileprivate static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
