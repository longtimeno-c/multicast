import Foundation
import MulticastHubModel
import MulticastRemote
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
    /// Apple Music playing on four speakers, one connecting, Patio failed, two not available.
    case speakers
    /// The same, with the full player open.
    case nowPlaying = "now-playing"
    /// Spotify playing; the JBL's detail sheet with its -180 ms sync trim.
    case speakerDetail = "speaker-detail"
    /// The speakers scene with the detail sheet of the neighbour's HomePod, which admits only
    /// its owner.
    case speakerRestricted = "speaker-restricted"
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
    /// The speakers scene with this iPhone playing too, through a Bluetooth speaker.
    case phoneSpeaker = "phone-speaker"
    /// The same, before "This iPhone" is turned on.
    case phoneSpeakerOff = "phone-speaker-off"
    /// This iPhone's own speaker details: sync trim and the link to the Mac.
    case phoneSpeakerDetail = "phone-speaker-detail"
    /// The hub's first second: no speakers found yet, Apple Music not yet allowed.
    case firstRun = "first-run"
    /// iPhone Only (experimental): speakers found, two turned on, no broadcast yet.
    case phoneOnly = "phone-only"
    /// iPhone Only: a broadcast playing on two speakers, a third joining.
    case phoneOnlyPlaying = "phone-only-playing"
    /// iPhone Only: a broadcast running, but the playing app shares no sound.
    case phoneOnlySilent = "phone-only-silent"
    /// iPhone Only: a broadcast whose speakers do not answer.
    case phoneOnlyUnreachable = "phone-only-unreachable"
    /// iPhone Only: the last broadcast gave up, with the reason.
    case phoneOnlyStopped = "phone-only-stopped"
    /// iPhone Only: still looking for speakers.
    case phoneOnlySearching = "phone-only-searching"
    /// iPhone Only: no speakers on the network.
    case phoneOnlyEmpty = "phone-only-empty"
    /// iPhone Only: playing, and a speaker that admits only its owner set apart.
    case phoneOnlyRestricted = "phone-only-restricted"

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
        case .phoneOnly, .phoneOnlyPlaying, .phoneOnlySilent, .phoneOnlyUnreachable, .phoneOnlyStopped,
             .phoneOnlySearching, .phoneOnlyEmpty, .phoneOnlyRestricted: nil
        case .phoneSpeaker, .phoneSpeakerOff, .phoneSpeakerDetail: .appleMusic
        case .lost, .speakers, .speakerRestricted, .nowPlaying, .playlists, .playlist, .folder, .search, .upNext, .files: .appleMusic
        case .speakerDetail, .spotify: .spotify
        case .otherApp: .appPicker
        case .firstRun: .firstRun
        }
    }

    @MainActor func makeSession() -> RemoteSession {
        if self == .live {
            return RemoteSession(connector: NetworkHubConnector(remoteName: NetworkHubConnector.deviceName()),
                                 phoneSpeaker: PhoneSpeakerModel(routes: AudioSessionRouteMonitor(), output: PhoneRouteOutput()))
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
        case .hubNotFound, .phoneOnly, .phoneOnlyPlaying, .phoneOnlySilent, .phoneOnlyUnreachable, .phoneOnlyStopped,
             .phoneOnlySearching, .phoneOnlyEmpty, .phoneOnlyRestricted:
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
        case .speakerRestricted: nav.speakerDetail = .init(id: MockData.neighbourHomePod)
        case .phoneSpeakerDetail: nav.speakerDetail = .init(id: MockPhoneSpeakerBackend.speakerID)
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
        case .phoneOnly, .phoneOnlyPlaying, .phoneOnlySilent, .phoneOnlyUnreachable, .phoneOnlyStopped,
             .phoneOnlySearching, .phoneOnlyEmpty, .phoneOnlyRestricted:
            nav.showsPhoneOnly = true
        default:
            break
        }

        let connector = MockHubConnector(backend: backend, options: options)
        // Every scene can try "This iPhone" on the mock hub; these three show it over Bluetooth.
        let showsPhone = [.phoneSpeaker, .phoneSpeakerOff, .phoneSpeakerDetail].contains(self)
        let route = showsPhone ? PhoneRoute(name: "Garden Speaker", kind: .bluetooth) : PhoneRoute(name: "Speaker", kind: .builtIn)
        let phone = PhoneSpeakerModel(routes: FixedRouteMonitor(route), output: SilentPhoneOutput())
        phone.attach(MockPhoneSpeakerBackend(hub: backend))
        if self == .phoneSpeaker || self == .phoneSpeakerDetail { phone.setOn(true) }
        return RemoteSession(connector: connector, navigation: nav, phoneSpeaker: phone, searchTimeout: timeout)
    }

    /// What iPhone Only mode runs on: Bonjour and the App Group in the real app, made-up
    /// speakers and a pretend broadcast in every review scene.
    @MainActor func makePhoneOnlyService() -> PhoneOnlyService {
        switch self {
        case .live: LivePhoneOnlyService()
        case .phoneOnlyPlaying: MockPhoneOnlyService(start: .capturing)
        case .phoneOnlySilent: MockPhoneOnlyService(start: .silent)
        case .phoneOnlyUnreachable: MockPhoneOnlyService(start: .unreachable)
        case .phoneOnlyStopped: MockPhoneOnlyService(start: .ended)
        case .phoneOnlySearching: MockPhoneOnlyService(start: .searching)
        case .phoneOnlyEmpty: MockPhoneOnlyService(start: .noSpeakers)
        case .phoneOnlyRestricted: MockPhoneOnlyService(start: .restricted)
        default: MockPhoneOnlyService(start: .idle)
        }
    }
}
