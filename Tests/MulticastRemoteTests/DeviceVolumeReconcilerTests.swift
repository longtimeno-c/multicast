import Foundation
import Testing
@testable import MulticastRemote

/// The phone's system volume and the hub's volume for its row, kept in step without a fight.
@Suite struct DeviceVolumeReconcilerTests {
    typealias Action = DeviceVolumeReconciler.Action

    /// A reconciler that has already told the hub where the device is.
    private func settled(hub: Double = 0.5, device: Double = 0.5, at now: TimeInterval = 0) -> DeviceVolumeReconciler {
        var r = DeviceVolumeReconciler()
        _ = r.hubReports(hub, device: device, now: now)
        return r
    }

    @Test func onJoiningTheDeviceVolumeGoesToTheHubAndTheRememberedOneIsNotApplied() {
        var r = DeviceVolumeReconciler()
        // The hub remembered 0.9 for this output; the phone is at 0.3.
        #expect(r.hubReports(0.9, device: 0.3, now: 10) == .tellHub(0.3))
        // The stale 0.9 is published again before the hub has taken the 0.3.
        #expect(r.hubReports(0.9, device: 0.3, now: 10.1) == .none)
        #expect(r.hubReports(0.3, device: 0.3, now: 10.2) == .none)
        #expect(r.hubReports(0.3, device: 0.3, now: 12) == .none)
    }

    @Test func nothingIsSentWhenTheHubAlreadyAgrees() {
        var r = DeviceVolumeReconciler()
        #expect(r.hubReports(0.5, device: 0.51, now: 0) == .none)
    }

    @Test func aChangeAtTheHubIsWrittenToTheDeviceAndItsEchoIsNotSentBack() {
        var r = settled(at: 0)
        #expect(r.hubReports(0.8, device: 0.5, now: 5) == .setDevice(0.8))
        // iOS reports the new volume, rounded to its own step.
        #expect(r.deviceChanged(to: 0.8125, now: 5.05) == .none)
        #expect(r.hubReports(0.8, device: 0.8125, now: 5.1) == .none)
    }

    @Test func aDragAtTheHubIsFollowedWithoutWaiting() {
        var r = settled(at: 0)
        var device = 0.5
        var writes: [Double] = []
        for (i, hub) in [0.55, 0.6, 0.65, 0.7, 0.75].enumerated() {
            let now = 5 + Double(i) * 0.1
            if case .setDevice(let v) = r.hubReports(hub, device: device, now: now) {
                writes.append(v)
                device = v
                #expect(r.deviceChanged(to: v, now: now + 0.02) == .none)
            }
        }
        #expect(writes == [0.55, 0.6, 0.65, 0.7, 0.75])
    }

    @Test func aDifferenceWithinHalfAStepIsLeftAlone() {
        var r = settled(at: 0)
        #expect(r.hubReports(0.53, device: 0.5, now: 5) == .none)
        #expect(r.hubReports(0.5 + 1.0 / 32 + 0.001, device: 0.5, now: 5) == .setDevice(0.5 + 1.0 / 32 + 0.001))
    }

    @Test func aHardwareButtonGoesToTheHubAndAStaleEchoDoesNotPullItBack() {
        var r = settled(at: 0)
        #expect(r.deviceChanged(to: 0.5625, now: 5) == .tellHub(0.5625))
        // The hub's state from before the command arrives.
        #expect(r.hubReports(0.5, device: 0.5625, now: 5.05) == .none)
        #expect(r.hubReports(0.5625, device: 0.5625, now: 5.2) == .none)
    }

    @Test func aHeldButtonNeverFightsItsOwnEchoes() {
        var r = settled(at: 0)
        var device = 0.5
        var hub = 0.5
        var inFlight: [Double] = []
        // A step every 100 ms for three seconds; the hub's echo is two steps behind.
        for i in 0..<30 {
            let now = 5 + Double(i) * 0.1
            device = min(1, device + 1.0 / 16)
            if case .tellHub(let v) = r.deviceChanged(to: device, now: now) { inFlight.append(v) }
            if inFlight.count > 2 { hub = inFlight.removeFirst() }
            #expect(r.hubReports(hub, device: device, now: now + 0.01) == .none)
        }
        hub = inFlight.last ?? hub
        #expect(hub == 1 && device == 1)
        #expect(r.hubReports(hub, device: device, now: 10) == .none)
    }

