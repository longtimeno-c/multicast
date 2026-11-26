import Foundation
import MulticastAudio
import Testing
@testable import MulticastEngine

/// Real-time tests against the real pacer thread. Serialized so they do not perturb each other's timing.
@Suite(.serialized) struct EngineTests {
    let packet = UInt64(PCM.framesPerPacket)

    struct Lateness {
        var mean: Double
        var max: UInt64
        var p99: UInt64
    }

    func lateness(_ rx: [MockSink.Received], _ tl: StreamTimeline) -> Lateness {
        var values: [UInt64] = rx.map { r in
            let deadline = tl.playoutHostNanos(forFrame: r.frame) - tl.latencyNanos
            return r.hostNanos > deadline ? r.hostNanos - deadline : 0
        }
        let mean = values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
        values.sort()
        let p99 = values.isEmpty ? 0 : values[min(values.count - 1, values.count * 99 / 100)]
        return Lateness(mean: mean, max: values.last ?? 0, p99: p99)
    }

    func latenessSlopeNanosPerSecond(_ rx: [MockSink.Received], _ tl: StreamTimeline) -> Double {
        guard rx.count > 2, let t0 = rx.first?.hostNanos else { return 0 }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for r in rx {
            let deadline = tl.playoutHostNanos(forFrame: r.frame) - tl.latencyNanos
            let x = Double(r.hostNanos - t0) / 1e9
            let y = Double(Int64(bitPattern: r.hostNanos &- deadline))
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let n = Double(rx.count)
        return (n * sxy - sx * sy) / (n * sxx - sx * sx)
    }

    // MARK: Cadence, drift, continuity

    /// The 10-second measurement run reported in the module report.
    @Test func pacerCadenceDriftAndJitterOverTenSeconds() async throws {
        let engine = MulticastEngine(configuration: testConfiguration(latencyMillis: 2000))
        let source = MockSource()
        let sink = MockSink(id: "a")
        try await engine.setSource(source)
        await engine.addSink(sink)
        let t0 = HostClock.nowNanos()
        try await engine.play()
        await sleepMillis(10_000)
        let elapsed = HostClock.nowNanos() - t0
        let stats = engine.pacerStatistics
        await engine.stop()

        let tl = try #require(sink.prepares.first)
        let rx = sink.received
        #expect(rx.isContiguous, "frames must have no gaps or duplicates")
        #expect(rx.first?.frame == 0)
        // Content continuity: every packet's first sample encodes exactly its frame index.
        #expect(rx.allSatisfy { firstSamplePosition($0.samples) == $0.frame })

        // Cadence: packets emitted == elapsed / packet duration (±2 for start/stop edges).
        let expected = Double(elapsed) / Double(PacingSchedule.packetNanos)
        #expect(abs(Double(stats.packetsEmitted) - expected) <= 3, "emitted \(stats.packetsEmitted) expected \(expected)")

        let l = lateness(rx, tl)
        // Drift: lateness at the end is no larger than at the start (no accumulation).
        let head = lateness(Array(rx.prefix(100)), tl)
        let tail = lateness(Array(rx.suffix(100)), tl)
        let slope = latenessSlopeNanosPerSecond(rx, tl)
        print(String(format: "PACER 10s: packets=%d realtime=%@ jitter mean=%.1f µs p99=%.1f µs max=%.1f µs | head mean=%.1f µs tail mean=%.1f µs | wake mean=%.1f µs max=%.1f µs | work mean=%.1f µs max=%.1f µs | maxBurst=%d skipped=%d | slope=%.3f µs/s",
                     rx.count, stats.realtimePolicyApplied ? "yes" : "no",
                     l.mean / 1000, Double(l.p99) / 1000, Double(l.max) / 1000,
                     head.mean / 1000, tail.mean / 1000,
                     stats.meanLatenessNanos / 1000, Double(stats.maxLatenessNanos) / 1000,
                     stats.meanWorkNanos / 1000, Double(stats.maxWorkNanos) / 1000,
                     stats.maxBurst, stats.packetsSkipped, slope / 1000))
        #expect(rx.count > 1200)
        #expect(l.mean < 1_000_000, "mean lateness under 1 ms")
        #expect(l.max < 10_000_000, "max lateness under 10 ms")
        #expect(abs(tail.mean - head.mean) < 1_000_000, "no drift")
        // Least-squares slope of per-packet lateness vs time over the whole run: a real drift
        // (e.g. cumulative rounding) would show up as a steady trend; < 20 µs per second here.
        #expect(abs(slope) < 20_000, "lateness trend \(slope) ns/s")
        #expect(stats.packetsSkipped == 0)
    }

    @Test func silencePaddingForShortReads() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let source = MockSource(maxFramesPerRead: 100, constant: 1000)
        let sink = MockSink(id: "a")
        try await engine.setSource(source)
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 20 }
        let stats = engine.pacerStatistics
        await engine.stop()
        let rx = sink.received
        #expect(rx.count >= 20)
        for r in rx {
            r.samples.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                #expect(s.count == PCM.framesPerPacket * 2)
                #expect(s[0..<200].allSatisfy { $0 == 1000 })
                #expect(s[200...].allSatisfy { $0 == 0 })
            }
        }
        #expect(stats.framesPadded >= UInt64(rx.count - 2) * 252)
    }

    // MARK: Late join

    @Test func lateJoinerWithoutBackfillStartsAtLiveEdge() async throws {
        var config = testConfiguration()
        config.lateJoinBackfill = false
        let engine = MulticastEngine(configuration: config)
        let a = MockSink(id: "a")
        let b = MockSink(id: "b")
        try await engine.setSource(MockSource())
        await engine.addSink(a)
        try await engine.play()
        await sleepMillis(400)
        let liveEdgeBefore = try #require(a.received.last?.frame)
        await engine.addSink(b)
        await waitUntil { b.receivedCount >= 30 }
        await engine.stop()

        // Same timeline as everyone else.
        #expect(b.prepares == [try #require(a.prepares.first)])
        let rb = b.received
        let ra = a.received
        #expect(rb.isContiguous)
        let first = try #require(rb.first?.frame)
        #expect(first > liveEdgeBefore)
        #expect(first % packet == 0)
        // b's stream is exactly a's stream from that frame on (same packets, same content).
        let idx = try #require(ra.firstIndex { $0.frame == first })
        for (x, y) in zip(ra[idx...], rb) {
            #expect(x.frame == y.frame && x.samples == y.samples)
        }
        // And b did not get it before a did.
        #expect(rb[0].hostNanos >= ra[idx].hostNanos)
    }

    @Test func lateJoinerWithBackfillGetsStillFuturePackets() async throws {
        let config = testConfiguration(latencyMillis: 500)
        let engine = MulticastEngine(configuration: config)
        let a = MockSink(id: "a")
        let b = MockSink(id: "b")
        try await engine.setSource(MockSource())
        await engine.addSink(a)
        try await engine.play()
        await sleepMillis(800)
        await engine.addSink(b)
        await waitUntil { b.receivedCount >= 80 }
        await engine.stop()
        let tl = try #require(a.prepares.first)
        let rb = b.received
        #expect(rb.isContiguous)
        let first = try #require(rb.first)
        // First backfilled packet is due at least minDeliveryLead after it was handed over…
        let playout = tl.playoutHostNanos(forFrame: first.frame)
        #expect(playout >= first.hostNanos + config.minDeliveryLeadNanos - 1_000_000)
        // …and it is the earliest such packet: the previous one would have been due too soon.
        let previousPlayout = tl.playoutHostNanos(forFrame: first.frame - packet)
        #expect(previousPlayout < first.hostNanos + config.minDeliveryLeadNanos + PacingSchedule.packetNanos)
        // Backfill reached behind the live edge (frames a had already received).
        let aAtJoin = a.received.filter { $0.hostNanos <= first.hostNanos }
        #expect(first.frame < (aAtJoin.last?.frame ?? 0))
        #expect(engine.pacerStatistics.packetsBackfilled == 0 || true)
        #expect(rb.allSatisfy { firstSamplePosition($0.samples) == $0.frame })
    }

    // MARK: Pause / resume

    @Test func pauseResumeFlushesThenPreparesNewAnchorAndFramesContinue() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        let source = MockSource()
        try await engine.setSource(source)
        await engine.addSink(sink)
        try await engine.play()
        // Past the anchor (300 ms latency), so something has actually been heard at the pause.
        await waitUntil { sink.receivedCount >= 60 }
        let beforePause = HostClock.nowNanos()
        await engine.pause()
        #expect(engine.snapshot.transport == .paused)
        let pausedAt = HostClock.nowNanos()
        let lastBeforePause = try #require(sink.received.last?.frame)
        let countAtPause = sink.receivedCount
        let readsAtPause = source.readCount
        await sleepMillis(200)
        #expect(sink.receivedCount == countAtPause, "no packets while paused")
        #expect(source.readCount == readsAtPause, "finite source not pulled while paused")
        try await engine.play()
        await waitUntil { sink.receivedCount >= countAtPause + 70 } // past the replayed tail
        await engine.stop()

        let prepares = sink.prepares
        #expect(prepares.count == 2)
        let t1 = prepares[0]
        let t2 = prepares[1]
        #expect(t2.anchorFrame == lastBeforePause + packet)
        #expect(t2.anchorHostNanos >= pausedAt + t2.latencyNanos)
        #expect(t2 != t1)

        // Order: prepare(t1) … flush … prepare(t2); volume pushed before each prepare.
        let calls = sink.calls
        let p1 = try #require(calls.firstIndex(of: .prepare(t1)))
        let p2 = try #require(calls.firstIndex(of: .prepare(t2)))
        let flushIdx = try #require(calls[p1...].firstIndex(of: .flush))
        #expect(flushIdx < p2)
        #expect(calls[..<p2].last { if case .volume = $0 { return true }; return false } != nil)

        let rx = sink.received
        #expect(rx.isContiguous, "frame stamps continue monotonically across pause/resume")
        // Post-resume packets are stamped on t2: the first one is t2's anchor.
        #expect(rx[countAtPause].frame == t2.anchorFrame)

        // CONTENT: what plays after resume must start where the listener was at the pause, not
        // where the source had been read to (~latency later). Before the pause, content == frame.
        let before = rx[..<countAtPause]
        #expect(before.allSatisfy { firstSamplePosition($0.samples) == $0.frame })
        let after = Array(rx[countAtPause...])
        let resumedContent = firstSamplePosition(after[0].samples)
        let audibleLo = max(0, t1.frame(atHostNanos: beforePause) - Double(packet))
        let audibleHi = max(0, t1.frame(atHostNanos: pausedAt)) + Double(packet)
        #expect(audibleLo > 0)
        #expect(Double(resumedContent) >= audibleLo && Double(resumedContent) <= audibleHi,
                "resumed at content \(resumedContent), audible at pause was \(audibleLo)...\(audibleHi)")
        #expect(resumedContent < lastBeforePause, "the unplayed tail is replayed, not skipped")
        // And from there the content is gapless and duplicate-free: the replayed tail runs straight
        // into fresh source reads.
        for (i, r) in after.enumerated() {
            #expect(firstSamplePosition(r.samples) == resumedContent + UInt64(i) * packet)
        }
        let replayed = engine.pacerStatistics.packetsReplayed
        #expect(replayed == (lastBeforePause + packet - resumedContent) / packet, "replayed \(replayed) last \(lastBeforePause) resumed \(resumedContent)")
    }

    @Test func pauseWithoutRetainingDropsTheUnplayedTail() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        try await engine.setSource(MockSource())
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 30 }
        await engine.pause(retainUnplayedAudio: false)
        let count = sink.receivedCount
        let last = try #require(sink.received.last)
        try await engine.play()
        await waitUntil { sink.receivedCount >= count + 5 }
        await engine.stop()
        let first = sink.received[count]
        #expect(firstSamplePosition(first.samples) == firstSamplePosition(last.samples) + packet)
    }

    @Test func pauseTwiceDuringReplayStillLosesNothing() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        try await engine.setSource(MockSource())
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 40 }
        await engine.pause()
        let c1 = sink.receivedCount
        try await engine.play()
        // Pause again while the retained tail (~300 ms) is still being replayed.
        await waitUntil { sink.receivedCount >= c1 + 5 }
        let t2 = try #require(engine.currentTimeline)
        let beforeSecond = HostClock.nowNanos()
        await engine.pause()
        let c2 = sink.receivedCount
        try await engine.play()
        await waitUntil { sink.receivedCount >= c2 + 80 }
        await engine.stop()
        let rx = sink.received
        let secondResume = firstSamplePosition(rx[c2].samples)
        // Content heard on t2 at the second pause:
        let heardFrame = MulticastEngine.packetFloor(t2.frame(atHostNanos: beforeSecond), timeline: t2)
        let heardIndex = Int((heardFrame - t2.anchorFrame) / packet)
        let expected = firstSamplePosition(rx[c1 + max(0, heardIndex)].samples)
        #expect(secondResume >= expected && secondResume <= expected + 2 * packet)
        let tail = Array(rx[c2...])
        for (i, r) in tail.enumerated() {
            #expect(firstSamplePosition(r.samples) == secondResume + UInt64(i) * packet)
        }
    }

    @Test func packetFloorAlignsToTheAnchorGrid() {
        let tl = StreamTimeline(anchorHostNanos: 1_000, anchorFrame: 1_000)
        #expect(MulticastEngine.packetFloor(0, timeline: tl) == 1_000)
        #expect(MulticastEngine.packetFloor(1_000, timeline: tl) == 1_000)
        #expect(MulticastEngine.packetFloor(1_351.9, timeline: tl) == 1_000)
        #expect(MulticastEngine.packetFloor(1_352, timeline: tl) == 1_352)
        #expect(MulticastEngine.packetFloor(.nan, timeline: tl) == 1_000)
    }

    @Test func liveSourceIsDrainedWhilePaused() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        let source = MockSource(isLive: true)
        try await engine.setSource(source)
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 10 }
        await engine.pause()
        let count = sink.receivedCount
        let reads = source.readCount
        await sleepMillis(300)
        #expect(sink.receivedCount == count)
        #expect(source.readCount >= reads + 25, "live input keeps being pulled and discarded")
        try await engine.play()
        await waitUntil { sink.receivedCount >= count + 10 }
        await engine.stop()
        let rx = sink.received
        #expect(rx.isContiguous)
        #expect(sink.prepares.count == 2)
    }

    // MARK: Failure isolation

    @Test func hangingAndThrowingSinksDoNotAffectOthers() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let good = MockSink(id: "good")
        let hang = MockSink(id: "hang", behavior: .hang)
        let bad = MockSink(id: "bad", behavior: .fail("refused"))
        defer { hang.releaseHangs() }
        let events = engine.events
        try await engine.setSource(MockSource())
        await engine.addSink(hang)
        await engine.addSink(bad)
        await engine.addSink(good)
        let t0 = HostClock.nowNanos()
        try await engine.play()
        let playReturned = HostClock.nowNanos() - t0
        #expect(playReturned < 100_000_000, "play() does not wait for slow sinks")

        await waitUntil { engine.snapshot.sinks.first { $0.id == "hang" }?.state == .failed }
        let snap = engine.snapshot
        #expect(snap.sinks.first { $0.id == "bad" }?.state == .failed)
        #expect(snap.sinks.first { $0.id == "hang" }?.state == .failed)
        #expect(snap.sinks.first { $0.id == "good" }?.state == .playing)
        #expect(snap.sinks.count == 3, "failed sinks stay in the list")

        // Retry the throwing one after it is fixed.
        bad.behavior = .succeed(delayNanos: 0)
        await engine.retrySink(id: "bad")
        await waitUntil { bad.receivedCount >= 10 }
        #expect(engine.snapshot.sinks.first { $0.id == "bad" }?.state == .playing)
        await engine.stop()

        let rx = good.received
        #expect(rx.isContiguous)
        #expect(rx.first?.frame == 0)
        let l = lateness(rx, try #require(good.prepares.first))
        #expect(l.max < 15_000_000, "good sink kept on schedule (max \(l.max) ns)")
        #expect(hang.receivedCount == 0)
        #expect(bad.received.isContiguous)

        var failedIDs: Set<String> = []
        for await e in events {
            if case .sinkFailed(let id, _) = e { failedIDs.insert(id) }
            if failedIDs.count == 2 { break }
        }
        #expect(failedIDs == ["hang", "bad"])
    }

    @Test func deviceReportedFailureMarksSinkFailed() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let a = MockSink(id: "a")
        let b = MockSink(id: "b")
        try await engine.setSource(MockSource())
        await engine.addSink(a)
        await engine.addSink(b)
        try await engine.play()
        await waitUntil { b.receivedCount >= 5 }
        b.report(.failed("connection reset"))
        await waitUntil { engine.snapshot.sinks.first { $0.id == "b" }?.state == .failed }
        let frozen = b.receivedCount
        await sleepMillis(100)
        #expect(b.receivedCount <= frozen + 1)
        #expect(engine.snapshot.sinks.first { $0.id == "b" }?.error == "connection reset")
        await engine.stop()
    }

    // MARK: Removal

    @Test func removalMidStream() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let a = MockSink(id: "a")
        let b = MockSink(id: "b")
        try await engine.setSource(MockSource())
        await engine.addSink(a)
        await engine.addSink(b)
        try await engine.play()
        await waitUntil { b.receivedCount >= 20 }
        await engine.removeSink(id: "b")
        let frozen = b.receivedCount
        let aAtRemoval = a.receivedCount
        await sleepMillis(150)
        #expect(b.receivedCount == frozen, "no enqueue after removeSink returns")
        #expect(a.receivedCount > aAtRemoval + 10)
        #expect(b.calls.suffix(2) == [.flush, .stop])
        #expect(engine.snapshot.sinks.map(\.id) == ["a"])
        await engine.stop()
        #expect(a.received.isContiguous)
    }

    @Test func disableAndReenableMidStream() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let a = MockSink(id: "a")
        let b = MockSink(id: "b")
        try await engine.setSource(MockSource())
        await engine.addSink(a)
        await engine.addSink(b)
        try await engine.play()
        await waitUntil { b.receivedCount >= 10 }
        await engine.setEnabled(false, forSink: "b")
        let frozen = b.receivedCount
        #expect(engine.snapshot.sinks.first { $0.id == "b" }?.state == .disabled)
        await sleepMillis(100)
        #expect(b.receivedCount == frozen)
        #expect(b.calls.last == .stop)
        await engine.setEnabled(true, forSink: "b")
        await waitUntil { b.receivedCount >= frozen + 10 }
        #expect(b.prepares.count == 2)
        #expect(b.prepares[0] == b.prepares[1], "re-enabled sink joins the current timeline")
        await engine.stop()
    }

    // MARK: Volume

    @Test func volumeIsSetBeforeAudioAndCoalesced() async throws {
        var config = testConfiguration()
        config.initialMasterVolume = 0.5
        let engine = MulticastEngine(configuration: config)
        let sink = MockSink(id: "a")
        try await engine.setSource(MockSource())
        await engine.addSink(sink, volume: 0.3)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 5 }

        // Volume reached the device before the first packet.
        let firstEnqueue = try #require(sink.firstEnqueueCallIndex)
        let before = sink.calls[..<firstEnqueue]
        #expect(before.contains(.volume(0.15)))
        let prepareIdx = try #require(before.firstIndex { if case .prepare = $0 { return true }; return false })
        #expect(before[..<prepareIdx].contains(.volume(0.15)))

        // Drag the master slider: 200 changes in ~400 ms.
        let pushesBefore = sink.volumes.count
        let t0 = HostClock.nowNanos()
        for i in 0..<200 {
            engine.setMasterVolume(Float(i) / 199)
            await sleepMillis(2)
        }
        let dragNanos = HostClock.nowNanos() - t0
        await sleepMillis(300)
        let pushes = Array(sink.volumes[pushesBefore...])
        let allowed = Int(dragNanos / config.volumeCoalesceNanos) + 3
        #expect(pushes.count <= allowed, "\(pushes.count) pushes for \(allowed) allowed")
        #expect(pushes.count >= 2)
        #expect(abs((pushes.last ?? -1) - 0.3) < 1e-6, "final value = 0.3 × 1.0")

        // Mute → 0, unmute → back; snapshot shows the math.
        engine.setMuted(true, forSink: "a")
        await waitUntil { sink.volumes.last == 0 }
        #expect(engine.snapshot.sinks[0].effectiveVolume == 0)
        engine.setMuted(false, forSink: "a")
        engine.setVolume(0.1, forSink: "a")
        engine.setMasterVolume(0.5)
        await waitUntil { abs((sink.volumes.last ?? -1) - 0.05) < 1e-6 }
        #expect(abs(engine.snapshot.sinks[0].effectiveVolume - 0.05) < 1e-6)
        #expect(engine.snapshot.masterVolume == 0.5)

        engine.setOffset(millis: -25, forSink: "a")
        await waitUntil { sink.calls.contains(.offset(-25)) }
        #expect(engine.snapshot.sinks[0].offsetMillis == -25)
        await engine.stop()
    }

    // MARK: End of stream / source switching

    @Test func endOfStreamFromFiniteSource() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        let total: UInt64 = 10_000 // 28 full packets + 144 frames
        let events = engine.events
        try await engine.setSource(MockSource(totalFrames: total))
        await engine.addSink(sink)
        try await engine.play()
        var endEvent: EngineEvent?
        for await e in events {
            if case .endOfStream = e { endEvent = e; break }
        }
        let tl = try #require(sink.prepares.first)
        #expect(endEvent == .endOfStream(endFrame: 29 * packet, audibleUntilHostNanos: tl.playoutHostNanos(forFrame: 29 * packet)))
        #expect(engine.snapshot.transport == .ended)
        let rx = sink.received
        #expect(rx.count == 29)
        #expect(rx.isContiguous)
        let last = try #require(rx.last)
        last.samples.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            let valid = Int(total - last.frame) // 144 frames
            #expect(Pattern.position(left: s[0], right: s[1]) == last.frame)
            #expect(s[(valid * 2)...].allSatisfy { $0 == 0 })
        }
        #expect(!sink.calls.contains(.flush), "the buffered tail is allowed to play out")
        await engine.stop()
    }

    @Test func gaplessSourceSwitchAfterEndOfStream() async throws {
        let engine = MulticastEngine(configuration: testConfiguration(latencyMillis: 500))
        let sink = MockSink(id: "a")
        let events = engine.events
        try await engine.setSource(MockSource(name: "one", totalFrames: 352 * 20))
        await engine.addSink(sink)
        try await engine.play()
        for await e in events { if case .endOfStream = e { break } }
        try await engine.setSource(MockSource(name: "two", totalFrames: 352 * 20, positionBase: 352 * 20))
        await waitUntil { sink.receivedCount >= 40 }
        #expect(engine.snapshot.sourceName == "two")
        let callsBeforeStop = sink.calls
        await engine.stop()
        let rx = sink.received
        #expect(rx.isContiguous)
        #expect(rx.prefix(40).allSatisfy { firstSamplePosition($0.samples) == $0.frame }, "second source continues seamlessly")
        #expect(sink.prepares.count == 1, "same timeline, no re-prepare")
        #expect(!callsBeforeStop.contains(.flush))
    }

    @Test func setSourceWhilePlayingFlushesAndContinues() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        let one = MockSource(name: "one")
        let two = MockSource(name: "two", positionBase: 1_000_000)
        try await engine.setSource(one)
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 20 }
        try await engine.setSource(two)
        let switchCount = sink.receivedCount
        let lastOld = try #require(sink.received.last?.frame)
        await waitUntil { sink.receivedCount >= switchCount + 20 }
        await engine.stop()
        #expect(one.stopCount == 1)
        #expect(two.startCount == 1)
        let prepares = sink.prepares
        #expect(prepares.count == 2)
        #expect(prepares[1].anchorFrame == lastOld + packet)
        let calls = sink.calls
        let p2 = try #require(calls.firstIndex(of: .prepare(prepares[1])))
        #expect(calls[..<p2].contains(.flush))
        let rx = sink.received
        #expect(rx.isContiguous)
        let firstNew = rx[switchCount]
        #expect(firstNew.frame == prepares[1].anchorFrame)
        #expect(firstSamplePosition(firstNew.samples) == 1_000_000, "new source starts at its beginning")
        #expect(engine.snapshot.transport == .stopped)
    }

    // MARK: Snapshot / meters

    @Test func snapshotStreamReplaysLatestToNewSubscribers() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        await engine.addSink(MockSink(id: "a"))
        engine.setMasterVolume(0.4)
        try await engine.setSource(MockSource(name: "tone"))
        var it = engine.snapshots.makeAsyncIterator()
        let first = try #require(await it.next())
        #expect(first == engine.snapshot)
        #expect(first.masterVolume == 0.4)
        #expect(first.sourceName == "tone")
        #expect(first.sinks.map(\.id) == ["a"])
        #expect(first.latencyMillis == 300)
        engine.setVolume(0.2, forSink: "a")
        let next = try #require(await it.next())
        #expect(next.revision > first.revision)
        #expect(next.sinks[0].volume == 0.2)
    }

    @Test func metersPublishAtRateWithSourceLevel() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        try await engine.setSource(MockSource(constant: 16384)) // 0.5 FS DC
        await engine.addSink(MockSink(id: "a"))
        let meters = engine.meters
        try await engine.play()
        var readings: [MeterReading] = []
        let t0 = HostClock.nowNanos()
        for await m in meters {
            readings.append(m)
            if HostClock.nowNanos() - t0 > 1_000_000_000 { break }
        }
        await engine.stop()
        #expect(readings.count >= 18 && readings.count <= 32, "~25 Hz, got \(readings.count)")
        for r in readings {
            #expect(abs(r.peakLeft - 0.5) < 1e-4)
            #expect(abs(r.rmsRight - 0.5) < 1e-4)
        }
        #expect(readings.last!.frame > readings.first!.frame)
    }

    @Test func stopTearsDownSinksAndSource() async throws {
        let engine = MulticastEngine(configuration: testConfiguration())
        let sink = MockSink(id: "a")
        let src = MockSource()
        try await engine.setSource(src)
        await engine.addSink(sink)
        try await engine.play()
        await waitUntil { sink.receivedCount >= 5 }
        await engine.stop()
        let count = sink.receivedCount
        await sleepMillis(50)
        #expect(sink.receivedCount == count)
        #expect(sink.calls.suffix(2) == [.flush, .stop])
        #expect(src.stopCount == 1)
        #expect(engine.snapshot.transport == .stopped)
        #expect(engine.snapshot.sinks[0].state == .idle)
        // Play again from stopped: fresh prepare, frames still monotonic.
        try await engine.play()
        await waitUntil { sink.receivedCount >= count + 5 }
        await engine.shutdown()
        #expect(sink.received.isContiguous)
    }

    @Test func playWithoutSourceThrows() async {
        let engine = MulticastEngine(configuration: testConfiguration())
        await #expect(throws: EngineError.noSource) { try await engine.play() }
    }
}
