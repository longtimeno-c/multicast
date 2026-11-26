import Foundation
import Testing
import MulticastAudio
@testable import MulticastDiscovery

@Suite struct MergeTests {
    private func byName(_ list: [SpeakerDescriptor]) -> [String: SpeakerDescriptor] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    @Test func groundTruthLANMergesToSixSpeakersWithMacHidden() {
        let list = SpeakerCatalog.merge(Fixture.all, hideThisMachine: true, localMachine: Fixture.macIdentity)
        #expect(list.map(\.name) == [
            "Denon AVR-X2800H", "Denon AVR-X2800H+", "Hall Sonos", "Main Bedroom", "Master Bedroom", "Patio",
        ])
        #expect(list.filter { $0.transport == .airplay1 }.count == 4)
        #expect(list.filter { $0.transport == .airplay2 }.count == 2)
        #expect(Set(list.map(\.id)).count == 6)
    }

    @Test func macIsKeptAndRecognisedWhenNotHidden() throws {
        let list = SpeakerCatalog.merge(Fixture.all, hideThisMachine: false, localMachine: Fixture.macIdentity)
        #expect(list.count == 7)
        let mac = try #require(byName(list)["Taylor’s MacBook Air"])
        #expect(mac.id == "2a419d001125")
        #expect(mac.transport == .airplay2)
        #expect(Fixture.macIdentity.matches(mac))
        #expect(!Fixture.macIdentity.matches(byName(list)["Hall Sonos"]!))
        #expect(mac.manufacturer == "Apple")
        #expect(mac.encryptionTypeCodes == [0, 3, 5])
        #expect(mac.encryptionTypes == [.none, .mfiSAP, .other(5)])
        #expect(mac.codecs == [.pcm, .alac, .aac, .aacELD])
    }

    @Test func loopbackSightingHidesMachineEvenWithoutHostMatch() {
        let records = Fixture.all + [Fixture.macRAOPLoopback]
        let list = SpeakerCatalog.merge(records, hideThisMachine: true, localMachine: LocalMachineIdentity())
        #expect(list.count == 6)
        #expect(!list.contains { $0.id == "2a419d001125" })
    }

    @Test func ownDeviceIDHidesMachine() {
        let identity = LocalMachineIdentity(deviceIDs: ["2A:41:9D:00:11:25"])
        let list = SpeakerCatalog.merge(Fixture.all, hideThisMachine: true, localMachine: identity)
        #expect(list.count == 6)
    }

    @Test func sonosMergesBothRecordsIntoOneAirPlay2Descriptor() throws {
        let list = SpeakerCatalog.merge([Fixture.sonosAirPlay, Fixture.sonosRAOP])
        #expect(list.count == 1)
        let s = try #require(list.first)
        #expect(s.id == "542a1b001122")
        #expect(s.name == "Hall Sonos")
        #expect(s.transport == .airplay2)
        #expect(s.host == "Sonos-542A1B001122.local")
        #expect(s.port == 7000)
        #expect(s.raopTXT["am"] == "One")
        #expect(s.airplayTXT["deviceid"] == "54:2A:1B:00:11:22")
        #expect(s.airplayDeviceID == s.id)
        #expect(s.model == "One")
        #expect(s.manufacturer == "Sonos")
        #expect(!s.requiresPassword)
        #expect(!s.advertisesPINRequired)
        #expect(!s.isAirConnectBridge)
        #expect(s.advertisesAirPlay2)
        #expect(s.encryptionTypes == [.none, .fairPlaySAPv25])
        #expect(s.codecs == [.pcm, .alac])
        #expect(s.supportsTextMetadata && s.supportsArtwork && s.supportsProgress)
        #expect(s.raopProtocolVersion == 65537)
        #expect(s.sourceVersion == "366.0")
        #expect(s.features.contains(.supportsBufferedAudio))
        #expect(s.statusFlags.contains(.deviceSetupForHKAccessControl))
    }

    @Test func bridgeIsAirPlay1WithRAOPHostAndPort() throws {
        let s = try #require(SpeakerCatalog.merge([Fixture.mainBedroom]).first)
        #expect(s.id == "bbbb58000010")
        #expect(s.name == "Main Bedroom")
        #expect(s.transport == .airplay1)
        #expect(s.host == "pi.local")
        #expect(s.port == 48179)
        #expect(s.isAirConnectBridge)
        #expect(s.model == "airupnp")
        #expect(s.manufacturer == nil)
        #expect(s.airplayTXT.isEmpty)
        #expect(s.features.rawValue == 0)
        #expect(s.encryptionTypes == [.none, .rsa])
        #expect(s.codecs == [.pcm, .alac])
        #expect(s.raopProtocolVersion == 3)
        #expect(!s.requiresPassword)
        #expect(!s.advertisesAirPlay2)
    }

    @Test func denonNativeUsesRAOPNameModelAndManufacturer() throws {
        let s = try #require(SpeakerCatalog.merge([Fixture.denonRAOP, Fixture.denonAirPlay]).first)
        #expect(s.id == "8ca96f0011e9")
        #expect(s.name == "Denon AVR-X2800H")
        #expect(s.host == "HEOS-Player.local")
        #expect(s.transport == .airplay2)
        #expect(s.model == "Denon AVR-X2800H")
        #expect(s.manufacturer == "Denon")
        #expect(s.statusFlags.contains(.relayable))
        #expect(!s.requiresPassword)
    }

    @Test func bridgeAndNativeDenonAreFlaggedAsSamePhysicalDevice() {
        let list = SpeakerCatalog.merge(Fixture.all, hideThisMachine: true, localMachine: Fixture.macIdentity)
        let conflicts = list.physicalDeviceConflicts()
        #expect(conflicts.count == 1)
        #expect(Set(conflicts.first?.map(\.id) ?? []) == ["bbbb6f0011e7", "8ca96f0011e9"])

        let named = byName(list)
        #expect(named["Denon AVR-X2800H+"]!.physicalDeviceName == "Denon AVR-X2800H")
        #expect(!named["Main Bedroom"]!.isLikelySamePhysicalDevice(as: named["Hall Sonos"]!))
        #expect(!named["Main Bedroom"]!.isLikelySamePhysicalDevice(as: named["Master Bedroom"]!))
    }

    @Test func bridgeIdProximityMatchesRenamedNative() {
        // Native renamed to "Denon AVR" by the user; bridge still "Denon AVR-X2800H+", ids differ by 2.
        var native = SpeakerCatalog.merge([Fixture.denonRAOP])[0]
        native.name = "Denon AVR"
        let bridge = SpeakerCatalog.merge([Fixture.denonBridge])[0]
        #expect(bridge.isLikelySamePhysicalDevice(as: native))
        #expect(native.isLikelySamePhysicalDevice(as: bridge))
    }

    @Test func passwordFromPwKeyOrStatusFlag() {
        var txt = TXTRecord.parse(displayString: Fixture.bridgeTXT)
        txt["pw"] = "true"
        let a = SpeakerCatalog.merge([ResolvedService(type: .raop, instanceName: "AABBCCDDEEFF@Locked", host: "x.local.", port: 5000, txt: txt)])
        #expect(a.first?.requiresPassword == true)

        let b = SpeakerCatalog.merge([ResolvedService(type: .raop, instanceName: "AABBCCDDEEFF@Locked", host: "x.local.", port: 5000, txt: ["sf": "0x84"])])
        #expect(b.first?.requiresPassword == true)
        #expect(b.first?.advertisesPINRequired == false)

        let c = SpeakerCatalog.merge([ResolvedService(type: .raop, instanceName: "AABBCCDDEEFF@Open", host: "x.local.", port: 5000, txt: ["pw": "false", "sf": "0x4"])])
        #expect(c.first?.requiresPassword == false)
    }

    @Test func laterRecordWinsSoPortChangesPropagate() {
        var moved = Fixture.mainBedroom
        moved.port = 40001
        let list = SpeakerCatalog.merge([Fixture.mainBedroom, moved])
        #expect(list.count == 1)
        #expect(list.first?.port == 40001)
    }

    @Test func removalDropsDevice() {
        let without = Fixture.all.filter { $0.instanceName != "BBBB58000030@Patio" }
        let list = SpeakerCatalog.merge(without, hideThisMachine: true, localMachine: Fixture.macIdentity)
        #expect(list.count == 5)
        #expect(!list.contains { $0.name == "Patio" })
    }

    @Test func airPlayOnlyDeviceUsesAirPlayEndpoint() throws {
        let s = try #require(SpeakerCatalog.merge([Fixture.sonosAirPlay]).first)
        #expect(s.id == "542a1b001122")
        #expect(s.name == "Hall Sonos")
        #expect(s.transport == .airplay2)
        #expect(s.port == 7000)
        #expect(s.raopTXT.isEmpty)
    }

    @Test func raopWithoutDeviceIDGetsStableNameKey() {
        let s = SpeakerCatalog.merge([ResolvedService(type: .raop, instanceName: "Kitchen", host: "k.local", port: 5000, txt: [:])])
        #expect(s.first?.id == "name:kitchen")
        #expect(s.first?.name == "Kitchen")
    }

    @Test func idsAreStableAcrossInputOrder() {
        let a = SpeakerCatalog.merge(Fixture.all, hideThisMachine: true, localMachine: Fixture.macIdentity)
        let b = SpeakerCatalog.merge(Fixture.all.reversed(), hideThisMachine: true, localMachine: Fixture.macIdentity)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a == b)
    }

    @Test func sortsByNameCaseInsensitivelyThenId() {
        let list = SpeakerCatalog.sorted([
            SpeakerDescriptor(id: "b", name: "kitchen", transport: .airplay1),
            SpeakerDescriptor(id: "a", name: "Kitchen", transport: .airplay1),
            SpeakerDescriptor(id: "c", name: "Bedroom 10", transport: .airplay1),
            SpeakerDescriptor(id: "d", name: "Bedroom 2", transport: .airplay1),
        ])
        #expect(list.map(\.id) == ["d", "c", "a", "b"])
    }
}

