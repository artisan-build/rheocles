import CoreGraphics
import Foundation
import Observation
import RheoclesCore

/// The daemon, as the app sees it.
///
/// The app holds no capture state (brief, rule 1): this is the one object
/// that talks to `rheocles-core`, and every view reads from it. It owns the
/// daemon's lifecycle (spec §3) — probe the port, use what answers, launch the
/// bundled core if nothing does, notice when it dies — and nothing else.
///
/// Never kills a daemon it did not start. A core launched by the NativePHP
/// app, or by hand, is used and left alone; only a child of this process is
/// terminated when this process quits.
@MainActor
@Observable
final class DaemonModel {
    enum Status: Equatable {
        /// Probing the port, or waiting for a launched core to answer.
        case launching
        /// Answering `GET /`.
        case running
        /// Not answering, and not being relaunched. The string is why.
        case down(String)
    }

    /// One model for the process. The app delegate connects at launch; the
    /// popover attaches to the same instance whenever it is opened.
    static let shared = DaemonModel()

    private(set) var status: Status = .launching
    /// The last `GET /` answer. Kept through a brief outage so the popover
    /// does not blank between two polls; cleared when the daemon is declared
    /// down.
    private(set) var discovery: Discovery?
    /// Whether the running core is our child.
    private(set) var startedByUs = false
    private(set) var lastError: String?

    /// `GET /streams`, verbatim. See Streams.swift.
    var streams: [StreamInfo] = []
    var permissions: Permissions?
    var streamsError: String?
    var pending: Pending?
    var armError: String?
    /// Bumped when a UserDefaults-backed setting changes, so views that
    /// read one through the model re-render.
    var settingsVersion = 0
    /// `--render-preview` only: a settings value without touching defaults.
    var showWindowsOverride: Bool?

    /// The active take, or the last one. See Takes.swift.
    var take: Manifest?
    var takeError: String?
    var takeBusy = false
    /// The name typed for the next take. UI state, not capture state: the
    /// daemon names the take when this is empty.
    var takeName = ""
    /// Ticks once a second while a take is recording, so the elapsed time
    /// in the popover moves.
    private(set) var now = Date()

    /// Where the daemon is and how it is launched. The app uses the
    /// defaults; tests point this at a stub on a spare port.
    struct Configuration {
        var port = Rheocles.defaultHTTPPort
        var tokenFile = TokenStore.standard.fileURL
        /// The core to launch; nil means the bundled one (or its sibling
        /// out of `swift build`).
        var coreExecutable: URL?
        var coreArguments: [String] = []
        var coreLog = Log.daemonLog
        var pulse: Duration = .seconds(3)
        /// How long a launched core has to answer `GET /`.
        var launchTimeout: Duration = .seconds(10)
        /// Launches allowed within `crashWindow` before giving up.
        var crashLimit = 3
        var crashWindow: TimeInterval = 60

        init() {}
    }

    let configuration: Configuration
    private(set) var api = API()
    /// The pid of the core this process launched, while it runs.
    var corePID: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    private var process: Process?
    private var health: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Set by `shutdown()`: nothing may be launched after it.
    private var stopping = false
    /// Launch times in the last minute, for the crash-loop guard.
    private var launches: [Date] = []

