import Foundation
import Testing
import MulticastAudio
@testable import MulticastRAOP

/// End-to-end RAOPSink tests against a loopback fake receiver (no network hardware needed).
@Suite(.serialized) struct SinkIntegrationTests {
    func packet(_ index: Int) -> AudioPacket {
        var d = Data(count: PCM.bytesPerPacket)
        d.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<s.count { s[i] = Int16(truncatingIfNeeded: index * 1000 + i) }
        }
        return AudioPacket(firstFrame: UInt64(index * PCM.framesPerPacket), samples: d)
    }

    func makeSink(_ fake: FakeReceiver, password: String? = nil) -> RAOPSink {
        var options = RAOPSink.Options(password: password)
        options.requestTimeout = 2
        options.connectTimeout = 2
        return RAOPSink(host: "127.0.0.1", port: fake.port, name: "AABBCCDDEEFF@Fake", txt: ["et": "0", "md": "0,1,2"], options: options)
    }

    @Test func fullSessionLifecycle() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        let sink = makeSink(fake)
        #expect(sink.id == "aabbccddeeff")
        #expect(sink.displayName == "Fake")
        await sink.setVolume(0.5)

        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_100_000_000, anchorFrame: 0)
        try await sink.prepare(timeline: timeline)
        #expect(sink.currentState == .playing)
        #expect(sink.reportedAudioLatencyFrames == 11_025)

        // RTSP order: volume is set (twice) before RECORD completes and before any audio.
        let methods = fake.requests.map(\.method)
        #expect(methods == ["OPTIONS", "ANNOUNCE", "SETUP", "SET_PARAMETER", "RECORD", "SET_PARAMETER"])
        let reqs = fake.requests
        #expect(String(decoding: reqs[3].body, as: UTF8.self) == "volume: -15.000000\r\n")
        #expect(reqs[1].headers["content-type"] == "application/sdp")
        #expect(String(decoding: reqs[1].body, as: UTF8.self).contains("a=rtpmap:96 AppleLossless"))
        #expect(reqs[4].headers["session"] == "1")
        #expect(reqs[0].headers["dacp-id"]?.count == 16)
        #expect(reqs[0].headers["active-remote"] != nil)
        let cseqs = reqs.compactMap { Int($0.headers["cseq"] ?? "") }
        #expect(cseqs == Array(1...6))
        let recordInfo = RTSPHeaderValue.parseParameters(reqs[4].headers["rtp-info"] ?? "")
        let recordSeq = try #require(recordInfo["seq"].flatMap { UInt16($0) })
        let recordRTP = try #require(recordInfo["rtptime"].flatMap { UInt32($0) })
        #expect(audioIsEmpty(fake))

        // The first sync packet (0x90) arrives at prepare, before audio.
        #expect(fake.wait { !fake.controlPackets.isEmpty })
        let firstSync = try #require(SyncPacket.decode(fake.controlPackets[0]))
        #expect(firstSync.isFirst)
        #expect(firstSync.rtpNow &- firstSync.rtpMinusLatency == 77_175)
        let audible = SyncMapping.receiverPlayoutHostNanos(rtp: recordRTP, sync: firstSync)
        #expect(abs(audible - Int64(timeline.anchorHostNanos)) < 1_000, "frame 0 must be audible at the anchor")

        for i in 0..<10 { sink.enqueue(packet(i)) }
        #expect(fake.wait { fake.audioPackets.count >= 10 })
        let headers = fake.audioPackets.compactMap { RTPAudio.parseHeader(Data($0)) }
        #expect(headers.count == 10)
        #expect(headers[0].marker && headers.dropFirst().allSatisfy { !$0.marker })
        #expect(headers.allSatisfy { $0.payloadType == 96 })
        #expect(headers[0].seq == recordSeq)
        #expect(headers[0].timestamp == recordRTP)
        for i in 1..<10 {
            #expect(headers[i].seq == headers[0].seq &+ UInt16(i))
            #expect(headers[i].timestamp == headers[0].timestamp &+ UInt32(352 * i))
        }
        #expect(fake.audioPackets[0].count == 12 + 1412)
        #expect(Data(fake.audioPackets[3][12...]) == ALACFramer.encode(packet(3).samples))

        // Timing request -> reply echoing our transmit time as origin, with sane receive/transmit times.
        let reply = try #require(try fake.timingRoundTrip(transmit: 0x0102030405060708))
        #expect(reply.count == 32 && reply[1] == 0xD3)
        let origin = reply.withUnsafeBytes { getBE64($0, 8) }
        let receive = reply.withUnsafeBytes { getBE64($0, 16) }
        let transmit = reply.withUnsafeBytes { getBE64($0, 24) }
        #expect(origin == 0x0102030405060708)
        #expect(transmit >= receive)
        let now = NTPTime.now()
        #expect(now >= transmit && now - transmit < (1 << 32))  // within 1 s

        // Retransmit request -> 0x56 + identical original packet.
        let before = fake.controlPackets.count
        fake.requestResend(seq: headers[3].seq, count: 2)
        #expect(fake.wait { fake.controlPackets.dropFirst(before).filter { $0[1] == 0xD6 }.count >= 2 })
        let resent = fake.controlPackets.dropFirst(before).filter { $0[1] == 0xD6 }
        #expect(Array(resent[0].dropFirst(4)) == fake.audioPackets[3])
        #expect(Array(resent[1].dropFirst(4)) == fake.audioPackets[4])
        #expect(sink.statistics.resendRequests == 1)
        #expect(sink.statistics.packetsResent == 2)
        #expect(sink.statistics.timingRequestsAnswered >= 1)

        // Offset trim moves the mapping: +100 ms -> frame 0 audible 100 ms later.
        await sink.setOffset(millis: 100)
        #expect(fake.wait { fake.controlPackets.compactMap(SyncPacket.decode).count >= 2 })
        let trimmedSync = try #require(fake.controlPackets.compactMap(SyncPacket.decode).last)
        #expect(!trimmedSync.isFirst)
        let trimmed = SyncMapping.receiverPlayoutHostNanos(rtp: recordRTP, sync: trimmedSync)
        #expect(abs(trimmed - Int64(timeline.anchorHostNanos) - 100_000_000) < 1_000)

        // Flush: FLUSH carries the next seq/rtptime, sink drops packets until re-prepared.
        await sink.flush()
        #expect(sink.currentState == .idle)
        let flush = try #require(fake.requests.last)
        #expect(flush.method == "FLUSH")
        let flushInfo = RTSPHeaderValue.parseParameters(flush.headers["rtp-info"] ?? "")
        #expect(flushInfo["seq"] == String(headers[9].seq &+ 1))
        #expect(flushInfo["rtptime"] == String(headers[9].timestamp &+ 352))
        let countAfterFlush = fake.audioPackets.count
        sink.enqueue(packet(10))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.audioPackets.count == countAfterFlush)

        // Re-prepare on a new timeline restarting at frame 0: no reconnect, marker again,
        // sequence and RTP time continue forward.
        let timeline2 = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)
        let requestCount = fake.requests.count
        try await sink.prepare(timeline: timeline2)
        #expect(sink.currentState == .playing)
        #expect(fake.requests.count == requestCount)
        sink.enqueue(packet(0))
        sink.enqueue(packet(1))
        #expect(fake.wait { fake.audioPackets.count >= countAfterFlush + 2 })
        let h2 = fake.audioPackets.suffix(2).compactMap { RTPAudio.parseHeader(Data($0)) }
        #expect(h2[0].marker && !h2[1].marker)
        #expect(h2[0].seq == headers[9].seq &+ 1)
        #expect(h2[0].timestamp == headers[9].timestamp &+ 352)
        let sync2 = try #require(fake.controlPackets.compactMap(SyncPacket.decode).last(where: { $0.isFirst }))
        let audible2 = SyncMapping.receiverPlayoutHostNanos(rtp: h2[0].timestamp, sync: sync2)
        #expect(abs(audible2 - Int64(timeline2.anchorHostNanos) - 100_000_000) < 1_000)

        // Volume during playback and metadata.
        await sink.setVolume(0)
        #expect(String(decoding: fake.requests.last!.body, as: UTF8.self) == "volume: -144.000000\r\n")
        await sink.setNowPlaying(title: "T", artist: "A", album: "B", artworkJPEG: Data([0xFF, 0xD8, 0xFF]))
        let meta = fake.requests.suffix(2)
        #expect(meta.first?.headers["content-type"] == "application/x-dmap-tagged")
        #expect(meta.first?.headers["rtp-info"]?.hasPrefix("rtptime=") == true)
        #expect(meta.last?.headers["content-type"] == "image/jpeg")

        await sink.stop()
        #expect(sink.currentState == .idle)
        #expect(fake.requests.last?.method == "TEARDOWN")
    }

    private func audioIsEmpty(_ fake: FakeReceiver) -> Bool { fake.audioPackets.isEmpty }

    @Test func stateUpdatesReplayCurrentState() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        let sink = makeSink(fake)
        try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0))
        var iterator = sink.stateUpdates.makeAsyncIterator()
        #expect(await iterator.next() == .playing)
        await sink.stop()
        #expect(await iterator.next() == .idle)
    }

    @Test func digestAuthentication() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        fake.password = "s3cret"
        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)

        let noPassword = makeSink(fake)
        await #expect(throws: RAOPError.passwordRequired) { try await noPassword.prepare(timeline: timeline) }
        if case .failed(let reason) = noPassword.currentState {
            #expect(reason.contains("password"))
        } else {
            Issue.record("expected .failed, got \(noPassword.currentState)")
        }

        let wrong = makeSink(fake, password: "nope")
        await #expect(throws: RAOPError.authenticationFailed) { try await wrong.prepare(timeline: timeline) }

        let right = makeSink(fake, password: "s3cret")
        try await right.prepare(timeline: timeline)
        #expect(right.currentState == .playing)
        #expect(fake.requests.last?.headers["authorization"]?.hasPrefix("Digest username=\"iTunes\"") == true)
        await right.stop()
    }

    @Test func receiverRefusingAccessFailsWithAccessRefused() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        fake.refuseAccess = true
        let sink = makeSink(fake)
        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)
        await #expect(throws: RAOPError.accessRefused(method: "OPTIONS")) {
            try await sink.prepare(timeline: timeline)
        }
        guard case .failed(let reason) = sink.currentState else { Issue.record("expected failed"); return }
        #expect(reason.contains("refused access"))
        #expect(fake.requests.map(\.method) == ["OPTIONS"])
    }

    @Test func accessCheckAsksOnceAndSendsNoAudio() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        fake.refuseAccess = true
        let sink = makeSink(fake)
        #expect(await sink.checkAccess() == .refused)
        #expect(fake.requests.map(\.method) == ["OPTIONS"])
        #expect(sink.currentState == .idle)

        // The owner changed the setting: admitted, still nothing but OPTIONS.
        fake.refuseAccess = false
        #expect(await sink.checkAccess() == .admitted)
        #expect(fake.requests.map(\.method) == ["OPTIONS", "OPTIONS"])
        #expect(fake.audioPackets.isEmpty)

        // A password is not the access setting.
        let locked = try FakeReceiver()
        defer { locked.shutdown() }
        locked.password = "s3cret"
        #expect(await makeSink(locked).checkAccess() == .admitted)

        // Nobody answering is no answer at all.
        let gonePort = fake.port
        fake.shutdown()
        var options = RAOPSink.Options()
        options.connectTimeout = 1
        options.requestTimeout = 1
        let gone = RAOPSink(host: "127.0.0.1", port: gonePort, name: "AABBCCDDEEFF@Gone", txt: ["et": "0"], options: options)
        guard case .inconclusive = await gone.checkAccess() else { Issue.record("expected inconclusive"); return }
    }

    @Test func failureThenPrepareAgain() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        fake.failAnnounces = 1
        let sink = makeSink(fake)
        let timeline = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)
        await #expect(throws: RAOPError.unexpectedStatus(method: "ANNOUNCE", status: 453, reason: "Not Enough Bandwidth")) {
            try await sink.prepare(timeline: timeline)
        }
        guard case .failed = sink.currentState else { Issue.record("expected failed"); return }
        sink.enqueue(packet(0))  // dropped silently
        try await sink.prepare(timeline: timeline)
        #expect(sink.currentState == .playing)
        await sink.stop()
    }

    @Test func receiverDroppingConnectionFailsSink() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        let sink = makeSink(fake)
        try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0))
        #expect(sink.currentState == .playing)
        fake.dropConnection()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, sink.currentState == .playing { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(sink.currentState == .failed(RAOPError.connectionClosed.description))
        // A failed sink tears its sockets down and drops packets.
        sink.enqueue(packet(0))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sink.statistics.packetsSent == 0)
        await sink.stop()
        #expect(sink.currentState == .idle)
    }

    /// Re-anchoring a still-streaming sink whose FLUSH fails (the speaker dropped the RTSP
    /// connection) must reconnect, not report `.playing` on a torn-down session.
    @Test func reanchorAfterFailedFlushReconnectsInsteadOfPlayingIntoClosedSockets() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        var options = RAOPSink.Options()
        options.requestTimeout = 2
        options.connectTimeout = 2
        options.keepAliveInterval = 600
        let sink = RAOPSink(host: "127.0.0.1", port: fake.port, name: "AABBCCDDEEFF@Fake", txt: ["et": "0"], options: options)
        try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0))
        #expect(sink.currentState == .playing)
        let announcesBefore = fake.requests.filter { $0.method == "ANNOUNCE" }.count
        fake.dropConnection()
        // Prepare again WITHOUT flush (the engine does this after a prepare timeout), before the
        // 1 s peer-close check notices: the re-anchor path's FLUSH hits the dead connection.
        let t2 = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 352 * 100)
        try await sink.prepare(timeline: t2)
        #expect(sink.currentState == .playing)
        #expect(fake.requests.filter { $0.method == "ANNOUNCE" }.count == announcesBefore + 1, "reconnected")
        // And audio really goes out on the new session.
        sink.enqueue(AudioPacket(firstFrame: 352 * 100, samples: packet(0).samples))
        #expect(fake.wait { !fake.audioPackets.isEmpty })
        #expect(sink.statistics.packetsSent == 1)
        await sink.stop()
    }

    @Test func updatedEndpointIsUsedForTheNextConnect() async throws {
        let fake = try FakeReceiver()
        defer { fake.shutdown() }
        let probe = try UDPSocket(family: AF_INET)
        let deadPort = probe.localPort
        probe.close()
        var options = RAOPSink.Options()
        options.connectTimeout = 1
        let sink = RAOPSink(host: "127.0.0.1", port: deadPort, name: "AABBCCDDEEFF@Bridge", options: options)
        let tl = StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0)
        await #expect(throws: RAOPError.self) { try await sink.prepare(timeline: tl) }
        sink.updateEndpoint(host: "127.0.0.1", port: fake.port)
        #expect(sink.endpoint.port == fake.port)
        try await sink.prepare(timeline: tl)
        #expect(sink.currentState == .playing)
        #expect(sink.descriptor.port == deadPort, "the descriptor is the original; the endpoint moved")
        await sink.stop()
    }

    @Test func unreachableSpeakerFails() async throws {
        // Grab a free port and close it so nothing listens there.
        let probe = try UDPSocket(family: AF_INET)
        let port = probe.localPort
        probe.close()
        var options = RAOPSink.Options()
        options.connectTimeout = 1
        let sink = RAOPSink(host: "127.0.0.1", port: port, name: "Nobody", options: options)
        await #expect(throws: RAOPError.self) {
            try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos() + 2_000_000_000, anchorFrame: 0))
        }
        guard case .failed = sink.currentState else { Issue.record("expected failed"); return }
    }

    @Test func rejectsTooSmallLatency() async throws {
        let sink = RAOPSink(host: "127.0.0.1", port: 1, name: "X")
        await #expect(throws: RAOPError.self) {
            try await sink.prepare(timeline: StreamTimeline(anchorHostNanos: HostClock.nowNanos(), anchorFrame: 0, latencyNanos: 100_000_000))
        }
    }
}
