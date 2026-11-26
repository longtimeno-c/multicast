import Foundation
import MulticastKit

// multicast-cli: list speakers, or play a tone / file / captured app audio to several speakers in sync.

let usage = """
usage:
  multicast-cli list [--wait S] [--show-self]
  multicast-cli play (--tone [--freq HZ] | --file PATH | --capture [--app BUNDLE_ID] | --mac-output)
                     --to NAME [--to NAME ...] [--volume 0.12] [--seconds 8]
                     [--offset NAME=MS ...] [--add-at SEC:NAME ...] [--remove-at SEC:NAME ...]
                     [--latency-ms MS] [--verbose]

  NAME is a speaker name ("Hall Sonos"), a unique name prefix, or an id ("542a1b001122",
  "local:BuiltInSpeakerDevice"). --volume is per speaker, 0...1 (default 0.12), and reaches
  every speaker before any audio. --seconds counts audible seconds (default 8); Ctrl-C fades out
  and tears down cleanly (a second Ctrl-C skips the fade). --add-at/--remove-at add or remove a
  speaker that many seconds after audio starts. --mac-output plays what the Mac sends to the
  "Multicast" output device (Drivers/MulticastDevice must be installed).
"""

let processStart = Date()
func stamp() -> String { String(format: "%7.3f", Date().timeIntervalSince(processStart)) }
func say(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func fail(_ s: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multicast-cli: \(s)\n".utf8))
    exit(code)
}

// MARK: Argument parsing

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--to", "--volume", "--seconds", "--offset", "--file", "--app", "--freq",
                                      "--wait", "--latency-ms", "--add-at", "--remove-at"]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if Args.valued.contains(a) {
                guard i + 1 < argv.count else { fail("\(a) needs a value\n\(usage)") }
                options[a, default: []].append(argv[i + 1])
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func one(_ k: String) -> String? { options[k]?.last }
    func all(_ k: String) -> [String] { options[k] ?? [] }
    func double(_ k: String) -> Double? {
        guard let s = one(k) else { return nil }
        guard let v = Double(s) else { fail("\(k) expects a number, got \(s)") }
        return v
    }
}

/// "3:Hall Sonos" -> (3, "Hall Sonos"); "Hall Sonos=40" -> ("Hall Sonos", 40)
func splitTimed(_ s: String) -> (Double, String) {
    guard let i = s.firstIndex(of: ":"), let t = Double(s[..<i]) else { fail("expected SEC:NAME, got \(s)") }
    return (t, String(s[s.index(after: i)...]))
}
func splitOffset(_ s: String) -> (String, Int) {
    guard let i = s.lastIndex(of: "="), let ms = Int(s[s.index(after: i)...]) else { fail("expected NAME=MS, got \(s)") }
    return (String(s[..<i]), ms)
}

func describe(_ m: SpeakerMatching.Match, query: String) -> String {
    switch m {
    case .found(let d): return "\(query) -> \(d.name) [\(d.id)]"
    case .notFound: return "no speaker matches \"\(query)\""
    case .ambiguous(let list): return "\"\(query)\" is ambiguous: " + list.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
    }
}

// MARK: list

func runList(_ args: Args) async -> Int32 {
    let wait = args.double("--wait") ?? 3
    let directory = SpeakerDirectory(configuration: .init(hideThisMachine: !args.flags.contains("--show-self")))
    directory.start()
    try? await Task.sleep(nanoseconds: UInt64(max(0.5, wait) * 1e9))
    let speakers = directory.speakers
    directory.stop()
    if let err = directory.discoveryError {
        print("warning: Bonjour error \(err)\(err == -65570 ? " (local network access denied: allow it in System Settings > Privacy & Security > Local Network)" : "")")
    }
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    print(pad("NAME", 26) + pad("TRANSPORT", 10) + pad("ADDRESS", 34) + pad("MODEL", 22) + "ID")
    for d in speakers {
        let address: String
        let model: String
        if d.transport == .local {
            address = d.localKind.map { "local (\($0.rawValue))" } ?? "local"
            model = ""
        } else {
            address = "\(d.host ?? "?"):\(d.port.map(String.init) ?? "?")"
            var m = d.advertisedModel ?? d.model ?? ""
            if d.isAirConnectBridge { m += m.isEmpty ? "AirConnect bridge" : " (bridge)" }
            model = m
        }
        var name = d.name
        if d.isThisMachine && d.transport != .local { name += " (this Mac)" }
        if d.requiresPassword { name += " [pw]" }
        print(pad(name, 26) + pad(d.transport.rawValue, 10) + pad(address, 34) + pad(model, 22) + d.id)
    }
    for group in speakers.physicalDeviceConflicts() {
        print("note: same physical device, play to only one of: " + group.map { "\"\($0.name)\"" }.joined(separator: ", "))
    }
    print("\(speakers.count) speaker(s)")
    return 0
}

