import Foundation
import Testing
import MulticastAudio
@testable import MulticastDiscovery

/// Browses the real LAN. Run with `MULTICAST_LIVE=1 swift test --filter LiveDiscovery`.
/// Passive only: it browses and resolves Bonjour records, it never connects to a speaker.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE"] == "1"), .serialized)
struct LiveDiscoveryTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// Collect snapshots for `seconds`, return the last one and how many snapshots arrived.
    private func browse(_ browser: SpeakerBrowser, seconds: Double) async -> (last: [SpeakerDescriptor], count: Int) {
        let stream = browser.snapshots
        let task = Task { () -> ([SpeakerDescriptor], Int) in
            var last: [SpeakerDescriptor] = []
            var count = 0
            for await snap in stream {
                last = snap
                count += 1
            }
            return (last, count)
        }
        browser.start()
        try? await Task.sleep(for: .seconds(seconds))
        let snapshot = browser.currentSpeakers
        task.cancel()
        let (_, count) = await task.value
        return (snapshot, count)
    }

    private func describe(_ s: SpeakerDescriptor) -> String {
        let flags = [
            s.isAirConnectBridge ? "bridge" : nil,
            s.requiresPassword ? "pw" : nil,
            s.isThisMachine ? "this-mac" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        return "\(s.transport.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(s.id)  \(s.name)  "
            + "\(s.host ?? "?"):\(s.port.map(String.init) ?? "?")  model=\(s.model ?? "-") mfr=\(s.manufacturer ?? "-") "
            + "et=\(s.encryptionTypeCodes) cn=\(s.codecCodes) ft=\(s.features) airplayTXT=\(s.airplayTXT.isEmpty ? "no" : "yes") [\(flags)]"
    }

    @Test func browseLAN() async throws {
        let log = Log()
        let browser = SpeakerBrowser(configuration: .init(hideThisMachine: true, log: { log.add($0) }))
        let start = Date()
        let (speakers, snapshots) = await browse(browser, seconds: 5)
        browser.stop()
        #expect(browser.currentSpeakers.isEmpty, "stop() publishes an empty snapshot")

        print("---- SpeakerBrowser live: \(speakers.count) speakers after \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(snapshots) snapshots, lastError=\(browser.lastError.map(String.init) ?? "none")")
        for s in speakers { print("  " + describe(s)) }
        for c in speakers.physicalDeviceConflicts() { print("  same physical device: \(c.map(\.name))") }
        print("  dns-sd events: \(log.all.count)")
        for line in log.all.prefix(60) { print("    " + line) }

        #expect(!speakers.isEmpty)
        #expect(Set(speakers.map(\.id)).count == speakers.count)
        #expect(!speakers.contains { $0.isThisMachine })
        #expect(speakers.allSatisfy { $0.host != nil && $0.port != nil })
        #expect(speakers == SpeakerCatalog.sorted(speakers))
    }

    @Test func restartAndShowThisMachine() async throws {
        let browser = SpeakerBrowser(configuration: .init(hideThisMachine: false))
        let (first, _) = await browse(browser, seconds: 2)
        browser.stop()
        let (second, _) = await browse(browser, seconds: 2)
        browser.stop()
        print("---- restart: first=\(first.count) second=\(second.count); this machine: \(second.filter(\.isThisMachine).map { "\($0.id) \($0.name)" })")
        #expect(!second.isEmpty)
        #expect(second.count >= first.count - 1)
    }
}
