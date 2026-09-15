import CoreMedia
import Foundation
import Testing

@testable import RheoclesCore

/// A writer that remembers it was started and finished, and can fail.
final class FakeWriter: Writer, @unchecked Sendable {
    let lock = NSLock()
    var frames = 0
    var finished = false
    let failure: String?
    init(failure: String? = nil) { self.failure = failure }
    var timecode: String? { "10:00:00:00" }
    var framesWritten: Int { lock.withLock { frames } }
    var framesDropped: Int { 0 }
    var drift: Double? { 0.001 }
    func sampleLevelDb() -> Double? { -20 }
    func handle(_ sampleBuffer: CMSampleBuffer) { lock.withLock { frames += 1 } }
    func finish() async -> String? {
        lock.withLock { finished = true }
        return failure
    }
}

final class FakeWriterFactory: WriterFactory, @unchecked Sendable {
    let lock = NSLock()
    var made: [String: (URL, FakeWriter)] = [:]
    var failing: [String: String] = [:]
    func makeWriter(
        for stream: StreamInfo, active: StreamInfo.Capabilities, codec: Manifest.Codec, url: URL
    ) throws
        -> any Writer
    {
        let writer = FakeWriter(failure: lock.withLock { failing[stream.id] })
        lock.withLock { made[stream.id] = (url, writer) }
        return writer
    }
}

@Suite("Takes")
struct TakeTests {
    private let scratch = Scratch()

    struct World {
        // accessible to JoinLeaveTests
        let scratch: Scratch
        let root: URL
        let registry: Registry
        let sessions: FakeFactory
        let writers: FakeWriterFactory
        let engine: TakeEngine
        let events: OSAllocatedUnfairLockBox<[String]>
        /// Every manifest handed to `onChange`, for tests that need a field
        /// beyond `id:state` — e.g. `removed` on a supersede.
        let manifests: OSAllocatedUnfairLockBox<[Manifest]>
    }

    /// The world owns its scratch: the engine's root closure holds it, so the
    /// directory lives as long as the engine does (JoinLeaveTests borrows this
    /// from a throwaway `TakeTests()`).
    func world(freeBytes: Int64? = 1 << 40) async throws -> World {
        let scratch = Scratch("take-tests")
        let root = scratch.url
        let sessions = FakeFactory()
        let registry = Registry(catalog: TwoStreams(), factory: sessions)
        let writers = FakeWriterFactory()
        let events = OSAllocatedUnfairLockBox<[String]>([])
        let manifests = OSAllocatedUnfairLockBox<[Manifest]>([])
        let engine = TakeEngine(
            registry: registry, outputRoot: { scratch.url }, writerFactory: writers,
            machine: .init(hostname: "test.local", machineId: "TEST"), freeBytes: { _ in freeBytes }
        ) { manifest in
            events.withLock { $0.append("\(manifest.id):\(manifest.state.rawValue)") }
            manifests.withLock { $0.append(manifest) }
        }
        return World(
            scratch: scratch, root: root, registry: registry, sessions: sessions, writers: writers,
            engine: engine, events: events, manifests: manifests)
    }

    private func manifestOnDisk(_ w: World, _ destination: String) throws -> Manifest {
        try Manifest.decode(
            Data(
                contentsOf: w.root.appendingPathComponent(destination).appendingPathComponent(
                    "manifest.json")))
    }

