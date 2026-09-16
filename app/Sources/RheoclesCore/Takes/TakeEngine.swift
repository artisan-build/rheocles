import Foundation

/// Takes: create, start, stop, and the one-click record (spec §7).
///
/// One active take at a time. `create` snapshots the armed set, reserves
/// paths, pre-flights the disk and writes the manifest — nothing records.
/// `start` is the cue: every armed stream's writer starts on frames that
/// are already flowing. `stop` finalizes every file and the manifest.
public actor TakeEngine {
    public struct CreateRequest: Codable, Sendable {
        public var name: String?
        /// Take folder, relative to the output root. Default
        /// `takes/<yyyy-MM-dd>/<HHmmss>[-<name>]`.
        public var destination: String?
        /// File name per stream id, relative to the take folder. Defaults
        /// derive from the stream's name.
        public var files: [String: String]?
        public var codec: Manifest.Codec?
        /// Seconds, for the disk pre-flight. Default 30 minutes.
        public var expectedDuration: Double?
        /// Reuse a destination that already exists. Never silently suffixed.
        public var overwrite: Bool?
        /// Also write a single combined.mov (passthrough mux). Defaults to
        /// `settings.combine`. Only valid with at most one video stream armed.
        public var combine: Bool?

        public init(
            name: String? = nil, destination: String? = nil, files: [String: String]? = nil,
            codec: Manifest.Codec? = nil, expectedDuration: Double? = nil, overwrite: Bool? = nil,
            combine: Bool? = nil
        ) {
            self.name = name
            self.destination = destination
            self.files = files
            self.codec = codec
            self.expectedDuration = expectedDuration
            self.overwrite = overwrite
            self.combine = combine
        }
    }

    /// `POST /takes` and `POST /record` answer the manifest plus anything
    /// the pre-flight wanted to say.
    public struct Created: Codable, Sendable, Equatable {
        public var take: Manifest
        public var warnings: [String]
    }

    /// One line of `GET /takes`.
    public struct Summary: Codable, Sendable, Equatable {
        public var id: String
        public var name: String?
        public var state: Manifest.State
        public var created: Date
        public var destination: String
        public var streams: Int
        /// The combined file, when the take has one — so a list can show the
        /// single-file line and its Open in Finder without a per-row fetch.
        public var combined: Manifest.Combined?
    }

    private struct Live {
        var manifest: Manifest
        var folder: URL
        var writers: [String: any Writer] = [:]
        var combine = false
    }

    private let registry: Registry
    private let rootProvider: @Sendable () -> URL
    private var root: URL { rootProvider() }
    private let defaultCodec: @Sendable () -> Manifest.Codec
    private let defaultCombine: @Sendable () -> Bool
    private let writerFactory: any WriterFactory
    private let machine: Manifest.Machine
    private let freeBytes: @Sendable (URL) -> Int64?
    private let onChange: @Sendable (Manifest) -> Void
    private let onEvent: @Sendable (String) -> Void
    private var live: Live?
    private var statusTask: Task<Void, Never>?
    /// Per-stream frame count and how many ticks it has been unchanged, for
    /// stall detection, plus whether we have already announced the stall.
    private var frameWatch: [String: (count: Int, stuck: Int, stalled: Bool)] = [:]
    /// Per-stream (delivered, dropped) samples over the last ~10 s, and whether
    /// an `overloaded` warning is currently raised, for the drop-rate watch.
    private var dropWatch: [String: (samples: [(delivered: Int, dropped: Int)], flagged: Bool)] =
        [:]
    /// Finished takes this process has seen, newest first, so `GET /takes`
    /// does not have to touch the disk for the common case.
    private var recent: [Manifest] = []
    /// The in-flight combine mux per take, so `shutdown` can wait for it, and
    /// a generation counter so a superseded run's result is discarded.
    private var combineTasks: [String: Task<Void, Never>] = [:]
    private var combineGeneration: [String: Int] = [:]

    public static let defaultExpectedDuration: Double = 30 * 60

    public init(
        registry: Registry, outputRoot: @escaping @Sendable () -> URL,
        writerFactory: any WriterFactory,
        machine: Manifest.Machine,
        defaultCodec: @escaping @Sendable () -> Manifest.Codec = { .hevc },
        defaultCombine: @escaping @Sendable () -> Bool = { false },
        freeBytes: @escaping @Sendable (URL) -> Int64? = { Discovery.freeBytes(at: $0) },
        onChange: @escaping @Sendable (Manifest) -> Void = { _ in },
        onEvent: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.registry = registry
        self.rootProvider = outputRoot
        self.defaultCodec = defaultCodec
        self.defaultCombine = defaultCombine
        self.writerFactory = writerFactory
        self.machine = machine
        self.freeBytes = freeBytes
        self.onChange = onChange
        self.onEvent = onEvent
    }

    // MARK: Live status

    /// Four times a second while recording: a `levels` event with each
    /// writing stream's peak dBFS (audio), frames written and drift, and a
    /// `stalled` event the moment a stream stops delivering.
    private func startStatusTicker() {
        guard statusTask == nil else { return }
        frameWatch = [:]
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopStatusTicker() {
        statusTask?.cancel()
        statusTask = nil
        frameWatch = [:]
        dropWatch = [:]
    }

    private func tick() async {
        guard let current = live, current.manifest.state == .recording else { return }
        var statuses: [StreamStatus] = []
        for (id, writer) in current.writers {
            let droppedSoFar = writer.framesDropped
            let paddingOff = (writer as? VideoWriter)?.paddingSuspended == true ? true : nil
            statuses.append(
                StreamStatus(
                    id: id, levelDb: writer.sampleLevelDb(), framesWritten: writer.framesWritten,
                    drift: writer.drift,
                    framesDropped: droppedSoFar > 0 ? droppedSoFar : nil,
                    measuredFrameRate: writer.measuredFrameRate, paddingOff: paddingOff))
            // Stall: framesSeen on the live session has not advanced.
            let seen = await registry.session(for: id)?.framesSeen ?? writer.framesWritten
            var watch = frameWatch[id] ?? (count: seen, stuck: 0, stalled: false)
            if seen == watch.count {
                watch.stuck += 1
                if watch.stuck >= 8, !watch.stalled {  // ~2 s
                    watch.stalled = true
                    if let info = await registry.stream(id) { onEvent(Event.stalled(info)) }
                }
            } else {
                watch = (count: seen, stuck: 0, stalled: false)
            }
            frameWatch[id] = watch

            // Overload: more than 5% of the last ~10 s of delivered frames
            // dropped. Raised once on crossing, cleared with hysteresis at 2.5%
            // so it does not flap. A ~40-sample window at 4 Hz is 10 s.
            var drop = dropWatch[id] ?? (samples: [], flagged: false)
            drop.samples.append((delivered: writer.framesDelivered, dropped: droppedSoFar))
            if drop.samples.count > 41 { drop.samples.removeFirst() }
            if drop.samples.count >= 40, let base = drop.samples.first {
                let dDelivered = writer.framesDelivered - base.delivered
                let dDropped = droppedSoFar - base.dropped
                let rate = dDelivered > 0 ? Double(dDropped) / Double(dDelivered) : 0
                if rate > 0.05, !drop.flagged {
                    drop.flagged = true
                    if let info = await registry.stream(id) {
                        onEvent(Event.overloaded(info, dropRate: (rate * 100).rounded() / 100))
                    }
                } else if rate < 0.025, drop.flagged {
                    drop.flagged = false
                }
            }
            dropWatch[id] = drop
        }
        if !statuses.isEmpty {
            onEvent(
                Event.levels(
                    takeID: current.manifest.id, streams: statuses.sorted { $0.id < $1.id }))
        }
    }

    /// Finalise the active take for a clean daemon shutdown (SIGINT/SIGTERM):
    /// every writer closes, the manifest is written `incomplete` with reason
    /// "daemon stopped", so an interrupted take is never left saying
    /// `recording` on disk. Idempotent.
    public func shutdown() async {
        stopStatusTicker()
        // Finalise the live take *first*: SIGTERM must always close its writers
        // and write `daemon stopped` within the budget, so a long in-flight
        // combine of an earlier take cannot delay finalising the one still
        // recording.
        if var current = live {
            switch current.manifest.state {
            case .recording:
                let end = Self.now()
                for index in current.manifest.streams.indices {
                    guard let writer = current.writers[current.manifest.streams[index].id] else {
                        continue
                    }
                    if let session = await registry.session(
                        for: current.manifest.streams[index].id)
                    {
                        session.sink = nil
                    }
                    finalize(
                        &current.manifest.streams[index], writer: writer, at: end,
                        cueOffset: current.manifest.offset(of: end) ?? 0)
                    _ = await writer.finish()
                }
                current.writers.removeAll()
                current.manifest.stopped = end
                current.manifest.state = .incomplete
                current.manifest.reason = "daemon stopped"
            case .created:
                current.manifest.state = .incomplete
                current.manifest.reason = "daemon stopped before start"
                current.manifest.removed = true
            default:
                break
            }
            // A take still `created` at shutdown never started, so it never
            // materialised on disk (§1): nothing to write or remove, just the
            // final event. A recording take is finalised to disk as before.
            if current.manifest.started != nil {
                Self.writeManifest(current.manifest, folder: current.folder)
                try? FileManager.default.removeItem(
                    at: current.folder.appendingPathComponent(Self.reserveName))
            }
            onChange(current.manifest)
            live = nil
        }
        // Then let any in-flight combine finish (it only needs the process
        // alive) so we do not leave a `pending` beside a half-written file.
        // Snapshot first — each task clears its own entry as it lands; a
        // SIGKILL past Server.stop's budget is caught by recovery on launch.
        for task in Array(combineTasks.values) { await task.value }
        combineTasks.removeAll()
    }

    /// On launch, any manifest left `recording` or `created` is from a daemon
    /// that died without finalising it (a crash, a SIGKILL). Rewrite each to
    /// `incomplete` reason "daemon died", so a recovered take is never served
    /// as if it were live — a front end would get 409 trying to stop it.
    /// Plain file I/O, safe to run synchronously before the actor exists.
    public static func recoverStaleManifests(in root: URL) {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        for case let url as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "manifest.json", let data = try? Data(contentsOf: url),
                var manifest = try? Manifest.decode(data)
            else { continue }
            let folder = url.deletingLastPathComponent()
            // A take still `created` on launch never started; if its folder
            // holds only the manifest it recorded nothing, so remove it rather
            // than leave an empty "daemon died" folder behind. (No event: this
            // runs before any client connects.)
            if manifest.state == .created, Self.recordedNothing(in: folder) {
                try? fm.removeItem(at: folder)
                continue
            }
            var changed = false
            if manifest.state == .recording || manifest.state == .created {
                manifest.state = .incomplete
                manifest.reason = "daemon died"
                changed = true
            }
            // A combine still `pending` on launch means the daemon died mid-mux:
            // the combined.mov (if any) is truncated. Fail it and remove the
            // partial file, so a front end's "pending" spinner never hangs.
            if manifest.combined?.state == .pending {
                let path = manifest.combined?.path ?? "combined.mov"
                try? fm.removeItem(
                    at: url.deletingLastPathComponent().appendingPathComponent(path))
                manifest.combined = Manifest.Combined(
                    path: path, state: .failed, reason: "daemon died")
                changed = true
            }
            guard changed else { continue }
            try? manifest.write(to: url)
            try? fm.removeItem(
                at: url.deletingLastPathComponent().appendingPathComponent(reserveName))
        }
    }

    /// The manifest of the active take, if any, refreshed with each writer's
    /// current frame count, drift and timecode — the manifest is live while
    /// recording (spec §11), not frozen at the cue.
    public var activeManifest: Manifest? { live.map(decorated) }

    /// The live manifest with each recording stream's current stats folded in.
    private func decorated(_ live: Live) -> Manifest {
        var manifest = live.manifest
        for index in manifest.streams.indices {
            guard let writer = live.writers[manifest.streams[index].id] else { continue }
            manifest.streams[index].framesWritten = writer.framesWritten
            manifest.streams[index].framesDropped =
                writer.framesDropped > 0 ? writer.framesDropped : nil
            manifest.streams[index].drift = writer.drift
            manifest.streams[index].measuredFrameRate = writer.measuredFrameRate
            if manifest.streams[index].timecode == nil {
                manifest.streams[index].timecode = writer.timecode
            }
            manifest.streams[index].timeReference =
                manifest.streams[index].timeReference ?? (writer as? AudioWriter)?.bwfTimeReference
        }
        return manifest
    }

    // MARK: Create

    public func create(_ request: CreateRequest) async throws -> Created {
        if let current = live {
            switch current.manifest.state {
            case .recording:
                throw APIError(
                    status: 409, code: "take_active",
                    message: "take \(current.manifest.id) is recording; stop it first")
            case .created:
                // A prepared take lives in memory only until start (§1), so
                // superseding it touches nothing on disk — a paired recorder
                // re-creates its take on every arm change, and none of those
                // now reach the filesystem. Emit the final event so a client
                // holding it drops it from its list.
                var superseded = current.manifest
                superseded.state = .incomplete
                superseded.reason = "superseded before start"
                superseded.combined = nil
                superseded.removed = true
                onChange(superseded)
                live = nil
            default:
                live = nil
            }
        }

        let armed = await registry.streams().filter(\.armed)
        guard !armed.isEmpty else {
            throw APIError.badRequest("no armed streams; arm something first")
        }

        let now = Self.now()
        let destination = try Self.destination(request.destination, name: request.name, at: now)
        let folder = root.appendingPathComponent(destination, isDirectory: true)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            let occupied =
                !isDirectory.boolValue
                || !((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty
            if occupied && request.overwrite != true {
                throw APIError.conflict(
                    "destination exists: \(destination); pass overwrite to reuse it")
            }
        }

        let files = try Self.files(for: armed, requested: request.files)
        // The client can pick a codec per take; otherwise the daemon's
        // default (settings.codec) applies — not a hardcoded HEVC.
        let codec = request.codec ?? defaultCodec()
        var warnings: [String] = []
        var combine = request.combine ?? defaultCombine()
        // Passthrough mux allows at most one video stream (spec §2). An
        // explicit `combine: true` with more is an error; but when combine was
        // only the *default* (settings.combine) and the request never asked
        // for it, drop it (with a warning) rather than refuse a plain record —
        // the front end hides the checkbox in that state, so it never sent one.
        if combine, armed.filter({ Self.isVideo($0.kind) }).count > 1 {
            let videos = armed.filter { Self.isVideo($0.kind) }.count
            if request.combine == true {
                throw APIError(
                    status: 400, code: "combine_requires_single_video",
                    message: "combine allows at most one video stream; \(videos) are armed")
            }
            combine = false
            warnings.append(
                "combine is on by default but \(videos) video streams are armed; recording without a combined file"
            )
        }
        let expected = request.expectedDuration ?? Self.defaultExpectedDuration

        // Disk pre-flight (spec §7): refuse if short, warn if tight.
        let estimate = armed.reduce(Int64(0)) {
            $0 + Self.estimateBytes(for: $1, codec: codec, seconds: expected)
        }
        if let free = freeBytes(root) {
            if free < estimate {
                throw APIError(
                    status: 507, code: "insufficient_storage",
                    message:
                        "about \(Self.gb(estimate)) GB needed for \(Int(expected)) s, \(Self.gb(free)) GB free"
                )
            }
            if free < estimate * 2 {
                warnings.append(
                    "disk is tight: about \(Self.gb(estimate)) GB needed, \(Self.gb(free)) GB free")
            }
        } else {
            warnings.append("free space could not be measured")
        }

        let manifest = Manifest(
            id: Self.makeID(at: now), name: request.name, state: .created, reason: nil,
            created: now,
            started: nil, stopped: nil, outputRoot: root.path, destination: destination,
            version: Rheocles.version, machine: machine,
            streams: armed.map { stream in
                Manifest.Stream(
                    id: stream.id, kind: stream.kind, name: stream.name, model: stream.model,
                    path: files[stream.id] ?? "",
                    codec: Self.codecName(for: stream.kind, codec: codec),
                    format: stream.active ?? stream.capabilities, started: nil, stopped: nil,
                    timecode: nil, timeReference: nil,
                    framesWritten: 0, drift: nil, events: [], error: nil)
            },
            markers: [], settings: .init(codec: codec, expectedDuration: request.expectedDuration),
            combined: combine ? Manifest.Combined(path: "combined.mov", state: .pending) : nil)

        // Nothing on disk yet (§1): a `created` take lives in memory — answered
        // from `live` on GET /takes/{id}, the listing and the event. The folder
        // and manifest are written at `start`, before the first writer opens.
        live = Live(manifest: manifest, folder: folder, combine: combine)
        onChange(manifest)
        return Created(take: manifest, warnings: warnings)
    }

    // MARK: Start / stop

    public func start(_ id: String) async throws -> Manifest {
        guard var current = live, current.manifest.id == id else {
            throw try await notActive(id)
        }
        guard current.manifest.state == .created else {
            throw APIError.conflict("take \(id) is \(current.manifest.state.rawValue), not created")
        }
        // Materialise the prepared take on disk now — it lived in memory until
        // this moment (§1). Still "before frame one": the folder, the reserve
        // and the manifest land before any writer opens a file in the folder.
        do {
            try FileManager.default.createDirectory(
                at: current.folder, withIntermediateDirectories: true)
            // A 64 KB reserve, freed if a full disk blocks the final manifest.
            try? Data(count: 64 * 1024).write(
                to: current.folder.appendingPathComponent(Self.reserveName))
            try current.manifest.write(to: current.folder.appendingPathComponent("manifest.json"))
        } catch {
            throw APIError(
                status: 500, code: "write_failed",
                message: "could not create \(current.manifest.destination): \(error)")
        }
        let cue = Self.now()
        current.manifest.started = cue
        current.manifest.state = .recording
        for index in current.manifest.streams.indices {
            let entry = current.manifest.streams[index]
            guard let session = await registry.session(for: entry.id) else {
                current.manifest.streams[index].error = "not armed at the cue"
                continue
            }
            do {
                let writer = try writerFactory.makeWriter(
                    for: session.info, active: session.active,
                    codec: current.manifest.settings.codec,
                    url: current.folder.appendingPathComponent(entry.path))
                current.writers[entry.id] = writer
                session.sink = writer
                current.manifest.streams[index].started = cue
                current.manifest.streams[index].events.append(.init(t: 0, type: .join))
            } catch {
                current.manifest.streams[index].error = "writer failed to start: \(error)"
            }
        }
        live = current
        Self.writeManifest(current.manifest, folder: current.folder)
        onChange(current.manifest)
        startStatusTicker()
        return current.manifest
    }

    public func stop(_ id: String) async throws -> Manifest {
        stopStatusTicker()
        guard var current = live, current.manifest.id == id else {
            throw try await notActive(id)
        }
        guard current.manifest.state == .recording else {
            throw APIError.conflict(
                "take \(id) is \(current.manifest.state.rawValue), not recording")
        }
        let end = Self.now()
        for index in current.manifest.streams.indices {
            let entry = current.manifest.streams[index]
            guard let writer = current.writers[entry.id] else { continue }
            if let session = await registry.session(for: entry.id) { session.sink = nil }
            finalize(
                &current.manifest.streams[index], writer: writer, at: end,
                cueOffset: current.manifest.offset(of: end) ?? 0)
            if let error = await writer.finish() { current.manifest.streams[index].error = error }
        }
        current.writers.removeAll()
        current.manifest.stopped = end
        let failed = current.manifest.streams.compactMap(\.error)
        if failed.isEmpty {
            current.manifest.state = .complete
        } else {
            current.manifest.state = .incomplete
            current.manifest.reason = failed.joined(separator: "; ")
        }
        Self.writeManifest(current.manifest, folder: current.folder)
        // The take is over; the reserve has done its job.
        try? FileManager.default.removeItem(
            at: current.folder.appendingPathComponent(Self.reserveName))
        live = nil
        recent.insert(current.manifest, at: 0)
        if recent.count > 50 { recent.removeLast() }
        onChange(current.manifest)
        if current.combine {
            startCombine(
                id: current.manifest.id, folder: current.folder, manifest: current.manifest)
        }
        return current.manifest
    }

    /// Start one stream's writer inside a running take (spec §6). Arms the
    /// stream first if it is cold. A stream not in the create snapshot is
    /// added to the manifest and stamped with the time it actually began, so
    /// an editor places it there.
    public func join(_ id: String, stream streamID: String) async throws -> Manifest {
        guard var current = live, current.manifest.id == id else { throw try await notActive(id) }
        guard current.manifest.state == .recording else {
            throw APIError.conflict(
                "take \(id) is \(current.manifest.state.rawValue), not recording")
        }
        if current.writers[streamID] != nil {
            throw APIError.conflict("stream \(streamID) is already recording in take \(id)")
        }
        // The ≤1-video rule holds across the take's life, not just at create:
        // a combine take must not gain a second video by joining one. The
        // kind is in the id (`<kind>:<identifier>`), so refuse before arming.
        if current.combine {
            let joiningKind = StreamInfo.Kind(
                rawValue: String(streamID.split(separator: ":").first ?? ""))
            let joiningIsVideo = joiningKind.map(Self.isVideo) ?? false
            let alreadyHasVideo = current.manifest.streams.contains {
                Self.isVideo($0.kind) && $0.id != streamID
            }
            if joiningIsVideo && alreadyHasVideo {
                throw APIError(
                    status: 400, code: "combine_requires_single_video",
                    message: "combine take \(id) already has a video stream; cannot join another")
            }
        }
        // Arm if needed (join on a cold stream arms it first), then attach.
        let armed = try await registry.arm(streamID)
        guard let session = await registry.session(for: streamID) else {
            throw APIError(
                status: 503, code: "device_unavailable", message: "\(streamID) is not live")
        }
        let now = Self.now()
        let t = current.manifest.offset(of: now) ?? 0
        // A stream already in the snapshot (armed at create but not at the
        // cue, or a late join) keeps its reserved path; a brand-new stream
        // gets a fresh non-colliding name.
        let existingEntry = current.manifest.streams.first(where: { $0.id == streamID })
        let path =
            try existingEntry?.path
            ?? Self.fileName(
                for: armed, requested: nil, used: Set(current.manifest.streams.map(\.path)))
        let writer: any Writer
        do {
            writer = try writerFactory.makeWriter(
                for: armed, active: session.active, codec: current.manifest.settings.codec,
                url: current.folder.appendingPathComponent(path))
        } catch {
            throw APIError(status: 500, code: "write_failed", message: "writer failed: \(error)")
        }
        current.writers[streamID] = writer
        session.sink = writer

        if let index = current.manifest.streams.firstIndex(where: { $0.id == streamID }) {
            current.manifest.streams[index].started = now
            current.manifest.streams[index].error = nil
            current.manifest.streams[index].events.append(.init(t: t, type: .join))
        } else {
            current.manifest.streams.append(
                Manifest.Stream(
                    id: armed.id, kind: armed.kind, name: armed.name, model: armed.model,
                    path: path,
                    codec: Self.codecName(for: armed.kind, codec: current.manifest.settings.codec),
                    format: session.active, started: now, stopped: nil, timecode: nil,
                    timeReference: nil,
                    framesWritten: 0, framesDropped: nil, drift: nil,
                    events: [.init(t: t, type: .join)], error: nil))
        }
        live = current
        persist(current)
        return current.manifest
    }

    /// Finalize one stream's file inside a running take; the stream stays
    /// armed and the take continues for the others (spec §6).
    public func leave(_ id: String, stream streamID: String) async throws -> Manifest {
        guard var current = live, current.manifest.id == id else { throw try await notActive(id) }
        guard current.manifest.state == .recording else {
            throw APIError.conflict(
                "take \(id) is \(current.manifest.state.rawValue), not recording")
        }
        guard let writer = current.writers[streamID],
            let index = current.manifest.streams.firstIndex(where: { $0.id == streamID })
        else {
            throw APIError.conflict("stream \(streamID) is not recording in take \(id)")
        }
        if let session = await registry.session(for: streamID) { session.sink = nil }
        let now = Self.now()
        finalize(
            &current.manifest.streams[index], writer: writer, at: now,
            cueOffset: current.manifest.offset(of: now) ?? 0)
        if let error = await writer.finish() { current.manifest.streams[index].error = error }
        current.writers[streamID] = nil
        live = current
        persist(current)
        return current.manifest
    }

    /// Append a marker at the current cue offset (spec §10). Rheocles knows
    /// when; the client knows what.
    public func addMarker(_ id: String, label: String) async throws -> Manifest {
        guard var current = live, current.manifest.id == id else { throw try await notActive(id) }
        guard current.manifest.state == .recording else {
            throw APIError.conflict(
                "take \(id) is \(current.manifest.state.rawValue), not recording")
        }
        let t = current.manifest.offset(of: Self.now()) ?? 0
        let marker = Manifest.Marker(t: t, label: label)
        current.manifest.markers.append(marker)
        live = current
        persist(current)
        onEvent(Event.marker(takeID: id, marker: marker))
        return current.manifest
    }

    private func persist(_ current: Live) {
        Self.writeManifest(current.manifest, folder: current.folder)
        onChange(current.manifest)
    }

    /// The manifest is the take: it must reach disk truthfully even when a
    /// writer just filled the volume. The atomic temp+rename and the in-place
    /// fallback both need free bytes, and a full disk has none — and the
    /// `incomplete` manifest, carrying error text, is larger than the
    /// `recording` one it replaces. So each take folder holds a small reserve
    /// file, written at create; when a manifest write fails, we free the
    /// reserve and try once more, which is enough for the final state to land.
    static let reserveName = ".manifest.reserve"

    static func writeManifest(_ manifest: Manifest, folder: URL) {
        let url = folder.appendingPathComponent("manifest.json")
        do {
            try manifest.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(reserveName))
            try? manifest.write(to: url)
        }
    }

    /// A take folder that recorded nothing holds only its manifest and the
    /// reserve — no media. Such a folder is safe to remove when the take is
    /// abandoned (superseded before start, or `created` at shutdown/recovery);
    /// a folder with any other file is left untouched, so media is never lost.
    static func recordedNothing(in folder: URL) -> Bool {
        let allowed: Set<String> = ["manifest.json", reserveName]
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: folder.path)
        else { return false }
        return contents.allSatisfy { allowed.contains($0) }
    }

    public func record(_ request: CreateRequest) async throws -> Created {
        var created = try await create(request)
        created.take = try await start(created.take.id)
        return created
    }

    // MARK: Combine

    static func isVideo(_ kind: StreamInfo.Kind) -> Bool {
        kind == .display || kind == .window || kind == .camera
    }

    /// Combine a take after the fact (`POST /takes/{id}/combine`). The take
    /// must not be the live take, must qualify (at most one video), and have
    /// files to combine; an `incomplete` take (one that lost a stream) is
    /// allowed — the streams it did keep are still worth a single file.
    /// Returns the manifest with `combined` pending; the `take` event fires
    /// again when the mux finishes.
    public func combine(_ id: String) async throws -> Manifest {
        if let current = live, current.manifest.id == id {
            throw APIError.conflict("take \(id) is still recording")
        }
        var manifest = try await self.manifest(id)
        // Idempotent while a mux is actually running *in this process*: two
        // clients (or a double click) never race two exports to the same file.
        // A persisted `pending` with no task behind it is stale — a combine the
        // launch-time recovery sweep never saw (an external root that mounted
        // late, a root switched in via PATCH) — so we fall through and re-run
        // rather than answer a pending that will never complete.
        if combineTasks[id] != nil { return manifest }
        if manifest.streams.filter({ Self.isVideo($0.kind) }).count > 1 {
            throw APIError(
                status: 400, code: "combine_requires_single_video",
                message: "combine allows at most one video stream")
        }
        let folder = URL(fileURLWithPath: manifest.outputRoot).appendingPathComponent(
            manifest.destination)
        guard Self.combineInputs(manifest, folder: folder).hasFiles else {
            throw APIError(
                status: 400, code: "nothing_to_combine", message: "the take has no files to combine"
            )
        }
        manifest.combined = Manifest.Combined(path: "combined.mov", state: .pending)
        store(manifest)
        // Persist `pending` before the mux runs: a daemon killed mid-export is
        // then recoverable — `recoverStaleManifests` turns a leftover pending
        // into `failed` and removes the truncated file on next launch.
        Self.writeManifest(manifest, folder: folder)
        onChange(manifest)
        startCombine(id: id, folder: folder, manifest: manifest)
        return manifest
    }

    private func startCombine(id: String, folder: URL, manifest: Manifest) {
        let generation = (combineGeneration[id] ?? 0) + 1
        combineGeneration[id] = generation
        let inputs = Self.combineInputs(manifest, folder: folder)
        combineTasks[id] = Task { [weak self] in
            let result = await Combiner.combine(
                in: folder, videoPath: inputs.video, audioPaths: inputs.audio)
            await self?.applyCombine(id: id, generation: generation, result)
        }
    }

    private func applyCombine(id: String, generation: Int, _ combined: Manifest.Combined) {
        // Drop a result from a superseded run: only the latest combine for
        // this take may land, so a stale Task can never overwrite a newer one.
        guard combineGeneration[id] == generation else { return }
        combineTasks[id] = nil
        if var manifest = recent.first(where: { $0.id == id }) ?? (try? diskManifest(id)) {
            manifest.combined = combined
            store(manifest)
            let folder = URL(fileURLWithPath: manifest.outputRoot).appendingPathComponent(
                manifest.destination)
            Self.writeManifest(manifest, folder: folder)
            onChange(manifest)
        }
    }

    /// The video path (at most one) and audio paths whose files actually
    /// exist on disk, for the mux.
    static func combineInputs(_ manifest: Manifest, folder: URL) -> (
        video: String?, audio: [String], hasFiles: Bool
    ) {
        func exists(_ path: String) -> Bool {
            !path.isEmpty
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
        }
        let video = manifest.streams.first { isVideo($0.kind) && exists($0.path) }?.path
        let audio = manifest.streams.filter { !isVideo($0.kind) && exists($0.path) }.map(\.path)
        return (video, audio, video != nil || !audio.isEmpty)
    }

    private func store(_ manifest: Manifest) {
        if let index = recent.firstIndex(where: { $0.id == manifest.id }) {
            recent[index] = manifest
        } else {
            recent.insert(manifest, at: 0)
        }
    }

    private func diskManifest(_ id: String) throws -> Manifest {
        guard let found = scanDisk().first(where: { $0.id == id }) else {
            throw APIError.notFound("no such take: \(id)")
        }
        return found
    }

    // MARK: Read

    public func manifest(_ id: String) async throws -> Manifest {
        if let current = live, current.manifest.id == id { return decorated(current) }
        if let past = recent.first(where: { $0.id == id }) { return past }
        if let onDisk = scanDisk().first(where: { $0.id == id }) { return onDisk }
        throw APIError.notFound("no such take: \(id)")
    }

    /// Recent takes, newest first: the active one, then what this process
    /// finished, then whatever the output root holds.
    public func list() -> [Summary] {
        var seen = Set<String>()
        var all: [Manifest] = []
        for manifest in [live?.manifest].compactMap({ $0 }) + recent + scanDisk()
        where !seen.contains(manifest.id) {
            seen.insert(manifest.id)
            all.append(manifest)
        }
        return all.sorted { $0.created > $1.created }.prefix(50).map {
            Summary(
                id: $0.id, name: $0.name, state: $0.state, created: $0.created,
                destination: $0.destination, streams: $0.streams.count, combined: $0.combined)
        }
    }

    private func notActive(_ id: String) async throws -> APIError {
        if (try? await manifest(id)) != nil {
            return APIError.conflict("take \(id) is not the active take")
        }
        return APIError.notFound("no such take: \(id)")
    }

    /// Every manifest under the output root, a few levels deep.
    private func scanDisk() -> [Manifest] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Manifest] = []
        for case let url as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "manifest.json", let data = try? Data(contentsOf: url),
                let manifest = try? Manifest.decode(data)
            else { continue }
            found.append(manifest)
        }
        return found
    }

    /// Fill a manifest stream from its writer and append a leave event. The
    /// writer's async finish() runs after, since it can block on the encoder.
    private func finalize(
        _ stream: inout Manifest.Stream, writer: any Writer, at end: Date, cueOffset: Double
    ) {
        stream.stopped = end
        stream.timecode = writer.timecode
        stream.timeReference = (writer as? AudioWriter)?.bwfTimeReference
        stream.framesWritten = writer.framesWritten
        stream.framesDropped = writer.framesDropped > 0 ? writer.framesDropped : nil
        stream.drift = writer.drift
        stream.measuredFrameRate = writer.measuredFrameRate
        if stream.events.last?.type != .leave {
            stream.events.append(.init(t: cueOffset, type: .leave))
        }
    }

    // MARK: Naming and sizing

    /// Host time to the millisecond — the manifest's own precision, so what
    /// is in memory is exactly what is on disk.
    static func now() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func makeID(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let random = (0..<4).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! }
        return f.string(from: date) + "-" + String(random)
    }

    /// A relative path that stays inside the root.
    static func destination(_ requested: String?, name: String?, at date: Date) throws -> String {
        if let requested {
            let trimmed = requested.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
                !trimmed.split(separator: "/").contains("..")
            else {
                throw APIError.badRequest(
                    "destination must be a relative path inside the output root")
            }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'/'HHmmss"
        let slug = name.map(slugify).flatMap { $0.isEmpty ? nil : "-" + $0 } ?? ""
        return "takes/" + f.string(from: date) + slug
    }

    static func files(
        for streams: [StreamInfo], requested: [String: String]?, existing: Set<String> = []
    ) throws -> [String: String] {
        var files: [String: String] = [:]
        var used = existing
        for stream in streams where files[stream.id] == nil {
            let name = try fileName(for: stream, requested: requested?[stream.id], used: used)
            used.insert(name)
            files[stream.id] = name
        }
        return files
    }

    /// One stream's file name, avoiding `used`.
    static func fileName(for stream: StreamInfo, requested: String?, used: Set<String>) throws
        -> String
    {
        let ext = stream.kind == .microphone || stream.kind == .systemAudio ? "wav" : "mov"
        if let asked = requested {
            guard !asked.hasPrefix("/"), !asked.split(separator: "/").contains("..") else {
                throw APIError.badRequest(
                    "file for \(stream.id) must be a relative path inside the take folder")
            }
            guard !used.contains(asked) else {
                throw APIError.badRequest("two streams cannot share the file \(asked)")
            }
            return asked
        }
        let base = stream.kind == .window ? "window-" + slugify(stream.model) : slugify(stream.name)
        let stem = base.isEmpty ? stream.kind.rawValue : base
        var name = stem + "." + ext
        var n = 2
        while used.contains(name) {
            name = stem + "-\(n)." + ext
            n += 1
        }
        return name
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var dash = false
        for c in lowered {
            if c.isLetter || c.isNumber {
                out.append(c)
                dash = false
            } else if !dash && !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    static func codecName(for kind: StreamInfo.Kind, codec: Manifest.Codec) -> String {
        switch kind {
        case .microphone, .systemAudio: "pcm_s24le"
        default: codec.rawValue
        }
    }

    /// Bits per pixel per frame: HEVC 0.15 (the measured transparent tier,
    /// docs/CAPTURE.md), ProRes 422 ≈ 2.4 (147 Mb/s at 1080p30).
    static func estimateBytes(for stream: StreamInfo, codec: Manifest.Codec, seconds: Double)
        -> Int64
    {
        let caps = stream.active ?? stream.capabilities
        var bitsPerSecond = 0.0
        if let video = caps.video {
            let pixelsPerSecond = Double(video.width * video.height) * min(video.maxFrameRate, 60)
            bitsPerSecond += pixelsPerSecond * (codec == .prores ? 2.4 : 0.15)
        }
        if let audio = caps.audio {
            bitsPerSecond += audio.sampleRate * 24 * Double(audio.channels)
        }
        return Int64(bitsPerSecond / 8 * seconds)
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1e9)
    }
}
