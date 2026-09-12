import AppKit
import Foundation

/// Preview on demand, one stream at a time (spec §12): `GET /preview/{id}`
/// polled while the pane is open, and nothing at all when it is not — a
/// wall of thumbnails would be a wall of capture sessions.
///
/// Step 7: video answers `image/jpeg` (longest side 640), audio answers
/// `{ "levelDb" }` — a short sample's peak — which feeds the row's meter,
/// so a microphone can be checked before anything is armed. A refusal
/// (`404`, `503 no_frame`) is shown in the daemon's words.
extension DaemonModel {
    static let previewInterval: Duration = .milliseconds(250)

    func togglePreview(_ id: String) {
        if previewing == id {
            stopPreview()
        } else {
            startPreview(id)
        }
    }

    func startPreview(_ id: String) {
        stopPreview()
        previewing = id
        previewFrame = nil
        previewError = nil
        Log.info("preview \(id)")
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.previewing == id else { break }
                do {
                    let (data, contentType) = try await self.api.bytes("/preview/\(id)")
                    if contentType?.hasPrefix("application/json") == true {
                        let sample = try JSONDecoder().decode(AudioSample.self, from: data)
                        self.levels[id] = sample.levelDb
                        self.previewError = nil
                    } else if let image = NSImage(data: data) {
                        self.previewFrame = image
                        self.previewError = nil
                    } else {
                        self.previewError =
                            "GET /preview/\(id) → not an image (\(data.count) bytes)"
                    }
                } catch {
                    self.previewError = "GET /preview/\(id) → \(error)"
                    // A refusal will not change in 250 ms; ask again slowly.
                    try? await Task.sleep(for: .seconds(2))
                }
                try? await Task.sleep(for: Self.previewInterval)
            }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        if let previewing, take?.isRecording != true {
            // The sampled level is stale the moment sampling stops.
            levels[previewing] = nil
        }
        previewing = nil
        previewFrame = nil
        previewError = nil
    }

    struct AudioSample: Decodable {
        let levelDb: Double
    }
}
