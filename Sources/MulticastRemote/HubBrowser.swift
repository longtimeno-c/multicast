import Foundation
import MulticastHubModel
import Network

/// A hub found on the local network.
public struct DiscoveredHub: Identifiable, Hashable, Sendable {
    /// The hub's stable id (from its TXT record); what a remote stores its pairing under.
    public let id: String
    public let name: String
    /// The protocol version the hub advertises, if it says.
    public let protocolVersion: Int?
    public let endpoint: NWEndpoint

    public init(id: String, name: String, protocolVersion: Int?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
    }

    /// Whether this build can talk to it, as far as the advertisement tells.
    public var isCompatible: Bool {
        guard let v = protocolVersion else { return true }
        return RemoteProtocol.supportedVersions.contains(v) || v > RemoteProtocol.currentVersion
    }
}

/// Browses Bonjour for `_multicast-hub._tcp`. Each `hubs()` call runs its own browser for as
/// long as the stream is consumed.
public final class HubBrowser: Sendable {
    private let type: String
    private let domain: String
    private let loopbackOnly: Bool

    public init(type: String = HubService.bonjourType, domain: String = "local.", loopbackOnly: Bool = false) {
        self.type = type
        self.domain = domain
        self.loopbackOnly = loopbackOnly
    }

    /// The current list of hubs (sorted by name) whenever it changes. An advertisement without
    /// a usable id is ignored. Finishes if browsing fails.
    public func hubs() -> AsyncStream<[DiscoveredHub]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DiscoveredHub].self, bufferingPolicy: .bufferingNewest(1))
        let params = NWParameters()
        params.includePeerToPeer = false
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain), using: params)
        browser.browseResultsChangedHandler = { results, _ in
            continuation.yield(Self.hubs(from: results))
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: DispatchQueue(label: "multicast.hub-browser"))
        return stream
    }

    static func hubs(from results: Set<NWBrowser.Result>) -> [DiscoveredHub] {
        var byID: [String: DiscoveredHub] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata else { continue }
            guard let hub = hub(txt: txt, endpoint: result.endpoint) else { continue }
            byID[hub.id] = byID[hub.id] ?? hub
        }
        return byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func hub(txt: NWTXTRecord, endpoint: NWEndpoint) -> DiscoveredHub? {
        guard let id = txt[RemoteProtocol.TXTKey.hubID], PeerText.isValidID(id) else { return nil }
        var serviceName: String?
        if case .service(let name, _, _, _) = endpoint { serviceName = name }
        let name = PeerText.displayName(txt[RemoteProtocol.TXTKey.name] ?? serviceName ?? "", fallback: "Mac")
        let version = txt[RemoteProtocol.TXTKey.version].flatMap { Int($0) }
        return DiscoveredHub(id: id, name: name, protocolVersion: version, endpoint: endpoint)
    }
}
