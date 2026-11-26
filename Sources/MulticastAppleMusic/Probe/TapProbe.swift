#if os(macOS)
import CoreAudio
import Foundation
import MulticastSources

/// What a process tap delivered over a short measurement window.
public struct TapMeasurement: Sendable, Equatable, CustomStringConvertible {
    public var target: String
    public var state: String
    public var permission: String
    public var framesRead: Int
    /// Largest absolute S16 sample seen (0 = digital silence).
    public var peak: Int
    public var rms: Double
    public var ioCycles: Int64
    public var nonSilentCycles: Int64

    public var isNonSilent: Bool { peak > 0 && nonSilentCycles > 0 }

    public var description: String {
        "tap[\(target)] state=\(state) permission=\(permission) frames=\(framesRead) peak=\(peak) "
            + String(format: "rms=%.1f", rms) + " ioCycles=\(ioCycles) nonSilentCycles=\(nonSilentCycles)"
    }
}

/// Opens a process tap (muted while tapped, so nothing is heard locally), pulls from it at
/// roughly real time for `seconds`, and reports whether real samples arrived.
@available(macOS 14.2, *)
public enum TapProbe {
    public static func measure(_ target: AppAudioTapSource.Target, seconds: Double,
                               muteBehavior: AppAudioTapSource.MuteBehavior = .mutedWhenTapped) async -> TapMeasurement {
        await measure(AppAudioTapSource(target: target, muteBehavior: muteBehavior, displayName: "Multicast probe"), seconds: seconds)
    }

    /// Measures an existing tap source (started and stopped here).
    public static func measure(_ source: AppAudioTapSource, seconds: Double) async -> TapMeasurement {
        var m = TapMeasurement(target: source.target.description, state: "idle", permission: "unknown", framesRead: 0,
                               peak: 0, rms: 0, ioCycles: 0, nonSilentCycles: 0)
        do {
            try await source.start()
        } catch {
            m.state = "start failed: \(error)"
            return m
        }
        let frames = 1024
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        defer { buffer.deallocate() }
        var sumSquares = 0.0
        var samples = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = source.read(into: buffer, frameCount: frames) ?? 0
            if n > 0 {
                m.framesRead += n
                for i in 0..<(n * 2) {
                    let s = Int(buffer[i])
                    m.peak = max(m.peak, abs(s))
                    sumSquares += Double(s * s)
                }
                samples += n * 2
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        m.rms = samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0
        let status = source.status
        let stats = source.statistics
        m.state = "\(status.state)"
        m.permission = "\(status.permission)"
        m.ioCycles = stats.ioCycles
        m.nonSilentCycles = stats.nonSilentCycles
        await source.stop()
        return m
    }

    /// One line per Core Audio client process that is currently running output.
    public static func describeOutputProcesses() -> [String] {
        AudioProcessDirectory.snapshot().filter(\.isRunningOutput).map(describe)
    }

    public static func describe(_ p: AudioProcessInfo) -> String {
        "obj=\(p.objectID) pid=\(p.pid) bundle=\(p.bundleID ?? "-") app=\(p.appBundleID ?? "-") name=\(p.name)"
            + " exe=\(p.executablePath.map { ($0 as NSString).lastPathComponent } ?? "-")"
            + (p.isCurrentProcess ? " [THIS PROCESS]" : "")
    }
}
#endif
