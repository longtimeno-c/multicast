import Foundation

/// Keeps two copies of one volume in step without letting them fight: the phone's system
/// volume (the device) and the hub's volume for this phone's speaker row.
///
/// Either side can be changed at any time. The device by the slider here, the hardware buttons
/// or Control Centre; the hub's by the Mac's slider or another remote. Changes cross a network,
/// so each side sees the other's a moment late, and the hub echoes back what the device told
/// it. The rules:
///
///  - The last writer wins. A change made on the device goes to the hub, and for a short
///    settle window afterwards what the hub reports is not applied: it may still be the value
///    from before (a drag in progress, a held volume button). Once the window has passed, a hub
///    value that differs is somebody else's later change and is written to the device.
///  - Values are compared with a tolerance of half an iOS volume step, so a device that rounds
///    to its own steps is not corrected for ever.
///  - A write to the device comes back as a change of the device. Within the settle window a
///    change that matches the last write is that echo and is not sent anywhere.
///  - A device that does not follow a write (an output with a fixed volume, the Simulator) is
///    the truth: after the settle window its real volume is sent to the hub, once.
///  - When the device leads (the speaker was just turned on, or its output changed and iOS
///    switched to that output's own volume), the device's volume is sent to the hub and the
///    hub's remembered value is never written to the device.
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

    private var deviceLeads = true
    private var quietUntil = -TimeInterval.infinity
    /// The last value written to the device, by either side, and until when a matching change
    /// of the device is taken to be its echo.
    private var written: Double?
    private var echoUntil = -TimeInterval.infinity
    /// The hub value last written to the device, and when: if the device still differs from
    /// it a settle window later, the device refused.
    private var fromHub: Double?
    private var fromHubAt = -TimeInterval.infinity

    public init(tolerance: Double = DeviceVolumeReconciler.defaultTolerance, settle: TimeInterval = 0.8) {
        self.tolerance = tolerance
        self.settle = settle
    }

    private func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    /// The device's volume is the one to keep: the speaker was just turned on, its output
    /// changed, or the hub does not list it (yet). The next `hubReports` sends it.
    public mutating func deviceLeadsNow() {
        deviceLeads = true
        written = nil
        fromHub = nil
    }

    /// The person moved the slider here, and the caller has written `volume` to the device.
    public mutating func userSet(_ volume: Double, now: TimeInterval) -> Action {
        written = volume
        echoUntil = now + settle
        fromHub = nil
        quietUntil = now + settle
        // While the device leads, the hub is not ready to be told: `hubReports` will.
        return deviceLeads ? .none : .tellHub(volume)
    }

    /// The device's volume changed: the hardware buttons, Control Centre, or the echo of a
    /// write made here.
    public mutating func deviceChanged(to volume: Double, now: TimeInterval) -> Action {
        if let written, now < echoUntil, same(written, volume) { return .none }
        written = nil
        fromHub = nil
        quietUntil = now + settle
        return deviceLeads ? .none : .tellHub(volume)
    }

    /// The hub's volume for this speaker, as last published, against the device's volume now.
    public mutating func hubReports(_ hub: Double, device: Double, now: TimeInterval) -> Action {
        if deviceLeads {
            deviceLeads = false
            quietUntil = now + settle
            return same(hub, device) ? .none : .tellHub(device)
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
            return .tellHub(device)
        }
        fromHub = hub
        fromHubAt = now
        written = hub
        echoUntil = now + settle
        return .setDevice(hub)
    }
}
