import CoreGraphics
import Foundation
import ImageIO
import MulticastAudio
import MulticastEngine
import MulticastHubModel
import Testing
@testable import MulticastHub

@Suite("Speaker presentation")
struct PresentationTests {
    @Test func transportsFromDescriptors() {
        #expect(SpeakerPresentation.transport(for: Fixtures.mainBedroom) == .airPlay1)
        #expect(SpeakerPresentation.transport(for: Fixtures.hallSonos) == .airPlay2)
        #expect(SpeakerPresentation.transport(for: Fixtures.local()) == .builtIn)
        var bt = Fixtures.local("local:bt-1", name: "Travel Speaker")
        bt.localKind = .bluetooth
        #expect(SpeakerPresentation.transport(for: bt) == .bluetooth)
        bt.localKind = .usb
        #expect(SpeakerPresentation.transport(for: bt) == .usb)
    }

    @Test func glyphsFromModelStrings() {
        #expect(SpeakerPresentation.glyph(for: Fixtures.mainBedroom, hostIsLaptop: true) == .airportExpress)
        #expect(SpeakerPresentation.glyph(for: Fixtures.hallSonos, hostIsLaptop: true) == .smartSpeaker)
        #expect(SpeakerPresentation.glyph(for: Fixtures.denonNative, hostIsLaptop: true) == .receiver)
        #expect(SpeakerPresentation.glyph(for: Fixtures.denonBridge, hostIsLaptop: true) == .receiver)
        #expect(SpeakerPresentation.glyph(for: Fixtures.local(), hostIsLaptop: true) == .laptop)
        #expect(SpeakerPresentation.glyph(for: Fixtures.local(), hostIsLaptop: false) == .speaker)
        let homePod = SpeakerDescriptor(id: "542a1b005566", name: "Kitchen", transport: .airplay2,
                                        airplayTXT: ["model": "AudioAccessory5,1"])
        #expect(SpeakerPresentation.glyph(for: homePod, hostIsLaptop: true) == .smartSpeaker)
        #expect(SpeakerPresentation.modelName(for: homePod) == "HomePod mini")
        var pods = Fixtures.local("local:bt-2", name: "Test AirPods Pro")
        pods.localKind = .bluetooth
        #expect(SpeakerPresentation.glyph(for: pods, hostIsLaptop: true) == .headphones)
    }

    @Test func modelNamesAndAddresses() {
        #expect(SpeakerPresentation.modelName(for: Fixtures.hallSonos) == "Sonos One")
        #expect(SpeakerPresentation.modelName(for: Fixtures.denonBridge) == "AirConnect bridge")
        #expect(SpeakerPresentation.modelName(for: Fixtures.denonNative) == "Denon AVR-X1000")
        #expect(SpeakerPresentation.modelName(for: Fixtures.mainBedroom) == "AirPort Express")
        #expect(SpeakerPresentation.modelName(for: Fixtures.local()) == nil)
        #expect(SpeakerPresentation.address(for: Fixtures.mainBedroom) == "main-bedroom.local:5000")
        #expect(SpeakerPresentation.address(for: Fixtures.hallSonos) == "192.0.2.20:7000")
        #expect(SpeakerPresentation.address(for: Fixtures.local()) == "BuiltInSpeakerDevice")
        let v6 = SpeakerDescriptor(id: "x", name: "x", transport: .airplay1, host: "2001:db8::5", port: 5000)
        #expect(SpeakerPresentation.address(for: v6) == "[2001:db8::5]:5000")
    }

    @Test func engineStatesMapToSpeakerStates() {
        func entry(_ s: EngineSnapshot.SinkStatus, _ error: String? = nil) -> EngineSnapshot.SinkEntry {
            .init(id: "a", name: "a", state: s, error: error, volume: 1, muted: false, enabled: true, offsetMillis: 0, effectiveVolume: 1)
        }
        #expect(SpeakerPresentation.state(for: nil) == .connecting)
        #expect(SpeakerPresentation.state(for: entry(.idle)) == .ready)
        #expect(SpeakerPresentation.state(for: entry(.connecting)) == .connecting)
        #expect(SpeakerPresentation.state(for: entry(.playing)) == .playing)
        #expect(SpeakerPresentation.state(for: entry(.failed, "Speaker did not become ready within 10.0 s"))
                == .failed(reason: "Not responding"))
    }

    @Test func failureWordingIsPlain() {
        // The messages MulticastEngine / RAOP / LocalOutput / Kit actually produce.
        #expect(FailureWording.plain("Speaker did not become ready within 10.0 s") == "Not responding")
        #expect(FailureWording.plain("cannot connect: Connection refused") == "Can\u{2019}t reach it on the network")
        #expect(FailureWording.plain("the speaker requires a password (401) and none was given") == "Needs an AirPlay password")
        #expect(FailureWording.plain("the speaker rejected the password (401 after digest)") == "Wrong AirPlay password")
        #expect(FailureWording.plain("ANNOUNCE failed: 453 Not Enough Bandwidth") == "In use by another device")
        #expect(FailureWording.plain("the speaker closed the RTSP connection") == "The speaker hung up")
        #expect(FailureWording.plain("Cannot open Patio: Patio has no resolved host/port yet") == "Not found on the network")
        #expect(FailureWording.plain("Output device Desk is not available") == "Output not available")
        #expect(FailureWording.plain("AudioOutputUnitStart failed (OSStatus -50 ????)") == "Core Audio refused the output")
        #expect(FailureWording.plain("something odd") == "Couldn\u{2019}t connect")
        #expect(FailureWording.plain("") == "Couldn\u{2019}t connect")
    }
}

