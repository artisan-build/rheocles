// Spike S2 — SCRecordingOutput and crash safety.
//
// Question: when the process dies mid-take (kill -9), what is left on disk?
// Two mechanisms for a display:
//
//   s2 rec-output --seconds N --out f.mov [--codec hevc|h264] [--display i]
//       ScreenCaptureKit's own SCRecordingOutput (macOS 15+) writes the file.
//   s2 writer --seconds N --out f.mov [--fragment secs] [--display i | --window title]
//       SCStream frames → our AVAssetWriter with movieFragmentInterval.
//   s2 probe f.mov
//       Read the file back with AVAsset: playable? duration? decodable frames?
//   s2 list
//
// Both recorders log the file size once a second while recording, which shows
// whether bytes reach disk as they go or only at finalisation. The harness
// (kill-test.sh) does the killing and the reading back.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

func fileSize(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
}

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.endIndex else { return nil }
    return args[i + 1]
}

/// Receives stream and recording-output callbacks; owns the AVAssetWriter path.
final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate,
    @unchecked Sendable
{
    let lock = NSLock()
    var frames = 0
    var written = 0
    var notReady = 0
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var writerURL: URL?
    var fragment: Double = 1
    var size = (0, 0)
    var finished = false

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
    }

    // MARK: SCRecordingOutputDelegate
    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        log("SCRecordingOutput did start recording")
    }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        log("SCRecordingOutput did finish recording")
        lock.lock(); finished = true; lock.unlock()
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        log("SCRecordingOutput failed: \(error)")
        lock.lock(); finished = true; lock.unlock()
    }

    // MARK: SCStreamOutput (writer path only)
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // Only complete frames carry pixels; idle/blank ones are bookkeeping.
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = atts.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete
        else { return }
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        if writer == nil, let url = writerURL {
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                w.movieFragmentInterval = CMTime(seconds: fragment, preferredTimescale: 600)
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
                ])
                i.expectsMediaDataInRealTime = true
                w.add(i)
                guard w.startWriting() else { throw w.error ?? NSError(domain: "s2", code: 1) }
                w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
                writer = w
                input = i
                log("AVAssetWriter started -> \(url.path) \(size.0)x\(size.1) hevc movieFragmentInterval=\(fragment)s")
            } catch {
                log("AVAssetWriter failed to start: \(error)")
                writerURL = nil
            }
        }
        if let i = input, let w = writer, w.status == .writing {
            if i.isReadyForMoreMediaData, i.append(sb) { written += 1 } else { notReady += 1 }
        }
    }

    func snapshot() -> (frames: Int, written: Int, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (frames, written, finished)
    }

    func finishWriter() {
        lock.lock()
        let w = writer, i = input
        writer = nil; input = nil; writerURL = nil
        lock.unlock()
        guard let w, let i else { return }
        i.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        w.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        log("AVAssetWriter finished status=\(w.status.rawValue) (2 completed, 3 failed) error=\(w.error.map { "\($0)" } ?? "none") frames=\(frames) written=\(written) notReady=\(notReady)")
    }
}

func shareable() async throws -> SCShareableContent {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
}

func makeStream(displayIndex: Int, windowMatch: String?, pixelFormat: OSType?, recorder: Recorder) async throws -> (SCStream, Int, Int) {
    let content = try await shareable()
    let filter: SCContentFilter
    if let windowMatch {
        // A window, same API, different filter — what the engine will do for
        // window streams. Cropped to the window, no other content.
        guard let window = content.windows.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(windowMatch) && $0.isOnScreen }) else {
            log("no on-screen window matching \(windowMatch); have: \(content.windows.compactMap(\.title).filter { !$0.isEmpty }.prefix(20))")
            exit(2)
        }
        log("window \(window.windowID) '\(window.title ?? "")' of \(window.owningApplication?.applicationName ?? "?") frame=\(window.frame)")
        filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
        guard displayIndex < content.displays.count else {
            log("no display \(displayIndex); have \(content.displays.count)")
            exit(2)
        }
        let display = content.displays[displayIndex]
        log("display \(display.displayID) \(display.width)x\(display.height) pt")
        filter = SCContentFilter(display: display, excludingWindows: [])
    }
    let scale = CGFloat(filter.pointPixelScale)
    let w = Int(filter.contentRect.width * scale), h = Int(filter.contentRect.height * scale)
    let cfg = SCStreamConfiguration()
    cfg.width = w
    cfg.height = h
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    cfg.showsCursor = true
    cfg.queueDepth = 6
    cfg.capturesAudio = false
    if let pixelFormat { cfg.pixelFormat = pixelFormat }
    log("content \(filter.contentRect) @\(scale)x -> \(w)x\(h) px, 30 fps cap")
    return (SCStream(filter: filter, configuration: cfg, delegate: recorder), w, h)
}

