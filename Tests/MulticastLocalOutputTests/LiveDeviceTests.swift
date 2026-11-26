#if os(macOS)
import Foundation
import Testing
import MulticastAudio
@testable import MulticastLocalOutput

/// Hardware-touching tests. Enumeration and error paths are silent and always run; the tone test
/// plays sound and only runs with `MULTICAST_LIVE_AUDIO=1`.
@Suite(.serialized) struct LiveDeviceTests {
    @Test func enumeratesOutputDevices() {
        let dir = LocalOutputDirectory()
        defer { dir.invalidate() }
        let devices = dir.devices
        print("[live] \(devices.count) output device(s); default = \(dir.defaultOutputID ?? "none")")
        for d in devices {
            let lat = d.localDeviceUID.flatMap { dir.reportedLatency(forDeviceUID: $0) }
            print("[live]  \(d.localKind?.rawValue ?? "?")\t\(d.name)\t\(d.id)\tlatency=\(lat.map { String(format: "%.2f ms @ %.0f Hz (dev %u, stream %u, safety %u, buffer %u)", $0.totalMillis, $0.deviceSampleRate, $0.deviceFrames, $0.streamFrames, $0.safetyOffsetFrames, $0.bufferFrames) } ?? "?")")
        }
        #expect(devices.allSatisfy { $0.transport == .local && $0.id.hasPrefix("local:") && $0.localDeviceUID != nil })
        #expect(devices.allSatisfy { !$0.name.hasPrefix("Multicast") })
        #expect(Set(devices.map(\.id)).count == devices.count)
    }

    @Test func updatesStreamReplaysCurrentList() async {
        let dir = LocalOutputDirectory()
        defer { dir.invalidate() }
        var it = dir.updates.makeAsyncIterator()
        let first = await it.next()
        #expect(first == dir.devices)
    }

