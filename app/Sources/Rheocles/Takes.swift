import Foundation
import RheoclesCore

/// The manifest is the take (spec §9), and Engine's `Manifest` is the
/// contract — the same type the daemon writes to disk and answers on
/// `GET /takes/{id}`, `POST /record` and the `take` event. The popover
/// reads it; nothing here is state the app owns.
typealias Manifest = RheoclesCore.Manifest

extension Manifest {
    var isRecording: Bool { state == .recording }
    var isOver: Bool { state == .complete || state == .incomplete }

    /// Streams still writing: joined and not left.
    var writing: [Stream] { streams.filter { $0.started != nil && $0.stopped == nil } }

    /// Streams that joined after the cue, by position among the take's
    /// streams — what the icon draws as a shorter stroke (BRAND § Mark).
    var lateJoined: Set<Int> {
        guard let cue = started else { return [] }
        return Set(
            streams.enumerated().compactMap { index, stream in
                guard let began = stream.started, began.timeIntervalSince(cue) > 1 else {
                    return nil
                }
                return index
            })
    }

    /// Seconds since the cue, to now or to the stop.
    func elapsed(at now: Date) -> TimeInterval? {
        guard let started else { return nil }
        return (stopped ?? now).timeIntervalSince(started)
    }

    /// Decodes the daemon's dates: UTC ISO 8601 with milliseconds, or
    /// without if a field ever comes back that way.
    static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
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

extension DaemonModel {
    struct RecordBody: Encodable {
        var name: String?
        var codec: Manifest.Codec?
    }

    struct MarkerBody: Encodable {
        var label: String
    }

    /// `POST /takes/{id}/markers` while recording (spec §10): Rheocles
    /// stamps `t` from its own clock; the label is ours and it never reads
    /// it. The manifest is re-read so the count is the daemon's.
    func mark() {
        guard let take, take.isRecording else { return }
        let label = markerLabel.trimmingCharacters(in: .whitespaces)
        let sent = label.isEmpty ? "marker \(take.markers.count + 1)" : label
        markerError = nil
        Task {
            do {
                try await api.post("/takes/\(take.id)/markers", MarkerBody(label: sent))
                Log.info("marker \"\(sent)\" on \(take.id)")
                markerLabel = ""
                await refreshTake(id: take.id)
            } catch {
                markerError = "POST /takes/\(take.id)/markers → \(error)"
            }
        }
    }

    /// Record: create and start in one — the popover's one button (spec §7).
    func record() {
        guard !takeBusy else { return }
        takeBusy = true
        takeError = nil
        let name = takeName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let created: TakeEngine.Created = try await api.post(
                    "/record", RecordBody(name: name.isEmpty ? nil : name, codec: codec),
                    decoder: Manifest.wireDecoder)
                Log.info("recording take \(created.take.id)")
                for warning in created.warnings { Log.info("take warning: \(warning)") }
                take = created.take
                tick(recording: created.take.isRecording)
                await refreshStreams()
            } catch {
                takeError = "POST /record → \(error)"
                Log.info("record failed: \(error)")
            }
            takeBusy = false
        }
    }

    /// Stop the active take.
    func stop() {
        guard let id = take?.id, !takeBusy else { return }
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
            take = try await api.get(
                "/takes/\(id)", as: Manifest.self, decoder: Manifest.wireDecoder)
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
            await refreshTake(id: take.id)
            return
        }
        guard
            let list = try? await api.get(
                "/takes", as: [TakeEngine.Summary].self, decoder: Manifest.wireDecoder)
        else { return }
        if let active = list.first(where: { $0.state == .recording }) {
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
