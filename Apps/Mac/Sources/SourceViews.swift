import SwiftUI
import UniformTypeIdentifiers
import MulticastHubModel

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

    /// One click on the row acts (plays the song, opens the playlist). The list still selects
    /// the row, so the keyboard carries on from it and Return does the same thing.
    func rowClick(_ action: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
    }
}

/// Swallows the repeat when one gesture reaches a list twice: a double click is two clicks and
/// then the list's own primary action. None of them should restart the song, and the second
/// click must not play whatever row slid under the pointer when a playlist opened.
@MainActor
final class RowActivation {
    private var last = Date.distantPast

    func once(_ action: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(last) > NSEvent.doubleClickInterval else { return }
        last = now
        action()
    }
}

/// Header pinned above a source list (search, a source's own controls). Every source starts
/// its first content at the same height under the toolbar.
struct SourceHeader<Content: View>: View {
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
struct SourceSectionTitle: View {
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

/// What stands in the way of a source, as the first row of its list: a permission to allow or
/// an app to open, with the one action that fixes it.
struct SourceIssueNotice: View {
    @Environment(HubModel.self) private var model
    var source: SourceKind
    /// Leave app-not-open issues to the source's own header (Spotify says it already).
    var permissionsOnly = false

    var body: some View {
        if let issue = Self.shown(model.health.shownIssues(for: source), permissionsOnly: permissionsOnly).first {
            HStack(alignment: .top, spacing: MC.Space.m) {
                Image(systemName: symbol(issue))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MC.Ink.body)
                    .frame(width: 20, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MC.Space.xs) {
                    Text(title(issue))
                        .font(MC.Font.bodyEmphasis)
                        .foregroundStyle(MC.Ink.primary)
                    Text(message(issue))
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    action(issue)
                        .padding(.top, MC.Space.xs)
                }
                Spacer(minLength: 0)
            }
            .padding(MC.Space.m)
            .background(RoundedRectangle(cornerRadius: MC.Radius.medium, style: .continuous).fill(MC.Surface.group))
            .accessibilityElement(children: .contain)
            .selectionDisabled()
            .sourceRow()
        }
    }

    static func shown(_ issues: [HubIssue], permissionsOnly: Bool) -> [HubIssue] {
        issues.filter { issue in
            switch issue {
            case .permissionMissing: true
            case .sourceAppNotRunning, .sourceAppNotInstalled: !permissionsOnly
            }
        }
    }

    private func symbol(_ issue: HubIssue) -> String {
        switch issue {
        case .permissionMissing: "lock.fill"
        case .sourceAppNotRunning, .sourceAppNotInstalled: "app.dashed"
        }
    }

    private func title(_ issue: HubIssue) -> String {
        switch issue {
        case .permissionMissing(let p, let status):
            status == .denied ? "\(p.title) is turned off for Multicast" : "Allow \(p.title)"
        case .sourceAppNotRunning(_, _, let name): "\(name) isn\u{2019}t open"
        case .sourceAppNotInstalled(_, _, let name): "\(name) isn\u{2019}t installed"
        }
    }

    private func message(_ issue: HubIssue) -> String {
        switch issue {
        case .permissionMissing(let p, let status):
            let why: String = switch p {
            case .audioCapture: "Multicast hears an app through System Audio Recording, then plays it on your speakers."
            case .automation: "Multicast uses Automation to see what\u{2019}s playing and to play, pause and skip."
            case .appleMusic: "Multicast needs it to read your library and play it."
            case .localNetwork: "Multicast needs it to find AirPlay speakers."
            }
            return status == .denied ? why + " Turn it on in Privacy & Security." : why
        case .sourceAppNotRunning(_, _, let name): return "Open \(name) to play from it."
        case .sourceAppNotInstalled(_, _, let name): return "Install \(name) to play from it."
        }
    }

