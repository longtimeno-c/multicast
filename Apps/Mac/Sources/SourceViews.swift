import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared bits

extension View {
    /// Middle-column lists sit on the same canvas as the speakers pane, so a header pinned
    /// above them shares one surface with the rows. No rules: rows are told apart by their
    /// artwork and icons, and the selection pill is the only shape that needs the list's insets.
    func sourceList() -> some View {
        listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .background(MC.Surface.canvas)
    }

    /// Applied to every row and section in a source list: one treatment, no rules.
    func sourceRow() -> some View {
        listRowSeparator(.hidden)
    }
}

/// Header pinned above a source list (search, a source's own controls). Every source starts
/// its first content at the same height under the toolbar.
private struct SourceHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.s) { content() }
            .padding(.horizontal, SourceHeaderMetrics.inset)
            .padding(.top, MC.Space.m)
            .padding(.bottom, MC.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MC.Surface.canvas)
    }
}

/// A section title inside a source list, as an ordinary row: one treatment everywhere, no
/// pinned header and no rule under it, 16pt of air above every title but the first.
private struct SourceSectionTitle: View {
    var title: String
    var isFirst = false
    init(_ title: String, isFirst: Bool = false) { self.title = title; self.isFirst = isFirst }

    var body: some View {
        Text(title)
            .font(MC.Font.captionEmphasis)
            .foregroundStyle(MC.Ink.secondary)
            .padding(.top, isFirst ? 0 : MC.Space.l)
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled()
            .sourceRow()
    }
}

enum SourceHeaderMetrics {
    /// The inset list's row content edge, so headers line up with the rows below them.
    static let inset: CGFloat = 16
}

/// An installed app's real icon, scaled past its transparent margin so the visible squircle
/// fills `size` and lines up with the words beside and below it.
struct AppIconView: View {
    var bundleID: String
    var size: CGFloat

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .scaleEffect(ArtworkView.iconBleed)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(MC.Surface.well)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(MC.Ink.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A library or file row: artwork, title over artist, and a trailing value.
struct TrackRow: View {
    @Environment(HubModel.self) private var model
    var track: TrackItem
    var isCurrent: Bool
    var detail: String? = nil

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(track.artwork), size: 32, radius: MC.Radius.small)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(track.title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                    .lineLimit(1)
                Text(detail ?? track.artist)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: MC.Space.s)
            ZStack(alignment: .trailing) {
                Text(MC.Format.time(track.duration))
                    .font(MC.Font.captionValue)
                    .foregroundStyle(MC.Ink.secondary)
                    .opacity(isCurrent ? 0 : 1)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(MC.accent)
                    .opacity(isCurrent ? 1 : 0)
            }
            .animation(MC.Motion.feedback, value: isCurrent)
            .accessibilityHidden(true)
        }
        .padding(.vertical, MC.Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Now playing" : MC.Format.time(track.duration))
    }
}

// MARK: - Apple Music

struct AppleMusicBrowser: View {
    enum Section: String, CaseIterable, Identifiable {
        case songs = "Songs", playlists = "Playlists", upNext = "Up next"
        var id: String { rawValue }
    }

    @Environment(HubModel.self) private var model
    @State private var section: Section = .songs
    @State private var query = ""
    @State private var selection: String?
    @State private var focusSearch = 0

    var body: some View {
        switch model.status.permission(.appleMusic) {
        case .granted: library
        case .notDetermined: connect
        case .denied: denied
        }
    }

