import Foundation

/// A directory under $TMPDIR that one test owns, gone when the test is.
///
/// Swift Testing makes one suite instance per test and lets it go when the
/// test returns, so a suite that keeps its `Scratch` in a stored property has
/// the directory for exactly the test's lifetime and `deinit` is the teardown.
/// Anything a test builds on the directory and hands around — a `World`, an
/// engine's `outputRoot` closure — should hold the `Scratch` itself, not a
/// path into it, so the directory outlives its last user and not the test.
///
/// Before this, 9,266 `rheocles-*tests-*` directories sat in $TMPDIR (14 Sep
/// 2026); the media tests had written real takes into them.
final class Scratch: Sendable {
    let url: URL

    init(_ label: String = "tests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rheocles-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A fresh subdirectory, created, for a test that needs more than one root.
    func directory(_ name: String = UUID().uuidString) -> URL {
        let dir = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A path inside, for a file the test will write.
    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
