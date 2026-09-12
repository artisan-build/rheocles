import Foundation

/// `GET /` — who am I, where do files go, how much room is there.
///
/// This is the first call every client makes. `outputRoot` is the one
/// absolute path in the whole API: every other path is relative to it
/// (spec §11), and `machineId` plus `hostname` are what a manifest carries so
/// a take stays legible after the machine is gone.
public struct Discovery: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let hostname: String
    public let machineId: String
    public let outputRoot: String
    /// Bytes available to this user on the output root's volume — measured on
    /// the nearest existing ancestor when the root itself has not been created
    /// yet. Absent means unmeasured, never zero.
    public let freeBytes: Int64?
    public let auth: String
    public let ports: Ports

    public struct Ports: Codable, Sendable, Equatable {
        public let http: UInt16
        public let ws: UInt16
    }

    public static func current(outputRoot: URL, httpPort: UInt16, wsPort: UInt16) -> Discovery {
        Discovery(
            name: "Rheocles",
            version: Rheocles.version,
            hostname: ProcessInfo.processInfo.hostName,
            machineId: machineIdentifier(),
            outputRoot: outputRoot.path,
            freeBytes: freeBytes(at: outputRoot),
            auth: "bearer",
            ports: Ports(http: httpPort, ws: wsPort))
    }

    /// The kernel's host UUID — stable across reboots and renames, unlike the
    /// hostname, and readable without IOKit.
    public static func machineIdentifier() -> String {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&uuid, &timeout) == 0 else { return "unknown" }
        return UUID(uuid: uuid).uuidString
    }

    /// "Important usage" capacity: what the system would actually let us
    /// write, after purgeable space is reclaimed, not the raw free count.
    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        return (try? probe.resourceValues(forKeys: keys))?.volumeAvailableCapacityForImportantUsage
    }
}
