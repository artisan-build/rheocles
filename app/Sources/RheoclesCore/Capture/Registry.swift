import Foundation

/// Every armed stream, and the one place arming happens.
///
/// "Armed means the device is live" (spec §6): the session runs, frames flow
/// and are discarded, so the cue starts a writer on frames that already
/// exist. Arming never stamps and never writes; disarming a joined stream
/// implies leave (step 6). One actor, so arm and disarm serialize and the
/// armed set is always consistent with the sessions that exist.
public actor Registry {
    private let catalog: any StreamSource
    private let factory: any SessionFactory
    private var sessions: [String: any StreamSession] = [:]
    /// Told about every change in armed state, for the event stream.
    private let onChange: @Sendable (StreamInfo) -> Void

    public init(
        catalog: any StreamSource, factory: any SessionFactory,
        onChange: @escaping @Sendable (StreamInfo) -> Void = { _ in }
    ) {
        self.catalog = catalog
        self.factory = factory
        self.onChange = onChange
    }

    /// The catalog's streams with armed state and, when armed, what the
    /// device is actually delivering.
    public func streams() async -> [StreamInfo] {
        await catalog.streams().map { decorate($0) }
    }

    public func stream(_ id: String) async -> StreamInfo? {
        await streams().first { $0.id == id }
    }

    public var armedIDs: [String] { Array(sessions.keys).sorted() }

    public func session(for id: String) -> (any StreamSession)? { sessions[id] }

    private func decorate(_ stream: StreamInfo) -> StreamInfo {
        var stream = stream
        if let session = sessions[stream.id] {
            stream.armed = true
            stream.active = session.active
            stream.framesSeen = session.framesSeen
        }
        return stream
    }

    /// Open the device and hold it. Idempotent.
    @discardableResult
    public func arm(_ id: String) async throws -> StreamInfo {
        if let existing = sessions[id] { return decorate(existing.info) }
        guard let stream = await catalog.streams().first(where: { $0.id == id }) else {
            throw APIError.notFound("no such stream: \(id)")
        }
        let session: any StreamSession
        do {
            session = try factory.makeSession(for: stream)
            try await session.start()
        } catch let error as CaptureError {
            throw error.apiError
        }
        sessions[id] = session
        let armed = decorate(stream)
        onChange(armed)
        return armed
    }

    /// Release the device. Idempotent; a stream that vanished from the
    /// catalog while armed can still be disarmed.
    @discardableResult
    public func disarm(_ id: String) async throws -> StreamInfo {
        guard let session = sessions.removeValue(forKey: id) else {
            guard let stream = await catalog.streams().first(where: { $0.id == id }) else {
                throw APIError.notFound("no such stream: \(id)")
            }
            return stream
        }
        await session.stop()
        var stream = session.info
        stream.armed = false
        stream.active = nil
        stream.framesSeen = nil
        onChange(stream)
        return stream
    }

    /// Release everything, for shutdown. Silent — no per-stream event, since
    /// the transports are coming down with it.
    public func disarmAll() async {
        for (_, session) in sessions { await session.stop() }
        sessions.removeAll()
    }

    /// Disarm every armed stream, announcing each — the "disarm all" button.
    /// Returns the full stream list afterwards.
    public func disarmArmed() async -> [StreamInfo] {
        for id in Array(sessions.keys) { _ = try? await disarm(id) }
        return await streams()
    }
}