// SCContentFilter(desktopIndependentWindow:) asserts CGS_REQUIRE_INIT unless
// a window-server connection exists; a bare executable has none until AppKit
// makes one.
_ = NSApplication.shared

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

switch args.first {
case "preflight":
    // Does this bundle have Screen Recording? Never prompts.
    print("screen capture preflight: \(CGPreflightScreenCaptureAccess())")
    exit(CGPreflightScreenCaptureAccess() ? 0 : 6)

case "list":
    Task {
        do {
            let c = try await shareable()
            for (i, d) in c.displays.enumerated() {
                print("display[\(i)] id=\(d.displayID) \(d.width)x\(d.height) pt frame=\(d.frame)")
            }
            print("\(c.windows.count) windows, \(c.applications.count) applications")
        } catch { log("SCShareableContent failed: \(error)") ; exitCode = 3 }
        sem.signal()
    }

case "rec-output", "writer":
    let mode = args[0]
    let seconds = Double(opt("--seconds") ?? "30") ?? 30
    let out = opt("--out") ?? "out/\(mode).mov"
    let displayIndex = Int(opt("--display") ?? "0") ?? 0
    let codec: AVVideoCodecType = (opt("--codec") ?? "hevc") == "h264" ? .h264 : .hevc
    let recorder = Recorder()
    recorder.fragment = Double(opt("--fragment") ?? "1") ?? 1
    log("pid \(ProcessInfo.processInfo.processIdentifier) mode=\(mode) seconds=\(seconds) out=\(out) bundle=\(Bundle.main.bundleIdentifier ?? "none")")
    log("screen capture preflight: \(CGPreflightScreenCaptureAccess())")
    try? FileManager.default.removeItem(atPath: out)

    Task {
        do {
            let (stream, w, h) = try await makeStream(
                displayIndex: displayIndex, windowMatch: opt("--window"),
                pixelFormat: mode == "writer" ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : nil,
                recorder: recorder)
            recorder.size = (w, h)
            var recOutput: SCRecordingOutput?
            if mode == "rec-output" {
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = URL(fileURLWithPath: out)
                rc.outputFileType = .mov
                rc.videoCodecType = codec
                let ro = SCRecordingOutput(configuration: rc, delegate: recorder)
                try stream.addRecordingOutput(ro)
                recOutput = ro
                log("SCRecordingOutput added codec=\(codec.rawValue) available=\(rc.availableVideoCodecTypes.map(\.rawValue)) fileTypes=\(rc.availableOutputFileTypes.map(\.rawValue))")
            } else {
                recorder.writerURL = URL(fileURLWithPath: out)
                try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "s2.frames"))
            }
            try await stream.startCapture()
            log("capture started")

            let start = Date()
            var tick = 0
            while Date().timeIntervalSince(start) < seconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                tick += 1
                let snap = recorder.snapshot()
                log("t=\(tick) fileSize=\(fileSize(out)) frames=\(snap.frames) written=\(snap.written)")
            }

            log("stopping cleanly (not killed)")
            if let recOutput {
                try stream.removeRecordingOutput(recOutput)
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if recorder.snapshot().finished { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try await stream.stopCapture()
            recorder.finishWriter()
            log("done; fileSize=\(fileSize(out))")
        } catch {
            log("failed: \(error)")
            exitCode = 4
        }
        sem.signal()
    }

case "probe":
    let path = args.count > 1 ? args[1] : ""
    Task {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
            log("AVAsset \(path): playable=\(playable) duration=\(String(format: "%.3f", duration.seconds))s tracks=\(tracks.count)")
            for t in tracks {
                let (fmt, nominal, range) = try await t.load(.formatDescriptions, .nominalFrameRate, .timeRange)
                let dims = fmt.first.map { CMVideoFormatDescriptionGetDimensions($0) }
                log("  track \(t.trackID) \(t.mediaType.rawValue) \(dims.map { "\($0.width)x\($0.height)" } ?? "") nominalFps=\(nominal) range=\(String(format: "%.3f", range.start.seconds))..\(String(format: "%.3f", range.end.seconds))")
            }
            if let video = tracks.first(where: { $0.mediaType == .video }) {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                reader.startReading()
                var n = 0
                var last = 0.0
                while let sb = output.copyNextSampleBuffer() {
                    n += 1
                    last = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                }
                log("  AVAssetReader decoded \(n) frames, last pts=\(String(format: "%.3f", last))s status=\(reader.status.rawValue) (2 completed, 3 failed) error=\(reader.error.map { "\($0)" } ?? "none")")
            }
        } catch {
            log("AVAsset load failed: \(error)")
            exitCode = 5
        }
        sem.signal()
    }

default:
    print("usage: s2 list | rec-output --seconds N --out f.mov [--codec hevc|h264] [--display i] | writer --seconds N --out f.mov [--fragment s] [--display i | --window title] | probe f.mov")
    exit(1)
}

sem.wait()
exit(exitCode)
