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
        /// Default for a take's `combine` option — write a single combined.mov
        /// alongside the per-stream files. Default false.
        public var combine: Bool

        public init(outputRoot: String, codec: Manifest.Codec, combine: Bool = false) {
            self.outputRoot = outputRoot
            self.codec = codec
            self.combine = combine
        }

        // `combine` was added after the first settings shipped; decode an
        // older settings.json / event that predates it as false rather than
        // failing, so a stored root is not discarded and older clients keep
        // working.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outputRoot = try c.decode(String.self, forKey: .outputRoot)
            codec = try c.decode(Manifest.Codec.self, forKey: .codec)
            combine = try c.decodeIfPresent(Bool.self, forKey: .combine) ?? false
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

    public var combine: Bool { values.combine }

    /// Apply a partial change, persist it, and announce it. Validation
    /// (e.g. refusing an outputRoot change mid-take) is the caller's.
    @discardableResult
    public func update(
        outputRoot newRoot: String? = nil, codec newCodec: Manifest.Codec? = nil,
        combine newCombine: Bool? = nil
    ) -> Values {
        let updated = state.withLock { values -> Values in
            if let newRoot { values.outputRoot = newRoot }
            if let newCodec { values.codec = newCodec }
            if let newCombine { values.combine = newCombine }
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
