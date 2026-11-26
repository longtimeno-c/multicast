import Foundation
import Testing
@testable import MulticastKit

// MARK: Fixtures (TXT records as advertised on the real LAN)

private let bridgeTXT = ["am": "airupnp", "tp": "UDP", "sm": "false", "sv": "false", "ek": "1", "et": "0,1",
                         "md": "0,1,2", "cn": "0,1", "ch": "2", "ss": "16", "sr": "44100", "vn": "3", "txtvers": "1"]
private let denonTXT = ["cn": "0,1", "da": "true", "et": "0,4", "ft": "0x445F8A00,0x801C340", "md": "0,1,2",
                        "am": "Denon AVR-X2800H", "sf": "0x804", "tp": "UDP", "vn": "65537", "vs": "366.0"]

private let builtIn = SpeakerDescriptor(id: "local:BuiltInSpeakerDevice", name: "MacBook Air Speakers", transport: .local,
                                        localDeviceUID: "BuiltInSpeakerDevice", localKind: .builtIn)
private let usb = SpeakerDescriptor(id: "local:USB1", name: "USB DAC", transport: .local, localDeviceUID: "USB1", localKind: .usb)
private let airplaySystem = SpeakerDescriptor(id: "local:AirPlay", name: "AirPlay", transport: .local,
                                              localDeviceUID: "AirPlay", localKind: .airplaySystem)
private let mainBedroom = SpeakerDescriptor(id: "bbbb58000010", name: "Main Bedroom", transport: .airplay1,
                                             host: "pi.local", port: 48179, model: "airupnp", raopTXT: bridgeTXT)
private let masterBedroom = SpeakerDescriptor(id: "bbbb58000020", name: "Master Bedroom", transport: .airplay1,
                                               host: "pi.local", port: 55707, model: "airupnp", raopTXT: bridgeTXT)
private let denonBridge = SpeakerDescriptor(id: "bbbb6f0011e7", name: "Denon AVR-X2800H+", transport: .airplay1,
                                            host: "pi.local", port: 53263, model: "airupnp", raopTXT: bridgeTXT)
private let denonNative = SpeakerDescriptor(id: "8ca96f0011e9", name: "Denon AVR-X2800H", transport: .airplay2,
                                            host: "HEOS-Player.local", port: 7000, model: "Denon AVR-X2800H",
                                            raopTXT: denonTXT, airplayTXT: ["features": "0x445F8A00,0x801C340"])
private let sonos = SpeakerDescriptor(id: "542a1b001122", name: "Hall Sonos", transport: .airplay2,
                                      host: "Sonos-542A1B001122.local", port: 7000, model: "One", raopTXT: denonTXT)
private let all = [builtIn, denonNative, denonBridge, sonos, mainBedroom, masterBedroom]

@Suite struct MatchingTests {
    @Test func resolvesByIDNameAndRawInstanceName() {
        #expect(SpeakerMatching.resolve("542a1b001122", in: all) == .found(sonos))
        #expect(SpeakerMatching.resolve("hall sonos", in: all) == .found(sonos))
        #expect(SpeakerMatching.resolve("542A1B001122@Hall Sonos", in: all) == .found(sonos))
        #expect(SpeakerMatching.resolve("local:BuiltInSpeakerDevice", in: all) == .found(builtIn))
        #expect(SpeakerMatching.resolve("MacBook Air Speakers", in: all) == .found(builtIn))
    }

    @Test func exactNameBeatsPrefixAndPrefixMustBeUnique() {
        // "Denon AVR-X2800H" is also a prefix of "Denon AVR-X2800H+", but the exact name wins.
        #expect(SpeakerMatching.resolve("Denon AVR-X2800H", in: all) == .found(denonNative))
        #expect(SpeakerMatching.resolve("Main", in: all) == .found(mainBedroom))
        guard case .ambiguous(let list) = SpeakerMatching.resolve("Ma", in: all) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(Set(list.map(\.id)) == [builtIn.id, mainBedroom.id, masterBedroom.id])
        #expect(SpeakerMatching.resolve("Kitchen", in: all) == .notFound)
        #expect(SpeakerMatching.resolve("  ", in: all) == .notFound)
    }

