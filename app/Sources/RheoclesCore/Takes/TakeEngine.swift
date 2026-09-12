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

        public init(
            name: String? = nil, destination: String? = nil, files: [String: String]? = nil,
            codec: Manifest.Codec? = nil, expectedDuration: Double? = nil, overwrite: Bool? = nil
        ) {
            self.name = name
            self.destination = destination
            self.files = files
            self.codec = codec
            self.expectedDuration = expectedDuration
            self.overwrite = overwrite
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
    }

    private struct Live {
        var manifest: Manifest
        var folder: URL
        var writers: [String: any Writer] = [:]
    }

    private let registry: Registry
    private let root: URL
    private let writerFactory: any WriterFactory
    private let machine: Manifest.Machine
    private let freeBytes: @Sendable (URL) -> Int64?
    private let onChange: @Sendable (Manifest) -> Void
    private var live: Live?
    /// Finished takes this process has seen, newest first, so `GET /takes`
    /// does not have to touch the disk for the common case.
    private var recent: [Manifest] = []

    public static let defaultExpectedDuration: Double = 30 * 60

    public init(
        registry: Registry, outputRoot: URL, writerFactory: any WriterFactory,
        machine: Manifest.Machine,
        freeBytes: @escaping @Sendable (URL) -> Int64? = { Discovery.freeBytes(at: $0) },
        onChange: @escaping @Sendable (Manifest) -> Void = { _ in }
    ) {
        self.registry = registry
        self.root = outputRoot
        self.writerFactory = writerFactory
        self.machine = machine
        self.freeBytes = freeBytes
        self.onChange = onChange
    }

    /// The manifest of the active take, if any.
    public var activeManifest: Manifest? { live?.manifest }

    // MARK: Create

    public func create(_ request: CreateRequest) async throws -> Created {
        if let current = live {
            switch current.manifest.state {
            case .recording:
                throw APIError(
                    status: 409, code: "take_active",
                    message: "take \(current.manifest.id) is recording; stop it first")
            case .created:
                // Created but never started: nothing on disk but a manifest.
                // The new take supersedes it rather than blocking forever on
                // a client that changed its mind.
                var superseded = current.manifest
                superseded.state = .incomplete
                superseded.reason = "superseded before start"
                try? superseded.write(to: current.folder.appendingPathComponent("manifest.json"))
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
        let manifestURL = folder.appendingPathComponent("manifest.json")
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
        let codec = request.codec ?? .hevc
        let expected = request.expectedDuration ?? Self.defaultExpectedDuration
        var warnings: [String] = []

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
                    timecode: nil,
                    framesWritten: 0, drift: nil, events: [], error: nil)
            },
            markers: [], settings: .init(codec: codec, expectedDuration: request.expectedDuration))

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try manifest.write(to: manifestURL)
        } catch {
            throw APIError(
                status: 500, code: "write_failed",
                message: "could not create \(destination): \(error)")
        }
        live = Live(manifest: manifest, folder: folder)
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
        try? current.manifest.write(to: current.folder.appendingPathComponent("manifest.json"))
        onChange(current.manifest)
        return current.manifest
    }

    public func stop(_ id: String) async throws -> Manifest {
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
            let error = await writer.finish()
            current.manifest.streams[index].stopped = end
            current.manifest.streams[index].timecode = writer.timecode
            current.manifest.streams[index].framesWritten = writer.framesWritten
            current.manifest.streams[index].drift = writer.drift
            current.manifest.streams[index].error = error
            if let t = current.manifest.offset(of: end) {
                current.manifest.streams[index].events.append(.init(t: t, type: .leave))
            }
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
        try? current.manifest.write(to: current.folder.appendingPathComponent("manifest.json"))
        live = nil
        recent.insert(current.manifest, at: 0)
        if recent.count > 50 { recent.removeLast() }
        onChange(current.manifest)
        return current.manifest
    }

    public func record(_ request: CreateRequest) async throws -> Created {
        var created = try await create(request)
        created.take = try await start(created.take.id)
        return created
    }

    // MARK: Read

    public func manifest(_ id: String) async throws -> Manifest {
        if let current = live, current.manifest.id == id { return current.manifest }
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
                destination: $0.destination, streams: $0.streams.count)
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

    static func files(for streams: [StreamInfo], requested: [String: String]?) throws -> [String:
        String]
    {
        var files: [String: String] = [:]
        var used = Set<String>()
        for stream in streams {
            let ext = stream.kind == .microphone || stream.kind == .systemAudio ? "wav" : "mov"
            var name: String
            if let asked = requested?[stream.id] {
                guard !asked.hasPrefix("/"), !asked.split(separator: "/").contains("..") else {
                    throw APIError.badRequest(
                        "file for \(stream.id) must be a relative path inside the take folder")
                }
                name = asked
            } else {
                let base =
                    stream.kind == .window
                    ? "window-" + slugify(stream.model) : slugify(stream.name)
                name = (base.isEmpty ? stream.kind.rawValue : base) + "." + ext
                var n = 2
                while used.contains(name) {
                    name = (base.isEmpty ? stream.kind.rawValue : base) + "-\(n)." + ext
                    n += 1
                }
            }
            guard !used.contains(name) else {
                throw APIError.badRequest("two streams cannot share the file \(name)")
            }
            used.insert(name)
            files[stream.id] = name
        }
        return files
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

    /// Rough bits per pixel per frame until step 9 measures the tiers:
    /// HEVC high quality ≈ 0.15, ProRes 422 ≈ 2.4 (147 Mb/s at 1080p30).
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
