import Foundation

/// Keeps two copies of one volume in step without letting them fight: the phone's system
/// volume (the device) and the hub's volume for this phone's speaker row.
///
/// Either side can be changed at any time. The device by the slider here, the hardware buttons
/// or Control Centre; the hub's by the Mac's slider or another remote. Changes cross a network,
/// so each side sees the other's a moment late, and the hub echoes back what the device told
/// it. The rules:
///
///  - The last writer wins. A change made on the device goes to the hub, and until the hub
///    has reported that very value back, nothing the hub reports is applied: it is still the
///    value from before (the command is on its way, or waiting behind another). For a short
///    settle window after the change the same holds even once the value has come back (a drag
///    in progress, a held volume button: an earlier value of the same gesture may match by
///    chance). After both, a hub value that differs is somebody else's later change and is
///    written to the device.
///  - A value the hub never reports back was lost or overtaken. After `resend` seconds the
///    device's volume is sent again; the hub's is still not written to the device.
///  - Values are compared with a tolerance of half an iOS volume step, so a device that rounds
///    to its own steps is not corrected for ever.
///  - A write to the device comes back as a change of the device, a moment later and possibly
///    after the next write has been made (a fast drag at the hub). Every write of the last
///    settle window is remembered, and a change that matches one of them is that echo and is
///    not sent anywhere.
///  - A device that does not follow a write (an output with a fixed volume, the Simulator) is
///    the truth: after the settle window its real volume is sent to the hub, once.
///  - When the device leads (the speaker was just turned on, or its output changed and iOS
///    switched to that output's own volume), the device's volume is sent to the hub and the
///    hub's remembered value is never written to the device, however long the hub takes.
///
/// "What the hub reports" must be the hub's own published value, not a copy that already shows
/// what was sent to it: the reconciler takes the value coming back as the hub having heard.
///
/// Pure: the caller passes the time, performs the returned action, and calls `hubReports`
/// again now and then (once a second is enough) so that a decision put off by the settle
/// window is made.
public struct DeviceVolumeReconciler: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        /// Write this volume to the device.
        case setDevice(Double)
        /// Send this volume to the hub as the speaker's volume.
        case tellHub(Double)
    }

    /// Half an iOS volume step (the hardware buttons move in sixteenths).
    public static let defaultTolerance = 1.0 / 32

    public var tolerance: Double
    /// How long after a change on the device the hub's reports are left alone, in seconds.
    public var settle: TimeInterval

    /// How long a value sent to the hub may go unreported before it is sent again, in seconds.
    public var resend: TimeInterval

    /// A value written to the device, and until when a matching change is taken for its echo.
    private struct Write: Sendable, Equatable {
        var value: Double
        var until: TimeInterval
    }

    private var deviceLeads = true
    private var quietUntil = -TimeInterval.infinity
    /// The writes to the device of the last settle window, by either side, oldest first.
    private var writes: [Write] = []
    /// The value last sent to the hub that it has not reported back yet, and when it was sent.
    private var told: Double?
    private var toldAt = -TimeInterval.infinity
    /// The hub value last written to the device, and when: if the device still differs from
    /// it a settle window later, the device refused.
    private var fromHub: Double?
    private var fromHubAt = -TimeInterval.infinity

    public init(tolerance: Double = DeviceVolumeReconciler.defaultTolerance, settle: TimeInterval = 0.8,
                resend: TimeInterval = 2) {
        self.tolerance = tolerance
        self.settle = settle
        self.resend = resend
    }

    private func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    private mutating func wrote(_ volume: Double, now: TimeInterval) {
        writes.removeAll { now >= $0.until }
        if writes.count >= 32 { writes.removeFirst() }
        writes.append(Write(value: volume, until: now + settle))
    }

    private mutating func tell(_ volume: Double, now: TimeInterval) -> Action {
        told = volume
        toldAt = now
        return .tellHub(volume)
    }

    /// The device's volume is the one to keep: the speaker was just turned on, its output
    /// changed, or the hub does not list it (yet). The next `hubReports` sends it.
    public mutating func deviceLeadsNow() {
        deviceLeads = true
        writes.removeAll()
        told = nil
        fromHub = nil
    }

    /// The person moved the slider here, and the caller has written `volume` to the device.
    public mutating func userSet(_ volume: Double, now: TimeInterval) -> Action {
        wrote(volume, now: now)
        fromHub = nil
        quietUntil = now + settle
        // While the device leads, the hub is not ready to be told: `hubReports` will.
        return deviceLeads ? .none : tell(volume, now: now)
    }

    /// The device's volume changed: the hardware buttons, Control Centre, or the echo of a
    /// write made here.
    public mutating func deviceChanged(to volume: Double, now: TimeInterval) -> Action {
        writes.removeAll { now >= $0.until }
        if let i = writes.firstIndex(where: { same($0.value, volume) }) {
            // The echo of that write. Echoes come in order, so the ones before it are done.
            writes.removeFirst(i)
            return .none
        }
        writes.removeAll()
        fromHub = nil
        quietUntil = now + settle
        return deviceLeads ? .none : tell(volume, now: now)
    }

    /// The hub's volume for this speaker, as it last published it, against the device's volume
    /// now.
    public mutating func hubReports(_ hub: Double, device: Double, now: TimeInterval) -> Action {
        if deviceLeads {
            deviceLeads = false
            quietUntil = now + settle
            told = nil
            return same(hub, device) ? .none : tell(device, now: now)
        }
        if let told {
            if same(hub, told) {
                self.told = nil
            } else if now - toldAt >= resend {
                // Lost, or overtaken by a change made elsewhere: say where the device is now.
                quietUntil = now + settle
                return tell(device, now: now)
            } else {
                return .none
            }
        }
        guard now >= quietUntil else { return .none }
        guard !same(hub, device) else {
            fromHub = nil
            return .none
        }
        if let fromHub, same(fromHub, hub) {
            // Already written, and the device is somewhere else.
            guard now - fromHubAt >= settle else { return .none }
            self.fromHub = nil
            quietUntil = now + settle
            return tell(device, now: now)
        }
        fromHub = hub
        fromHubAt = now
        wrote(hub, now: now)
        return .setDevice(hub)
    }
}
