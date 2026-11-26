#if os(macOS)
import CoreAudio
import Foundation
import MulticastAudio
import Testing
@testable import MulticastSources

@Suite struct LiveFillControllerTests {
    @Test func primesBeforeDelivering() {
        var c = LiveFillController(targetFrames: 1000)
        #expect(c.decide(available: 500, requested: 352) == .wait)
        #expect(c.decide(available: 999, requested: 352) == .wait)
        #expect(c.decide(available: 1000, requested: 352) == .read(frames: 352))
        #expect(!c.priming)
    }

    @Test func underrunReprimes() {
        var c = LiveFillController(targetFrames: 1000)
        _ = c.decide(available: 1000, requested: 352)
        #expect(c.decide(available: 0, requested: 352) == .wait)
        #expect(c.priming)
        #expect(c.decide(available: 600, requested: 352) == .wait)
    }

    @Test func driftCorrectionBands() {
        var c = LiveFillController(targetFrames: 1000) // low 500, high 2000, max 5000
        _ = c.decide(available: 1000, requested: 352)
        #expect(c.decide(available: 1200, requested: 352) == .read(frames: 352))
        #expect(c.decide(available: 2500, requested: 352) == .readDroppingOne(frames: 352))
        #expect(c.decide(available: 700, requested: 352) == .readDuplicatingOne(frames: 352))
        #expect(c.decide(available: 200, requested: 352) == .read(frames: 200))
        #expect(c.decide(available: 9000, requested: 352) == .resync(drop: 8000, frames: 352))
    }

    @Test func steadyStateNeverCorrectsWhenAtTarget() {
        var c = LiveFillController(targetFrames: 4410)
        var avail = 4410
        var corrections = 0
        for _ in 0..<10_000 {
            switch c.decide(available: avail + 352, requested: 352) {
            case .read: break
            default: corrections += 1
            }
            avail = 4410
        }
        #expect(corrections == 0)
    }
}

@Suite struct AudioProcessDirectoryTests {
    @Test func bundleMatching() {
        #expect(AudioProcessDirectory.bundleID("com.spotify.client", matchesApp: "com.spotify.client"))
        #expect(AudioProcessDirectory.bundleID("com.spotify.client.helper", matchesApp: "com.spotify.client"))
        #expect(AudioProcessDirectory.bundleID("COM.Apple.Music", matchesApp: "com.apple.Music"))
        #expect(!AudioProcessDirectory.bundleID("com.spotify.clientX", matchesApp: "com.spotify.client"))
        #expect(!AudioProcessDirectory.bundleID(nil, matchesApp: "com.spotify.client"))
        #expect(!AudioProcessDirectory.bundleID("com.spotify.client", matchesApp: ""))
    }

    @Test func outermostAppBundle() {
        let p = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(AudioProcessDirectory.outermostAppBundle(containing: p)?.path == "/Applications/Google Chrome.app")
        #expect(AudioProcessDirectory.outermostAppBundle(containing: "/usr/bin/afplay") == nil)
    }

    @Test func tapTargetDescriptions() {
        if #available(macOS 14.2, *) {
            #expect(AppAudioTapSource.Target.system.description == "System audio")
            #expect(AppAudioTapSource.Target.apps(bundleIDs: ["com.spotify.client"]).description == "com.spotify.client")
        }
    }
}

/// Live hardware tests. Run with `MULTICAST_LIVE=1 swift test --filter Live`.
@Suite(.serialized, .enabled(if: TestAudio.liveEnabled))
struct LiveMacTests {
    @Test func listAudioProcesses() {
        let procs = AudioProcessDirectory.snapshot()
        print("[live] \(procs.count) Core Audio process objects:")
        for p in procs.sorted(by: { $0.name < $1.name }) {
            print("[live]   obj=\(p.objectID) pid=\(p.pid) name=\(p.name) bundle=\(p.bundleID ?? "-") app=\(p.appBundleID ?? "-") out=\(p.isRunningOutput) in=\(p.isRunningInput) self=\(p.isCurrentProcess)")
        }
        #expect(!procs.isEmpty)
        print("[live] own process object: \(AudioProcessDirectory.currentProcessObject().map(String.init) ?? "nil")")
    }

    @Test func processDirectoryPublishesUpdates() async throws {
        let dir = AudioProcessDirectory()
        var it = dir.updates.makeAsyncIterator()
        let first = await it.next()
        #expect(first != nil)
        print("[live] directory first snapshot: \(first?.count ?? -1) processes")
    }