    @Test func curlyApostropheAndDiacriticsAreFolded() {
        let mac = SpeakerDescriptor(id: "2a419d001125", name: "Taylor’s Café", transport: .airplay2)
        #expect(SpeakerMatching.resolve("taylor's cafe", in: [mac]) == .found(mac))
    }

    @Test func duplicateExactNamesAreAmbiguous() {
        var twin = sonos
        twin.id = "aabbccddeeff"
        guard case .ambiguous = SpeakerMatching.resolve("Hall Sonos", in: [sonos, twin]) else {
            Issue.record("expected ambiguous"); return
        }
    }

    @Test func bridgeAndNativeDenonConflict() {
        #expect(SpeakerMatching.physicalConflict(for: denonBridge, among: [sonos, denonNative]) == denonNative)
        #expect(SpeakerMatching.physicalConflict(for: denonNative, among: [denonBridge]) == denonBridge)
        #expect(SpeakerMatching.physicalConflict(for: mainBedroom, among: [masterBedroom, sonos, builtIn]) == nil)
        #expect(SpeakerMatching.physicalConflict(for: builtIn, among: all) == nil)
    }
}

@Suite struct DirectoryMergeTests {
    @Test func localFirstDefaultFirstThenNetworkInDiscoveryOrder() {
        let merged = SpeakerDirectory.merge(network: [denonNative, sonos, mainBedroom], local: [builtIn, usb],
                                            defaultLocalID: usb.id)
        #expect(merged.map(\.id) == [usb.id, builtIn.id, denonNative.id, sonos.id, mainBedroom.id])
    }

    @Test func hidesAirPlaySystemOutputAndDeduplicatesIDs() {
        var dup = sonos
        dup.name = "Hall Sonos (stale)"
        let merged = SpeakerDirectory.merge(network: [sonos, dup], local: [builtIn, airplaySystem])
        #expect(merged.map(\.id) == [builtIn.id, sonos.id])
        #expect(merged.last?.name == "Hall Sonos")
        let shown = SpeakerDirectory.merge(network: [], local: [airplaySystem], hiddenLocalKinds: [])
        #expect(shown.map(\.id) == [airplaySystem.id])
    }

    @Test func emptyInputsGiveEmptyList() {
        #expect(SpeakerDirectory.merge(network: [], local: []).isEmpty)
    }
}

@Suite struct SinkFactoryTests {
    @Test func transportsMapToSinkKinds() {
        #expect(SinkFactory.kind(for: mainBedroom) == .raop)
        #expect(SinkFactory.kind(for: sonos) == .raop)
        #expect(SinkFactory.kind(for: builtIn) == .local)
    }

    @Test func networkSpeakersBecomeRAOPSinksWithTheirID() throws {
        let sink = try SinkFactory(passwords: [sonos.id: "secret"]).makeSink(for: sonos)
        let raop = try #require(sink as? RAOPSink)
        #expect(raop.id == sonos.id)
        #expect(raop.displayName == "Hall Sonos")
        #expect(raop.options.password == "secret")
        let other = try #require(try SinkFactory().makeSink(for: mainBedroom) as? RAOPSink)
        #expect(other.options.password == nil)
    }

    @Test func unresolvedNetworkSpeakerIsRejected() {
        var unresolved = sonos
        unresolved.host = nil
        #expect(throws: SinkFactoryError.missingNetworkAddress(speaker: "Hall Sonos")) {
            try SinkFactory().makeSink(for: unresolved)
        }
    }

    #if os(macOS)
    @Test func localSpeakerWithoutUIDIsRejected() {
        let broken = SpeakerDescriptor(id: "local:x", name: "Broken", transport: .local)
        #expect(throws: SinkFactoryError.missingDeviceUID(speaker: "Broken")) {
            try SinkFactory().makeSink(for: broken)
        }
    }
    #endif
}