    @Test(
        "Create snapshots the armed set and reserves paths in memory — nothing on disk, nothing records"
    )
    func create() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        try await w.registry.arm("microphone:fake")
        let created = try await w.engine.create(.init(name: "Episode 12"))
        let take = created.take
        #expect(take.state == .created)
        #expect(take.name == "Episode 12")
        #expect(take.destination.hasPrefix("takes/") && take.destination.hasSuffix("-episode-12"))
        #expect(take.streams.map(\.path) == ["fake-camera.mov", "fake-mic.wav"])
        #expect(take.streams.map(\.codec) == ["hevc", "pcm_s24le"])
        #expect(
            take.streams[0].format.video?.width == 640, "the active format, not the advertised one")
        #expect(take.machine.machineId == "TEST" && take.version == Rheocles.version)
        #expect(created.warnings.isEmpty)
        // §1: a prepared take lives in memory — nothing on disk until start,
        // but it is answered from memory by id and in the listing.
        #expect(
            !FileManager.default.fileExists(
                atPath: w.root.appendingPathComponent(take.destination).path),
            "create writes nothing to disk")
        #expect(try await w.engine.manifest(take.id) == take, "answered from memory")
        #expect(await w.engine.list().contains { $0.id == take.id }, "listed from memory")
        #expect(w.writers.made.isEmpty, "create must not open a writer")
        #expect(w.sessions.made["camera:fake"]?.sink == nil)
    }

    @Test(
        "Start is the cue: every stream's writer starts and the manifest says recording; stop finalizes"
    )
    func startStop() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.create(.init()).take.id
        let started = try await w.engine.start(id)
        #expect(started.state == .recording && started.started != nil)
        #expect(started.streams[0].started == started.started)
        #expect(started.streams[0].events == [.init(t: 0, type: .join)])
        let writer = try #require(w.writers.made["camera:fake"])
        #expect(writer.0.lastPathComponent == "fake-camera.mov")
        #expect(
            w.sessions.made["camera:fake"]?.sink === writer.1, "the session's sink is the writer")
        #expect(try manifestOnDisk(w, started.destination).state == .recording)

        let stopped = try await w.engine.stop(id)
        #expect(stopped.state == .complete && stopped.stopped != nil && stopped.reason == nil)
        #expect(writer.1.finished)
        #expect(
            w.sessions.made["camera:fake"]?.sink == nil,
            "stop detaches the writer, the stream stays armed")
        #expect(await w.registry.armedIDs == ["camera:fake"])
        #expect(stopped.streams[0].timecode == "10:00:00:00" && stopped.streams[0].drift == 0.001)
        #expect(stopped.streams[0].events.last?.type == .leave)
        #expect(try manifestOnDisk(w, stopped.destination) == stopped)
        #expect(await w.engine.activeManifest == nil)
        #expect(w.events.withLock { $0 } == ["\(id):created", "\(id):recording", "\(id):complete"])
    }

    @Test("Record is create + start in one call")
    func record() async throws {
        let w = try await world()
        try await w.registry.arm("microphone:fake")
        let created = try await w.engine.record(.init(name: "quick"))
        #expect(created.take.state == .recording)
        #expect(w.writers.made["microphone:fake"] != nil)
        _ = try await w.engine.stop(created.take.id)
    }

    @Test("One active take: a recording take blocks create with 409; a created one is superseded")
    func oneActive() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let first = try await w.engine.create(.init(name: "first")).take
        let second = try await w.engine.create(.init(name: "second")).take
        // The superseded prepared take lived in memory only (§1): it never
        // reached disk, and the final event marks it removed.
        #expect(
            !FileManager.default.fileExists(
                atPath: w.root.appendingPathComponent(first.destination).path))
        let firstEvent = try #require(
            w.manifests.withLock { $0 }.last { $0.id == first.id })
        #expect(firstEvent.state == .incomplete)
        #expect(firstEvent.reason == "superseded before start")
        #expect(firstEvent.removed == true)
        _ = try await w.engine.start(second.id)
        await #expect(throws: APIError.self) { try await w.engine.create(.init(name: "third")) }
        do {
            _ = try await w.engine.create(.init(name: "third"))
        } catch let error as APIError {
            #expect(error.status == 409 && error.code == "take_active")
        }
        _ = try await w.engine.stop(second.id)
    }

    @Test("Same destination twice is 409 unless overwrite")
    func destinationConflict() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init(destination: "shows/ep1")).take.id
        _ = try await w.engine.stop(id)
        await #expect(
            throws: APIError.conflict("destination exists: shows/ep1; pass overwrite to reuse it")
        ) {
            try await w.engine.create(.init(destination: "shows/ep1"))
        }
        let again = try await w.engine.create(.init(destination: "shows/ep1", overwrite: true)).take
        #expect(again.destination == "shows/ep1")
        await #expect(throws: APIError.self) {
            try await w.engine.create(.init(destination: "../escape"))
        }
        await #expect(throws: APIError.self) {
            try await w.engine.create(.init(destination: "/abs"))
        }
    }

    @Test("Disk pre-flight refuses with 507 when short and warns when tight")
    func preflight() async throws {
        let tight = try await world(freeBytes: 4_000_000_000)
        try await tight.registry.arm("camera:fake")
        // 640x480x15 fps HEVC ≈ 86 kB/s → 10 hours ≈ 3.1 GB; 4 GB free is tight, not short.
        let created = try await tight.engine.create(.init(expectedDuration: 30 * 60 * 20))
        #expect(created.warnings.first?.hasPrefix("disk is tight") == true)

        let short = try await world(freeBytes: 1_000)
        try await short.registry.arm("camera:fake")
        do {
            _ = try await short.engine.create(.init())
            Issue.record("expected 507")
        } catch let error as APIError {
            #expect(error.status == 507 && error.code == "insufficient_storage")
        }
    }

    @Test("No armed streams is a 400, not an empty take")
    func nothingArmed() async throws {
        let w = try await world()
        await #expect(throws: APIError.badRequest("no armed streams; arm something first")) {
            try await w.engine.create(.init())
        }
    }

    @Test("A writer that fails leaves the take incomplete with the reason, files intact")
    func writerFailure() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        try await w.registry.arm("microphone:fake")
        w.writers.failing["microphone:fake"] = "disk full"
        let id = try await w.engine.record(.init()).take.id
        let stopped = try await w.engine.stop(id)
        #expect(stopped.state == .incomplete && stopped.reason == "disk full")
        #expect(stopped.streams[1].error == "disk full" && stopped.streams[0].error == nil)
    }

    @Test("A manifest reserve is written at start and freed at stop (full-disk safety net)")
    func manifestReserve() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let take = try await w.engine.create(.init()).take
        let folder = w.root.appendingPathComponent(take.destination)
        let reserve = folder.appendingPathComponent(".manifest.reserve")
        // Nothing on disk after create (§1); the reserve lands at start, 64 KB,
        // so a full disk can be relieved to land the final manifest truthfully.
        #expect(!FileManager.default.fileExists(atPath: reserve.path))
        _ = try await w.engine.start(take.id)
        #expect(FileManager.default.fileExists(atPath: reserve.path))
        let size =
            (try FileManager.default.attributesOfItem(atPath: reserve.path)[.size] as? Int) ?? 0
        #expect(size == 64 * 1024)
        _ = try await w.engine.stop(take.id)
        #expect(
            !FileManager.default.fileExists(atPath: reserve.path),
            "reserve is released once the take is over")
    }

    @Test("Manifests are readable by id after the fact, and listed newest first")
    func readBack() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let a = try await w.engine.record(.init(name: "a")).take.id
        _ = try await w.engine.stop(a)
        let b = try await w.engine.record(.init(name: "b")).take.id
        let list = await w.engine.list()
        #expect(list.map(\.name) == ["b", "a"])
        #expect(list[0].state == .recording && list[1].state == .complete)
        #expect(try await w.engine.manifest(a).state == .complete)
        await #expect(throws: APIError.notFound("no such take: nope")) {
            try await w.engine.manifest("nope")
        }
        _ = try await w.engine.stop(b)

        // A fresh engine over the same root finds them on disk.
        let fresh = TakeEngine(
            registry: w.registry, outputRoot: { w.root }, writerFactory: w.writers,
            machine: .init(hostname: "x", machineId: "y"))
        #expect(await fresh.list().map(\.name) == ["b", "a"])
        #expect(try await fresh.manifest(a).name == "a")
    }

    @Test("shutdown finalises a recording take incomplete with 'daemon stopped'")
    func shutdownFinalises() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let id = try await w.engine.record(.init()).take.id
        await w.engine.shutdown()
        #expect(await w.engine.activeManifest == nil)
        let take = try await w.engine.manifest(id)
        #expect(take.state == .incomplete && take.reason == "daemon stopped")
        #expect(take.streams.allSatisfy { $0.stopped != nil })
        #expect(w.writers.made["camera:fake"]?.1.finished == true)
    }

    @Test("recoverStaleManifests rewrites a left-recording manifest to incomplete 'daemon died'")
    func recovery() async throws {
        let root = scratch.directory("recover")
        let folder = root.appendingPathComponent("takes/x", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A manifest a dead daemon left mid-recording.
        var stale = Manifest(
            id: "x", name: nil, state: .recording, reason: nil, created: Date(), started: Date(),
            stopped: nil, outputRoot: root.path, destination: "takes/x", version: "0.1.0",
            machine: .init(hostname: "h", machineId: "m"), streams: [], markers: [],
            settings: .init(codec: .hevc, expectedDuration: nil))
        try stale.write(to: folder.appendingPathComponent("manifest.json"))

        TakeEngine.recoverStaleManifests(in: root)

        let recovered = try Manifest.decode(
            Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(recovered.state == .incomplete && recovered.reason == "daemon died")
        // A created-but-unstarted take recorded nothing: its manifest-only
        // folder is removed on recovery, not rewritten.
        stale.state = .created
        try stale.write(to: folder.appendingPathComponent("manifest.json"))
        TakeEngine.recoverStaleManifests(in: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        // But a `created` folder that holds a file is left alone (rewritten
        // incomplete): the guard never deletes anything but a manifest.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stale.write(to: folder.appendingPathComponent("manifest.json"))
        try Data("frame".utf8).write(to: folder.appendingPathComponent("camera.mov"))
        TakeEngine.recoverStaleManifests(in: root)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(
            try Manifest.decode(Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                .state == .incomplete)
    }

    @Test("Neither create nor supersede touches disk until start")
    func prepareWritesNothing() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let first = try await w.engine.create(.init(name: "first")).take
        let second = try await w.engine.create(.init(name: "second")).take
        // Nothing was written for either prepared take.
        #expect(
            !FileManager.default.fileExists(
                atPath: w.root.appendingPathComponent(first.destination).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: w.root.appendingPathComponent(second.destination).path))
        // Only start materialises the surviving one.
        _ = try await w.engine.start(second.id)
        #expect(try manifestOnDisk(w, second.destination).state == .recording)
        _ = try await w.engine.stop(second.id)
    }

    @Test("A recorded take's folder survives a later create")
    func recordedFolderSurvivesLaterCreate() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let recorded = try await w.engine.record(.init(name: "keep")).take
        _ = try await w.engine.stop(recorded.id)
        // A new take is created afterwards; the recorded one is untouched.
        _ = try await w.engine.create(.init(name: "next")).take
        #expect(
            FileManager.default.fileExists(
                atPath: w.root.appendingPathComponent(recorded.destination).path))
        #expect(try manifestOnDisk(w, recorded.destination).state == .complete)
    }

    @Test("shutdown discards a prepared take that never reached disk")
    func shutdownDiscardsPrepared() async throws {
        let w = try await world()
        try await w.registry.arm("camera:fake")
        let take = try await w.engine.create(.init()).take
        let folder = w.root.appendingPathComponent(take.destination)
        // §1: a prepared take is in memory only — nothing on disk before or
        // after shutdown; only the final event marks it removed.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await w.engine.shutdown()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await w.engine.activeManifest == nil)
        let event = try #require(w.manifests.withLock { $0 }.last { $0.id == take.id })
        #expect(event.removed == true && event.reason == "daemon stopped before start")
    }

    @Test("Manifest JSON round-trips with ISO 8601 UTC dates and sorted keys")
    func manifestJSON() throws {
        let m = Manifest(
            id: "x", name: nil, state: .created, reason: nil,
            created: Date(timeIntervalSince1970: 1_800_000_000.5),
            started: nil, stopped: nil, outputRoot: "/r", destination: "takes/x", version: "0.1.0",
            machine: .init(hostname: "h", machineId: "m"), streams: [], markers: [],
            settings: .init(codec: .hevc, expectedDuration: nil))
        let data = try m.encoded()
        #expect(
            String(decoding: data, as: UTF8.self).contains(
                "\"created\" : \"2027-01-15T08:00:00.500Z\""))
        #expect(try Manifest.decode(data) == m)
    }

    @Test("API responses stamp dates with milliseconds, not truncated to the second")
    func apiDatesHaveMilliseconds() throws {
        // Response.encoder is what the API and the `take` event use; it must
        // match the on-disk manifest's fractional seconds so a marker t plus
        // `started` lands on a frame (Ptero saw seconds-only over the API).
        let m = Manifest(
            id: "x", name: nil, state: .recording, reason: nil,
            created: Date(timeIntervalSince1970: 1_800_000_000.5),
            started: Date(timeIntervalSince1970: 1_800_000_000.5), stopped: nil, outputRoot: "/r",
            destination: "takes/x", version: "0.1.0", machine: .init(hostname: "h", machineId: "m"),
            streams: [], markers: [], settings: .init(codec: .hevc, expectedDuration: nil))
        let body = String(decoding: Response(json: m).body, as: UTF8.self)
        #expect(body.contains(#""created":"2027-01-15T08:00:00.500Z""#))
        #expect(body.contains(#""started":"2027-01-15T08:00:00.500Z""#))
        #expect(!body.contains(#""created":"2027-01-15T08:00:00Z""#), "not truncated to the second")
    }

    @Test("Names become file-safe slugs")
    func slugs() {
        #expect(TakeEngine.slugify("Elgato 4K X") == "elgato-4k-x")
        #expect(TakeEngine.slugify("  Scarlett 2i2 USB ") == "scarlett-2i2-usb")
        #expect(TakeEngine.slugify("Café — Ep. 12!") == "cafe-ep-12")
        #expect(TakeEngine.slugify("???") == "")
    }
}
