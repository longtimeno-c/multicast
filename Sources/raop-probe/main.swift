// raop-probe — stream a quiet 440 Hz tone to one or more AirPlay (RAOP) speakers on one shared
// StreamTimeline through RAOPSink, without the engine. Prints the RTSP exchange and counters.
//
//   raop-probe --name "Main Bedroom" [--name "Hall Sonos" ...] [--seconds 6] [--volume 0.12] [--verbose]
//   raop-probe --host H --port P [--name label] ...
//   raop-probe --list
//
// Safety limits for a lived-in home: volume is capped at 0.15 and set before any audio, the
// tone is quiet with 0.5 s fades, runs are capped at 8 s, "Patio" is refused, and the two
// names of the same Denon receiver are never played together. Ctrl-C tears everything down.
import Darwin
import Foundation
import MulticastAudio
import MulticastRAOP

let maxVolume: Float = 0.15
let maxSeconds = 8.0
let refusedNames: Set<String> = ["patio"]

struct ProbeArguments {
    var names: [String] = []
    var host: String?
    var port: UInt16?
    var seconds = 6.0
    var volume: Float = 0.12
    var verbose = false
    var list = false
    var flushTest = false
    var latencyMillis = 2000
    var offsets: [Int] = []
    var userAgent: String?
    var authSetup: RAOPSink.AuthSetupPolicy = .automatic
    var dropTest = false
    var keepAliveSeconds: Double?
    var metadata = false
}

func usage() -> Never {
    print("""
    usage: raop-probe --name NAME [--name NAME ...] [--seconds S<=8] [--volume V<=0.15] [--verbose]
                      [--host H --port P] [--flush-test] [--latency-ms MS] [--offset-ms MS ...]
                      [--user-agent UA] [--auth-setup auto|always|never]
                      [--drop-test] [--keepalive-s S] [--metadata]
           raop-probe --list
    """)
    exit(2)
}

func parseArguments() -> ProbeArguments {
    var args = ProbeArguments()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { print("missing value for \(flag)"); usage() }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--name": args.names.append(value(arg))
        case "--host": args.host = value(arg)
        case "--port": args.port = UInt16(value(arg)) ?? { usage() }()
        case "--seconds": args.seconds = Double(value(arg)) ?? { usage() }()
        case "--volume": args.volume = Float(value(arg)) ?? { usage() }()
        case "--latency-ms": args.latencyMillis = Int(value(arg)) ?? { usage() }()
        case "--offset-ms": args.offsets.append(Int(value(arg)) ?? { usage() }())
        case "--user-agent": args.userAgent = value(arg)
        case "--auth-setup":
            switch value(arg) {
            case "always": args.authSetup = .always
            case "never": args.authSetup = .never
            default: args.authSetup = .automatic
            }
        case "--verbose", "-v": args.verbose = true
        case "--list": args.list = true
        case "--flush-test": args.flushTest = true
        case "--drop-test": args.dropTest = true
        case "--metadata": args.metadata = true
        case "--keepalive-s": args.keepAliveSeconds = Double(value(arg)) ?? { usage() }()
        case "-h", "--help": usage()
        default: print("unknown argument \(arg)"); usage()
        }
    }
    if args.volume > maxVolume {
        print("volume \(args.volume) capped to \(maxVolume)")
        args.volume = maxVolume
    }
    if args.volume < 0 { args.volume = 0 }
    if args.seconds > maxSeconds {
        print("duration \(args.seconds) s capped to \(maxSeconds) s")
        args.seconds = maxSeconds
    }
    if args.seconds < 1 { args.seconds = 1 }
    return args
}

let startHost = HostClock.nowNanos()
let logLock = NSLock()
func log(_ message: String) {
    let t = Double(HostClock.nowNanos() &- startHost) / 1e9
    logLock.lock()
    print(String(format: "[+%7.3f] ", t) + message)
    fflush(stdout)
    logLock.unlock()
}

/// Canonical name for the "same physical device" check: trailing "+" (AirConnect bridge) removed.
func physicalKey(_ name: String) -> String {
    var n = name.lowercased().trimmingCharacters(in: .whitespaces)
    while n.hasSuffix("+") { n.removeLast() }
    return n
}

// MARK: - Cancellation (Ctrl-C)

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

let cancelFlag = CancelFlag()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue(label: "probe.signals")
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
for source in [sigint, sigterm] {
    source.setEventHandler {
        if cancelFlag.isCancelled {
            log("second interrupt: exiting immediately")
            exit(130)
        }
        log("interrupt: stopping and tearing down…")
        cancelFlag.cancel()
    }
    source.resume()
}

// MARK: - Tone

