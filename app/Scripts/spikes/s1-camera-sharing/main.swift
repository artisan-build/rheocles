// Spike S1 — camera sharing.
//
// Question: can two processes hold one camera open on this macOS, one of them
// recording, without either losing frames? Rheocles' answer to "do we need a
// virtual camera" hangs on it.
//
//   s1 list                      every video device, with who-has-it-open
//   s1 watch [seconds]           poll isInUseByAnotherApplication for all devices
//   s1 run --device <match> --seconds N [--record out.mov] [--writer out2.mov] [--hold-lock] [--label name]
//
// `run` opens the device in an AVCaptureSession with a video-data output that
// counts every frame and every reported drop, and — with --record — an
// AVCaptureMovieFileOutput writing a real file. It prints one status line per
// second. Late-frame discarding is switched off so a reported drop comes from
// upstream of us, and inter-frame gaps are measured from presentation
// timestamps so a device-side stall shows up even when nothing is "dropped".

import AVFoundation
import CoreMedia
import Foundation

func log(_ s: String) {
  let f = DateFormatter()
  f.dateFormat = "HH:mm:ss.SSS"
  print("[\(f.string(from: Date()))] \(s)")
  fflush(stdout)
}

func describe(_ d: AVCaptureDevice) -> String {
  let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
  let maxFPS = d.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
  let sub = CMFormatDescriptionGetMediaSubType(d.activeFormat.formatDescription)
  let fourcc =
    String(
      bytes: [
        UInt8(sub >> 24 & 0xff), UInt8(sub >> 16 & 0xff), UInt8(sub >> 8 & 0xff), UInt8(sub & 0xff),
      ],
      encoding: .ascii) ?? "?"
  return
    "\(d.localizedName) | model=\(d.modelID) | id=\(d.uniqueID) | \(dims.width)x\(dims.height)@\(maxFPS) \(fourcc) | inUseByOther=\(d.isInUseByAnotherApplication) | connected=\(d.isConnected)"
}

func devices() -> [AVCaptureDevice] {
  AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
    mediaType: .video, position: .unspecified
  ).devices
}

func find(_ match: String) -> AVCaptureDevice? {
  let all = devices()
  return all.first { $0.uniqueID == match }
    ?? all.first { $0.localizedName.localizedCaseInsensitiveContains(match) }
}

func ensureAccess() -> Bool {
  let status = AVCaptureDevice.authorizationStatus(for: .video)
  log(
    "camera authorization status: \(status.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)"
  )
  if status == .authorized { return true }
  if status == .notDetermined {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { ok in
      granted = ok
      sem.signal()
    }
    log("requesting camera access — a TCC prompt should appear on the host app now")
    sem.wait()
    log("camera access granted: \(granted)")
    return granted
  }
  return false
}

final class Monitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureFileOutputRecordingDelegate, @unchecked Sendable
{
  let lock = NSLock()
  var frames = 0
  var drops = 0
  var dropReasons: [String: Int] = [:]
  var lastPTS: CMTime?
  var gaps: [Double] = []  // every inter-frame gap, so stalls are judged against the observed cadence, not the format's nominal rate
  var recordingErrors: [String] = []
  var recordingFinished = false

