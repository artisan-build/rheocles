import Foundation
import RheoclesCore
import Testing

@testable import Rheocles

/// Open in Finder and the single-file option (feature brief §1, §2): the
/// reveal calls go to the daemon and nowhere else, and the checkbox shows
/// only when at most one video stream is armed.
@Suite("Reveal and combine", .serialized)
@MainActor
struct RevealCombineTests {
    private func stream(_ id: String, video: Bool, armed: Bool = true) -> StreamInfo {
        StreamInfo(
            id: id, kind: video ? .camera : .microphone, name: id, model: "x",
            capabilities: video
                ? .init(video: .init(width: 1280, height: 720, maxFrameRate: 30))
                : .init(audio: .init(sampleRate: 48000, channels: 1)),
            armed: armed)
    }

    @Test("The checkbox is offered for zero or one armed video stream, never two")
    func visibility() {
        let cam = stream("camera:a", video: true)
        let cam2 = stream("camera:b", video: true)
        let display = stream("display:c", video: true)
        let mic = stream("microphone:d", video: false)
        let mic2 = stream("microphone:e", video: false)

        #expect(DaemonModel.combineAvailable(armed: []))
        #expect(DaemonModel.combineAvailable(armed: [mic]))
        #expect(DaemonModel.combineAvailable(armed: [mic, mic2]))
        #expect(DaemonModel.combineAvailable(armed: [cam]))
        #expect(DaemonModel.combineAvailable(armed: [cam, mic, mic2]))
        #expect(!DaemonModel.combineAvailable(armed: [cam, cam2]))
        #expect(!DaemonModel.combineAvailable(armed: [cam, display, mic]))

        // In the popover: nothing armed shows no checkbox either — there is
        // no take to combine — and only armed streams count.
        let model = DaemonModel.staged(
            .running,
            streams: [cam, cam2, mic].map {
                var s = $0; s.armed = false; return s
            })
        #expect(!model.combineAvailable)
        let one = DaemonModel.staged(
            .running, streams: [cam, stream("camera:b", video: true, armed: false), mic])
        #expect(one.combineAvailable)
        let two = DaemonModel.staged(.running, streams: [cam, cam2, mic])
        #expect(!two.combineAvailable)
    }

    @Test("Open in Finder is the daemon's: the take, a file in it, and the output root")
    func reveal() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let log = scratch.appendingPathComponent("posts.log")
        let stub = try StubDaemon.launch(
            port: port, tokenFile: scratch.appendingPathComponent("token"), postLog: log)
        defer { stub.terminate() }
        #expect(await StubDaemon.waitUntilAnswers(port: port, token: "ab" * 32))

        var configuration = DaemonModel.Configuration()
        configuration.port = port
        configuration.tokenFile = scratch.appendingPathComponent("token")
        let model = DaemonModel(configuration: configuration)
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })

        model.reveal(take: "tk_1")
        model.reveal(take: "tk_1", path: "combined.mov")
        model.revealOutputRoot()
        #expect(
            await eventually {
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
                    == 3
            })
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(
            String.init)
        #expect(lines.contains("/takes/tk_1/reveal {}"))
        #expect(lines.contains(#"/takes/tk_1/reveal {"path":"combined.mov"}"#))
        #expect(lines.contains(#"/reveal {"path":""}"#))
        #expect(model.takeError == nil)
        #expect(model.settingsError == nil)

    }

    @Test("combined is read from the manifest in every state, and absent when the take has none")
    func combinedDecodes() throws {
        let model = DaemonModel.staged(.running)
        func manifest(combined: String?) -> Data {
            Data(
                """
                { "id": "tk_1", "state": "complete", "created": "2026-09-11T14:02:09.412Z",
                  "started": "2026-09-11T14:02:17.004Z", "stopped": "2026-09-11T14:14:40.501Z",
                  "outputRoot": "/tmp", "destination": "takes/x", "version": "0.1.0",
                  "machine": { "hostname": "h", "machineId": "m" }, "streams": [], "markers": [],
                  "settings": { "codec": "hevc" }\(combined.map { ", \"combined\": \($0)" } ?? "") }
                """.utf8)
        }
        let pending = try model.absorbTake(
            manifest(combined: #"{ "path": "combined.mov", "state": "pending" }"#))
        #expect(pending.combined?.isPending == true)
        let complete = try model.absorbTake(
            manifest(combined: #"{ "path": "combined.mov", "state": "complete" }"#))
        #expect(complete.combined?.isComplete == true)
        let failed = try model.absorbTake(
            manifest(
                combined: #"{ "path": "combined.mov", "state": "failed", "reason": "disk full" }"#))
        #expect(failed.combined?.reason == "disk full")
        #expect(failed.combined?.isComplete == false)
        #expect(try model.absorbTake(manifest(combined: nil)).combined == nil)
    }

    @Test("The combine setting is the daemon's: PATCHed, read back, and absent reads false")
    func combineSetting() async throws {
        let flow = TakeFlowTests()
        let (daemon, model) = try flow.engine()
        defer { daemon.stop() }
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.settings != nil })
        // Today's engine does not know `combine`; the app reads that as
        // false and a PATCH of it is either accepted or refused as
        // bad_request — never a crash, never a stale checkbox.
        #expect(model.combine == false)
        model.updateSettings(combine: true)
        #expect(await eventually { model.combine })
        #expect(model.settingsError == nil)

        // And a take created under it carries `combined` from the start,
        // pending, with the stub-written files it will never mux.
        model.arm("microphone:fake", true)
        #expect(await eventually { model.armedStreams.count == 1 })
        model.record()
        #expect(await eventually { model.take?.isRecording == true })
        #expect(model.take?.combined?.isPending == true)
        model.stop()
        #expect(await eventually { model.take?.isOver == true })
        #expect(await eventually(.seconds(8)) { model.take?.combined?.isPending == false })
        // Null writers leave no files, so the mux has nothing to do; either
        // outcome is reported, never left pending.
        #expect(model.take?.combined != nil)

        model.updateSettings(combine: false)
        #expect(await eventually { !model.combine })
    }
}

extension String {
    fileprivate static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
