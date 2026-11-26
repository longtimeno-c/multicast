import MulticastHubModel
import SwiftUI

/// The iOS remote for a Multicast hub on a Mac. By default it finds and pairs with the Mac over
/// the network (`NetworkHubConnector`, which yields a `RemoteHubBackend`); `-MCScene <name>`
/// launches a fixed review scene on the mock hub instead (see `RemoteScene`).
@main
struct RemoteApp: App {
    @State private var session = RemoteScene.current.makeSession()

    var body: some Scene {
        WindowGroup {
            RemoteRootView()
                .environment(session)
                .preferredColorScheme(RemoteScene.colorScheme)
        }
    }
}

/// Connecting until there is a hub to show, then the hub screens; one cross-fade between them,
/// caused by the link.
struct RemoteRootView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch session.screen {
            case .connect:
                ConnectFlowView()
                    .transition(.opacity)
            case .main:
                if let model = session.model {
                    RemoteMainView(model: model)
                        .transition(.opacity)
                }
            }
        }
        .task { session.start() }
        .onAppear { session.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, new in session.reduceMotion = new }
    }
}
