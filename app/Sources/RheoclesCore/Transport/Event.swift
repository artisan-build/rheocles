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