/// Quiet 440 Hz stereo tone, ~-18 dBFS, 0.5 s raised-cosine fades, pre-rendered into packets.
func renderTone(seconds: Double, firstFrame: UInt64) -> [AudioPacket] {
    let total = Int(seconds * Double(PCM.sampleRate))
    let packets = (total + PCM.framesPerPacket - 1) / PCM.framesPerPacket
    let fade = Double(PCM.sampleRate) * 0.5
    let amplitude = 0.12 * 32767.0
    var result: [AudioPacket] = []
    result.reserveCapacity(packets)
    for p in 0..<packets {
        var data = Data(count: PCM.bytesPerPacket)
        data.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<PCM.framesPerPacket {
                let n = p * PCM.framesPerPacket + i
                var gain = 1.0
                if n >= total { gain = 0 } else {
                    if Double(n) < fade { gain = 0.5 - 0.5 * cos(Double.pi * Double(n) / fade) }
                    let left = Double(total - n)
                    if left < fade { gain = min(gain, 0.5 - 0.5 * cos(Double.pi * left / fade)) }
                }
                let v = Int16(amplitude * gain * sin(2 * Double.pi * 440 * Double(n) / Double(PCM.sampleRate)))
                s[2 * i] = v.littleEndian
                s[2 * i + 1] = v.littleEndian
            }
        }
        result.append(AudioPacket(firstFrame: firstFrame + UInt64(p * PCM.framesPerPacket), samples: data))
    }
    return result
}

