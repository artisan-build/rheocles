import Foundation
import os

/// Daemon-owned defaults, persisted to
/// `~/Library/Application Support/Rheocles/settings.json` (spec §12): the
/// output root new takes land under and the default codec. Read on `GET /`
/// and `GET /settings`, changed by `PATCH /settings`, and shared with the
/// take engine, which reads the current root at each create.
///
/// A class behind a lock so the HTTP handler, the take engine and discovery
/// all see one value.
public final class Settings: Sendable {
    public struct Values: Codable, Sendable, Equatable {
        public var outputRoot: String
        public var codec: Manifest.Codec

        public init(outputRoot: String, codec: Manifest.Codec) {
            self.outputRoot = outputRoot
            self.codec = codec
        }
    }

    private let state: OSAllocatedUnfairLock<Values>
    private let fileURL: URL
    private let onChange: @Sendable (Values) -> Void

    public init(
        fileURL: URL, defaults: Values, onChange: @escaping @Sendable (Values) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.onChange = onChange
        if let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(Values.self, from: data)
        {
            state = OSAllocatedUnfairLock(initialState: stored)
        } else {
            state = OSAllocatedUnfairLock(initialState: defaults)
        }
    }

    public var values: Values { state.withLock { $0 } }

    public var outputRoot: URL { URL(fileURLWithPath: values.outputRoot) }

    public var codec: Manifest.Codec { values.codec }

    /// Apply a partial change, persist it, and announce it. Validation
    /// (e.g. refusing an outputRoot change mid-take) is the caller's.
    @discardableResult
    public func update(outputRoot newRoot: String? = nil, codec newCodec: Manifest.Codec? = nil)
        -> Values
    {
        let updated = state.withLock { values -> Values in
            if let newRoot { values.outputRoot = newRoot }
            if let newCodec { values.codec = newCodec }
            return values
        }
        persist(updated)
        onChange(updated)
        return updated
    }

    private func persist(_ values: Values) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(values) { try? data.write(to: fileURL, options: .atomic) }
    }
}