@Suite("File queue")
struct FileQueueTests {
    private func info(_ t: String) -> InspectedFile { InspectedFile(title: t, artist: "A", album: "B", duration: 60) }
    private func url(_ n: String) -> URL { URL(fileURLWithPath: "/tmp/\(n).m4a") }

    @Test func appendSelectsFirstAndAdvances() {
        var q = FileQueue()
        #expect(q.current == nil)
        let added = q.append([(url("a"), info("A")), (url("b"), info("B")), (url("c"), InspectedFile(duration: 5))])
        #expect(added.map(\.title) == ["A", "B", "c"])
        #expect(q.current?.track.title == "A")
        do { let r = q.advance(); #expect(r) }
        #expect(q.current?.track.title == "B")
        do { let r = q.advance(); #expect(r) }
        do { let r = q.advance(); #expect(!r) }
        #expect(q.current?.track.title == "c")
        do { let r = q.goBack(); #expect(r) }
        #expect(q.current?.track.title == "B")
        q.rewind()
        #expect(q.current?.track.title == "A")
        do { let r = q.goBack(); #expect(!r) }
    }

    @Test func removingTheCurrentItemMovesToWhatFollowed() {
        var q = FileQueue()
        let t = q.append([(url("a"), info("A")), (url("b"), info("B")), (url("c"), info("C")), (url("d"), info("D"))])
        do { let r = q.select(id: t[2].id); #expect(r) }
        // Remove an earlier one and the current one: D followed C.
        do { let r = q.remove(ids: [t[0].id, t[2].id]); #expect(r) }
        #expect(q.current?.track.title == "D")
        // Removing a non-current item keeps the cursor on the same track.
        do { let r = q.remove(ids: [t[1].id]); #expect(!r) }
        #expect(q.current?.track.title == "D")
        // Removing the last current item when it is the last wraps to the first.
        _ = q.append([(url("e"), info("E"))])
        do { let r = q.select(id: q.tracks[1].id); #expect(r) }
        do { let r = q.remove(ids: [q.tracks[1].id]); #expect(r) }
        #expect(q.current?.track.title == "D")
        do { let r = q.remove(ids: Set(q.tracks.map(\.id))); #expect(r) }
        #expect(q.current == nil && q.isEmpty)
    }

    @Test func idsAreUniqueAndArtworkOnlyWhenPresent() {
        var q = FileQueue()
        let t = q.append([(url("a"), info("A")), (url("a"), InspectedFile(duration: 1, artwork: Data([1])))])
        #expect(t[0].id != t[1].id)
        #expect(t[0].artworkID == nil)
        #expect(t[1].artworkID == FileQueue.artworkID(forTrack: t[1].id))
    }

    @Test func folderExpansionFindsAudioFilesInOrder() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Disc 2")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for path in ["10 b.flac", "2 a.mp3", "notes.txt", ".hidden.m4a", "Disc 2/1 c.wav"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(path).path, contents: Data())
        }
        let root = dir.resolvingSymlinksInPath().path + "/"
        let found = AudioFileFilter.expand([dir]).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") }
        #expect(found == ["2 a.mp3", "10 b.flac", "Disc 2/1 c.wav"])
        #expect(AudioFileFilter.expand([dir.appendingPathComponent("notes.txt")]).isEmpty)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func userDefaultsRoundTrip() throws {
        let suite = "MulticastHubTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == HubSettings())
        let s = HubSettings(masterVolume: 0.3, speakers: ["542a1b001122": .init(volume: 0.2, syncTrimMs: 40, isEnabled: true)])
        store.save(s)
        #expect(UserDefaultsSettingsStore(defaults: defaults).load() == s)
    }

    @Test func artworkScalesDown() throws {
        // A 64×32 PNG made with ImageIO, scaled to 16.
        let ctx = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(ctx.makeImage())
        let png = try #require(ArtworkImaging.encode(image, as: .png))
        let small = try #require(ArtworkImaging.scaled(png, maxPixel: 16))
        let src = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 16)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 8)
        let jpeg = try #require(ArtworkImaging.jpeg(png))
        #expect(jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        #expect(ArtworkImaging.scaled(png, maxPixel: 0) == png)
    }
}
