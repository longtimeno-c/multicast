import Foundation
import Testing
import MulticastAudio
@testable import MulticastDiscovery

@Suite struct TXTRecordTests {
    @Test func decodesWireFormat() {
        // [len]key=value ... including a bare boolean key and an empty-value key.
        var bytes: [UInt8] = []
        for entry in ["am=airupnp", "et=0,1", "da", "pw=", "vn=3"] {
            bytes.append(UInt8(entry.utf8.count))
            bytes.append(contentsOf: entry.utf8)
        }
        let txt = TXTRecord.decode(Data(bytes))
        #expect(txt == ["am": "airupnp", "et": "0,1", "da": "", "pw": "", "vn": "3"])
    }

    @Test func toleratesMalformedInput() {
        // Empty canonical TXT, a zero-length string, a key-less entry, a duplicate (first wins,
        // case-insensitively) and a truncated tail.
        #expect(TXTRecord.decode(Data([0])).isEmpty)
        let bytes: [UInt8] = [0, 2] + Array("=x".utf8) + [4] + Array("a=12".utf8) + [3] + Array("A=9".utf8) + [9] + Array("cut".utf8)
        #expect(TXTRecord.decode(Data(bytes)) == ["a": "12"])
    }

    @Test func valueMayContainEqualsAndUTF8() {
        let entry = Array("n=Taylor’s=Mac".utf8)
        let txt = TXTRecord.decode(Data([UInt8(entry.count)] + entry))
        #expect(txt["n"] == "Taylor’s=Mac")
    }

    @Test func encodeRoundTripsRealBridgeRecord() {
        let dict = TXTRecord.parse(displayString: Fixture.bridgeTXT)
        #expect(dict.count == 13)
        #expect(dict["am"] == "airupnp")
        #expect(dict["sr"] == "44100")
        #expect(TXTRecord.decode(TXTRecord.encode(dict)) == dict)
    }

    @Test func parsesEscapedSpacesFromDNSSDOutput() {
        let dict = TXTRecord.parse(displayString: Fixture.denonRAOPTXT)
        #expect(dict["am"] == "Denon AVR-X2800H")
        #expect(dict["vn"] == "65537")
    }

    @Test func lookupIsCaseInsensitive() {
        let dict = ["DeviceID": "54:2A:1B:00:11:22"]
        #expect(dict.txtValue("deviceid") == "54:2A:1B:00:11:22")
    }
}

@Suite struct NameTests {
    @Test func splitsRAOPInstanceNames() {
        let a = RAOPInstanceName("542A1B001122@Hall Sonos")
        #expect(a.deviceID == "542a1b001122")
        #expect(a.name == "Hall Sonos")

        let b = RAOPInstanceName("BBBB6F0011E7@Denon AVR-X2800H+")
        #expect(b.deviceID == "bbbb6f0011e7")
        #expect(b.name == "Denon AVR-X2800H+")

        let c = RAOPInstanceName("2A419D001125@Taylor’s MacBook Air")
        #expect(c.deviceID == "2a419d001125")
        #expect(c.name == "Taylor’s MacBook Air")
    }

    @Test func onlyFirstAtSeparatesAndPrefixMustBeHex() {
        #expect(RAOPInstanceName("AABBCCDDEEFF@Me@Home").name == "Me@Home")
        let noHex = RAOPInstanceName("Kitchen@Home")
        #expect(noHex.deviceID == nil)
        #expect(noHex.name == "Kitchen@Home")
        let noAt = RAOPInstanceName("Kitchen")
        #expect(noAt.deviceID == nil)
        #expect(noAt.name == "Kitchen")
    }

    @Test func normalisesDeviceIDs() {
        #expect(DeviceID.normalize("54:2A:1B:00:11:22") == "542a1b001122")
        #expect(DeviceID.normalize("8C-A9-6F-00-11-E9") == "8ca96f0011e9")
        #expect(DeviceID.normalize("BBBB58000010") == "bbbb58000010")
        #expect(DeviceID.normalize("") == nil)
        #expect(DeviceID.normalize("xyz") == nil)
        #expect(DeviceID.normalize("ABC") == nil)
    }

    @Test func cleansHostNames() {
        #expect(HostName.clean("pi.local.") == "pi.local")
        #expect(HostName.equal("Taylors-MacBook-Air.local.", "taylors-macbook-air.local"))
    }
}

@Suite struct FeatureTests {
    @Test func parsesSonosFeatureMask() throws {
        let f = try #require(AirPlayFeatures(txtValue: "0x445F8A00,0x801C340"))
        #expect(f.rawValue == 0x0801_C340_445F_8A00)
        #expect(f.contains(.supportsBufferedAudio)) // 38
        #expect(f.contains(.supportsPTP))           // 40
        #expect(f.contains(.transientPairing))      // 48
        #expect(f.contains(.audio))                 // 9
        #expect(!f.contains(.video))
        #expect(f.contains(bit: 59))
        #expect(!f.contains(bit: 64))
        #expect(f.description == "0x445F8A00,0x801C340")
        #expect(f.setBits.first == 9)
    }

    @Test func parsesLowOnlyAndDecimalForms() {
        #expect(AirPlayFeatures(txtValue: "0x5A7FFFF7")?.rawValue == 0x5A7F_FFF7)
        #expect(AirPlayFeatures(txtValue: "0x5A7FFFF7,0x1E")?.rawValue == 0x1E_5A7F_FFF7)
        #expect(AirPlayFeatures(txtValue: "512")?.contains(.audio) == true)
        #expect(AirPlayFeatures(txtValue: "") == nil)
        #expect(AirPlayFeatures(txtValue: "0x") == nil)
        #expect(AirPlayFeatures(txtValue: "0xZZ") == nil)
        #expect(AirPlayFeatures(txtValue: "1,2,3") == nil)
        #expect(AirPlayFeatures(txtValue: "0x1FFFFFFFF") == nil) // a word is 32 bits
    }

    @Test func parsesStatusFlags() {
        let sonos = AirPlayStatusFlags(txtValue: "0x404")
        #expect(sonos == [.audioCableAttached, .deviceSetupForHKAccessControl])
        let mac = AirPlayStatusFlags(txtValue: "0x204")
        #expect(mac?.contains(.oneTimePairingRequired) == true)
        #expect(mac?.contains(.passwordRequired) == false)
        #expect(AirPlayStatusFlags(txtValue: "0x80")?.contains(.passwordRequired) == true)
        #expect(AirPlayStatusFlags(txtValue: "8")?.contains(.pinRequired) == true)
        #expect(AirPlayStatusFlags(txtValue: "nope") == nil)
    }
}