// MARK: play

final class Interrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var source: DispatchSourceSignal?

    func install() {
        signal(SIGINT, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.count += 1; let n = self.count; self.lock.unlock()
            FileHandle.standardError.write(Data((n == 1 ? "\ninterrupt: fading out and tearing down (Ctrl-C again to skip the fade)\n"
                                                        : "\ninterrupt: stopping now\n").utf8))
        }
        s.resume()
        source = s
    }

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

func statusLine(_ session: MulticastSession, elapsed: Double, level: Float? = nil) -> String {
    let snap = session.engine.snapshot
    let diags = Dictionary(uniqueKeysWithValues: session.diagnostics().map { ($0.id, $0) })
    var parts: [String] = [String(format: "t=%+.1fs %@", elapsed, snap.transport.rawValue)]
    for s in snap.sinks {
        var p = "\(s.name): \(s.state.rawValue)"
        if let e = s.error { p += " (\(e))" }
        if let d = diags[s.id] {
            switch d.kind {
            case .raop:
                p += " pkts=\(d.packetsSent ?? 0) resendReq=\(d.resendRequests ?? 0) resent=\(d.packetsResent ?? 0)"
                if let e = d.sendErrors, e > 0 { p += " sendErr=\(e)" }
                p += " timing=\(d.timingRequestsAnswered ?? 0)"
            case .local:
                p += String(format: " cb=%llu err=%.3fms rate=%+.0fppm under=%llu", d.renderCallbacks ?? 0,
                            d.syncErrorMillis ?? 0, d.rateCorrectionPPM ?? 0, d.underrunFrames ?? 0)
            }
        }
        parts.append(p)
    }
    #if os(macOS)
    if #available(macOS 14.2, *), let tap = session.currentSource as? AppAudioTapSource {
        let st = tap.status, stats = tap.statistics
        parts.append("capture: \(st.state) permission=\(st.permission) cycles=\(stats.ioCycles) nonSilent=\(stats.nonSilentCycles)")
    }
    if let dev = session.currentSource as? OutputDeviceSource {
        let st = dev.statistics
        parts.append(String(format: "mac output: %.0f Hz cycles=%lld frames=%lld nonSilent=%lld under=%lld drift=-%lld/+%lld",
                            st.sampleRate, st.ioCycles, st.capturedFrames, st.nonSilentCycles, st.underruns,
                            st.driftDrops, st.driftDuplicates))
    }
    #endif
    let p = session.engine.pacerStatistics
    parts.append("pacer: emitted=\(p.packetsEmitted) backfilled=\(p.packetsBackfilled) skipped=\(p.packetsSkipped) padded=\(p.framesPadded)")
    if let level { parts.append(String(format: "source peak %.1f dBFS", MeterReading.decibels(level))) }
    return parts.joined(separator: " | ")
}

