import Foundation
import Testing

@testable import Rheocles

/// The menu bar icon says what the daemon says (spec §12): idle, armed,
/// recording — and which streams joined late.
@Suite("Icon state")
@MainActor
struct IconStateTests {
    private func manifest(_ json: String) throws -> Manifest {
        try Manifest.decoder.decode(Manifest.self, from: Data(json.utf8))
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
        let live = try manifest(
            """
            { "take": { "id": "tk_1", "state": "recording", "started": "2026-09-11T14:02:17.004Z" },
              "streams": [] }
            """)
        #expect(
            MenuBarIcon.State.derive(status: .running, take: live, armedCount: 2)
                == .recording(lateJoined: []))

        let done = try manifest(
            """
            { "take": { "id": "tk_1", "state": "complete", "started": "2026-09-11T14:02:17.004Z",
                        "stopped": "2026-09-11T14:14:40.501Z" }, "streams": [] }
            """)
        #expect(MenuBarIcon.State.derive(status: .running, take: done, armedCount: 2) == .armed)
        #expect(MenuBarIcon.State.derive(status: .running, take: done, armedCount: 0) == .idle)
    }

    @Test("A stream that started after the cue is a late join, by position")
    func lateJoin() throws {
        let take = try manifest(
            """
            { "take": { "id": "tk_1", "state": "recording", "started": "2026-09-11T14:02:17.004Z" },
              "streams": [
                { "id": "camera:a", "started": "2026-09-11T14:02:17.004Z" },
                { "id": "window:b", "started": "2026-09-11T14:06:17.021Z" },
                { "id": "microphone:c", "started": "2026-09-11T14:02:17.010Z" }
              ] }
            """)
        #expect(take.lateJoined == [1])
        #expect(
            MenuBarIcon.State.derive(status: .running, take: take, armedCount: 3)
                == .recording(lateJoined: [1]))
        #expect(take.elapsed(at: Date(timeIntervalSince1970: 1_789_135_337.004 + 100)) != nil)
    }

    @Test("Absent fields decode as absent, never as a failure")
    func lenientManifest() throws {
        let bare = try manifest(#"{ "take": { "id": "tk_2" } }"#)
        #expect(bare.take.state == nil)
        #expect(bare.isRecording == false)
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
