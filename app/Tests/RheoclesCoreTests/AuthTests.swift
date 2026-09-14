import Foundation
import Testing

@testable import RheoclesCore

/// The token file is how every same-machine client pairs, and its mode is the
/// whole reason a hostile page cannot.
@Suite("Token store")
struct TokenStoreTests {
    private let scratch = Scratch()

    private func temporaryStore() -> TokenStore {
        TokenStore(fileURL: scratch.directory().appendingPathComponent("Rheocles/token"))
    }

    @Test("First launch creates a 64-hex token with mode 0600 in a fresh directory")
    func creates() throws {
        let store = temporaryStore()
        let token = try store.loadOrCreate()

        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == token + "\n")
    }

    @Test("A later launch reads the same token back")
    func reuses() throws {
        let store = temporaryStore()
        let first = try store.loadOrCreate()
        #expect(try store.loadOrCreate() == first)
    }

    @Test("Rotation replaces the token and the old one no longer matches")
    func rotates() throws {
        let store = temporaryStore()
        let first = try store.loadOrCreate()
        let second = try store.rotate()
        #expect(first != second)
        #expect(try store.loadOrCreate() == second)
        #expect(!BearerAuth(token: second).matches(token: first))
    }

    /// An empty token would authenticate `Authorization: Bearer ` — a lock that
    /// opens for nothing. Anything malformed is replaced, not served.
    @Test(
        "An empty or malformed file is replaced rather than trusted",
        arguments: ["", "\n", "short", "zz"])
    func replacesMalformed(_ contents: String) throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.fileURL)
        let token = try store.loadOrCreate()
        #expect(token.count == 64)
    }

    @Test("A loosened mode is put back to 0600 on load")
    func reassertsMode() throws {
        let store = temporaryStore()
        _ = try store.loadOrCreate()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        _ = try store.loadOrCreate()
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite("Bearer auth")
struct BearerAuthTests {
    private let token = String(repeating: "ab", count: 32)
    private var auth: BearerAuth { BearerAuth(token: token) }

    @Test("The right token in the header is accepted, case-insensitively on the scheme")
    func header() {
        #expect(auth.matches(header: "Bearer \(token)"))
        #expect(auth.matches(header: "bearer \(token)"))
        #expect(auth.matches(header: "BEARER \(token)"))
    }

    @Test("The right token as access_token is accepted")
    func query() {
        let request = Request(method: "GET", path: "/events", query: ["access_token": token])
        #expect(auth.authorizes(request))
    }

    @Test(
        "Everything else is refused without crashing",
        arguments: [
            nil, "", "Bearer", "Bearer ", "Basic abc", "Bearer nope",
            "Bearer " + String(repeating: "ab", count: 31),
            "Bearer " + String(repeating: "ab", count: 32) + "0",
            "Token " + String(repeating: "ab", count: 32),
        ])
    func refuses(_ header: String?) {
        #expect(!auth.matches(header: header))
    }

    @Test("An empty token never matches, even an empty candidate")
    func emptyToken() {
        #expect(!BearerAuth(token: "").matches(token: ""))
    }
}
