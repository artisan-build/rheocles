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

/// `manifest.combined` (feature brief §2): the single passthrough file the
/// daemon writes after stop when asked — one video track and every audio
/// stream as its own track. A bonus artefact: its failure never marks the
/// take incomplete.
typealias Combined = Manifest.Combined

extension Manifest.Combined {
    var isPending: Bool { state == .pending }
    var isComplete: Bool { state == .complete }
}

extension Manifest {
    /// "Combine now" qualifies a finished take with no combined file and at
    /// most one video stream (feature brief, addendum).
    var canCombine: Bool {
        isOver && combined == nil && streams.filter { $0.format.video != nil }.count <= 1
    }
}

extension DaemonModel {
    /// `POST /takes/{id}/combine`: the mux after the fact. Answers the
    /// manifest with `combined` pending; completion comes on the `take`
    /// event. The current take, or a recent one — whichever it was.
    func combineNow(_ id: String) {
        takeError = nil
        Task {
            do {
                let manifest = try absorbTake(
                    try await api.postData("/takes/\(id)/combine", EmptyBody()))
                Log.info("combining \(id)")
                place(manifest)
            } catch {
                takeError = "POST /takes/\(id)/combine → \(error)"
            }
        }
    }

    /// Where a manifest that arrived goes: the current take if it is the
    /// same one or is recording; otherwise it is a recent take's detail.
    func place(_ manifest: Manifest) {
        if manifest.isRecording || take?.id == manifest.id || take == nil {
            take = manifest
            tick(recording: manifest.isRecording)
        }
        recentDetail[manifest.id] = manifest
    }

    /// The manifests behind the Recent rows, fetched when the fold opens so
    /// the rows can say whether a take qualifies for Combine now.
    func loadRecentDetail() async {
        for summary in recent.prefix(5) where recentDetail[summary.id] == nil {
            if let data = try? await api.bytes("/takes/\(summary.id)").0,
                let manifest = try? absorbTake(data)
            {
                recentDetail[summary.id] = manifest
            }
        }
    }

    /// Decode a manifest off the wire.
    @discardableResult
    func absorbTake(_ data: Data) throws -> Manifest {
        try Manifest.wireDecoder.decode(Manifest.self, from: data)
    }

    /// `GET /takes`, newest first.
    func refreshRecent() async {
        if let list = try? await api.get(
            "/takes", as: [TakeEngine.Summary].self, decoder: Manifest.wireDecoder)
        {
            recent = list
        }
    }

    struct RecordBody: Encodable {
        var name: String?
        /// The daemon's own default, sent back explicitly: as of step 6
        /// `POST /record` without `codec` records HEVC whatever
        /// `settings.codec` says (`request.codec ?? .hevc` in TakeEngine).
        /// Reported to Engine; harmless to keep once fixed.
        var codec: Manifest.Codec?
    }

    struct StreamBody: Encodable {
        var stream: String
    }

    /// Join a stream to the recording take now (spec §6): arms it first if
    /// it is cold, stamps the file with the time it actually began.
    func join(_ id: String) {
        guard let take, take.isRecording, !takeBusy else { return }
        takeBusy = true
        takeError = nil
        Task {
            do {
                self.take = try await api.post(
                    "/takes/\(take.id)/join", StreamBody(stream: id), as: Manifest.self,
                    decoder: Manifest.wireDecoder)
                Log.info("joined \(id) to \(take.id)")
                await refreshStreams()
            } catch {
                takeError = "POST /takes/\(take.id)/join → \(error)"
            }
            takeBusy = false
        }
    }

    /// Leave: finalize that stream's file; it stays armed, the take goes on.
    func leave(_ id: String) {
        guard let take, take.isRecording, !takeBusy else { return }
        takeBusy = true
        takeError = nil
        Task {
            do {
                self.take = try await api.post(
                    "/takes/\(take.id)/leave", StreamBody(stream: id), as: Manifest.self,
                    decoder: Manifest.wireDecoder)
                Log.info("\(id) left \(take.id)")
            } catch {
                takeError = "POST /takes/\(take.id)/leave → \(error)"
            }
            takeBusy = false
        }
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
                self.take = try await api.post(
                    "/takes/\(take.id)/markers", MarkerBody(label: sent), as: Manifest.self,
                    decoder: Manifest.wireDecoder)
                Log.info("marker \"\(sent)\" on \(take.id)")
                markerLabel = ""
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
                let data = try await api.postData(
                    "/record", RecordBody(name: name.isEmpty ? nil : name, codec: settings?.codec))
                let created = try Manifest.wireDecoder.decode(TakeEngine.Created.self, from: data)
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
                take = try absorbTake(try await api.postData("/takes/\(id)/stop", EmptyBody()))
                tick(recording: false)
                Log.info("stopped take \(id)")
                await refreshStreams()
                await refreshRecent()
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
            take = try absorbTake(try await api.bytes("/takes/\(id)").0)
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
