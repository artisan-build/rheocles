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

    private(set) var api = API()
    private var process: Process?
    private var health: Task<Void, Never>?
    /// Launch times in the last minute, for the crash-loop guard.
    private var launches: [Date] = []

    /// Path of the token file, for the popover's settings later on.
    let tokenFile = TokenStore.standard.fileURL

    init() {}

    /// For `--render-preview` only: a model frozen in one state, never
    /// connected to anything.
    static func staged(
        _ status: Status, discovery: Discovery? = nil, ours: Bool = true,
        streams: [StreamInfo] = [], permissions: Permissions? = nil, showWindows: Bool = false,
        armError: String? = nil
    ) -> DaemonModel {
        let model = DaemonModel()
        model.status = status
        model.discovery = discovery
        model.startedByUs = ours
        model.streams = streams
        model.permissions = permissions
        model.showWindowsOverride = showWindows
        model.armError = armError
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
                try? await Task.sleep(for: .seconds(3))
                await self.check()
            }
        }
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
        health?.cancel()
        health = nil
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
            await refreshStreams()
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
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if let process, !process.isRunning {
                fail("rheocles-core exited with status \(process.terminationStatus)")
                return
            }
            readToken()
            if let answer = try? await api.get("/", as: Discovery.self) {
                discovery = answer
                status = .running
                lastError = nil
                Log.info("rheocles-core \(answer.version) answering on :\(api.port)")
                await refreshStreams()
                return
            }
        }
        fail("rheocles-core did not answer on :\(api.port) within 10 s")
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
        launches = launches.filter { $0.timeIntervalSinceNow > -60 }
        if launches.count >= 3 {
            fail("rheocles-core exited three times in a minute; not relaunching")
            return false
        }

        guard let executable = Self.coreExecutable else {
            fail("no rheocles-core beside the app")
            return false
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = []
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Both streams to one file, appended, so a crash's last words land
        // next to the line that preceded them.
        if !FileManager.default.fileExists(atPath: Log.daemonLog.path) {
            FileManager.default.createFile(atPath: Log.daemonLog.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: Log.daemonLog) {
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
    private static var coreExecutable: URL? {
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
    }
}
