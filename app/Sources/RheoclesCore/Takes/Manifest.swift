import Foundation

/// The manifest is the take (spec §2, §9). Everything downstream consumes
/// this; nothing guesses from a folder listing.
///
/// Written at create and rewritten atomically on every state change, so at
/// any instant `manifest.json` is either the previous complete version or
/// the next. Paths are relative to the take folder; the take folder is
/// relative to the output root recorded here.
public struct Manifest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case created, recording, complete, incomplete
    }

    public enum Codec: String, Codable, Sendable {
        case hevc, prores
    }

    public struct Machine: Codable, Sendable, Equatable {
        public var hostname: String
        public var machineId: String
    }

    public struct Settings: Codable, Sendable, Equatable {
        public var codec: Codec
        /// Seconds the client said the take would run, if it said.
        public var expectedDuration: Double?
    }

    /// The single-file combined artefact.
    public struct Combined: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case pending, complete, failed
        }
        /// Relative to the take folder — always `combined.mov`.
        public var path: String
        public var state: State
        /// Present only when `failed`.
        public var reason: String?

        public init(path: String, state: State, reason: String? = nil) {
            self.path = path
            self.state = state
            self.reason = reason
        }
    }

    public struct Marker: Codable, Sendable, Equatable {
        /// Seconds from the cue. Rheocles knows when; the client knows what.
        public var t: Double
        public var label: String
    }

    public struct StreamEvent: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case join, leave
        }
        public var t: Double
        public var type: Kind
    }

    /// One armed stream's file.
    public struct Stream: Codable, Sendable, Equatable {
        public var id: String
        public var kind: StreamInfo.Kind
        public var name: String
        public var model: String
        /// Relative to the take folder.
        public var path: String
        /// `hevc`, `prores`, or `pcm_s24le` for audio.
        public var codec: String
        /// The format at the time of writing.
        public var format: StreamInfo.Capabilities
        public var started: Date?
        public var stopped: Date?
        /// Time-of-day timecode of the first written frame (video) or the
        /// BWF time reference as timecode (audio). Absent until written.
        public var timecode: String?
        /// Audio only: the BWF `TimeReference`, samples since local midnight
        /// at the first sample. The sample-exact form of `timecode`.
        public var timeReference: Int?
        public var framesWritten: Int
        /// Frames the encoder was not ready for. Absent when zero.
        public var framesDropped: Int?
        /// Frames × frame duration versus host elapsed, in seconds. Positive
        /// means the file runs long. Absent until measured.
        public var drift: Double?
        /// The true incoming rate, delivered frames over the host span — a
        /// 59.94 source behind a "60" card reads 59.94. Video only; absent for
        /// audio and until measured.
        public var measuredFrameRate: Double?
        public var events: [StreamEvent]
        /// Why the file is not what was asked for, when it is not.
        public var error: String?
    }

    public var id: String
    public var name: String?
    public var state: State
    /// Present only when `incomplete`.
    public var reason: String?
    public var created: Date
    public var started: Date?
    public var stopped: Date?
    /// Absolute, as it was when the take was created.
    public var outputRoot: String
    /// Take folder, relative to the output root.
    public var destination: String
    public var version: String
    public var machine: Machine
    public var streams: [Stream]
    public var markers: [Marker]
    public var settings: Settings
    /// The optional single-file artefact (spec "Loom mode"): a passthrough mux
    /// of the video and every audio stream into one MOV. A bonus — its state
    /// is independent of the take's, and a failed combine never marks the take
    /// incomplete. Absent unless the take was created with `combine`.
    public var combined: Combined?
    /// Set on the final `take` event for a take whose folder was removed
    /// because it recorded nothing — superseded before start, or still
    /// `created` when the daemon stopped. The take stays `incomplete` with the
    /// reason; `removed` tells a client holding it to drop it from Recent.
    /// Never written to disk (the folder is gone); absent everywhere else.
    public var removed: Bool?

    /// Seconds from the cue for a host time, to the millisecond, or nil
    /// before the cue.
    public func offset(of date: Date) -> Double? {
        started.map { (date.timeIntervalSince($0) * 1000).rounded() / 1000 }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Manifest.iso8601.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = Manifest.iso8601.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "not an ISO 8601 date: \(s)"))
            }
            return date
        }
        return d
    }()

    /// UTC with milliseconds: the manifest is the authoritative clock across
    /// midnight (spec §8) and a second is too coarse for a cue.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Manifest {
        try decoder.decode(Manifest.self, from: data)
    }

    /// Temp file + rename in the same directory: readers see the old file
    /// or the new one, never a torn one.
    public func write(to url: URL) throws {
        let data = try encoded()
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".manifest-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
