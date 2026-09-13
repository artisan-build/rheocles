import AVFoundation
import Foundation

/// The single-file output ("Loom mode"): a **passthrough** mux of a take's
/// video (with its `tmcd` track) and every audio stream — each as its own
/// enabled track, no mixdown — into one `combined.mov`. No re-encode, no
/// ffmpeg: `AVMutableComposition` + a passthrough `AVAssetExportSession`.
///
/// A bonus artefact: the take's own state is unaffected, and a failure here
/// only marks `manifest.combined` failed with a reason.
public enum Combiner {
    struct Failure: Error { let reason: String }

    /// Build `<folder>/combined.mov` from the given relative paths. At most
    /// one video path (the ≤1-video rule is enforced upstream); zero video
    /// yields an audio-only MOV with the audio tracks.
    public static func combine(
        in folder: URL, videoPath: String?, audioPaths: [String]
    ) async -> Manifest.Combined {
        let output = folder.appendingPathComponent("combined.mov")
        try? FileManager.default.removeItem(at: output)
        let composition = AVMutableComposition()
        do {
            if let videoPath {
                let asset = AVURLAsset(url: folder.appendingPathComponent(videoPath))
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                    let track = composition.addMutableTrack(
                        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw Failure(reason: "no video track in \(videoPath)") }
                try track.insertTimeRange(range, of: source, at: .zero)
                // Carry the time-of-day tmcd track and associate it with the
                // video, so an editor still syncs by timecode.
                if let tcSource = try await asset.loadTracks(withMediaType: .timecode).first,
                    let tcTrack = composition.addMutableTrack(
                        withMediaType: .timecode, preferredTrackID: kCMPersistentTrackID_Invalid)
                {
                    try tcTrack.insertTimeRange(range, of: tcSource, at: .zero)
                    track.addTrackAssociation(to: tcTrack, type: .timecode)
                }
            }
            for audioPath in audioPaths {
                let asset = AVURLAsset(url: folder.appendingPathComponent(audioPath))
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    continue
                }
                let duration = try await asset.load(.duration)
                guard
                    let track = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            }
            guard
                composition.tracks.contains(where: {
                    $0.mediaType == .video || $0.mediaType == .audio
                })
            else { throw Failure(reason: "nothing to combine") }

            guard
                let export = AVAssetExportSession(
                    asset: composition, presetName: AVAssetExportPresetPassthrough)
            else { throw Failure(reason: "could not create the export session") }
            do {
                try await export.export(to: output, as: .mov)
            } catch {
                throw Failure(reason: "export failed: \(error.localizedDescription)")
            }
            return Manifest.Combined(path: "combined.mov", state: .complete)
        } catch {
            try? FileManager.default.removeItem(at: output)
            return Manifest.Combined(
                path: "combined.mov", state: .failed,
                reason: (error as? Failure)?.reason ?? "\(error)")
        }
    }
}
