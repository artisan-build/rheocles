import CoreMedia
import Foundation

/// The one clock every stamp derives from (S3).
///
/// Sample buffers carry host-time presentation timestamps. One offset
/// between the host clock and the wall clock, captured once, turns any PTS
/// into a wall time more precisely than reading `Date()` in a callback that
/// ran some milliseconds after the sample. Time-of-day is local, as
/// timecode is; the manifest carries UTC.
public struct HostClock: Sendable {
    /// Wall seconds since 1970 minus host seconds, at capture.
    public let offset: TimeInterval

    public init() {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        offset = Date().timeIntervalSince1970 - host
    }

    public init(offset: TimeInterval) {
        self.offset = offset
    }

    public static let shared = HostClock()

    public func date(forHostSeconds host: Double) -> Date {
        Date(timeIntervalSince1970: host + offset)
    }

    public func date(for time: CMTime) -> Date {
        date(forHostSeconds: time.seconds)
    }

    public var nowHostSeconds: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Seconds since local midnight, with fraction.
    public static func secondsSinceMidnight(_ date: Date, calendar: Calendar = .current) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    /// Time-of-day frame number at `fps`, rounded to the nearest frame (S3:
    /// flooring puts video up to a frame early; nearest halves the worst case).
    public static func frames(sinceMidnightOf date: Date, fps: Int) -> Int {
        Int((secondsSinceMidnight(date) * Double(fps)).rounded()) % (24 * 3600 * fps)
    }

    /// `HH:MM:SS:FF`, non-drop.
    public static func timecode(frames: Int, fps: Int) -> String {
        let s = frames / fps
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, frames % fps)
    }

    /// The integer frame rate a `tmcd` track counts in: 59.94 and 60.00024
    /// both count in 60; the file's own frame timing carries the exact rate.
    public static func timecodeRate(for frameRate: Double) -> Int {
        max(1, Int(frameRate.rounded()))
    }
}
