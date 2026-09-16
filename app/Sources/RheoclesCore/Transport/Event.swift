import Foundation

/// Everything `GET /events` carries and every WebSocket client receives.
///
/// One JSON object per event, always with an `event` key naming the kind.
/// Built here as strings so both transports send exactly the same bytes.
public enum Event {
    /// A stream's armed state changed.
    public static func stream(_ stream: StreamInfo) -> String {
        encode(["event": "stream", "stream": stream])
    }

    /// A take changed state (created, recording, complete, incomplete).
    public static func take(_ manifest: Manifest) -> String {
        encode(["event": "take", "take": manifest])
    }

    /// A marker was added.
    public static func marker(takeID: String, marker: Manifest.Marker) -> String {
        encode(["event": "marker", "take": takeID, "marker": marker])
    }

    /// Per-stream levels, drift and frame counts while recording. Emitted a
    /// few times a second; a client renders meters and a drift readout.
    public static func levels(takeID: String, streams: [StreamStatus]) -> String {
        encode(["event": "levels", "take": takeID, "streams": streams])
    }

    /// An armed or recording stream stopped delivering frames.
    public static func stalled(_ stream: StreamInfo) -> String {
        encode(["event": "stalled", "stream": stream])
    }

    /// A recording stream is dropping frames faster than a threshold (~5% over
    /// the last 10 s): the encoder cannot keep up. The file stays CFR — the
    /// drops become duplicated frames — but the footage is degraded, so a
    /// client can warn. `dropRate` is the fraction over the window.
    public static func overloaded(_ stream: StreamInfo, dropRate: Double) -> String {
        encode(["event": "overloaded", "stream": stream, "dropRate": dropRate])
    }

    /// The daemon's settings changed.
    public static func settings(_ values: Settings.Values) -> String {
        encode(["event": "settings", "settings": values])
    }

    private static func encode(_ fields: [String: any Encodable & Sendable]) -> String {
        struct Box: Encodable {
            let fields: [String: any Encodable & Sendable]
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                for (key, value) in fields {
                    try container.encode(AnyEncodable(value), forKey: Key(key))
                }
            }
        }
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        struct AnyEncodable: Encodable {
            let value: any Encodable
            init(_ value: any Encodable) { self.value = value }
            func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
        }
        let data = (try? Response.encoder.encode(Box(fields: fields))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// One stream's live status inside a `levels` event.
public struct StreamStatus: Codable, Sendable, Equatable {
    public let id: String
    /// Peak level in dBFS since the last event, for audio streams; nil for video.
    public let levelDb: Double?
    public let framesWritten: Int
    public let drift: Double?
    /// Frames the encoder has dropped so far; nil (omitted) when none.
    public let framesDropped: Int?
    /// The true incoming rate, for video; nil for audio and before measurable.
    public let measuredFrameRate: Double?
    /// True while the encoder is saturated and padding is suspended — the file
    /// is held-frame, not strictly CFR, for this span. Absent otherwise.
    public let paddingOff: Bool?

    public init(
        id: String, levelDb: Double?, framesWritten: Int, drift: Double?,
        framesDropped: Int? = nil, measuredFrameRate: Double? = nil, paddingOff: Bool? = nil
    ) {
        self.id = id
        self.levelDb = levelDb
        self.framesWritten = framesWritten
        self.drift = drift
        self.framesDropped = framesDropped
        self.measuredFrameRate = measuredFrameRate
        self.paddingOff = paddingOff
    }
}