func runPlay(_ args: Args) async -> Int32 {
    let targets = args.all("--to")
    guard !targets.isEmpty else { fail("play needs at least one --to NAME\n\(usage)") }
    let volume = Float(args.double("--volume") ?? 0.12)
    guard (0...1).contains(volume) else { fail("--volume must be between 0 and 1") }
    let seconds = args.double("--seconds") ?? 8
    guard seconds > 0 else { fail("--seconds must be positive") }
    let verbose = args.flags.contains("--verbose")

    var config = MulticastSession.Configuration()
    if let ms = args.double("--latency-ms") { config.engine.latencyNanos = UInt64(max(100, ms) * 1e6) }
    config.defaultSpeakerVolume = volume
    var raop = RAOPSink.Options()
    if verbose {
        raop.log = { say("raop: \($0)") }
        raop.verbose = true
    }
    let session = MulticastSession(configuration: config, factory: SinkFactory(raopOptions: raop))

    // Source first: a bad file path should fail before anything connects.
    let source: MulticastSession.Source
    if args.flags.contains("--tone") {
        source = .tone(frequency: args.double("--freq") ?? 440, amplitude: 0.125, duration: nil)
    } else if let path = args.one("--file") {
        guard FileManager.default.isReadableFile(atPath: path) else { fail("cannot read \(path)") }
        source = .file(URL(fileURLWithPath: path))
    } else if args.flags.contains("--capture") {
        #if os(macOS)
        source = .capture(args.one("--app").map { .app(bundleID: $0) } ?? .system)
        #else
        fail("--capture is macOS only")
        #endif
    } else if args.flags.contains("--mac-output") {
        #if os(macOS)
        guard OutputDeviceSource.isInstalled else { fail("the Multicast output device isn't installed (Drivers/MulticastDevice)") }
        source = .custom(OutputDeviceSource())
        #else
        fail("--mac-output is macOS only")
        #endif
    } else {
        fail("choose a source: --tone, --file PATH, --capture or --mac-output\n\(usage)")
    }

    let interrupts = Interrupts()
    interrupts.install()

    session.start()
    let scheduledAdds = args.all("--add-at").map(splitTimed)
    let scheduledRemoves = args.all("--remove-at").map(splitTimed)
    let allQueries = targets + scheduledAdds.map(\.1) + scheduledRemoves.map(\.1)
    let matches = await session.directory.waitForSpeakers(allQueries, timeout: 8)
    var resolved: [String: SpeakerDescriptor] = [:]
    for (q, m) in zip(allQueries, matches) {
        guard case .found(let d) = m else {
            await session.shutdown()
            fail(describe(m, query: q))
        }
        resolved[q] = d
        say("speaker " + describe(m, query: q) + " \(d.transport.rawValue) \(d.host.map { "\($0):\(d.port ?? 0)" } ?? "")")
    }
    var offsets: [String: Int] = [:]
    for o in args.all("--offset") {
        let (name, ms) = splitOffset(o)
        let m = SpeakerMatching.resolve(name, in: session.directory.speakers)
        guard case .found(let d) = m else { await session.shutdown(); fail(describe(m, query: name)) }
        offsets[d.id] = ms
    }

    do {
        let made = try await session.setSource(source)
        say("source: \(made.displayName)\(made.isLive ? " (live)" : "")")
        #if os(macOS)
        if made is OutputDeviceSource {
            let ok = OutputDeviceSource.reportLatency(seconds: Double(config.engine.latencyNanos) / 1e9)
            say("mac output: latency reported \(ok ? "" : "NOT ")set; device reports \(OutputDeviceSource.reportedLatencySeconds().map { String(format: "%.3f s", $0) } ?? "nothing")")
        }
        #endif
        for q in targets {
            let d = resolved[q]!
            try await session.select(d, volume: volume, offsetMillis: offsets[d.id] ?? 0)
            say("selected \(d.name) volume=\(volume) offset=\(offsets[d.id] ?? 0)ms")
        }
    } catch {
        await session.shutdown()
        fail("\(error)", code: 1)
    }
    if interrupts.value > 0 { await session.shutdown(); return 130 }

    let events = session.events
    let endBox = EndBox()
    let peak = PeakBox()
    let meters = session.meters
    let meterTask = Task { for await m in meters { peak.note(max(m.peakLeft, m.peakRight)) } }
    let eventTask = Task {
        for await e in events {
            switch e {
            case .endOfStream(_, let until): endBox.set(until)
            case .sinkJoined(let id, _): say("joined \(id)")
            case .sinkFailed(let id, let msg): say("FAILED \(id): \(msg)")
            case .timelineChanged(let tl): say("timeline anchor frame \(tl.anchorFrame), audible in \(String(format: "%.3f", Double(Int64(tl.anchorHostNanos) - Int64(HostClock.nowNanos())) / 1e9)) s")
            }
        }
    }

    do {
        try await session.play()
    } catch {
        await session.shutdown()
        fail("play failed: \(error)", code: 1)
    }
    guard let timeline = session.engine.currentTimeline else { await session.shutdown(); fail("no timeline", code: 1) }
    let audibleStart = timeline.anchorHostNanos
    let fade = config.fadeSeconds
    // The pacer reads the source one group latency ahead of playout, so a fade requested at host
    // time T is heard from T + latency. Requesting it at audibleStart - latency + (seconds - fade)
    // makes it audible from `seconds - fade` and silent at `seconds`: audible time == `seconds`,
    // fade included. (The request itself is therefore logged ~latency + fade before the end.)
    let fadeAt = PlayTiming.fadeRequestHostNanos(audibleStart: audibleStart, latencyNanos: timeline.latencyNanos,
                                                 seconds: seconds, fadeSeconds: fade)
    let hardLimit = audibleStart + UInt64((seconds + 5) * 1e9)
    var fading = false
    var pendingAdds = scheduledAdds.sorted { $0.0 < $1.0 }
    var pendingRemoves = scheduledRemoves.sorted { $0.0 < $1.0 }
    var lastStatus: UInt64 = 0
    var exitCode: Int32 = 0

    while true {
        let now = HostClock.nowNanos()
        let elapsed = Double(Int64(now) - Int64(audibleStart)) / 1e9
        let interruptsSeen = interrupts.value
        if interruptsSeen >= 2 { exitCode = 130; break }
        if !fading && (interruptsSeen == 1 || now >= fadeAt) {
            fading = true
            if interruptsSeen == 1 { exitCode = 130 }
            let heardFrom = Double(Int64(now + timeline.latencyNanos) - Int64(audibleStart)) / 1e9
            say(String(format: "fading out (heard from t=%+.2fs, silent by t=%+.2fs)", heardFrom, heardFrom + fade))
            session.requestFadeOut()
        }
        if let until = endBox.value, now >= until + 100_000_000 {
            say(String(format: "tail played out: audible for %.2fs (asked for %.2fs)",
                       Double(Int64(until) - Int64(audibleStart)) / 1e9, seconds))
            break
        }
        if now >= hardLimit { say("time limit reached"); break }
        while let next = pendingAdds.first, elapsed >= next.0, !fading {
            pendingAdds.removeFirst()
            let d = resolved[next.1]!
            say("adding \(d.name) mid-playback")
            do { try await session.select(d, volume: volume, offsetMillis: offsets[d.id] ?? 0) }
            catch { say("add failed: \(error)"); exitCode = 1 }
        }
        while let next = pendingRemoves.first, elapsed >= next.0, !fading {
            pendingRemoves.removeFirst()
            let d = resolved[next.1]!
            say("removing \(d.name) mid-playback")
            await session.deselect(speakerID: d.id)
            say("removed \(d.name)")
        }
        if now - lastStatus >= 1_000_000_000 {
            lastStatus = now
            say(statusLine(session, elapsed: elapsed, level: peak.take()))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    let finalSnap = session.engine.snapshot
    say("final: " + statusLine(session, elapsed: Double(Int64(HostClock.nowNanos()) - Int64(audibleStart)) / 1e9))
    let failed = finalSnap.sinks.filter { $0.state == .failed }
    say("tearing down")
    await session.shutdown()
    eventTask.cancel()
    meterTask.cancel()
    say("torn down")
    if !failed.isEmpty {
        for f in failed { say("speaker \(f.name) failed: \(f.error ?? "unknown error")") }
        if exitCode == 0 { exitCode = 1 }
    }
    return exitCode
}

enum PlayTiming {
    /// Host time to request the fade-out so the audio is heard for `seconds` in all, its fade
    /// included: the source is read `latencyNanos` ahead of playout.
    static func fadeRequestHostNanos(audibleStart: UInt64, latencyNanos: UInt64, seconds: Double,
                                     fadeSeconds: Double) -> UInt64 {
        let fadeAudibleAt = audibleStart + UInt64(max(0, seconds - fadeSeconds) * 1e9)
        return fadeAudibleAt > latencyNanos ? fadeAudibleAt - latencyNanos : 0
    }
}

/// Largest source peak since the last status line.
final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float?
    func note(_ v: Float) { lock.lock(); peak = max(peak ?? 0, v); lock.unlock() }
    func take() -> Float? { lock.lock(); defer { peak = nil; lock.unlock() }; return peak }
}

final class EndBox: @unchecked Sendable {
    private let lock = NSLock()
    private var until: UInt64?
    func set(_ v: UInt64) { lock.lock(); until = v; lock.unlock() }
    var value: UInt64? { lock.lock(); defer { lock.unlock() }; return until }
}

// MARK: main

let args = Args(Array(CommandLine.arguments.dropFirst()))
let code: Int32
switch args.positional.first {
case "list": code = await runList(args)
case "play": code = await runPlay(args)
case "help", nil: print(usage); code = args.positional.isEmpty ? 2 : 0
default: fail("unknown command \(args.positional[0])\n\(usage)")
}
exit(code)