  // Our own writer, fed from the data output the way the product will be.
  // Started on the first frame after `writerURL` is set, so it never sees a
  // frame before its session begins.
  var writer: AVAssetWriter?
  var writerInput: AVAssetWriterInput?
  var writerFrames = 0
  var writerDropped = 0  // frames the input was not ready for
  var writerURL: URL?
  var lastDims = (0, 0)

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    if let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
      let d = CMVideoFormatDescriptionGetDimensions(fd)
      if (Int(d.width), Int(d.height)) != lastDims {
        lastDims = (Int(d.width), Int(d.height))
        log("frame dimensions now \(d.width)x\(d.height)")
      }
    }
    lock.lock()
    frames += 1
    if let url = writerURL, writer == nil, let fd = CMSampleBufferGetFormatDescription(sampleBuffer)
    {
      do {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let input = AVAssetWriterInput(
          mediaType: .video,
          outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width), AVVideoHeightKey: Int(dims.height),
          ])
        input.expectsMediaDataInRealTime = true
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        writer = w
        writerInput = input
        log("writer started -> \(url.path) \(dims.width)x\(dims.height)")
      } catch {
        log("writer failed to start: \(error)")
        writerURL = nil
      }
    }
    if let input = writerInput, let w = writer, w.status == .writing {
      if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
        writerFrames += 1
      } else {
        writerDropped += 1
      }
    }
    if let last = lastPTS?.seconds { gaps.append(pts - last) }
    lastPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    lock.unlock()
  }

  func captureOutput(
    _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    var reason = "unknown"
    if let att = CMGetAttachment(
      sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
    {
      reason = "\(att)"
    }
    lock.lock()
    drops += 1
    dropReasons[reason, default: 0] += 1
    lock.unlock()
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    log("recording started -> \(fileURL.path)")
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    lock.lock()
    if let error { recordingErrors.append("\(error)") }
    recordingFinished = true
    lock.unlock()
    log("recording finished -> \(outputFileURL.path) error=\(error.map { "\($0)" } ?? "none")")
  }

  func finishWriter() {
    lock.lock()
    let w = writer
    let input = writerInput
    writer = nil
    writerInput = nil
    writerURL = nil
    lock.unlock()
    guard let w, let input else { return }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
    log(
      "writer finished status=\(w.status.rawValue) (2 completed, 3 failed) error=\(w.error.map { "\($0)" } ?? "none") frames=\(writerFrames) notReady=\(writerDropped)"
    )
  }

  /// frames, drops, reasons, median gap, max gap, stalls (gaps > 1.5x median).
  func snapshot() -> (Int, Int, [String: Int], Double, Double, Int) {
    lock.lock()
    defer { lock.unlock() }
    let sorted = gaps.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let stalls = median > 0 ? gaps.filter { $0 > median * 1.5 }.count : 0
    return (frames, drops, dropReasons, median, sorted.last ?? 0, stalls)
  }
}

let args = CommandLine.arguments.dropFirst()
func opt(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.endIndex else { return nil }
  return args[i + 1]
}