    @ViewBuilder private func action(_ issue: HubIssue) -> some View {
        switch issue {
        case .permissionMissing(let p, let status):
            Button(status == .denied ? "Open Settings\u{2026}" : "Allow\u{2026}") { model.requestPermission(p) }
        case .sourceAppNotRunning(.spotify, _, _):
            Button("Open Spotify") { model.openSpotify() }
        case .sourceAppNotRunning, .sourceAppNotInstalled:
            EmptyView()
        }
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
    /// Marks the row with its source (the combined library).
    var source: SourceKind? = nil

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(track.artworkID), size: 32, radius: MC.Radius.small)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(track.title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                    .lineLimit(1)
                HStack(spacing: MC.Space.xs) {
                    if let source { SourceMark(source: source) }
                    Text(detail ?? track.artist)
                }
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

// MARK: - Spotify

struct SpotifySourceView: View {
    @Environment(HubModel.self) private var model
    static let bundleID = "com.spotify.client"
    @State private var activation = RowActivation()
    @State private var selection: String?

    var body: some View {
        List(selection: $selection) {
            SourceIssueNotice(source: .spotify, permissionsOnly: true)
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
                Text("Choose music in Spotify, or queue its songs here. Multicast sends whatever it plays to your speakers, and play, pause and skip here control Spotify.")
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

            if model.libraryIsCombined {
                Text("Songs Spotify played this session, and pinned Spotify playlists, are in Library with your Apple Music.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(nil)
                    .selectionDisabled()
                    .sourceRow()
            } else if !model.spotifyHistory.items.isEmpty {
                SourceSectionTitle("This session")
                ForEach(model.spotifyHistory.items) { track in
                    TrackRow(track: track, isCurrent: isLive && model.nowPlaying?.trackID == track.id)
                        .rowClick { if track.isSpotifyTrack { activation.once { model.playTrack(track.id, context: .spotifyHistory) } } }
                        .tag(track.id)
                        .sourceRow()
                        .onAppear { model.loadMoreIfNeeded(.spotifyHistory, after: track.id) }
                }
            }
            SpotifyLinkField(kind: .song)
                .selectionDisabled()
                .sourceRow()
        }
        .sourceList()
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = model.spotifyHistory.items.filter { ids.contains($0.id) && $0.isSpotifyTrack }
            if !chosen.isEmpty {
                Button("Play") { model.playTrack(chosen[0].id, context: .spotifyHistory) }
                QueueMenuItems(tracks: chosen, source: .spotify)
            }
        }
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
            SourceIssueNotice(source: .app)
            SourceSectionTitle("Making sound", isFirst: !hasIssue)
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

    private var hasIssue: Bool { !SourceIssueNotice.shown(model.health.shownIssues(for: .app), permissionsOnly: false).isEmpty }

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
    @State private var activation = RowActivation()

    var body: some View {
        Group {
            if model.files.isLoaded && model.files.items.isEmpty {
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
                    ForEach(model.files.items) { file in
                        TrackRow(track: file,
                                 isCurrent: model.activeSource == .files && model.nowPlaying?.trackID == file.id,
                                 detail: [file.artist, file.format].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .rowClick { play(file.id) }
                            .tag(file.id)
                            .sourceRow()
                            .onAppear { model.loadMoreIfNeeded(.files, after: file.id) }
                    }
                }
                .sourceList()
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Play") { ids.first.map { model.playTrack($0, context: .files) } }
                    QueueMenuItems(tracks: model.files.items.filter { ids.contains($0.id) }, source: .files)
                    Divider()
                    Button("Remove from Files") { model.removeFiles(Array(ids)) }
                } primaryAction: { ids in
                    ids.first.map(play)
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

    private func play(_ id: String) {
        activation.once { model.playTrack(id, context: .files) }
    }
}

// MARK: - Queue

extension TrackItem {
    /// A Spotify song the hub can play again (Spotify gave its URI).
    var isSpotifyTrack: Bool { id.hasPrefix("spotify:track:") }
}

/// Play Next and Add to Queue, for a context menu.
struct QueueMenuItems: View {
    @Environment(HubModel.self) private var model
    var tracks: [TrackItem]
    var source: SourceKind

    var body: some View {
        if !tracks.isEmpty {
            Divider()
            Button("Play Next") { model.playNext(tracks, from: source) }
            Button("Add to Queue") { model.addToQueue(tracks, from: source) }
        }
    }
}

/// Pin or unpin a playlist, for a context menu.
struct PinButton: View {
    @Environment(HubModel.self) private var model
    var playlistID: String?

    var body: some View {
        if let id = playlistID {
            if model.isPinned(id) {
                Button("Unpin") { model.unpin(id) }
            } else {
                Button("Pin to Top") { model.pin(id) }
                    .disabled(model.pins.count >= PinnedPlaylist.limit)
            }
        }
    }
}

/// Up Next as list rows: click plays, drag reorders, the context menu removes.
struct UpNextRows: View {
    @Environment(HubModel.self) private var model
    var filter: String
    var activate: (String) -> Void

    var body: some View {
        if model.upNext.isLoaded && model.upNext.items.isEmpty {
            Text("Play Next and Add to Queue put songs here, from Apple Music, Spotify or Files.")
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.secondary)
                .lineLimit(nil)
                .padding(.vertical, MC.Space.s)
                .selectionDisabled()
                .sourceRow()
        }
        ForEach(items) { item in
            QueueRow(item: item)
                .rowClick { activate(item.id) }
                .tag(item.id)
                .sourceRow()
                .onAppear { model.loadMoreIfNeeded(.upNext, after: item.id) }
        }
        .onMove(perform: filter.isEmpty ? { model.moveInQueue(from: $0, to: $1) } : nil)
    }

    private var items: [QueueItem] {
        guard !filter.isEmpty else { return model.upNext.items }
        return model.upNext.items.filter {
            $0.track.title.localizedCaseInsensitiveContains(filter) || $0.track.artist.localizedCaseInsensitiveContains(filter)
        }
    }
}

/// An Up Next song, marked with the app that plays it when that isn't Apple Music.
struct QueueRow: View {
    var item: QueueItem

    var body: some View {
        TrackRow(track: item.track, isCurrent: false, detail: detail)
            .accessibilityHint(item.source == .appleMusic ? "" : "Plays from \(item.source.title)")
    }

    private var detail: String {
        switch item.source {
        case .appleMusic: item.track.artist
        default: [item.source.title, item.track.artist].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
    }
}

/// Paste a Spotify link: a song to queue it, a playlist to pin it.
struct SpotifyLinkField: View {
    enum Kind { case song, playlist }

    @Environment(HubModel.self) private var model
    var kind: Kind
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.xs) {
            Text(kind == .song ? "Queue a Spotify song" : "Pin a Spotify playlist")
                .font(MC.Font.captionEmphasis)
                .foregroundStyle(MC.Ink.secondary)
            HStack(spacing: MC.Space.s) {
                TextField(kind == .song ? "Paste a link from Share \u{203A} Copy Song Link"
                                        : "Paste a link from Share \u{203A} Copy Link to Playlist", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: text) { invalid = false }
                Button(kind == .song ? "Add to Queue" : "Pin", action: add)
                    .disabled(text.isEmpty)
            }
            if invalid {
                Text(kind == .song ? "That isn\u{2019}t a Spotify song link." : "That isn\u{2019}t a Spotify playlist link.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
            if kind == .playlist {
                Text("Spotify plays it; Multicast can\u{2019}t list its songs.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
        }
        .padding(.top, MC.Space.l)
    }

    private func add() {
        let ok = kind == .song ? model.addSpotifyLink(text) : model.pinSpotifyLink(text)
        if ok { text = "" } else { invalid = true }
    }
}

// MARK: - Combined library

/// The source of a row in the combined library: a small glyph, named for VoiceOver.
struct SourceMark: View {
    var source: SourceKind

    var body: some View {
        Image(systemName: source.symbolName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(MC.Ink.tertiary)
            .accessibilityLabel(source.title)
            .help(source.title)
    }
}