    @Test func aDragHereTellsTheHubAndHoldsOffWhatTheHubSaysMeanwhile() {
        var r = settled(at: 0)
        #expect(r.userSet(0.6, now: 5) == .tellHub(0.6))
        #expect(r.deviceChanged(to: 0.6, now: 5.02) == .none)
        #expect(r.userSet(0.7, now: 5.1) == .tellHub(0.7))
        // The hub has only just heard the 0.6.
        #expect(r.hubReports(0.6, device: 0.7, now: 5.15) == .none)
        #expect(r.deviceChanged(to: 0.6875, now: 5.2) == .none)
        #expect(r.hubReports(0.7, device: 0.6875, now: 6.5) == .none)
    }

    @Test func aSlowDragHereIsNeverMistakenForAnEcho() {
        var r = settled(at: 0)
        #expect(r.hubReports(0.6, device: 0.5, now: 5) == .setDevice(0.6))
        // The person takes the slider straight afterwards and moves it a little.
        #expect(r.userSet(0.61, now: 5.1) == .tellHub(0.61))
        #expect(r.userSet(0.62, now: 5.2) == .tellHub(0.62))
    }

    @Test func theLastWriterWinsOnceThingsHaveSettled() {
        var r = settled(at: 0)
        #expect(r.deviceChanged(to: 0.5625, now: 5) == .tellHub(0.5625))
        // Somebody at the Mac moves the slider just afterwards: the hub ends up at 0.2.
        #expect(r.hubReports(0.2, device: 0.5625, now: 5.3) == .none)
        #expect(r.hubReports(0.2, device: 0.5625, now: 5.9) == .setDevice(0.2))
        #expect(r.deviceChanged(to: 0.1875, now: 5.95) == .none)
        #expect(r.hubReports(0.2, device: 0.1875, now: 7) == .none)
    }

    @Test func aDeviceThatDoesNotFollowIsReportedOnceAndNotWrittenAgain() {
        // An output with a fixed volume, or the Simulator: writes do nothing.
        var r = settled(hub: 0.5, device: 0.5, at: 0)
        #expect(r.hubReports(0.9, device: 0.5, now: 5) == .setDevice(0.9))
        #expect(r.hubReports(0.9, device: 0.5, now: 5.3) == .none)
        #expect(r.hubReports(0.9, device: 0.5, now: 6) == .tellHub(0.5))
        #expect(r.hubReports(0.9, device: 0.5, now: 6.1) == .none)
        #expect(r.hubReports(0.5, device: 0.5, now: 6.2) == .none)
        for i in 0..<20 { #expect(r.hubReports(0.5, device: 0.5, now: 7 + Double(i)) == .none) }
    }

    @Test func aDeviceThatFollowsOnlyPartWayReportsWhereItStopped() {
        var r = settled(at: 0)
        #expect(r.hubReports(1, device: 0.5, now: 5) == .setDevice(1))
        // A loudness limit: it stops at 0.75.
        #expect(r.deviceChanged(to: 0.75, now: 5.05) == .tellHub(0.75))
        #expect(r.hubReports(1, device: 0.75, now: 5.1) == .none)
        #expect(r.hubReports(0.75, device: 0.75, now: 6) == .none)
    }

    @Test func afterARouteChangeTheNewOutputsVolumeIsSentNotOverwritten() {
        var r = settled(hub: 0.8, device: 0.8, at: 0)
        // A Bluetooth speaker connects; iOS switches to the volume it keeps for it.
        r.deviceLeadsNow()
        #expect(r.deviceChanged(to: 0.4, now: 5) == .none)
        // The hub now shows what it remembered for that output.
        #expect(r.hubReports(0.9, device: 0.4, now: 5.2) == .tellHub(0.4))
        #expect(r.hubReports(0.9, device: 0.4, now: 5.3) == .none)
        #expect(r.hubReports(0.4, device: 0.4, now: 5.4) == .none)
        // iOS settles on the output's volume a moment later: that is sent too.
        #expect(r.deviceChanged(to: 0.4375, now: 5.5) == .tellHub(0.4375))
    }

    @Test func aChangeWhileTheHubIsNotReadyWaitsForIt() {
        var r = DeviceVolumeReconciler()
        #expect(r.userSet(0.7, now: 1) == .none)
        #expect(r.deviceChanged(to: 0.75, now: 3) == .none)
        #expect(r.hubReports(0.2, device: 0.75, now: 4) == .tellHub(0.75))
    }

    @Test func theEchoWindowEndsSoALaterMatchingChangeIsSent() {
        var r = settled(at: 0)
        #expect(r.hubReports(0.8, device: 0.5, now: 5) == .setDevice(0.8))
        #expect(r.deviceChanged(to: 0.8, now: 5.05) == .none)
        // Down and up again by hand, long after.
        #expect(r.deviceChanged(to: 0.7375, now: 20) == .tellHub(0.7375))
        #expect(r.deviceChanged(to: 0.8, now: 20.3) == .tellHub(0.8))
    }
}
