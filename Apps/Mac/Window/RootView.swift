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

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Self.sidebarMin, ideal: 200, max: 260)
        } content: {
            SourceBrowser()
                .navigationSplitViewColumnWidth(min: Self.contentMin, ideal: 330, max: 440)
        } detail: {
            SpeakersPanel()
                .navigationSplitViewColumnWidth(min: Self.detailMin, ideal: 640)
        }
        .navigationSplitViewStyle(.balanced)
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
                    SidebarRow(source: source, isLive: model.activeSource == source)
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

    var body: some View {
        HStack(spacing: MC.Space.s) {
            Label(source.title, systemImage: source.symbolName)
            Spacer(minLength: MC.Space.s)
            if isLive {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(MC.accent)
                    .help("Playing from \(source.title)")
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
            }
        }
        .navigationTitle(model.browsingSource.title)
    }
}
