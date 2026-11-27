import Foundation
import MulticastAudio
import MulticastHubModel
import Testing
@testable import MulticastHub

/// Speakers whose slider is a real device volume (a Mac output), against a fake provider.
@Suite("LocalHub device-volume speakers")
struct DeviceVolumeTests {
    static let desk = "local:BuiltInSpeakerDevice"

    /// A hub whose desk speakers have a device volume of `volume`.
    private func rig(deskVolume volume: Double? = 0.3, settings: InMemorySettingsStore = InMemorySettingsStore()) async -> Rig {
        let rig = Rig(settings: settings)
        rig.deviceVolumes.volumes.update { $0[Self.desk] = volume }
        await rig.start()
        return rig
    }

    private func volumeCalls(_ rig: Rig, _ id: String = desk) -> [String] {
        rig.session.calls.filter { $0.hasPrefix("volume \(id) ") }
    }

    @Test func stateReportsTheDeviceVolumeOnOrOff() async throws {
        let rig = await rig()
        let off = try #require(rig.speaker(Fixtures.local()))
        #expect(off.state == .off && off.volume == 0.3)
        // The others keep their preset.
        #expect(rig.speaker(Fixtures.mainBedroom)?.volume == 0.5)

        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        try await rig.waitFor("ready") { $0.speaker(SpeakerID(Self.desk))?.state == .ready }
        #expect(rig.speaker(Fixtures.local())?.volume == 0.3)
    }

