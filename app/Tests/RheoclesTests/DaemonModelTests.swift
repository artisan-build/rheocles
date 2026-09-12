import Foundation
import RheoclesCore
import Testing

@testable import Rheocles

/// The daemon lifecycle (spec §3, brief rule 2), against a stub core on a
/// spare port: use what answers, launch what does not, notice death, give
/// up on a crash loop, and never kill what we did not start.
@Suite("DaemonModel", .serialized)
@MainActor
struct DaemonModelTests {
    /// A model pointed at a spare port and a scratch token file, launching
    /// the stub as its core. Fast pulse so the tests do not wait on the
    /// real three seconds.
    private func model(
        port: UInt16, scratch: URL, die: Bool = false, crashLimit: Int = 3
    ) -> DaemonModel {
        var configuration = DaemonModel.Configuration()
        configuration.port = port
        configuration.tokenFile = scratch.appendingPathComponent("token")
        configuration.coreExecutable = StubDaemon.python
        configuration.coreArguments = StubDaemon.arguments(
            port: port, tokenFile: configuration.tokenFile, die: die)
        configuration.coreLog = scratch.appendingPathComponent("core.log")
        configuration.pulse = .milliseconds(200)
        configuration.launchTimeout = .seconds(5)
        configuration.crashLimit = crashLimit
        return DaemonModel(configuration: configuration)
    }

    @Test("Probe, then use: a daemon already on the port is used, not replaced")
    func probeThenUse() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let tokenFile = scratch.appendingPathComponent("token")
        let theirs = try StubDaemon.launch(port: port, tokenFile: tokenFile)
        defer { theirs.terminate() }
        // The stub writes the token file as the daemon does; wait until it
        // is up and answering with it.
        #expect(await StubDaemon.waitUntilAnswers(port: port, token: "ab" * 32))

        let model = model(port: port, scratch: scratch)
        model.connect()
        #expect(await eventually { model.status == .running })
        #expect(model.startedByUs == false)
        #expect(model.corePID == nil)
        #expect(model.discovery?.hostname == "stub.local")

        // Quitting leaves a daemon we did not start alone.
        model.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        #expect(theirs.isRunning)
    }

    @Test("Probe, then launch: nothing answers, so the bundled core is started and waited for")
    func probeThenLaunch() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let model = model(port: port, scratch: scratch)
        #expect(!FileManager.default.fileExists(atPath: model.tokenFile.path))

        model.connect()
        #expect(await eventually(.seconds(8)) { model.status == .running })
        #expect(model.startedByUs)
        let pid = model.corePID
        #expect(pid != nil)
        // The token the core wrote is the one the model paired with.
        #expect(FileManager.default.fileExists(atPath: model.tokenFile.path))
        #expect(model.discovery?.version == "stub")

        // Quitting terminates the core we started.
        model.shutdown()
        #expect(await eventually { model.corePID == nil })
        if let pid { #expect(kill(pid, 0) != 0) }
    }

    @Test("A core that dies is relaunched, and comes back with a new pid")
    func relaunchOnDeath() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let model = model(port: port, scratch: scratch)
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually(.seconds(8)) { model.status == .running })
        let first = try #require(model.corePID)

        kill(first, SIGKILL)
        #expect(await eventually(.seconds(8)) { model.corePID != nil && model.corePID != first })
        #expect(await eventually(.seconds(8)) { model.status == .running })
        #expect(model.startedByUs)
    }

    @Test("Three exits in a minute and the model stops relaunching and says so")
    func crashLoopGuard() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let model = model(port: port, scratch: scratch, die: true, crashLimit: 3)
        model.connect()
        defer { model.shutdown() }

        #expect(
            await eventually(.seconds(15)) {
                if case .down(let why) = model.status { return why.contains("not relaunching") }
                return false
            })
        #expect(model.corePID == nil)
        // Nothing is listening: the guard fired on exits, not on a port.
        #expect(await StubDaemon.answers(port: port, token: nil) == false)
    }

    @Test("Relaunch after the guard fires forgets the count and tries again")
    func relaunchButton() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let model = model(port: port, scratch: scratch, die: true, crashLimit: 1)
        model.connect()
        defer { model.shutdown() }
        #expect(
            await eventually(.seconds(8)) {
                if case .down = model.status { return true }
                return false
            })

        model.relaunch()
        #expect(model.status == .launching)
        #expect(
            await eventually(.seconds(8)) {
                if case .down = model.status { return true }
                return false
            })
    }

    @Test("Events are dispatched as they arrive, not on the next pulse")
    func eventsArrive() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let tokenFile = scratch.appendingPathComponent("token")
        let theirs = try StubDaemon.launch(port: port, tokenFile: tokenFile)
        defer { theirs.terminate() }
        #expect(await StubDaemon.waitUntilAnswers(port: port, token: "ab" * 32))

        var configuration = DaemonModel.Configuration()
        configuration.port = port
        configuration.tokenFile = tokenFile
        // A slow pulse, so anything that arrives arrived by the event stream.
        configuration.pulse = .seconds(30)
        let model = DaemonModel(configuration: configuration)
        model.connect()
        defer { model.shutdown() }
        #expect(await eventually { model.status == .running })

        #expect(await eventually(.seconds(3)) { model.streamStatus["microphone:stub"] != nil })
        let first = model.streamStatus["microphone:stub"]?.framesWritten ?? 0
        #expect(model.levels["microphone:stub"] == -20)
        // And keeps arriving.
        #expect(
            await eventually(.seconds(3)) {
                (model.streamStatus["microphone:stub"]?.framesWritten ?? 0) > first
            })
    }

    @Test("The token is read from the file; a stale one is a refusal, not a relaunch")
    func tokenLoading() async throws {
        let port = StubDaemon.freePort()
        let scratch = StubDaemon.scratch()
        let tokenFile = scratch.appendingPathComponent("token")
        try ("cd" * 32 + "\n").write(to: tokenFile, atomically: true, encoding: .utf8)
        let theirs = try StubDaemon.launch(port: port, tokenFile: tokenFile)
        defer { theirs.terminate() }
        #expect(await StubDaemon.waitUntilAnswers(port: port, token: "cd" * 32))

        // Right token: paired.
        let paired = model(port: port, scratch: scratch)
        paired.connect()
        #expect(await eventually { paired.status == .running })
        #expect(paired.startedByUs == false)
        paired.shutdown()

        // Wrong token: the daemon answers 401, and launching another daemon
        // behind it would not help — so this is "down", with the reason.
        let other = StubDaemon.scratch()
        try ("ef" * 32 + "\n").write(
            to: other.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let refused = model(port: port, scratch: other)
        refused.connect()
        #expect(
            await eventually {
                if case .down(let why) = refused.status { return why.contains("401") }
                return false
            })
        #expect(refused.corePID == nil)
        refused.shutdown()
    }
}

extension String {
    fileprivate static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