    private func runAfplay() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", "0.3", "/System/Library/Sounds/Glass.aiff"]
        try p.run()
        return p
    }

    /// Pulls like the engine (real-time pace) for `seconds`, returns (nonZeroSamples, totalFrames, peak).
    private func pull(_ src: AudioSource, seconds: Double) -> (Int, Int, Int) {
        var buf = [Int16](repeating: 0, count: 352 * 2)
        var nonZero = 0, total = 0, peak = 0
        let start = HostClock.nowNanos()
        let packets = Int(seconds * 44_100 / 352)
        for k in 0..<packets {
            // Absolute schedule, like the engine's pacing thread.
            let due = start + PCM.nanos(forFrames: UInt64(k * 352))
            let now = HostClock.nowNanos()
            if due > now { usleep(UInt32((due - now) / 1000)) }
            let n = buf.withUnsafeMutableBufferPointer { src.read(into: $0.baseAddress!, frameCount: 352) } ?? 0
            for i in 0..<(n * 2) where buf[i] != 0 {
                nonZero += 1
                peak = max(peak, abs(Int(buf[i])))
            }
            total += n
        }
        return (nonZero, total, peak)
    }

    @available(macOS 14.2, *)
    @Test func systemTapCapturesAfplay() async throws {
        let cleaned = AppAudioTapSource.cleanupStaleDevices()
        print("[live] stale cleanup: \(cleaned)")
        let src = AppAudioTapSource(target: .system, muteBehavior: .unmuted)
        do {
            try await src.start()
        } catch {
            print("[live] system tap start FAILED: \(error)")
            Issue.record("tap start failed: \(error)")
            return
        }
        print("[live] status after start: \(src.status)")
        print("[live] visible multicast devices while running: \(AppAudioTapSource.visibleMulticastDevices())")
        try await Task.sleep(nanoseconds: 300_000_000)
        let player = try runAfplay()
        let (nz, total, peak) = pull(src, seconds: 2.5)
        player.waitUntilExit()
        let stats = src.statistics
        let status = src.status
        print("[live] system tap: pulled \(total) frames, nonZero samples \(nz), peak \(peak)")
        print("[live] stats: \(stats)")
        print("[live] status: \(status)")
        await src.stop()
        print("[live] visible multicast devices right after stop: \(AppAudioTapSource.visibleMulticastDevices())")
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = AppAudioTapSource.visibleMulticastDevices()
        print("[live] visible multicast devices 0.5 s after stop: \(after)")
        #expect(after.aggregates.isEmpty && after.taps.isEmpty)
        #expect(stats.ioCycles > 0)
    }

    @available(macOS 14.2, *)
    @Test func processTapCapturesAfplayByProcessObject() async throws {
        let player = try runAfplay()
        defer { if player.isRunning { player.terminate() } }
        var obj: AudioObjectID?
        for _ in 0..<50 {
            obj = AudioProcessDirectory.processObject(forPID: player.processIdentifier)
            if obj != nil { break }
            usleep(10_000)
        }
        guard let obj else {
            print("[live] afplay never became a Core Audio client")
            return
        }
        let src = AppAudioTapSource(target: .processObjects([obj]), muteBehavior: .mutedWhenTapped)
        try await src.start()
        let (nz, total, peak) = pull(src, seconds: 1.5)
        print("[live] afplay process tap (obj \(obj)): pulled \(total) frames, nonZero \(nz), peak \(peak), stats \(src.statistics), status \(src.status)")
        await src.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(AppAudioTapSource.visibleMulticastDevices().aggregates.isEmpty)
        #expect(nz > 0 || src.status.permission != .granted)
    }

    /// Source deallocated without stop(): deinit must tear down tap + aggregate.
    @available(macOS 14.2, *)
    @Test func deinitDestroysDevices() async throws {
        do {
            let src = AppAudioTapSource(target: .system, muteBehavior: .unmuted)
            try await src.start()
            #expect(AppAudioTapSource.visibleMulticastDevices().taps.count == 1)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        let after = AppAudioTapSource.visibleMulticastDevices()
        print("[live] after deinit: \(after)")
        #expect(after.aggregates.isEmpty && after.taps.isEmpty)
    }

    /// The global tap must list this process among the excluded ones (feedback-loop guard).
    @available(macOS 14.2, *)
    @Test func systemTapExcludesOwnProcess() async throws {
        let src = AppAudioTapSource(target: .system)
        try await src.start()
        let me = AudioProcessDirectory.currentProcessObject()
        print("[live] system tap excludes \(src.status.processObjects), own object \(me.map(String.init) ?? "nil")")
        if let me { #expect(src.status.processObjects.contains(me)) }
        await src.stop()
    }

    @available(macOS 14.2, *)
    @Test func appTapWaitsForMissingApp() async throws {
        let src = AppAudioTapSource(target: .apps(bundleIDs: ["com.example.not-installed"]))
        try await src.start()
        #expect(src.status.state == .waitingForProcess)
        await src.stop()
        #expect(src.status.state == .idle)
    }

    @Test func queryRunningMediaApps() async throws {
        for app in MediaApp.allCases {
            let c = MediaAppController(app: app)
            guard c.isRunning else {
                print("[live] \(app.displayName) not running; skipped (not launched)")
                // Must not launch it as a side effect of querying.
                let np = try await c.nowPlaying()
                #expect(np == nil)
                #expect(!c.isRunning)
                continue
            }
            let perm = await c.automationPermission(askIfNeeded: false)
            print("[live] \(app.displayName) running; automation permission: \(perm)")
            guard perm == .granted else { continue }
            do {
                let np = try await c.nowPlaying()
                var printable = np
                printable?.artworkData = nil
                print("[live] \(app.displayName) now playing: \(String(describing: printable)) artworkBytes=\(np?.artworkData?.count ?? 0)")
            } catch {
                print("[live] \(app.displayName) query error: \(error)")
            }
        }
    }
}
#endif
