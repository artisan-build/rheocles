import AppKit
import Foundation
import RheoclesCore
import Testing

@testable import Rheocles

/// Task 4's surfaces: levels from events, preview on demand, and the codec
/// preference travelling with Record.
extension Live {
    @Suite("Levels, preview, settings")
    @MainActor
    struct PanelTests {
        private let scratch = Scratch()

        private func message(_ json: String) throws -> EventStream.Message {
            let data = Data(json.utf8)
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return EventStream.Message(kind: object["event"] as! String, json: object, raw: data)
        }

        @Test("Levels: peak dBFS for audio, frames and drift for all, absent until said")
        func levels() throws {
            let model = DaemonModel()
            #expect(model.levels.isEmpty)
            model.handle(
                try message(
                    #"{ "event": "levels", "take": "tk", "streams": [ { "id": "microphone:a", "levelDb": -18.5, "framesWritten": 96000, "drift": 0 }, { "id": "camera:b", "framesWritten": 60 } ] }"#
                ))
            #expect(model.levels["microphone:a"] == -18.5)
            #expect(model.levels["camera:b"] == nil)
            #expect(model.streamStatus["camera:b"]?.framesWritten == 60)
            #expect(model.streamStatus["camera:b"]?.drift == nil)
            #expect(model.streamStatus["microphone:a"]?.drift == 0)
            #expect(model.levels["microphone:never"] == nil)
        }

        @Test("Stalled is set by the event and cleared when the stream reports again")
        func stalled() throws {
            let model = DaemonModel()
            model.handle(
                try message(
                    #"{ "event": "stalled", "stream": { "id": "camera:b", "kind": "camera", "name": "x", "model": "x", "capabilities": {}, "armed": true, "framesSeen": 0 } }"#
                ))
            #expect(model.stalled == ["camera:b"])
            model.handle(
                try message(
                    #"{ "event": "levels", "take": "tk", "streams": [ { "id": "camera:b", "framesWritten": 61 } ] }"#
                ))
            #expect(model.stalled.isEmpty)
        }

        @Test("A settings event replaces the settings; the codec is the daemon's")
        func settingsEvent() throws {
            let model = DaemonModel.staged(.running)
            model.handle(
                try message(
                    #"{ "event": "settings", "settings": { "outputRoot": "/Volumes/SSD/Takes", "codec": "prores" } }"#
                ))
            #expect(model.settings?.outputRoot == "/Volumes/SSD/Takes")
            #expect(model.codec == .prores)
        }

        @Test("Preview polls one stream, shows its frame, and stops when asked")
        func preview() async throws {
            let port = StubDaemon.freePort()
            let scratch = self.scratch.directory()
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

            // Audio: a sampled level into the meter, gone when sampling stops.
            model.togglePreview("microphone:stub")
            #expect(await eventually { model.levels["microphone:stub"] == -12.5 })
            #expect(model.previewFrame == nil)
            model.stopPreview()
            #expect(model.levels["microphone:stub"] == nil)
        }

        @Test("The codec is the daemon's setting: PATCH it and the next take is ProRes")
        func codecTravels() async throws {
            let flow = TakeFlowTests()
            let (daemon, model) = try flow.engine()
            defer { daemon.stop() }
            model.connect()
            defer { model.shutdown() }
            #expect(await eventually { model.status == .running })
            #expect(await eventually { model.settings != nil })
            #expect(model.codec == .hevc)

            model.updateSettings(codec: .prores)
            #expect(await eventually { model.codec == .prores })
            model.arm("camera:fake", true)
            #expect(await eventually { model.armedStreams.count == 1 })
            model.record()
            #expect(await eventually { model.take?.isRecording == true })
            #expect(model.take?.settings.codec == .prores)
            #expect(model.take?.streams.first?.codec == "prores")
            #expect(await eventually { !model.takeBusy })
            model.stop()
            #expect(await eventually { model.take?.isOver == true })
        }

        @Test("The output root cannot move under an active take: 409, shown, settings unchanged")
        func outputRootRefusedWhileRecording() async throws {
            let flow = TakeFlowTests()
            let (daemon, model) = try flow.engine()
            defer { daemon.stop() }
            model.connect()
            defer { model.shutdown() }
            #expect(await eventually { model.settings != nil })
            let before = model.settings?.outputRoot

            model.arm("camera:fake", true)
            #expect(await eventually { model.armedStreams.count == 1 })
            model.record()
            #expect(await eventually { model.take?.isRecording == true })

            model.updateSettings(outputRoot: "/tmp/elsewhere")
            #expect(await eventually { model.settingsError != nil })
            #expect(model.settingsError?.contains("409") == true)
            #expect(model.settings?.outputRoot == before)

            #expect(await eventually { !model.takeBusy })
            model.stop()
            #expect(await eventually { model.take?.isOver == true })
            model.updateSettings(outputRoot: "/tmp/elsewhere")
            #expect(await eventually { model.settings?.outputRoot == "/tmp/elsewhere" })
            #expect(model.settingsError == nil)
        }

        @Test("Rotate takes two clicks, swaps the token in place, and the old one is dead")
        func rotate() async throws {
            let flow = TakeFlowTests()
            let (daemon, model) = try flow.engine()
            defer { daemon.stop() }
            model.connect()
            defer { model.shutdown() }
            #expect(await eventually { model.status == .running })
            let old = try #require(model.token)

            model.rotateToken()
            #expect(model.rotateArmed)
            #expect(model.token == old)
            model.rotateToken()
            #expect(!model.rotateArmed)
            #expect(await eventually { model.token != old })
            let new = try #require(model.token)
            #expect(new.count == 64)

            // The old token is refused; the new one — and the model — carry on.
            var stale = API()
            stale.port = model.configuration.port
            stale.token = old
            await #expect(throws: API.Failure.unauthorized) {
                try await stale.get("/", as: Discovery.self)
            }
            await model.check()
            #expect(model.status == .running)
            #expect(model.settingsError == nil)
            // And the file the daemon rewrote says the same.
            let onDisk = try String(contentsOf: model.tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(onDisk == new)
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
}

extension String {
    fileprivate static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