@Suite struct FadeTests {
    private func run(_ g: inout FadeGain, frames: Int, value: Int16 = 10_000) -> [Int16] {
        var buf = [Int16](repeating: value, count: frames * 2)
        buf.withUnsafeMutableBufferPointer { g.apply(to: $0.baseAddress!, frames: frames, channels: 2) }
        return buf
    }

    @Test func fadeInRampsLinearlyThenPassesThrough() {
        var g = FadeGain(fadeInFrames: 100, fadeOutFrames: 100)
        let a = run(&g, frames: 150)
        #expect(a[0] == 0 && a[1] == 0)
        #expect(a[50 * 2] == 5_000)
        #expect(a[99 * 2] == 9_900)
        #expect(a[100 * 2] == 10_000 && a[149 * 2 + 1] == 10_000)
        #expect(g.position == 150 && !g.fadingOut && !g.finished)
        let b = run(&g, frames: 352)
        #expect(b.allSatisfy { $0 == 10_000 })
    }

    @Test func fadeOutRampsToSilenceAndFinishes() {
        var g = FadeGain(fadeInFrames: 0, fadeOutFrames: 200)
        _ = run(&g, frames: 50)
        g.beginFadeOut()
        let a = run(&g, frames: 150)
        #expect(a[0] == 10_000)
        #expect(a[100 * 2] == 5_000)
        #expect(!g.finished)
        let b = run(&g, frames: 100)
        #expect(b[49 * 2] == 50)
        #expect(b[50 * 2] == 0 && b[99 * 2 + 1] == 0)
        #expect(g.finished)
        g.beginFadeOut() // idempotent
        #expect(g.finished)
    }

    @Test func zeroLengthFadeOutEndsImmediately() {
        var g = FadeGain(fadeInFrames: 0, fadeOutFrames: 0)
        g.beginFadeOut()
        #expect(g.finished)
    }

    @Test func fadingSourceEndsAfterRequestedFade() {
        let tone = ToneSource(frequency: 1_000, amplitude: 0.5, duration: nil, fadeIn: 0, fadeOut: 0)
        let src = FadingSource(tone, fadeIn: 0.01, fadeOut: 0.02) // 441 / 882 frames
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: 352 * 2)
        defer { buf.deallocate() }
        #expect(src.read(into: buf, frameCount: 352) == 352)
        #expect(buf[0] == 0)
        #expect(src.read(into: buf, frameCount: 352) == 352)
        src.requestFadeOut()
        var reads = 0
        while src.read(into: buf, frameCount: 352) != nil { reads += 1; if reads > 10 { break } }
        #expect(reads == 3) // 882 frames of fade = 2.5 packets
        #expect(src.read(into: buf, frameCount: 352) == nil)
        #expect(src.displayName == tone.displayName)
        #expect(!src.isLive)
    }

    @Test func rearmAfterAFinishedFadeOutPlaysAgainWithAFadeIn() async throws {
        let tone = ToneSource(frequency: 1_000, amplitude: 0.5, duration: nil, fadeIn: 0, fadeOut: 0)
        let src = FadingSource(tone, fadeIn: 0.01, fadeOut: 0.01)
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: 352 * 2)
        defer { buf.deallocate() }
        src.requestFadeOut()
        while src.read(into: buf, frameCount: 352) != nil {}
        #expect(src.read(into: buf, frameCount: 352) == nil)
        #expect(src.isFadeOutRequested)
        src.rearm()
        #expect(!src.isFadeOutRequested)
        #expect(src.read(into: buf, frameCount: 352) == 352)
        #expect(buf[0] == 0, "fresh fade-in starts from silence")
        // start() re-arms too (the engine calls it on play after stop).
        src.requestFadeOut()
        while src.read(into: buf, frameCount: 352) != nil {}
        try await src.start()
        #expect(src.read(into: buf, frameCount: 352) == 352)
    }
}
