import Foundation

/// The bearer token, provisioned to a file so same-machine apps pair with
/// zero clicks (spec §11).
///
/// `~/Library/Application Support/Rheocles/token`, mode 0600, created on the
/// daemon's first launch. Any process running as the user reads it and is
/// paired; a web page in the user's browser cannot, which is the whole threat
/// model on loopback. Rotation writes a new token and the old one stops
/// working on the next request.
///
/// The token is 32 random bytes as 64 hex characters: plain ASCII, no
/// padding, safe in a header, a query string or a pairing code shown in a UI.
public struct TokenStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location.
    public static var standard: TokenStore {
        TokenStore(fileURL: Rheocles.applicationSupport.appendingPathComponent("token"))
    }

    /// The current token, creating one if the file does not exist.
    ///
    /// A file that exists but is empty or malformed is replaced rather than
    /// served: an empty token would authenticate `Authorization: Bearer ` and
    /// a lock that opens for nothing is worse than none.
    public func loadOrCreate() throws -> String {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isWellFormed(trimmed) {
                try enforcePermissions()
                return trimmed
            }
        }
        return try rotate()
    }

    /// Replace the token. Returns the new one.
    @discardableResult
    public func rotate() throws -> String {
        let token = Self.generate()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Write with the final mode from the first byte: create-then-chmod
        // leaves a window where the file is world-readable.
        let tmp = fileURL.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try Data((token + "\n").utf8).write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        try enforcePermissions()
        return token
    }

    /// Re-assert 0600. A user who chmods the file to share it with another
    /// account has defeated the point; the daemon quietly puts it back.
    private func enforcePermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.count == 64 && token.allSatisfy { $0.isHexDigit }
    }
}

/// Checks a presented credential against the token.
///
/// Accepts `Authorization: Bearer <token>` on any request, and — for the two
/// places a browser cannot set a header, `EventSource` and `WebSocket` — the
/// same token as an `access_token` query parameter (RFC 6750 §2.3) or as the
/// first WebSocket message. Loopback only, so the URL form costs nothing a
/// local page could not already see in the header form.
public struct BearerAuth: Sendable {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    /// Compare a candidate token in constant time.
    public func matches(token candidate: String?) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    /// Compare an `Authorization` header value.
    public func matches(header: String?) -> Bool {
        guard let header else { return false }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return matches(token: parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// Header first, then the query parameter.
    public func authorizes(_ request: Request) -> Bool {
        matches(header: request.headers["authorization"])
            || matches(token: request.query["access_token"])
    }
}
