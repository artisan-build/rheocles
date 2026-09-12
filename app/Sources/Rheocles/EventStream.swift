import Foundation

/// `GET /events`, read as server-sent events.
///
/// One long-lived request; `data: <json>` lines, blank line between events,
/// `: connected` on open (PROTOCOL § Events). The app reads it so that a
/// stream armed by another client, or a take started over the API, shows
/// in the popover the moment it happens rather than on the next pulse. The
/// pulse stays as the fallback: an event stream that drops is reconnected,
/// and nothing the app shows depends on having seen every event.
enum EventStream {
    /// One decoded event: its kind, and the whole object for the handler.
    struct Message {
        let kind: String
        let json: [String: Any]
        let raw: Data
    }

    /// Read events until the connection drops or the task is cancelled.
    /// Throws on a failure to connect; returns when the server closes.
    static func read(_ url: URL, handle: @escaping @MainActor (Message) -> Void) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = .infinity
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Split on newlines by hand. `bytes.lines` drops empty lines, and
        // the empty line is the one that ends an SSE event — with it gone,
        // every `data:` line joins one endless event that never dispatches.
        // (That is how the first four tasks' "live" updates were all the
        // three-second pulse, and nobody noticed.)
        var buffer: [UInt8] = []
        var data = ""
        for try await byte in bytes {
            if byte != UInt8(ascii: "\n") {
                buffer.append(byte)
                continue
            }
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.isEmpty {
                // End of one event.
                if !data.isEmpty, let message = decode(data) {
                    await handle(message)
                }
                data = ""
            } else if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).drop(while: { $0 == " " })
                data += (data.isEmpty ? "" : "\n") + payload
            }
            // Comments (`: connected`) and other fields are ignored.
        }
        // A trailing event without its blank line.
        if !data.isEmpty, let message = decode(data) {
            await handle(message)
        }
    }

    private static func decode(_ text: String) -> Message? {
        let raw = Data(text.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let kind = json["event"] as? String
        else { return nil }
        return Message(kind: kind, json: json, raw: raw)
    }
}
