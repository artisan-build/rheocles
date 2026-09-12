import Foundation
import os

/// Where the app writes what it did.
///
/// No Terminal windows: the app is launched with `open` and the daemon is a
/// child with no tty, so both log to files under `~/Library/Logs/Rheocles/`
/// where `tail -f` and a bug report can find them. The app's own lines also
/// go to the unified log for `log stream --predicate 'subsystem == "build.artisan.rheocles"'`.
enum Log {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Rheocles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let appLog = directory.appending(path: "Rheocles.log")
    static let daemonLog = directory.appending(path: "rheocles-core.log")

    private static let logger = Logger(subsystem: "build.artisan.rheocles", category: "app")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("\(stamp.string(from: Date())) \(message)\n")
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: appLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: appLog)
        }
    }
}