switch args.first {
case "list":
  for d in devices() { print(describe(d)) }

case "watch":
  let seconds = Int(args.dropFirst().first ?? "30") ?? 30
  var last: [String: Bool] = [:]
  let end = Date().addingTimeInterval(TimeInterval(seconds))
  log("watching isInUseByAnotherApplication for \(seconds)s")
  while Date() < end {
    for d in devices() {
      let v = d.isInUseByAnotherApplication
      if last[d.uniqueID] != v {
        log("\(d.localizedName): inUseByOther=\(v)")
        last[d.uniqueID] = v
      }
    }
    Thread.sleep(forTimeInterval: 0.25)
  }

case "run":
  guard let match = opt("--device"), let device = find(match) else {
    log("no device matching \(opt("--device") ?? "<none>"); have:")
    for d in devices() { print("  " + describe(d)) }
    exit(2)
  }
  let seconds = Double(opt("--seconds") ?? "20") ?? 20
  let label = opt("--label") ?? "s1"
  let recordPath = opt("--record")
  let writerPath = opt("--writer")
  let holdLock = args.contains("--hold-lock")

  guard ensureAccess() else {
    log("no camera access; giving up")
    exit(3)
  }

  log("[\(label)] opening: \(describe(device))")

  let session = AVCaptureSession()
  let monitor = Monitor()
  let input = try AVCaptureDeviceInput(device: device)
  session.beginConfiguration()
  guard session.canAddInput(input) else {
    log("cannot add input")
    exit(4)
  }
  session.addInput(input)

  let data = AVCaptureVideoDataOutput()
  data.alwaysDiscardsLateVideoFrames = false
  data.setSampleBufferDelegate(monitor, queue: DispatchQueue(label: "s1.frames"))
  guard session.canAddOutput(data) else {
    log("cannot add data output")
    exit(4)
  }
  session.addOutput(data)

  var movie: AVCaptureMovieFileOutput?
  if recordPath != nil {
    let m = AVCaptureMovieFileOutput()
    if session.canAddOutput(m) {
      session.addOutput(m)
      movie = m
    } else {
      log("cannot add movie file output alongside data output — recording disabled")
    }
  }
  session.commitConfiguration()

  let nc = NotificationCenter.default
  for name in [
    AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
    AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification,
    AVCaptureSession.didStartRunningNotification,
  ] {
    nc.addObserver(forName: name, object: session, queue: nil) { n in
      log("notification \(n.name.rawValue) userInfo=\(n.userInfo ?? [:])")
    }
  }
  nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
    n in
    log("device disconnected: \((n.object as? AVCaptureDevice)?.localizedName ?? "?")")
  }
  let inUseObs = device.observe(\.isInUseByAnotherApplication, options: [.new]) { d, _ in
    log("[\(label)] \(d.localizedName) inUseByOther -> \(d.isInUseByAnotherApplication)")
  }
  let formatObs = device.observe(\.activeFormat, options: [.new]) { d, _ in
    log("[\(label)] activeFormat changed -> \(describe(d))")
  }

  if let writerPath {
    try? FileManager.default.removeItem(atPath: writerPath)
    monitor.writerURL = URL(fileURLWithPath: writerPath)
  }
  session.startRunning()
  log("[\(label)] session running=\(session.isRunning) format now: \(describe(device))")
  if holdLock {
    // Does holding the configuration lock for the whole run stop another
    // process from reconfiguring the device under us?
    do {
      try device.lockForConfiguration()
      log("[\(label)] holding lockForConfiguration for the run")
    } catch {
      log("[\(label)] lockForConfiguration failed: \(error)")
    }
  }

  if let movie, let recordPath {
    let url = URL(fileURLWithPath: recordPath)
    try? FileManager.default.removeItem(at: url)
    movie.startRecording(to: url, recordingDelegate: monitor)
  }

  let start = Date()
  var lastFrames = 0
  var tick = 0
  while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: 1.0)
    tick += 1
    let (frames, drops, reasons, median, maxGap, stalls) = monitor.snapshot()
    log(
      String(
        format:
          "[%@] t=%2d frames=%5d (+%3d) drops=%d%@ medianGap=%.4fs maxGap=%.4fs stalls=%d inUseByOther=%@ running=%@",
        label, tick, frames, frames - lastFrames, drops,
        reasons.isEmpty ? "" : " \(reasons)", median, maxGap, stalls,
        device.isInUseByAnotherApplication ? "true" : "false",
        session.isRunning ? "true" : "false"))
    lastFrames = frames
  }

  if let movie {
    movie.stopRecording()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !monitor.recordingFinished { Thread.sleep(forTimeInterval: 0.1) }
    if !monitor.recordingFinished {
      log("movie file output never reported didFinishRecording within 5s")
    }
  }
  monitor.finishWriter()
  if holdLock { device.unlockForConfiguration() }
  session.stopRunning()
  _ = inUseObs
  _ = formatObs

  let (frames, drops, reasons, median, maxGap, stalls) = monitor.snapshot()
  let elapsed = Date().timeIntervalSince(start)
  log(
    String(
      format:
        "[%@] SUMMARY device=%@ seconds=%.1f frames=%d avgFps=%.2f medianGap=%.4fs (%.1f fps) drops=%d %@ maxGap=%.4fs stalls=%d recordingErrors=%@",
      label, device.localizedName, elapsed, frames, Double(frames) / elapsed, median,
      median > 0 ? 1 / median : 0, drops, "\(reasons)", maxGap, stalls, "\(monitor.recordingErrors)"
    ))
  for path in [recordPath, writerPath].compactMap({ $0 }) {
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] ?? 0
    log("[\(label)] file \(path) size=\(size)")
  }

default:
  print(
    "usage: s1 list | watch [seconds] | run --device <match> --seconds N [--record out.mov] [--writer out2.mov] [--hold-lock] [--label name]"
  )
  exit(1)
}
