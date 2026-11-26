import SwiftUI
import MulticastHubModel

/// Sources on the left, the chosen source's browser in the middle, and the speakers, the
/// reason this app exists, in the widest column on the right.
struct RootView: View {
    @Environment(HubModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns: NavigationSplitViewVisibility = .all

    /// Column minimums; the window's minimum width is their sum plus the dividers, so no column
    /// is ever squeezed below the width its rows were designed for.
    static let sidebarMin: CGFloat = 180
    static let contentMin: CGFloat = 260
    /// Fits "MacBook Air Speakers" on one line beside the 200pt slider track.
    static let detailMin: CGFloat = 560
    static let minWidth: CGFloat = sidebarMin + contentMin + detailMin + 2
    static let upNextWidth: CGFloat = 300

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The player is the window's title bar, as in Music: the window buttons sit at its
            // leading edge, then transport, the display in the middle, Up Next at the end.
            PlayerBar()
            split
        }
        .toolbar(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { model.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, new in model.reduceMotion = new }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: Self.sidebarMin, ideal: 200, max: 260)
        } content: {
            // Up Next slides in on the library's right, inside the same column, which widens to
            // make room so the playlists keep their size.
            HStack(spacing: 0) {
                SourceBrowser()
                if model.showsUpNext {
                    Rectangle().fill(MC.Ink.faint).frame(width: 0.5)
                    UpNextPanel()
                        .frame(width: Self.upNextWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .navigationSplitViewColumnWidth(min: Self.contentMin + (model.showsUpNext ? Self.upNextWidth : 0),
                                            ideal: model.showsUpNext ? 420 + Self.upNextWidth : 420,
                                            max: model.showsUpNext ? 640 + Self.upNextWidth : 640)
        } detail: {
            SpeakersPanel()
                .navigationSplitViewColumnWidth(min: Self.detailMin, ideal: 640)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct SidebarView: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        List(selection: Binding<SourceKind?>(
            get: { model.browsingSource },
            set: { if let s = $0 { model.browsingSource = s } }
        )) {
            Section("Sources") {
                ForEach(SourceKind.allCases) { source in
                    SidebarRow(source: source, isLive: model.activeSource == source,
                               title: source == .appleMusic ? model.libraryTitle : source.title,
                               symbol: source == .appleMusic ? model.librarySymbol : source.symbolName)
                        .tag(source)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    var source: SourceKind
    var isLive: Bool
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: MC.Space.s) {
            Label(title, systemImage: symbol)
            Spacer(minLength: MC.Space.s)
            if isLive {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(MC.accent)
                    .help("Playing from \(title)")
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? "Playing" : "")
    }
}

/// The middle column: whatever the selected source needs to choose what plays.
struct SourceBrowser: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        Group {
            switch model.browsingSource {
            case .appleMusic: AppleMusicBrowser()
            case .spotify: SpotifySourceView()
            case .app: AppPickerView()
            case .files: FilesBrowser()
            case .macOutput: MacOutputView()
            }
        }
        .navigationTitle(model.browsingSource == .appleMusic ? model.libraryTitle : model.browsingSource.title)
    }
}
