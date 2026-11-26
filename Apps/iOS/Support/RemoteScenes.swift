import Foundation
import MulticastHubModel
import SwiftUI

/// Reproducible states for review screenshots, chosen with launch arguments:
///
///     -MCScene <name>        one of `RemoteScene`'s raw values (default `live`)
///     -MCAppearance dark     or `light`; omitted follows the system
///
/// `live` is the real app: it finds the Mac on the network and pairs with it
/// (`NetworkHubConnector`). Every other scene runs on `MockHubBackend` and `MockHubConnector`;
/// nothing there touches the network.
/// The fixed scenes start already connected with a hub state from `MockScene`, and stay live:
/// taps still go through `HubModel` to the mock.
enum RemoteScene: String, CaseIterable {
    /// The real remote: Bonjour, pairing and the hub on the Mac.
    case live
    /// The mock app as a person would meet it on a second launch: paired, reconnects silently,
    /// speakers found over a moment.
    case mock
    /// First launch: browse, choose the Mac, type the code (any six digits but 000000).
    case pair
    /// The pairing screen, waiting for the code.
    case pairing
    /// The pairing screen after a refused code.
    case pairingError = "pairing-error"
    /// Browsing, nothing found yet.
    case searching
    /// Browsing found nothing: what to check.
    case hubNotFound = "hub-not-found"
    /// Connected, then the link drops after a second: banner over the last state.
    case lost
    /// Apple Music playing on four speakers, one connecting, Patio failed.
    case speakers
    /// The same, with the full player open.
    case nowPlaying = "now-playing"
    /// Spotify playing; the JBL's detail sheet with its -180 ms sync trim.
    case speakerDetail = "speaker-detail"
    /// Music tab, Apple Music, playlists.
    case playlists
    /// A playlist's songs.
    case playlist
    /// A playlist folder with a nested folder.
    case folder
    /// Apple Music, a library search.
    case search
    /// Up Next over the library.
    case upNext = "up-next"
    /// The Spotify source while it plays.
    case spotify
    /// Capturing another app (Podcasts).
    case otherApp = "other-app"
    /// The hub's DRM-free files.
    case files
    /// The hub's first second: no speakers found yet, Apple Music not yet allowed.
    case firstRun = "first-run"

    static var current: RemoteScene {
        UserDefaults.standard.string(forKey: "MCScene").flatMap(RemoteScene.init(rawValue:)) ?? .live
    }

    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "MCAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// The hub state behind a fixed scene; nil for the live mock.
    private var hubScene: MockScene? {
        switch self {
        case .live, .mock, .pair, .pairing, .pairingError, .searching, .hubNotFound: nil
        case .lost, .speakers, .nowPlaying, .playlists, .playlist, .folder, .search, .upNext, .files: .appleMusic
        case .speakerDetail, .spotify: .spotify
        case .otherApp: .appPicker
        case .firstRun: .firstRun
        }
    }

    @MainActor func makeSession() -> RemoteSession {
        if self == .live {
            return RemoteSession(connector: NetworkHubConnector(remoteName: NetworkHubConnector.deviceName()))
        }
        let backend: MockHubBackend
        if let hubScene {
            backend = MockHubBackend(state: hubScene.state, content: hubScene.content, artwork: MockData.artwork)
            if hubScene.state.transport.isPlaying {
                // Starts the mock's clock and level meter for a scene that opens mid-song.
                Task { try? await backend.perform(.play) }
            }
        } else {
            backend = MockHubBackend.live()
        }

        var options = MockHubConnector.Options()
        var timeout: Duration = .seconds(10)
        switch self {
        case .live, .mock: options.isPaired = true
        case .pair: break
        case .pairing: options.initialLink = .pairing(PairingPrompt())
        case .pairingError:
            options.initialLink = .pairing(PairingPrompt(
                failure: "That code doesn\u{2019}t match. Check the code on \(MockHubConnector.studio.name) and try again.",
                attempt: 1))
        case .searching:
            options.discovers = false
            timeout = .seconds(600)
        case .hubNotFound:
            options.discovers = false
            timeout = .zero
        case .lost:
            options.initialLink = .connected
            options.dropAfter = .milliseconds(1200)
        default:
            options.initialLink = .connected
        }

        let nav = RemoteNavigation()
        switch self {
        case .nowPlaying: nav.showsNowPlaying = true
        case .speakerDetail: nav.speakerDetail = .init(id: MockData.jbl)
        case .playlists:
            nav.tab = .music
            nav.musicPath = [.source(.appleMusic)]
        case .playlist:
            nav.tab = .music
            // Dinner party sits in the Evenings folder: the stack goes through it.
            if let p = MockData.playlists.first(where: { $0.id == "p4" }),
               let f = MockData.playlists.first(where: { $0.id == "f1" }) {
                nav.musicPath = [.source(.appleMusic), .folder(f), .playlist(p)]
            }
        case .folder:
            nav.tab = .music
            if let f = MockData.playlists.first(where: { $0.id == "f1" }) {
                nav.musicPath = [.source(.appleMusic), .folder(f)]
            }
        case .search:
            nav.tab = .music
            nav.musicPath = [.source(.appleMusic)]
            nav.librarySearch = "Juniper"
        case .upNext:
            nav.tab = .music
            nav.musicPath = [.source(.appleMusic)]
            nav.showsUpNext = true
        case .spotify:
            nav.tab = .music
            nav.musicPath = [.source(.spotify)]
        case .otherApp:
            nav.tab = .music
            nav.musicPath = [.source(.app)]
        case .files:
            nav.tab = .music
            nav.musicPath = [.source(.files)]
        default:
            break
        }

        let connector = MockHubConnector(backend: backend, options: options)
        return RemoteSession(connector: connector, navigation: nav, searchTimeout: timeout)
    }
}
