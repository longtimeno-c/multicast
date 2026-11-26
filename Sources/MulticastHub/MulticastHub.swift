import MulticastHubModel
import MulticastKit

// The Mac hub: `LocalHub`, a `HubBackend` over MulticastKit (speakers, sources, engine) that the
// Mac app runs in-process. A network server for iOS remotes drives the same `LocalHub` through
// `perform(_:)` and `answer(_:)`.
public enum MulticastHubModule {
    public static let isImplemented = true
}