    @Test func unknownDeviceFailsCleanlyAndStateReplays() async {
        let sink = LocalOutputSink(deviceUID: "Multicast-Test-NoSuchDevice", name: "Nope")
        #expect(sink.id == "local:Multicast-Test-NoSuchDevice")
        await #expect(throws: LocalOutputError.deviceNotFound(uid: "Multicast-Test-NoSuchDevice")) {
            try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos(), anchorFrame: 0))
        }
        var it = sink.stateUpdates.makeAsyncIterator()
        let replayed = await it.next()
        guard case .failed(let reason)? = replayed else { Issue.record("expected .failed, got \(String(describing: replayed))"); return }
        #expect(reason.contains("not connected"))
        await sink.stop()
        #expect(sink.currentState == .idle)
    }

    @Test func descriptorWithoutUIDIsRejected() {
        let d = SpeakerDescriptor(id: "542a1b001122", name: "Hall Sonos", transport: .airplay2)
        #expect(throws: LocalOutputError.self) { try LocalOutputSink(descriptor: d) }
    }

    /// Plays a quiet 3 s 440 Hz tone (−20 dBFS, ×0.15 volume ≈ −45 dBFS, 200 ms fades) on the
    /// built-in speakers through `LocalOutputSink`, paced like the engine does, and logs the
    /// measured expected-vs-actual read position error.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE_AUDIO"] == "1"))
    func playsQuietToneOnBuiltInSpeakers() async throws {
        let dir = LocalOutputDirectory()
        defer { dir.invalidate() }
        let wanted = ProcessInfo.processInfo.environment["MULTICAST_LIVE_DEVICE"] ?? "MacBook Air Speakers"
        guard let speaker = dir.devices.first(where: { $0.name == wanted })
                ?? dir.devices.first(where: { $0.localKind == .builtIn }) else {
            Issue.record("no built-in output device found"); return
        }
        print("[live] target: \(speaker.name) (\(speaker.id))")
        let sink = try LocalOutputSink(descriptor: speaker)
        await sink.setVolume(0.15) // before any audio

        let leadNanos: UInt64 = 500_000_000
        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + leadNanos, anchorFrame: 0, latencyNanos: leadNanos)
        let toneFrames = 3 * PCM.sampleRate
        let packets = (toneFrames + PCM.framesPerPacket - 1) / PCM.framesPerPacket

        var samples: [(t: Double, err: Double, filt: Double, ppm: Double, readVsWall: Double)] = []
        var stateLog: [SinkState] = []
        let stateTask = Task { for await s in sink.stateUpdates { stateLog.append(s) } }

        do {
            try await sink.prepare(timeline: timeline)
            let lat = sink.reportedLatency
            print(String(format: "[live] reported latency %.2f ms (dev %u + stream %u + safety %u frames @ %.0f Hz, converter %.3f ms; IO buffer %u frames)",
                         lat.totalMillis, lat.deviceFrames, lat.streamFrames, lat.safetyOffsetFrames, lat.deviceSampleRate, lat.unitLatencySeconds * 1000, lat.bufferFrames))

            // Tiny test pacer: deliver each packet `latencyNanos` before it is due.
            let pacer = Thread {
                var buf = [Int16](repeating: 0, count: PCM.framesPerPacket * 2)
                let fade = Double(PCM.sampleRate) * 0.2
                for p in 0..<packets {
                    let first = UInt64(p * PCM.framesPerPacket)
                    let due = timeline.playoutHostNanos(forFrame: first) - timeline.latencyNanos
                    mach_wait_until(HostClock.hostTicks(fromNanos: due))
                    for i in 0..<PCM.framesPerPacket {
                        let n = Double(Int(first) + i)
                        var env = 1.0
                        if n < fade { env = n / fade }
                        if n > Double(toneFrames) - fade { env = max(0, (Double(toneFrames) - n) / fade) }
                        let v = sin(2 * Double.pi * 440 * n / Double(PCM.sampleRate)) * 0.1 * env
                        let s = Int16((v * 32767).rounded())
                        buf[2 * i] = s
                        buf[2 * i + 1] = s
                    }
                    let data = buf.withUnsafeBytes { Data($0) }
                    sink.enqueue(AudioPacket(firstFrame: first, samples: data))
                }
            }
            pacer.qualityOfService = .userInteractive
            pacer.start()

            // Sample telemetry every 50 ms until the tone has played out.
            let endHost = timeline.playoutHostNanos(forFrame: UInt64(toneFrames)) + 300_000_000
            while HostClock.nowNanos() < endHost {
                try await Task.sleep(nanoseconds: 50_000_000)
                let now = HostClock.nowNanos()
                let st = sink.syncStats
                // Independent wall-clock check: where should the hardware be reading right now?
                let wallIdeal = PlayoutClock.frameToRender(timeline: timeline, callbackHostNanos: now,
                                                           outputLatencyNanos: lat.totalNanos, offsetNanos: 0)
                let tSec = Double(Int64(bitPattern: now &- timeline.anchorHostNanos)) / 1e9
                samples.append((tSec, st.lastErrorFrames, st.filteredErrorFrames, st.ratioPPM, st.readFrame - wallIdeal))
            }
        } catch {
            await sink.stop()
            stateTask.cancel()
            throw error
        }
        let final = sink.syncStats
        await sink.stop()
        stateTask.cancel()

        let playing = samples.filter { $0.t >= 0.25 && $0.t <= 3.0 }
        let errMs = playing.map { abs($0.err) * 1000 / 44_100 }
        let wallMs = playing.map { $0.readVsWall * 1000 / 44_100 }
        print("[live] t(s)\terr(ms)\tfiltered(ms)\tratio(ppm)\tread-vs-wallclock(ms)")
        for s in samples where Int((s.t * 20).rounded()) % 5 == 0 {
            print(String(format: "[live] %.2f\t%+.4f\t%+.4f\t%+.1f\t%+.2f", s.t, s.err * 1000 / 44_100, s.filt * 1000 / 44_100, s.ppm, s.readVsWall * 1000 / 44_100))
        }
        if !errMs.isEmpty {
            print(String(format: "[live] during tone: n=%d  mean|err|=%.4f ms  max|err|=%.4f ms  read-vs-wallclock mean=%.2f ms min=%.2f max=%.2f",
                         errMs.count, errMs.reduce(0, +) / Double(errMs.count), errMs.max()!,
                         wallMs.reduce(0, +) / Double(wallMs.count), wallMs.min()!, wallMs.max()!))
        }
        print("[live] final: callbacks=\(final.callbacks) jumps=\(final.jumps) underrunFrames=\(final.underrunFrames) overruns=\(final.overrunWrites) extrapolatedTimestamps=\(final.extrapolatedTimestamps) oversized=\(final.oversizedCallbacks) ratioPPM=\(String(format: "%.1f", final.ratioPPM))")
        print("[live] states: \(stateLog)")

        #expect(final.callbacks > 100)
        #expect(final.jumps == 0)
        #expect(final.oversizedCallbacks == 0)
        #expect(errMs.max() ?? 99 < 1.0)
        #expect(stateLog.contains(.playing))
    }
}
#endif