@Suite struct ClassificationTests {
    @Test func realRecords() {
        let bridge = TXTRecord.parse(displayString: Fixture.bridgeTXT)
        #expect(SpeakerCatalog.classify(raopTXT: bridge, airplayTXT: [:]) == .airplay1)

        let sonos = TXTRecord.parse(displayString: Fixture.sonosRAOPTXT)
        #expect(SpeakerCatalog.classify(raopTXT: sonos, airplayTXT: [:]) == .airplay2) // ft alone suffices
        #expect(SpeakerCatalog.classify(raopTXT: [:], airplayTXT: TXTRecord.parse(displayString: Fixture.sonosAirPlayTXT)) == .airplay2)
    }

    @Test func airPlay1DeviceWithVideoOnlyAirPlayRecordStaysAirPlay1() {
        // Classic Apple TV / AirPort Express style: features without bits 38/40/48.
        let raop = ["vn": "65537", "ft": "0x5A7FFFF7,0x0", "et": "0,3,5", "cn": "0,1,2,3"]
        let airplay = ["deviceid": "00:11:22:33:44:55", "features": "0x5A7FFFF7,0x0"]
        #expect(SpeakerCatalog.classify(raopTXT: raop, airplayTXT: airplay) == .airplay1)
    }

    @Test func vnFallbackOnlyWithoutFeatureMask() {
        #expect(SpeakerCatalog.classify(raopTXT: ["vn": "65537"], airplayTXT: ["deviceid": "00:11:22:33:44:55"]) == .airplay2)
        #expect(SpeakerCatalog.classify(raopTXT: ["vn": "65537"], airplayTXT: [:]) == .airplay1)
        #expect(SpeakerCatalog.classify(raopTXT: ["vn": "3"], airplayTXT: ["deviceid": "00:11:22:33:44:55"]) == .airplay1)
    }

    @Test func eachMarkerBitAloneClassifiesAsAirPlay2() {
        for bit in [38, 40, 48] {
            let mask = AirPlayFeatures(rawValue: 1 << UInt64(bit))
            #expect(SpeakerCatalog.classify(raopTXT: ["ft": mask.description], airplayTXT: [:]) == .airplay2)
        }
    }
}
