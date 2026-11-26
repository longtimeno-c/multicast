import Foundation
import os

/// Timing logs for the click-to-playing path (Console / `log stream`, subsystem
/// `io.github.longtimeno-c.multicast`, category `timing`). Durations only, never ids or names.
public enum MulticastTiming {
    public static let log = Logger(subsystem: "io.github.longtimeno-c.multicast", category: "timing")

    /// Milliseconds since `start` (a `DispatchTime.now().uptimeNanoseconds` reading).
    @inlinable public static func ms(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    @inlinable public static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}
