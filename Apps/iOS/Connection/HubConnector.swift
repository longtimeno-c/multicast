import Foundation
import MulticastHubModel

/// A Mac hub seen on the network (Bonjour `HubService.bonjourType`).
struct DiscoveredHub: Identifiable, Hashable, Sendable, Codable {
    /// Stable across launches: the hub's own identifier, not its address.
    let id: String
    /// The name the Mac advertises ("Studio Mac").
    var name: String
}

/// What the pairing screen needs: how many digits, and why the last attempt failed.
struct PairingPrompt: Equatable, Sendable {
    var codeLength = 6
    /// Set after a refused code; nil on the first attempt.
    var failure: String?
    /// Grows with every refused attempt, so the screen can answer each one (clear, shake).
    var attempt = 0
}

/// The link between this phone and one hub. Exactly one of these at a time.
enum HubLink: Sendable {
    /// Browsing; no hub chosen yet (or the chosen one forgotten).
    case searching
    /// Opening a session with `hub`: first contact, or a silent reconnect with stored pairing.
    case connecting(DiscoveredHub)
    /// The hub wants the code it is showing on the Mac before it will accept this phone.
    case pairing(DiscoveredHub, PairingPrompt)
    /// Paired and talking. `backend` drives the shared `HubModel`.
    case connected(DiscoveredHub, any HubBackend)
    /// Was connected (or connecting) and the link dropped. The connector keeps trying on its
    /// own; `connect(to:)` asks it to try now.
    case lost(DiscoveredHub?, reason: String)

    var hub: DiscoveredHub? {
        switch self {
        case .searching: nil
        case .connecting(let h), .pairing(let h, _), .connected(let h, _): h
        case .lost(let h, _): h
        }
    }

    /// The link's phase without its payload, for comparisons and tests.
    var phase: Phase {
        switch self {
        case .searching: .searching
        case .connecting: .connecting
        case .pairing: .pairing
        case .connected: .connected
        case .lost: .lost
        }
    }

    enum Phase: Equatable, Sendable { case searching, connecting, pairing, connected, lost }
}

/// The seam between the remote's UI and whatever finds and talks to the hub.
/// `NetworkHubConnector` is the real one (Bonjour with `HubBrowser`, code pairing and the
/// encrypted session of `RemoteHubBackend`, all from MulticastRemote); `MockHubConnector`
/// stands in for it in the review scenes.
///
/// Contract:
/// - `hubs()` yields the current list at once, then every change.
/// - `links()` yields the current link at once, then every change.
/// - A connector that holds pairing for a hub reconnects to it by itself as soon as it is seen,
///   with no pairing step: that is the silent reconnect.
/// - `submit(code:)` answers through `links()`: `.connected`, or `.pairing` again with a
///   `failure` and a larger `attempt`.
protocol HubConnector: AnyObject, Sendable {
    func hubs() async -> AsyncStream<[DiscoveredHub]>
    func links() async -> AsyncStream<HubLink>
    func connect(to hub: DiscoveredHub) async
    func submit(code: String) async
    /// Leave pairing or connecting and go back to browsing.
    func cancel() async
    /// Drop the stored pairing for the current hub and go back to browsing.
    func forget() async
}