    /// Path of the token file, for the popover's settings later on.
    var tokenFile: URL { configuration.tokenFile }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        api.port = configuration.port
    }

    /// For `--render-preview` only: a model frozen in one state, never
    /// connected to anything.
    static func staged(
        _ status: Status, discovery: Discovery? = nil, ours: Bool = true,
        streams: [StreamInfo] = [], permissions: Permissions? = nil, showWindows: Bool = false,
        armError: String? = nil, take: Manifest? = nil, takeName: String = ""
    ) -> DaemonModel {
        let model = DaemonModel()
        model.status = status
        model.discovery = discovery
        model.startedByUs = ours
        model.streams = streams
        model.permissions = permissions
        model.showWindowsOverride = showWindows
        model.armError = armError
        model.take = take
        model.takeName = takeName
        if case .down(let why) = status { model.lastError = why }
        return model
    }

    // MARK: - lifecycle

    /// Bring the daemon up — or find it — and keep watching it.
    func connect() {
        guard health == nil else { return }
        health = Task { [weak self] in
            await self?.establish()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: configuration.pulse)
                await self.check()
            }
        }
    }

    /// Screen Recording takes effect on the daemon's next launch (PROTOCOL
    /// § GET /streams): its first list raises the prompt, and the grant is
    /// invisible to that process. The app can see it — the child is
    /// attributed to this bundle — so when the daemon says `notDetermined`
    /// and macOS says granted, and the daemon is ours, restart it. A shared
    /// daemon is left alone; the nudge tells the user to relaunch it.
    private func relaunchForScreenGrantIfNeeded() async {
        guard startedByUs, let permissions, permissions.screen != .authorized,
            CGPreflightScreenCaptureAccess()
        else { return }
        Log.info("Screen Recording granted since the daemon launched; relaunching it")
        await relaunchCore()
    }

    /// Stop our core and start it again — for a grant that only a fresh
    /// process can see. Never for a daemon we did not start.
    func relaunchCore() async {
        guard startedByUs, let process, process.isRunning else { return }
        events?.cancel()
        events = nil
        status = .launching
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        launches.removeAll()
        await establish()
    }

    /// The Relaunch button: forget the crash-loop count and try again.
    func relaunch() {
        launches.removeAll()
        lastError = nil
        status = .launching
        Task { await establish() }
    }

    /// Stop the daemon if — and only if — it is ours.
    func shutdown() {
        stopping = true
        health?.cancel()
        health = nil
        events?.cancel()
        events = nil
        ticker?.cancel()
        ticker = nil
        guard let process, process.isRunning, startedByUs else { return }
        Log.info("terminating rheocles-core pid \(process.processIdentifier) (ours)")
        process.terminate()
    }

    // MARK: - discovery

    /// Probe once; if nothing answers, launch and wait.
    private func establish() async {
        readToken()
        do {
            discovery = try await api.get("/", as: Discovery.self)
            status = .running
            if !startedByUs { Log.info("using a running rheocles-core on :\(api.port)") }
            await becameRunning()
            return
        } catch API.Failure.unreachable {
            // Nothing there. Ours to launch.
        } catch {
            // Answering, but not usefully — a stale token, a foreign process
            // on the port. Launching another daemon behind it would not help.
            fail("daemon on :\(api.port) answered but \(error)")
            return
        }

        guard launch() else { return }

        // Wait for the port. A cold launch answers in well under a second;
        // ten is generous enough that a slow disk is not reported as a crash.
        // A core that exits before answering is launched again, under the
        // same crash-loop guard as one that dies later: three in a minute
        // and we stop and say so.
        var deadline = ContinuousClock.now + configuration.launchTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let process, !process.isRunning {
                Log.info(
                    "rheocles-core exited with status \(process.terminationStatus) before answering"
                )
                guard launch() else { return }
                deadline = ContinuousClock.now + configuration.launchTimeout
                continue
            }
            readToken()
            if let answer = try? await api.get("/", as: Discovery.self) {
                discovery = answer
                status = .running
                lastError = nil
                Log.info("rheocles-core \(answer.version) answering on :\(api.port)")
                await becameRunning()
                return
            }
        }
        fail("rheocles-core did not answer on :\(api.port) within \(configuration.launchTimeout)")
    }

    /// The periodic pulse. Until the event stream exists (task 3) this is
    /// also how the popover's numbers refresh. The popover calls it on
    /// opening so the list is current the moment it is seen.
    func check() async {
        do {
            discovery = try await api.get("/", as: Discovery.self)
            if status != .running {
                status = .running
                lastError = nil
            }
            await refreshStreams()
            await discoverActiveTake()
            listen()
            await relaunchForScreenGrantIfNeeded()
        } catch API.Failure.unauthorized {
            // The token rotated underneath us. Read it again; if it still
            // fails next time round that is a real error.
            readToken()
        } catch API.Failure.unreachable {
            if case .down = status { return }
            Log.info("rheocles-core stopped answering")
            status = .launching
            discovery = nil
            await establish()
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - the process

    /// Launch the bundled core as a child. Returns false when it could not
    /// even be started (missing binary, crash loop); `status` says why.
    private func launch() -> Bool {
        guard !stopping else { return false }
        launches = launches.filter { $0.timeIntervalSinceNow > -configuration.crashWindow }
        if launches.count >= configuration.crashLimit {
            fail("rheocles-core exited three times in a minute; not relaunching")
            return false
        }

        guard let executable = configuration.coreExecutable ?? Self.bundledCore else {
            fail("no rheocles-core beside the app")
            return false
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = configuration.coreArguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Both streams to one file, appended, so a crash's last words land
        // next to the line that preceded them.
        let log = configuration.coreLog
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                Log.info(
                    "rheocles-core pid \(finished.processIdentifier) exited, status \(finished.terminationStatus)"
                )
            }
        }

        do {
            try process.run()
        } catch {
            fail("could not launch \(executable.path): \(error.localizedDescription)")
            return false
        }

        launches.append(Date())
        self.process = process
        startedByUs = true
        status = .launching
        Log.info("launched \(executable.path) as pid \(process.processIdentifier)")
        return true
    }

    /// `Contents/Resources/rheocles-core` in the bundle; beside the
    /// executable when run straight out of `swift build`.
    private static var bundledCore: URL? {
        if let bundled = Bundle.main.url(forResource: "rheocles-core", withExtension: nil),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled
        }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
            .appending(path: "rheocles-core")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    private func readToken() {
        let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        api.token = (token?.isEmpty == false) ? token : nil
    }

    private func fail(_ why: String) {
        Log.info("daemon down: \(why)")
        lastError = why
        discovery = nil
        status = .down(why)
        events?.cancel()
        events = nil
    }

    /// The daemon is answering: read everything once, then follow events.
    private func becameRunning() async {
        await refreshStreams()
        await discoverActiveTake()
        listen()
    }

    // MARK: - events

    /// Follow `GET /events` for as long as the daemon is up, reconnecting
    /// after a second if the stream drops. One listener at a time.
    private func listen() {
        guard events == nil, let url = api.eventsURL else { return }
        events = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await EventStream.read(url) { message in
                        self?.handle(message)
                    }
                    Log.info("event stream closed")
                } catch {
                    if Task.isCancelled { break }
                    Log.info("event stream: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.status == .running else { break }
            }
            self?.events = nil
        }
    }

    private func handle(_ message: EventStream.Message) {
        switch message.kind {
        case "stream":
            // The StreamInfo as it now is; replace it in place so the switch
            // moves without a full re-read.
            if let payload = message.json["stream"],
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let info = try? JSONDecoder().decode(StreamInfo.self, from: data),
                let index = streams.firstIndex(where: { $0.id == info.id })
            {
                streams[index] = info
            } else {
                Task { await refreshStreams() }
            }
        case "state", "join", "leave", "marker", "error":
            // Planned (step 6). Until their shapes land, any of them means
            // the take changed: re-read it.
            Task { await discoverActiveTake() }
        default:
            break
        }
    }

    /// The one-second tick while recording; idle otherwise.
    func tick(recording: Bool) {
        if recording, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else if !recording {
            ticker?.cancel()
            ticker = nil
        }
    }
}