/// Paces `packets` to `sinks` in real time on a dedicated thread: each packet is handed over
/// `timeline.latencyNanos` before it is due. Returns how many packets were delivered.
func pace(_ packets: [AudioPacket], timeline: StreamTimeline, sinks: [RAOPSink]) async -> Int {
    await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
        let thread = Thread {
            var delivered = 0
            for packet in packets {
                if cancelFlag.isCancelled { break }
                let due = timeline.playoutHostNanos(forFrame: packet.firstFrame) &- timeline.latencyNanos
                if due > HostClock.nowNanos() { mach_wait_until(HostClock.hostTicks(fromNanos: due)) }
                for sink in sinks { sink.enqueue(packet) }
                delivered += 1
            }
            c.resume(returning: delivered)
        }
        thread.name = "probe.pacing"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

func sleepNanos(_ ns: UInt64) async {
    // Sleep in small steps so Ctrl-C is honoured promptly.
    let end = HostClock.nowNanos() + ns
    while HostClock.nowNanos() < end, !cancelFlag.isCancelled {
        try? await Task.sleep(nanoseconds: min(50_000_000, end - HostClock.nowNanos()))
    }
}

// MARK: - Main

func run() async -> Int32 {
    let args = parseArguments()

    if args.list {
        let names = DNSSD.browse(type: "_raop._tcp", seconds: 2)
        for name in names.sorted() { print(name) }
        return names.isEmpty ? 1 : 0
    }

    var services: [ResolvedService] = []
    if let host = args.host {
        guard let port = args.port else { usage() }
        let label = args.names.first ?? host
        services.append(ResolvedService(instanceName: label, host: host, port: port, txt: [:]))
    } else {
        guard !args.names.isEmpty else { usage() }
        log("browsing _raop._tcp …")
        let instances = DNSSD.browse(type: "_raop._tcp", seconds: 1.5)
        for wanted in args.names {
            let matches = instances.filter { inst in
                let display = inst.split(separator: "@", maxSplits: 1).last.map(String.init) ?? inst
                return display.caseInsensitiveCompare(wanted) == .orderedSame || inst.caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard let instance = matches.first else {
                log("ERROR: no _raop._tcp service named \"\(wanted)\" (seen: \(instances.joined(separator: ", ")))")
                return 1
            }
            guard let service = DNSSD.resolve(instance: instance, type: "_raop._tcp", timeout: 3) else {
                log("ERROR: could not resolve \(instance)")
                return 1
            }
            services.append(service)
        }
    }

    // Etiquette checks.
    var seen: [String: String] = [:]
    for s in services {
        if refusedNames.contains(s.displayName.lowercased()) {
            log("ERROR: refusing to play to \"\(s.displayName)\"")
            return 2
        }
        let key = physicalKey(s.displayName)
        if let other = seen[key] {
            log("ERROR: \"\(other)\" and \"\(s.displayName)\" are the same physical device; refusing to play to both")
            return 2
        }
        seen[key] = s.displayName
    }

    var sinks: [RAOPSink] = []
    for (i, s) in services.enumerated() {
        let txtSummary = ["et", "cn", "md", "am", "vn", "sf", "tp", "pw"].compactMap { k in s.txt[k].map { "\(k)=\($0)" } }.joined(separator: " ")
        log("\(s.instanceName) -> \(s.host):\(s.port)  \(txtSummary)")
        var options = RAOPSink.Options()
        options.log = { log($0) }
        options.verbose = args.verbose
        options.requireVolumeAck = true
        options.authSetup = args.authSetup
        if let ua = args.userAgent { options.userAgent = ua }
        if args.dropTest { options.debugDropPacketIndices = [100, 250, 251, 252] }
        if let k = args.keepAliveSeconds { options.keepAliveInterval = max(1, k) }
        let sink = RAOPSink(host: s.host, port: s.port, name: s.instanceName, txt: s.txt, options: options)
        if i < args.offsets.count { await sink.setOffset(millis: args.offsets[i]) }
        sinks.append(sink)
    }

    // State monitors.
    var monitors: [Task<Void, Never>] = []
    for sink in sinks {
        monitors.append(Task {
            for await state in sink.stateUpdates { log("[\(sink.displayName)] state: \(state)") }
        })
    }

    // Volume first: stored now, sent during prepare before RECORD and again before any audio.
    for sink in sinks { await sink.setVolume(args.volume) }
    log(String(format: "volume %.3f -> %.2f dB", args.volume, RAOPVolume.decibels(forLinear: args.volume)))

    let latency = UInt64(args.latencyMillis) * 1_000_000
    let prepareBudget: UInt64 = 1_500_000_000
    var timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + latency + prepareBudget, anchorFrame: 0, latencyNanos: latency)

    func prepareAll(_ timeline: StreamTimeline) async -> [RAOPSink] {
        await withTaskGroup(of: (RAOPSink, Bool).self) { group in
            for sink in sinks {
                group.addTask {
                    do {
                        try await sink.prepare(timeline: timeline)
                        return (sink, true)
                    } catch {
                        log("[\(sink.displayName)] prepare FAILED: \(error)")
                        return (sink, false)
                    }
                }
            }
            var ok: [RAOPSink] = []
            for await (sink, success) in group where success { ok.append(sink) }
            return ok
        }
    }

    var exitCode: Int32 = 0
    let t0 = HostClock.nowNanos()
    var active = await prepareAll(timeline)
    let prepMillis = Double(HostClock.nowNanos() - t0) / 1e6
    log(String(format: "prepared %d/%d sink(s) in %.0f ms", active.count, sinks.count, prepMillis))
    if active.count < sinks.count { exitCode = 1 }
    if HostClock.nowNanos() + latency > timeline.anchorHostNanos {
        log("WARNING: prepare took longer than the start budget; the first packets are late")
    }
    if args.metadata {
        for sink in active {
            await sink.setNowPlaying(title: "raop-probe 440 Hz", artist: "Multicast", album: "Test tones", artworkJPEG: nil)
            await sink.setProgress(elapsedSeconds: 0, durationSeconds: args.seconds)
        }
    }

    var lastFrameDue = timeline.anchorHostNanos
    if !active.isEmpty && !cancelFlag.isCancelled {
        if args.flushTest {
            let half = args.seconds / 2
            let first = renderTone(seconds: half, firstFrame: 0)
            let n1 = await pace(first, timeline: timeline, sinks: active)
            log("phase 1: delivered \(n1) packets; flushing")
            for sink in active { await sink.flush() }
            timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + latency + 500_000_000, anchorFrame: 0, latencyNanos: latency)
            active = await withTaskGroup(of: RAOPSink?.self) { group in
                for sink in active {
                    group.addTask {
                        do { try await sink.prepare(timeline: timeline); return sink } catch {
                            log("[\(sink.displayName)] re-prepare FAILED: \(error)")
                            return nil
                        }
                    }
                }
                var ok: [RAOPSink] = []
                for await s in group { if let s { ok.append(s) } }
                return ok
            }
            let second = renderTone(seconds: half, firstFrame: 0)
            let n2 = await pace(second, timeline: timeline, sinks: active)
            log("phase 2: delivered \(n2) packets")
            lastFrameDue = timeline.playoutHostNanos(forFrame: UInt64(second.count * PCM.framesPerPacket))
        } else {
            let packets = renderTone(seconds: args.seconds, firstFrame: 0)
            let delivered = await pace(packets, timeline: timeline, sinks: active)
            log("delivered \(delivered)/\(packets.count) packets to \(active.count) sink(s)")
            lastFrameDue = timeline.playoutHostNanos(forFrame: UInt64(packets.count * PCM.framesPerPacket))
        }
        // Let the buffered tail play out before TEARDOWN.
        let now = HostClock.nowNanos()
        if lastFrameDue + 300_000_000 > now { await sleepNanos(lastFrameDue + 300_000_000 - now) }
    }

    for sink in sinks {
        let s = sink.statistics
        log("[\(sink.displayName)] stats: sent=\(s.packetsSent) dropped(not playing)=\(s.packetsDroppedNotPlaying) withheld(test)=\(s.packetsDroppedForTest) sendErrors=\(s.sendErrors) sync=\(s.syncPacketsSent) timingAnswered=\(s.timingRequestsAnswered) resendRequests=\(s.resendRequests) resent=\(s.packetsResent) resendMisses=\(s.resendMisses) audioLatency=\(sink.reportedAudioLatencyFrames.map(String.init) ?? "-") state=\(sink.currentState)")
        if case .failed = sink.currentState { exitCode = 1 }
        if s.packetsSent == 0 { exitCode = 1 }
        if s.packetsSent > 0 && s.timingRequestsAnswered == 0 {
            log("[\(sink.displayName)] note: the speaker sent no timing requests")
        }
    }
    for sink in sinks { await sink.stop() }
    log("torn down")
    for m in monitors { m.cancel() }
    if cancelFlag.isCancelled && exitCode == 0 { exitCode = 130 }
    return exitCode
}

let code = await run()
exit(code)
