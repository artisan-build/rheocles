import Foundation
import Testing

@testable import Rheocles

/// The menu bar icon says what the daemon says (spec §12): idle, armed,
/// recording — and which streams joined late.
@Suite("Icon state")
@MainActor
struct IconStateTests {
    /// A manifest in the daemon's shape with only what a test varies.
    private func manifest(
        state: String, started: String? = "2026-09-11T14:02:17.004Z", stopped: String? = nil,
        streams: [(id: String, started: String)] = []
    ) throws -> Manifest {
        let files = streams.map {
            """
            { "id": "\($0.id)", "kind": "camera", "name": "x", "model": "x", "path": "x.mov",
              "codec": "hevc", "format": {}, "started": "\($0.started)", "framesWritten": 0,
              "events": [] }
            """
        }
        let json = """
            { "id": "tk_1", "state": "\(state)", "created": "2026-09-11T14:02:09.412Z",
              \(started.map { "\"started\": \"\($0)\"," } ?? "")
              \(stopped.map { "\"stopped\": \"\($0)\"," } ?? "")
              "outputRoot": "/tmp", "destination": "takes/x", "version": "0.1.0",
              "machine": { "hostname": "h", "machineId": "m" },
              "streams": [\(files.joined(separator: ","))], "markers": [],
              "settings": { "codec": "hevc" } }
            """
        return try Manifest.wireDecoder.decode(Manifest.self, from: Data(json.utf8))
    }

    @Test("Launching or down is idle, whatever else is known")
    func notRunningIsIdle() {
        #expect(MenuBarIcon.State.derive(status: .launching, take: nil, armedCount: 3) == .idle)
        #expect(MenuBarIcon.State.derive(status: .down("x"), take: nil, armedCount: 3) == .idle)
    }

    @Test("Running with nothing armed is idle; anything armed is armed")
    func armed() {
        #expect(MenuBarIcon.State.derive(status: .running, take: nil, armedCount: 0) == .idle)
        #expect(MenuBarIcon.State.derive(status: .running, take: nil, armedCount: 1) == .armed)
    }

    @Test("A recording take is recording; a finished one is not")
    func recording() throws {
        let live = try manifest(state: "recording")
        #expect(
            MenuBarIcon.State.derive(status: .running, take: live, armedCount: 2)
                == .recording(lateJoined: []))

        let done = try manifest(state: "complete", stopped: "2026-09-11T14:14:40.501Z")
        #expect(MenuBarIcon.State.derive(status: .running, take: done, armedCount: 2) == .armed)
        #expect(MenuBarIcon.State.derive(status: .running, take: done, armedCount: 0) == .idle)
        #expect(done.elapsed(at: Date()).map { Int($0) } == 743)
    }

    @Test("A stream that started after the cue is a late join, by position")
    func lateJoin() throws {
        let take = try manifest(
            state: "recording",
            streams: [
                ("camera:a", "2026-09-11T14:02:17.004Z"),
                ("window:b", "2026-09-11T14:06:17.021Z"),
                ("microphone:c", "2026-09-11T14:02:17.010Z"),
            ])
        #expect(take.lateJoined == [1])
        #expect(take.writing.count == 3)
        #expect(
            MenuBarIcon.State.derive(status: .running, take: take, armedCount: 3)
                == .recording(lateJoined: [1]))
    }

    @Test("Before the cue there is no elapsed time and nothing is late")
    func createdOnly() throws {
        let bare = try manifest(state: "created", started: nil)
        #expect(bare.isRecording == false)
        #expect(bare.isOver == false)
        #expect(bare.elapsed(at: Date()) == nil)
        #expect(bare.lateJoined.isEmpty)
    }

    @Test("The counter reads like a tape counter")
    func clock() {
        #expect(TimeInterval(0).clock == "00:00")
        #expect(TimeInterval(257.9).clock == "04:17")
        #expect(TimeInterval(3661).clock == "1:01:01")
    }
}