    private var library: some View {
        List(selection: $selection) {
            switch section {
            case .songs, .upNext:
                ForEach(tracks) { track in
                    TrackRow(track: track, isCurrent: model.activeSource == .appleMusic && model.nowPlaying?.trackID == track.id)
                        .tag(track.id)
                        .sourceRow()
                }
            case .playlists:
                ForEach(model.library.playlists) { playlist in
                    PlaylistRow(playlist: playlist).tag(playlist.id).sourceRow()
                }
            }
        }
        .sourceList()
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Play") { play(ids) }
        } primaryAction: { ids in
            play(ids)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SourceHeader {
                SearchField(text: $query, prompt: "Search your library", focusRequest: focusSearch)
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .background {
            // Command-F reaches the library search, as Music's does.
            Button("Find") { focusSearch += 1 }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var connect: some View {
        ContentUnavailableView {
            Label("Connect Apple Music", systemImage: "music.note")
        } description: {
            Text("Multicast plays your library and playlists itself, then sends them to every speaker you choose.")
        } actions: {
            Button("Allow Access") { model.requestPermission(.appleMusic) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MC.Surface.canvas)
    }

    private var denied: some View {
        ContentUnavailableView {
            Label("Apple Music is turned off for Multicast", systemImage: "music.note")
        } description: {
            Text("Allow it under Media & Apple Music in Privacy & Security to see your library here.")
        } actions: {
            Button("Open Settings\u{2026}") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MC.Surface.canvas)
    }

    private var tracks: [TrackItem] {
        let base = section == .upNext ? model.library.upNext : model.library.songs
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }

    private func play(_ ids: Set<String>) {
        guard let id = ids.first else { return }
        if section == .playlists { model.playPlaylist(id) } else { model.playTrack(id) }
    }
}

private struct PlaylistRow: View {
    @Environment(HubModel.self) private var model
    var playlist: PlaylistItem
    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(playlist.artwork), size: 32, radius: MC.Radius.small)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(playlist.name).font(MC.Font.body).foregroundStyle(MC.Ink.primary)
                Text("\(playlist.trackCount) songs").font(MC.Font.caption).foregroundStyle(MC.Ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MC.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Spotify

struct SpotifySourceView: View {
    @Environment(HubModel.self) private var model
    static let bundleID = "com.spotify.client"

    var body: some View {
        List {
            // The source's own header scrolls with its history, as the first row.
            VStack(alignment: .leading, spacing: MC.Space.m) {
                HStack(spacing: MC.Space.m) {
                    AppIconView(bundleID: Self.bundleID, size: 40)
                    VStack(alignment: .leading, spacing: MC.Space.xxs) {
                        Text("Spotify")
                            .font(MC.Font.title)
                            .foregroundStyle(MC.Ink.primary)
                        HStack(spacing: MC.Space.xs) {
                            if isLive {
                                Circle().fill(MC.Status.playing).frame(width: 6, height: 6)
                            }
                            Text(status)
                        }
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                    }
                }
                Text("Choose music in Spotify. Multicast sends whatever it plays to your speakers, and play, pause and skip here control Spotify.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.body)
                    .lineLimit(nil)
                HStack(spacing: MC.Space.s) {
                    if !isLive && model.spotify == .running {
                        Button("Play from Spotify") { model.selectSource(.spotify) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Open Spotify") { model.openSpotify() }
                }
            }
            .selectionDisabled()
            .sourceRow()

            if !model.spotifyHistory.isEmpty {
                SourceSectionTitle("Earlier this session")
                ForEach(model.spotifyHistory) { track in
                    TrackRow(track: track, isCurrent: false).sourceRow()
                }
            }
        }
        .sourceList()
    }

    private var isLive: Bool { model.activeSource == .spotify }

    private var status: String {
        switch model.spotify {
        case .notInstalled: "Not installed"
        case .notRunning: "Not open"
        case .running: isLive ? "Capturing Spotify\u{2019}s audio" : "Open, not in use"
        }
    }
}

// MARK: - Other apps

struct AppPickerView: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        List(selection: Binding<String?>(
            get: { model.activeSource == .app ? model.capturedAppID : nil },
            set: { if let id = $0 { model.captureApp(id) } }
        )) {
            SourceSectionTitle("Making sound", isFirst: true)
            ForEach(model.capturableApps.filter(\.isMakingSound)) { app in
                AppRow(app: app, isCaptured: isCaptured(app)).tag(app.id).sourceRow()
            }
            SourceSectionTitle("Other open apps")
            ForEach(model.capturableApps.filter { !$0.isMakingSound }) { app in
                AppRow(app: app, isCaptured: isCaptured(app)).tag(app.id).sourceRow()
            }
            Text("Only the chosen app is captured, never alerts.")
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
                .lineLimit(nil)
                .padding(.top, MC.Space.s)
                .selectionDisabled()
                .sourceRow()
        }
        .sourceList()
    }

    private func isCaptured(_ app: CapturableApp) -> Bool {
        model.activeSource == .app && model.capturedAppID == app.id
    }
}

private struct AppRow: View {
    var app: CapturableApp
    var isCaptured: Bool

    var body: some View {
        HStack(spacing: MC.Space.m) {
            AppIconView(bundleID: app.id, size: 24)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(app.name)
                    .font(MC.Font.body)
                    .lineLimit(1)
                if isCaptured {
                    // Opens its line and carries the rows below; the model animates the change.
                    Text("Capturing")
                        .font(MC.Font.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MC.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCaptured ? "Capturing" : (app.isMakingSound ? "Making sound" : ""))
    }
}

// MARK: - Files

struct FilesBrowser: View {
    @Environment(HubModel.self) private var model
    @State private var selection: String?
    @State private var importing = false

    var body: some View {
        Group {
            if model.files.isEmpty {
                ContentUnavailableView {
                    Label("No files yet", systemImage: "music.note")
                } description: {
                    Text("Drop audio files here, or add them from Finder.")
                } actions: {
                    Button("Add Files\u{2026}") { importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MC.Surface.canvas)
            } else {
                List(selection: $selection) {
                    ForEach(model.files) { file in
                        TrackRow(track: file,
                                 isCurrent: model.activeSource == .files && model.nowPlaying?.trackID == file.id,
                                 detail: [file.artist, file.format].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .tag(file.id)
                            .sourceRow()
                    }
                }
                .sourceList()
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Play") { ids.first.map(model.playTrack) }
                } primaryAction: { ids in
                    ids.first.map(model.playTrack)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add audio files")
            }
        }
    }
}
