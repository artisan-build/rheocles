import Foundation
import RheoclesCore

/// A take, as `GET /takes/{id}` serves the manifest.
///
/// Decoded leniently on purpose: the manifest's shape is in the docs
/// (takes-and-the-manifest) and the field names are Engine's to finalise
/// in `openapi.yaml`. Everything the popover needs — id, name, state, the
/// cue time, which streams are writing — is optional here except the id,
/// so a field that moves shows as absent (`··`) rather than as a decode
/// failure that blanks the whole popover.
struct Manifest: Decodable, Equatable {
    struct Take: Decodable, Equatable {
        let id: String
        var name: String?
        var state: String?
        var created: Date?
        var started: Date?
        var stopped: Date?
        var reason: String?
    }

    struct Stream: Decodable, Equatable, Identifiable {
        let id: String
        var kind: String?
        var name: String?
        var path: String?
        var started: Date?
        var stopped: Date?
        var timecode: String?
        var frames: Int?
        var driftMs: Double?
    }

    struct Marker: Decodable, Equatable {
        let t: Double
        let label: String
    }

    var take: Take
    var streams: [Stream]
    var markers: [Marker]

    init(take: Take, streams: [Stream] = [], markers: [Marker] = []) {
        self.take = take
        self.streams = streams
        self.markers = markers
    }

    private enum CodingKeys: String, CodingKey {
        case take, streams, markers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        take = try container.decode(Take.self, forKey: .take)
        streams = try container.decodeIfPresent([Stream].self, forKey: .streams) ?? []
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
    }

    var isRecording: Bool { take.state == "recording" }
    var isOver: Bool { take.state == "complete" || take.state == "incomplete" }

    /// Streams still writing: joined and not left.
    var writing: [Stream] { streams.filter { $0.started != nil && $0.stopped == nil } }

    /// Streams that joined after the cue, by position among the take's
    /// streams — what the icon draws as a shorter stroke (BRAND § Mark).
    var lateJoined: Set<Int> {
        guard let cue = take.started else { return [] }
        return Set(
            streams.enumerated().compactMap { index, stream in
                guard let started = stream.started, started.timeIntervalSince(cue) > 1 else {
                    return nil
                }
                return index
            })
    }

    /// Seconds since the cue, to now or to the stop.
    func elapsed(at now: Date) -> TimeInterval? {
        guard let started = take.started else { return nil }
        return (take.stopped ?? now).timeIntervalSince(started)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // ISO 8601 with fractional seconds, as the manifest writes host
        // times; without fractions if a field ever comes back that way.
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? fractional.parse(raw) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a date: \(raw)"))
        }
        return d
    }()
}

/// What `POST /record` and `POST /takes` answer: the handle, and the state.
/// Paths come along too but the popover reads them from the manifest.
struct TakeHandle: Decodable {
    let id: String
    var state: String?
}

/// `GET /takes`: recent takes. Accepts either a bare array or `{ takes: [] }`
/// until Engine pins the shape.
struct TakeList: Decodable {
    var takes: [Manifest.Take]

    init(from decoder: Decoder) throws {
        if let list = try? [Manifest.Take](from: decoder) {
            takes = list
            return
        }
        struct Wrapped: Decodable {
            let takes: [Manifest.Take]
        }
        takes = try Wrapped(from: decoder).takes
    }
}

extension DaemonModel {
    struct RecordBody: Encodable {
        var name: String?
    }

    /// Record: create and start in one — the popover's one button (spec §7).
    func record() {
        guard !takeBusy else { return }
        takeBusy = true
        takeError = nil
        let name = takeName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let handle: TakeHandle = try await api.post(
                    "/record", RecordBody(name: name.isEmpty ? nil : name))
                Log.info("recording take \(handle.id)")
                await refreshTake(id: handle.id)
            } catch {
                takeError = "POST /record → \(error)"
                Log.info("record failed: \(error)")
            }
            takeBusy = false
        }
    }

    /// Stop the active take.
    func stop() {
        guard let id = take?.take.id, !takeBusy else { return }
        takeBusy = true
        takeError = nil
        Task {
            do {
                try await api.post("/takes/\(id)/stop", EmptyBody())
                Log.info("stopped take \(id)")
                await refreshTake(id: id)
            } catch {
                takeError = "POST /takes/\(id)/stop → \(error)"
                Log.info("stop failed: \(error)")
            }
            takeBusy = false
        }
    }

    struct EmptyBody: Encodable {}

    /// Re-read one take's manifest.
    func refreshTake(id: String) async {
        do {
            take = try await api.get("/takes/\(id)", as: Manifest.self, decoder: Manifest.decoder)
            tick(recording: take?.isRecording == true)
            await refreshStreams()
        } catch {
            takeError = "GET /takes/\(id) → \(error)"
        }
    }

    /// Find a take that is recording — one started by another client, or
    /// one that was running when the app launched. Called from the pulse
    /// until the event stream carries `state`.
    func discoverActiveTake() async {
        if let take, take.isRecording {
            await refreshTake(id: take.take.id)
            return
        }
        guard let list = try? await api.get("/takes", as: TakeList.self, decoder: Manifest.decoder)
        else { return }
        if let active = list.takes.first(where: { $0.state == "recording" }) {
            await refreshTake(id: active.id)
        }
    }
}

extension TimeInterval {
    /// `h:mm:ss` from the cue — what a tape counter says.
    var clock: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
