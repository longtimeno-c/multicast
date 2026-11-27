import Foundation
import MulticastHubModel
import MulticastKit
import MulticastRAOP
import Testing
@testable import MulticastHub

/// A speaker whose AirPlay access setting admits only its owner: the hub turns it off by
/// itself, keeps it apart for the run, never tries it again on its own, and asks it once more
/// only when the person says so.
@Suite("LocalHub restricted speakers")
struct RestrictedSpeakerTests {
    private static let homePod = Fixtures.neighboursHomePod
    private static let id = SpeakerID(homePod.id)
    private static let speakers = [Fixtures.local(), Fixtures.mainBedroom, Fixtures.hallSonos, homePod]

    /// Hall Sonos and the HomePod on, a file playing; the HomePod answers 403.
    private func refusedWhilePlaying(_ rig: Rig) async throws {
        await rig.start()
        try await rig.addFiles(["one.m4a"], in: temporaryDirectory())
        rig.session.failOnPrepare(Self.homePod.id, Fixtures.refusal)
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("refused") { $0.speaker(Self.id)?.isRestricted == true }
        await rig.hub.settle()
    }

    @Test func refusalTurnsTheSpeakerOffAndSetsItApart() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        let pod = try #require(rig.state.speaker(Self.id))
        #expect(pod.isRestricted && !pod.isEnabled && pod.state == .off)
        // The rest plays on; the refused one is out of the group and remembered as off.
        #expect(rig.state.speaker("542a1b003344")?.state == .playing)
        #expect(!rig.session.inner.get().selected.contains(Self.homePod.id))
        #expect(rig.settings.load().speakers[Self.homePod.id]?.isEnabled == false)
        #expect(rig.state.transport.isPlaying)
        // Not counted as failing, nor as on.
        let counts = SpeakerCounts(rig.state.speakers)
        #expect(counts.failed == 0 && counts.playing == 1)
        // Mainly not mentioned anywhere as a problem.
        #expect(rig.state.speakers.allSatisfy { if case .failed = $0.state { false } else { true } })
    }

    @Test func aRefusedSpeakerIsNotTriedAgainOnItsOwn() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        let before = rig.session.calls.filter { $0.hasSuffix(Self.homePod.id) }
        // Refresh, the network listing changing, time passing: none of it touches the HomePod.
        try await rig.hub.perform(.refreshSpeakers)
        rig.session.setSpeakers(Self.speakers.reversed())
        rig.clock.advance(120)
        await rig.hub.tick()
        await rig.hub.settle()
        #expect(rig.session.calls.filter { $0.hasSuffix(Self.homePod.id) } == before)
        #expect(rig.state.speaker(Self.id)?.isRestricted == true)
        #expect(rig.state.speaker(Self.id)?.isEnabled == false)
    }

    @Test func aRefusedPlayingSpeakerAloneStopsPlayback() async throws {
        let rig = Rig(speakers: Self.speakers)
        await rig.start()
        try await rig.addFiles(["one.m4a"], in: temporaryDirectory())
        rig.session.failOnPrepare(Self.homePod.id, Fixtures.refusal)
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("stopped") { $0.speaker(Self.id)?.isRestricted == true && !$0.transport.isPlaying }
        #expect(rig.session.inner.get().selected.isEmpty)
    }

    @Test func theNextLaunchDoesNotRestoreIt() async throws {
        let store = InMemorySettingsStore()
        do {
            let rig = Rig(settings: store, speakers: Self.speakers)
            try await refusedWhilePlaying(rig)
            await rig.hub.shutdown()
        }
        #expect(store.load().speakers[Self.homePod.id]?.isEnabled == false)
        #expect(store.load().speakers["542a1b003344"]?.isEnabled == true)

        let rig = Rig(settings: store, speakers: Self.speakers)
        await rig.start()
        try await rig.waitFor("restored") { $0.speaker("542a1b003344")?.state == .ready }
        #expect(!rig.session.calls.contains("select \(Self.homePod.id)"))
        // A new run has not been told anything yet: an ordinary speaker, off.
        let pod = try #require(rig.state.speaker(Self.id))
        #expect(!pod.isRestricted && !pod.isEnabled && pod.state == .off)
    }

    @Test func aRememberedSpeakerThatRefusesAtRestoreIsSetApartAndForgotten() async throws {
        let store = InMemorySettingsStore()
        var saved = HubSettings()
        saved.speakers[Self.homePod.id] = .init(volume: 0.4, isEnabled: true)
        store.save(saved)
        let rig = Rig(settings: store, speakers: Self.speakers)
        // The owner changed the setting since the last run, and a sink can't even be made now.
        rig.session.inner.update { $0.selectErrors[Self.homePod.id] = RAOPError.accessRefused(method: "OPTIONS") }
        await rig.start()
        try await rig.waitFor("restricted") { $0.speaker(Self.id)?.isRestricted == true }
        #expect(rig.state.speaker(Self.id)?.isEnabled == false)
        #expect(store.load().speakers[Self.homePod.id]?.isEnabled == false)
        #expect(store.load().speakers[Self.homePod.id]?.volume == 0.4)
    }

    @Test func checkAgainAdmittedMakesItAnOrdinarySpeakerThatStaysOff() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        rig.session.inner.update { $0.access[Self.homePod.id] = .admitted }
        rig.session.accessGate.close()
        try await rig.hub.perform(.retrySpeaker(id: Self.id))
        // While it asks: still apart and off (so a remote that predates `isCheckingAccess`
        // never sees a connecting speaker), marked as being asked, still not counted.
        let asking = try #require(rig.state.speaker(Self.id))
        #expect(asking.isRestricted && asking.isCheckingAccess && asking.state == .off && !asking.isEnabled)
        #expect(SpeakerCounts(rig.state.speakers).connecting == 0)
        #expect(rig.state.speakers.filter { $0.state == .connecting }.isEmpty)
        // A second press while it asks is the same question.
        try await rig.hub.perform(.retrySpeaker(id: Self.id))
        rig.session.accessGate.open()
        try await rig.waitFor("admitted") { $0.speaker(Self.id)?.isRestricted == false }
        let pod = try #require(rig.state.speaker(Self.id))
        #expect(!pod.isEnabled && pod.state == .off && !pod.isCheckingAccess)
        #expect(rig.session.calls.filter { $0 == "checkAccess \(Self.homePod.id)" }.count == 1)
        // Asked apart from the group: never selected, so nothing was heard there.
        #expect(!rig.session.inner.get().selected.contains(Self.homePod.id))
        #expect(rig.settings.load().speakers[Self.homePod.id]?.isEnabled == false)

        // Now the person can turn it on like any other speaker.
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.waitFor("playing") { $0.speaker(Self.id)?.state == .playing }
    }

    @Test func checkAgainRefusedOrUnansweredLeavesItApart() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        for answer in [SpeakerAccessCheck.refused, .inconclusive("cannot connect: timed out")] {
            rig.session.inner.update { $0.access[Self.homePod.id] = answer }
            try await rig.hub.perform(.retrySpeaker(id: Self.id))
            await rig.hub.settle()
            let pod = try #require(rig.state.speaker(Self.id))
            #expect(pod.isRestricted && !pod.isEnabled && pod.state == .off, "\(answer)")
        }
        #expect(rig.session.calls.filter { $0 == "checkAccess \(Self.homePod.id)" }.count == 2)
        #expect(!rig.session.inner.get().selected.contains(Self.homePod.id))
    }

    /// A check that was overtaken (the person turned the speaker on meanwhile, it refused again
    /// and they pressed Check Again) still finishes, since its `OPTIONS` can't be cancelled. Its
    /// answer is stale: it must neither end the newer check nor decide for it.
    @Test func anOvertakenCheckCannotAnswerForTheNextOne() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        let first = Gate(), second = Gate()
        first.close(); second.close()
        rig.session.scriptedAccess.set([(.admitted, first), (.refused, second)])

        try await rig.hub.perform(.retrySpeaker(id: Self.id))                       // check A
        #expect(rig.state.speaker(Self.id)?.isCheckingAccess == true)
        // An older remote turns it on; it is refused again at once.
        rig.session.inner.update { $0.selectErrors[Self.homePod.id] = RAOPError.accessRefused(method: "OPTIONS") }
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.waitFor("refused again") {
            $0.speaker(Self.id)?.isRestricted == true && $0.speaker(Self.id)?.isEnabled == false
        }
        try await rig.hub.perform(.retrySpeaker(id: Self.id))                       // check B
        #expect(rig.state.speaker(Self.id)?.isCheckingAccess == true)

        // A answers "admitted", late: ignored, and B is still asking.
        first.open()
        let deadline = Date().addingTimeInterval(2)
        while rig.session.calls.filter({ $0 == "checkAccess \(Self.homePod.id)" }).count < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let during = try #require(rig.state.speaker(Self.id))
        #expect(during.isRestricted && during.isCheckingAccess)

        // B's own answer decides.
        second.open()
        try await rig.waitFor("B answered") { $0.speaker(Self.id)?.isCheckingAccess == false }
        let pod = try #require(rig.state.speaker(Self.id))
        #expect(pod.isRestricted && !pod.isEnabled && pod.state == .off)
    }

    @Test func turningItOnByHandTriesItAgain() async throws {
        let rig = Rig(speakers: Self.speakers)
        try await refusedWhilePlaying(rig)
        // An older remote shows it as an ordinary speaker; the person turns it on.
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.waitFor("on again") { $0.speaker(Self.id)?.state == .playing }
        #expect(rig.state.speaker(Self.id)?.isRestricted == false)
        #expect(rig.settings.load().speakers[Self.homePod.id]?.isEnabled == true)
    }

    /// A password or a network failure is a different thing: it keeps the failed treatment.
    @Test func otherFailuresAreNotRestrictions() async throws {
        let rig = Rig(speakers: Self.speakers)
        await rig.start()
        try await rig.addFiles(["one.m4a"], in: temporaryDirectory())
        rig.session.failOnPrepare(Self.homePod.id, String(describing: RAOPError.passwordRequired))
        rig.session.failOnPrepare("542a1b003344", String(describing: RAOPError.connectFailed("192.0.2.20:7000: Connection refused")))
        try await rig.hub.perform(.setSpeakerEnabled(id: Self.id, enabled: true))
        try await rig.hub.perform(.setSpeakerEnabled(id: "542a1b003344", enabled: true))
        try await rig.hub.perform(.playTrack(id: "file-1", context: .files))
        try await rig.waitFor("failed") {
            $0.speaker(Self.id)?.state == .failed(reason: "Needs an AirPlay password")
                && $0.speaker("542a1b003344")?.state == .failed(reason: "Can\u{2019}t reach it on the network")
        }
        #expect(rig.state.speakers.allSatisfy { !$0.isRestricted })
        #expect(SpeakerCounts(rig.state.speakers).failed == 2)
    }
}
