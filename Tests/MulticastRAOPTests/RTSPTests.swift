import Foundation
import Testing
@testable import MulticastRAOP

@Suite struct RTSPTests {
    @Test func requestSerialization() {
        var request = RTSPRequest(method: "SET_PARAMETER", uri: "rtsp://10.0.0.2/1234",
                                  headers: [RTSPHeader("CSeq", "5"), RTSPHeader("Content-Type", "text/parameters")],
                                  body: Data("volume: -20.000000\r\n".utf8))
        request.setHeader("content-type", "text/parameters")
        let text = String(decoding: request.serialized(), as: UTF8.self)
        #expect(text == "SET_PARAMETER rtsp://10.0.0.2/1234 RTSP/1.0\r\nCSeq: 5\r\nContent-Type: text/parameters\r\nContent-Length: 20\r\n\r\nvolume: -20.000000\r\n")
    }

    @Test func requestWithoutBodyHasNoContentLength() {
        let text = String(decoding: RTSPRequest(method: "OPTIONS", uri: "*", headers: [RTSPHeader("CSeq", "1")]).serialized(), as: UTF8.self)
        #expect(text == "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n")
    }

    @Test func parsesResponseAndWaitsForBody() throws {
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002\r\nContent-Length: 4\r\n\r\nabcdRTSP/1.0 200 OK\r\n"
        let data = Data(raw.utf8)
        #expect(try RTSPResponse.parse(data.prefix(40)) == nil)
        let full = try #require(try RTSPResponse.parse(data))
        #expect(full.response.statusCode == 200)
        #expect(full.response.reason == "OK")
        #expect(full.response.cseq == 3)
        #expect(full.response.header("session") == "1")
        #expect(full.response.body == Data("abcd".utf8))
        #expect(full.consumed == raw.utf8.count - "RTSP/1.0 200 OK\r\n".utf8.count)
        // Body incomplete -> need more.
        #expect(try RTSPResponse.parse(data.prefix(full.consumed - 1)) == nil)
    }

    @Test func parsesSliceWithNonZeroStartIndex() throws {
        var buffer = Data("XXRTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: 9\r\n\r\n".utf8)
        buffer.removeFirst(2)
        let parsed = try #require(try RTSPResponse.parse(buffer))
        #expect(parsed.response.statusCode == 453)
        #expect(parsed.response.reason == "Not Enough Bandwidth")
        #expect(parsed.consumed == buffer.count)
    }

    @Test func rejectsGarbageStatusLine() {
        #expect(throws: RTSPParseError.self) { try RTSPResponse.parse(Data("HELLO\r\n\r\n".utf8)) }
    }

    @Test func transportParsing() {
        let params = RTSPHeaderValue.parseParameters("RTP/AVP/UDP;unicast;mode=record;server_port=53561;control_port=63379;timing_port=50607")
        #expect(params["server_port"] == "53561")
        #expect(params["control_port"] == "63379")
        #expect(params["timing_port"] == "50607")
        #expect(params["unicast"] == "")
        #expect(RTSPHeaderValue.setupTransport(controlPort: 6001, timingPort: 6002)
                == "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=6001;timing_port=6002")
        #expect(RTSPHeaderValue.rtpInfo(seq: 65535, rtpTime: 4_294_967_295) == "seq=65535;rtptime=4294967295")
    }

    @Test func sdp() {
        let sdp = RAOPSDP.announce(sessionID: 42, localIP: "192.168.1.10", remoteIP: "192.168.1.20")
        #expect(sdp == "v=0\r\no=iTunes 42 0 IN IP4 192.168.1.10\r\ns=iTunes\r\nc=IN IP4 192.168.1.20\r\nt=0 0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 AppleLossless\r\na=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r\n")
        let v6 = RAOPSDP.announce(sessionID: 1, localIP: "fe80::1", remoteIP: "fe80::2", localIsIPv6: true, remoteIsIPv6: true)
        #expect(v6.contains("o=iTunes 1 0 IN IP6 fe80::1\r\n"))
        #expect(v6.contains("c=IN IP6 fe80::2\r\n"))
    }

    @Test func digestChallengeAndResponse() throws {
        let challenge = try #require(RTSPDigestChallenge.parse("Digest realm=\"raop\", nonce=\"a1b2, c3\""))
        #expect(challenge.realm == "raop")
        #expect(challenge.nonce == "a1b2, c3")
        #expect(RTSPDigestChallenge.parse("Basic realm=\"x\"") == nil)
        // RFC 2617 digest without qop: MD5(MD5(user:realm:pass):nonce:MD5(method:uri)).
        let c = RTSPDigestChallenge(realm: "raop", nonce: "abc")
        let ha1 = RTSPDigestChallenge.md5Hex("iTunes:raop:secret")
        let ha2 = RTSPDigestChallenge.md5Hex("ANNOUNCE:rtsp://1.2.3.4/1")
        let expected = RTSPDigestChallenge.md5Hex("\(ha1):abc:\(ha2)")
        let header = c.authorization(method: "ANNOUNCE", uri: "rtsp://1.2.3.4/1", username: "iTunes", password: "secret")
        #expect(header == "Digest username=\"iTunes\", realm=\"raop\", nonce=\"abc\", uri=\"rtsp://1.2.3.4/1\", response=\"\(expected)\"")
        #expect(RTSPDigestChallenge.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test func dmap() {
        let item = DMAP.string("minm", "Hi")
        #expect([UInt8](item) == [0x6D, 0x69, 0x6E, 0x6D, 0, 0, 0, 2, 0x48, 0x69])
        let listing = DMAP.nowPlaying(title: "T", artist: nil, album: "A")
        #expect(listing.count == 8 + 9 + 9)
        #expect(listing.prefix(4) == Data("mlit".utf8))
        #expect(DMAP.progressBody(start: 1, current: 2, end: 3) == "progress: 1/2/3\r\n")
    }

    @Test func volumeMapping() {
        #expect(RAOPVolume.decibels(forLinear: 0) == -144)
        #expect(RAOPVolume.decibels(forLinear: -1) == -144)
        #expect(RAOPVolume.decibels(forLinear: .nan) == -144)
        #expect(RAOPVolume.decibels(forLinear: 1) == 0)
        #expect(RAOPVolume.decibels(forLinear: 2) == 0)
        #expect(abs(RAOPVolume.decibels(forLinear: 0.5) - -15) < 0.0001)
        #expect(abs(RAOPVolume.decibels(forLinear: 0.15) - -25.5) < 0.0001)
        #expect(RAOPVolume.parameterBody(forLinear: 0.5) == "volume: -15.000000\r\n")
        #expect(abs(RAOPVolume.linear(forDecibels: -15) - 0.5) < 0.0001)
        #expect(RAOPVolume.linear(forDecibels: -144) == 0)
    }
}
