import AppKit
import Foundation

/// Preview on demand, one stream at a time (spec §12): `GET /preview/{id}`
/// polled while the pane is open, and nothing at all when it is not — a
/// wall of thumbnails would be a wall of capture sessions.
///
/// Planned, step 7. The frame is taken as whatever bytes `NSImage` can read
/// (JPEG or PNG both work); a JSON error is shown in the daemon's words,
/// which today is `404 not_found` until the route lands.
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
                    let (data, _) = try await self.api.bytes("/preview/\(id)")
                    if let image = NSImage(data: data) {
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
        previewing = nil
        previewFrame = nil
        previewError = nil
    }
}