    @Test func sliderSetsTheDeviceAndLeavesTheGainAtFull() async throws {
        let store = InMemorySettingsStore()
        let rig = await rig(settings: store)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 1)

        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 0.8))
        #expect(rig.deviceVolumes.sets.get().map(\.volume) == [0.8])
        #expect(rig.deviceVolumes.volumes.get()[Self.desk] == 0.8)
        #expect(rig.speaker(Fixtures.local())?.volume == 0.8)
        // The session never hears anything but full gain for it, and the preset is not touched.
        #expect(volumeCalls(rig).allSatisfy { $0 == "volume \(Self.desk) 1.0" })
        #expect(store.load().speakers[Self.desk]?.volume ?? 0.5 == 0.5)

        // Out-of-range values are clamped before they reach the device.
        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 1.7))
        #expect(rig.deviceVolumes.sets.get().last?.volume == 1)
    }

    @Test func sliderSetsTheDeviceWhileTheSpeakerIsOff() async throws {
        let rig = await rig()
        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 0.6))
        let off = try #require(rig.speaker(Fixtures.local()))
        #expect(off.state == .off && off.volume == 0.6)
        #expect(rig.deviceVolumes.volumes.get()[Self.desk] == 0.6)
    }

    @Test func turningOnDoesNotWriteARememberedVolumeToTheDevice() async throws {
        // A preset of a speaker whose slider already was the device's volume.
        let store = InMemorySettingsStore(HubSettings(speakers: [
            Self.desk: .init(volume: 0.9, syncTrimMs: 20, isEnabled: true, volumeHandedToDevice: true)]))
        let rig = await rig(deskVolume: 0.2, settings: store)
        try await rig.waitFor("restored") { $0.speaker(SpeakerID(Self.desk))?.state == .ready }
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        #expect(rig.deviceVolumes.volumes.get()[Self.desk] == 0.2)
        #expect(rig.speaker(Fixtures.local())?.volume == 0.2)
        // Not as gain either; the trim is still its preset.
        let i = rig.session.inner.get()
        #expect(i.selectVolumes[Self.desk] == 1 && i.selectOffsets[Self.desk] == 20)

        // Off and on again by hand: the same.
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: false))
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 1)
    }

    @Test func aGainRememberedFromBeforeIsFoldedIntoTheDeviceOnce() async throws {
        // Saved by a version in which the slider was a gain: heard as 0.25 of the Mac's 0.8.
        let old = try JSONDecoder().decode(HubSettings.self, from: Data("""
            {"masterVolume":0.6,"speakers":{"\(Self.desk)":{"volume":0.25,"syncTrimMs":20,"isEnabled":true}}}
            """.utf8))
        #expect(old.speakers[Self.desk]?.volumeHandedToDevice == false)
        let store = InMemorySettingsStore(old)
        let rig = await rig(deskVolume: 0.8, settings: store)
        try await rig.waitFor("restored") { $0.speaker(SpeakerID(Self.desk))?.state == .ready }
        // Full gain from now on, and the device turned down to match instead of a jump.
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 1)
        let sets = rig.deviceVolumes.sets.get()
        #expect(sets.count == 1 && abs((sets.first?.volume ?? 0) - 0.2) < 1e-9)
        #expect(abs((rig.speaker(Fixtures.local())?.volume ?? 0) - 0.2) < 1e-9)
        #expect(store.load().speakers[Self.desk]?.volumeHandedToDevice == true)

        // Once: off and on again, and a hub started again on the same settings, leave it alone.
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: false))
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.deviceVolumes.sets.get().count == 1)
        let again = await self.rig(deskVolume: 0.2, settings: store)
        try await again.waitFor("restored") { $0.speaker(SpeakerID(Self.desk))?.state == .ready }
        #expect(again.deviceVolumes.sets.get().isEmpty)
    }

    @Test func anOldGainIsNotFoldedWhileTheSpeakerIsOffOrAfterTheSliderWasUsed() async throws {
        let store = InMemorySettingsStore(HubSettings(speakers: [Self.desk: .init(volume: 0.25, isEnabled: false)]))
        let rig = await rig(deskVolume: 0.8, settings: store)
        await rig.hub.settle()
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        // The person sets the device's volume with the slider: that is the level they want.
        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 0.5))
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.deviceVolumes.sets.get().map(\.volume) == [0.5])
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 1)
    }

    @Test func aMutedDeviceIsFoldedWhenItsVolumeComesBack() async throws {
        let store = InMemorySettingsStore(HubSettings(speakers: [Self.desk: .init(volume: 0.5, isEnabled: true)]))
        let rig = await rig(deskVolume: 0, settings: store)
        try await rig.waitFor("restored") { $0.speaker(SpeakerID(Self.desk))?.state == .ready }
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        rig.deviceVolumes.changeOutside(Self.desk, to: 0.6)
        try await rig.waitFor("folded") { abs(($0.speaker(SpeakerID(Self.desk))?.volume ?? 0) - 0.3) < 1e-9 }
        #expect(rig.deviceVolumes.sets.get().count == 1)
        rig.deviceVolumes.changeOutside(Self.desk, to: 0.7)
        try await rig.waitFor("left alone") { $0.speaker(SpeakerID(Self.desk))?.volume == 0.7 }
        #expect(rig.deviceVolumes.sets.get().count == 1)
    }

    @Test func aSpeakerFirstUsedWithADeviceVolumeIsNeverFolded() async throws {
        let store = InMemorySettingsStore()
        let rig = await rig(deskVolume: 0.8, settings: store)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        #expect(store.load().speakers[Self.desk]?.volumeHandedToDevice == true)
    }

    @Test func aChangeMadeElsewhereIsPublished() async throws {
        let rig = await rig()
        let before = rig.state.revision
        rig.deviceVolumes.changeOutside(Self.desk, to: 0.45)
        try await rig.waitFor("published") { $0.speaker(SpeakerID(Self.desk))?.volume == 0.45 }
        #expect(rig.state.revision > before)
        // Nothing was set and no gain moved: the hub only reports it.
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        #expect(volumeCalls(rig).isEmpty)
    }

    @Test func aDeviceWithoutVolumeControlKeepsItsGain() async throws {
        let store = InMemorySettingsStore()
        let rig = await rig(deskVolume: nil, settings: store)
        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 0.25))
        #expect(rig.speaker(Fixtures.local())?.volume == 0.25)
        #expect(store.load().speakers[Self.desk]?.volume == 0.25)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 0.25)
        try await rig.hub.perform(.setSpeakerVolume(id: SpeakerID(Self.desk), volume: 0.75))
        #expect(rig.session.calls.contains("volume \(Self.desk) 0.75"))
        #expect(rig.deviceVolumes.sets.get().isEmpty)
    }

    @Test func masterVolumeStillReachesTheSession() async throws {
        let rig = await rig()
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        try await rig.hub.perform(.setMasterVolume(volume: 0.35))
        #expect(rig.session.inner.get().master == 0.35)
        #expect(rig.state.masterVolume == 0.35)
        // The master is the group's, not the device's.
        #expect(rig.deviceVolumes.sets.get().isEmpty)
        #expect(rig.speaker(Fixtures.local())?.volume == 0.3)
    }

    @Test func aSpeakerThatGainsOrLosesItsControlWhileOnChangesGain() async throws {
        let store = InMemorySettingsStore(HubSettings(speakers: [Self.desk: .init(volume: 0.4, syncTrimMs: 0, isEnabled: false)]))
        let rig = await rig(settings: store)
        try await rig.hub.perform(.setSpeakerEnabled(id: SpeakerID(Self.desk), enabled: true))
        await rig.hub.settle()
        #expect(rig.session.inner.get().selectVolumes[Self.desk] == 1)

        // The control goes away (the device changed): back to the remembered gain.
        rig.deviceVolumes.changeOutside(Self.desk, to: nil)
        try await rig.waitFor("gain") { $0.speaker(SpeakerID(Self.desk))?.volume == 0.4 }
        #expect(volumeCalls(rig).last == "volume \(Self.desk) 0.4")

        // And comes back: full gain again, the device's volume shown.
        rig.deviceVolumes.changeOutside(Self.desk, to: 0.7)
        try await rig.waitFor("device") { $0.speaker(SpeakerID(Self.desk))?.volume == 0.7 }
        #expect(volumeCalls(rig).last == "volume \(Self.desk) 1.0")
    }
}
