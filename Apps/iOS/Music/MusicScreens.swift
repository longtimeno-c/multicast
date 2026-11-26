import SwiftUI
import MulticastHubModel

/// What plays: the hub's four sources, each with what it can truly do from here.
struct MusicScreen: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        @Bindable var nav = session.navigation
        NavigationStack(path: $nav.musicPath) {
            SourcesList()
                .navigationDestination(for: RemoteNavigation.MusicRoute.self) { route in
                    switch route {
                    case .source(.appleMusic): AppleMusicView()
                    case .source(.spotify): SpotifyView()
                    case .source(.app): OtherAppView()
                    case .source(.files): FilesView()
                    case .playlist(let p): PlaylistView(playlist: p)
                    }
                }
        }
        .disabled(session.linkProblem != nil)
    }
}

// MARK: - Shared list look

extension View {
    /// Lists sit on the same canvas as the speakers, rows on the grouped fill, like the Mac.
    func remoteList() -> some View {
        scrollContentBackground(.hidden)
            .background(MC.Surface.canvas)
    }
}

/// A track: artwork, title over artist, and its length, or a speaker glyph while it plays.
struct PhoneTrackRow: View {
    @Environment(HubModel.self) private var model
    var track: TrackItem
    var isCurrent: Bool
    var detail: String? = nil
    var showsArtwork = true

    var body: some View {
        HStack(spacing: MC.Space.m) {
            if showsArtwork {
                ArtworkView(data: model.artwork(track.artworkID, maxPixel: 200), size: 44, radius: MC.Radius.small + 2)
            }
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(track.title)
                    .font(MC.Font.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(MC.accent) : AnyShapeStyle(MC.Ink.primary))
                Text(detail ?? track.artist)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                Text(MC.Format.time(track.duration))
                    .font(MC.Font.captionValue)
                    .foregroundStyle(MC.Ink.secondary)
                    .opacity(isCurrent ? 0 : 1)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(MC.accent)
                    .opacity(isCurrent ? 1 : 0)
            }
            .animation(MC.Motion.feedback, value: isCurrent)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Now playing" : MC.Format.time(track.duration))
        .accessibilityAddTraits(.isButton)
    }
}

/// A calm explanation where a source can't work yet, with the one action that helps.
private struct SourceIssueView: View {
    @Environment(HubModel.self) private var model
    var source: SourceKind
    var issue: HubIssue
    var hubName: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: source.symbolName)
        } description: {
            Text(message)
        } actions: {
            switch issue {
            case .permissionMissing(let p, .notDetermined):
                Button("Ask on \(hubName)") { model.requestPermission(p) }
                    .buttonStyle(.borderedProminent)
            case .sourceAppNotRunning(.spotify, _, _):
                Button("Open Spotify on \(hubName)") { model.openSpotify() }
                    .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch issue {
        case .permissionMissing(let p, _): "\(p.title) Is Off"
        case .sourceAppNotRunning(_, _, let name): "\(name) Isn\u{2019}t Open"
        case .sourceAppNotInstalled(_, _, let name): "\(name) Isn\u{2019}t Installed"
        }
    }

    private var message: String {
        switch issue {
        case .permissionMissing(let p, .denied):
            "Turn on \(p.title) for Multicast in Privacy & Security on \(hubName)."
        case .permissionMissing(let p, _):
            "\(hubName) needs \(p.title) to play \(source.title). The request appears on the Mac."
        case .sourceAppNotRunning(_, _, let name):
            "Open \(name) on \(hubName) to play from it here."
        case .sourceAppNotInstalled(_, _, let name):
            "Install \(name) on \(hubName) to play from it."
        }
    }
}

/// A quiet line at the end of a plain list, on the canvas like the rows (a plain list's own
/// footer draws its own background).
private struct ListNote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(MC.Font.caption)
            .foregroundStyle(MC.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, MC.Space.xs)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Sources

private struct SourcesList: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        List {
            Section {
                ForEach(SourceKind.allCases) { source in
                    NavigationLink(value: RemoteNavigation.MusicRoute.source(source)) {
                        SourceRow(source: source, subtitle: subtitle(source), isLive: model.activeSource == source)
                    }
                }
            } footer: {
                Text("Everything plays on \(session.hub?.name ?? "your Mac") and goes to the speakers you choose.")
            }
            .listRowBackground(Rectangle().fill(MC.Surface.group))
        }
        .remoteList()
        .navigationTitle("Music")
    }

    private func subtitle(_ source: SourceKind) -> String {
        if let issue = model.health.shownIssues(for: source).first {
            switch issue {
            case .permissionMissing(let p, _): return "Needs \(p.title) on the Mac"
            case .sourceAppNotRunning(_, _, let name): return "\(name) isn\u{2019}t open on the Mac"
            case .sourceAppNotInstalled(_, _, let name): return "\(name) isn\u{2019}t installed"
            }
        }
        switch source {
        case .appleMusic:
            return "Playlists, songs and search"
        case .spotify:
            switch model.spotify {
            case .notInstalled: return "Not installed on the Mac"
            case .notRunning: return "Not open on the Mac"
            case .running: return model.activeSource == .spotify ? "Playing what Spotify plays" : "Choose music in Spotify"
            }
        case .app:
            if model.activeSource == .app, let id = model.capturedAppID,
               let app = model.capturableApps.first(where: { $0.id == id }) {
                return "Capturing \(app.name)"
            }
            let sounding = model.capturableApps.filter(\.isMakingSound)
            switch sounding.count {
            case 0: return "Any app\u{2019}s sound on the Mac"
            case 1: return "\(sounding[0].name) is making sound"
            default: return "\(sounding[0].name) and \(sounding.count - 1) more making sound"
            }
        case .files:
            let n = model.files.totalCount ?? model.files.items.count
            return n == 1 ? "1 file on the Mac" : "\(n) files on the Mac"
        }
    }
}

private struct SourceRow: View {
    var source: SourceKind
    var subtitle: String
    var isLive: Bool

    var body: some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: source.symbolName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(MC.Ink.body)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(source.title)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                Text(subtitle)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isLive {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(MC.accent)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? "Playing" : "")
    }
}

// MARK: - Apple Music

private struct AppleMusicView: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        @Bindable var nav = session.navigation
        Group {
            if let issue = model.health.shownIssues(for: .appleMusic).first {
                SourceIssueView(source: .appleMusic, issue: issue, hubName: session.hub?.name ?? "the Mac")
            } else {
                library
            }
        }
        .navigationTitle("Apple Music")
        .searchable(text: $nav.librarySearch, prompt: "Search your library")
        .onChange(of: nav.librarySearch) { _, q in model.search(q) }
        .onAppear { if !nav.librarySearch.isEmpty { model.search(nav.librarySearch) } }
    }

    private var isSearching: Bool { !session.navigation.librarySearch.isEmpty }

    private var library: some View {
        @Bindable var nav = session.navigation
        return List {
            if isSearching {
                searchResults
            } else {
                if !model.pins.isEmpty {
                    PinnedShelf(artworkSize: 96)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                Picker("Show", selection: $nav.appleMusicSection) {
                    ForEach(RemoteNavigation.AppleMusicSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                switch nav.appleMusicSection {
                case .playlists: playlists(model.playlists.items)
                case .songs: tracks(model.songs.items, list: .songs, context: .songs)
                case .upNext:
                    UpNextSection()
                }
            }
        }
        .listStyle(.plain)
        .remoteList()
        .animation(MC.Motion.feedback, value: nav.appleMusicSection)
        .toolbar {
            if nav.appleMusicSection == .upNext && !isSearching { UpNextToolbar() }
            if nav.appleMusicSection == .playlists && !isSearching && model.spotify != .notInstalled { PinSpotifyToolbar() }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let q = session.navigation.librarySearch
        let matching = model.playlists.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        if !matching.isEmpty {
            Section("Playlists") { playlists(matching) }
        }
        Section("Songs") {
            if model.searchResults.isLoaded && model.searchResults.items.isEmpty && model.searchQuery == q.trimmingCharacters(in: .whitespaces) {
                Text("No songs match \u{201C}\(q)\u{201D}.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
            }
            tracks(model.searchResults.items, list: .search, context: .search(query: model.searchQuery))
        }
    }

    private func playlists(_ items: [PlaylistItem]) -> some View {
        ForEach(items) { playlist in
            NavigationLink(value: RemoteNavigation.MusicRoute.playlist(playlist)) {
                PlaylistRow(playlist: playlist)
            }
            .listRowBackground(Color.clear)
            .onAppear { model.loadMoreIfNeeded(.playlists, after: playlist.id) }
        }
    }

    private func tracks(_ items: [TrackItem], list: HubModel.ListKey, context: TrackContext) -> some View {
        ForEach(items) { track in
            Button { model.playTrack(track.id, context: context) } label: {
                PhoneTrackRow(track: track, isCurrent: isCurrent(track))
            }
            .buttonStyle(.plain)
            .queueActions(track, source: .appleMusic, play: { model.playTrack(track.id, context: context) })
            .listRowBackground(Color.clear)
            .onAppear { model.loadMoreIfNeeded(list, after: track.id) }
        }
    }

    private func isCurrent(_ track: TrackItem) -> Bool {
        model.activeSource == .appleMusic && model.nowPlaying?.trackID == track.id
    }
}

private struct PlaylistRow: View {
    @Environment(HubModel.self) private var model
    var playlist: PlaylistItem

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(playlist.artworkID, maxPixel: 200), size: 56, radius: MC.Radius.medium)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(playlist.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                Text(playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A playlist's songs, with Play at the top. Tapping a song starts the playlist there.
private struct PlaylistView: View {
    @Environment(HubModel.self) private var model
    var playlist: PlaylistItem

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if model.openPlaylistID == playlist.id {
                ForEach(model.playlistTracks.items) { track in
                    Button { model.playTrack(track.id, context: .playlist(id: playlist.id)) } label: {
                        PhoneTrackRow(track: track, isCurrent: isCurrent(track))
                    }
                    .buttonStyle(.plain)
                    .queueActions(track, source: .appleMusic, play: { model.playTrack(track.id, context: .playlist(id: playlist.id)) })
                    .listRowBackground(Color.clear)
                    .onAppear { model.loadMoreIfNeeded(.playlist, after: track.id) }
                }
            }
        }
        .listStyle(.plain)
        .remoteList()
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        // The header already names the playlist; the bar keeps the name for the back menu only.
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .primaryAction) {
                let pinned = model.isPinned(playlist.id)
                Button { pinned ? model.unpin(playlist.id) : model.pin(playlist.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(pinned ? "Unpin" : "Pin to Top")
            }
        }
        .onAppear { model.openPlaylist(playlist.id) }
    }

    private var header: some View {
        VStack(spacing: MC.Space.m) {
            ArtworkView(data: model.artwork(playlist.artworkID), size: 220, radius: MC.Radius.large)
            VStack(spacing: MC.Space.xxs) {
                Text(playlist.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MC.Ink.primary)
                Text(playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .monospacedDigit()
            }
            .multilineTextAlignment(.center)
            HStack(spacing: MC.Space.m) {
                Button { model.playPlaylist(playlist.id) } label: {
                    // An explicit icon and title, centred together in the capsule.
                    HStack(spacing: MC.Space.s) {
                        Image(systemName: "play.fill")
                            .accessibilityHidden(true)
                        Text("Play")
                    }
                    .font(MC.Font.bodyEmphasis)
                    .frame(minWidth: 112)
                }
                .accessibilityLabel("Play \(playlist.name)")
                .buttonStyle(.borderedProminent)
                Button { model.playPlaylist(playlist.id, shuffled: true) } label: {
                    HStack(spacing: MC.Space.s) {
                        Image(systemName: "shuffle")
                            .accessibilityHidden(true)
                        Text("Shuffle")
                    }
                    .font(MC.Font.bodyEmphasis)
                    .frame(minWidth: 112)
                }
                .accessibilityLabel("Shuffle \(playlist.name)")
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, MC.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MC.Space.m)
    }

    private func isCurrent(_ track: TrackItem) -> Bool {
        model.activeSource == .appleMusic && model.nowPlaying?.trackID == track.id
    }
}

// MARK: - Spotify

/// Spotify is chosen in Spotify. Here: whether it's live, the button that makes it the source,
/// and what has played this session (for reference; it can't be replayed from here).
private struct SpotifyView: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        Group {
            if let issue = model.health.shownIssues(for: .spotify).first {
                SourceIssueView(source: .spotify, issue: issue, hubName: hubName)
            } else {
                List {
                    header
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if !model.spotifyHistory.items.isEmpty {
                        Section("This session") {
                            ForEach(model.spotifyHistory.items) { track in
                                if track.id.hasPrefix("spotify:track:") {
                                    Button { model.playTrack(track.id, context: .spotifyHistory) } label: {
                                        PhoneTrackRow(track: track, isCurrent: isLive && model.nowPlaying?.trackID == track.id)
                                    }
                                    .buttonStyle(.plain)
                                    .queueActions(track, source: .spotify, play: { model.playTrack(track.id, context: .spotifyHistory) })
                                    .listRowBackground(Color.clear)
                                    .onAppear { model.loadMoreIfNeeded(.spotifyHistory, after: track.id) }
                                } else {
                                    PhoneTrackRow(track: track, isCurrent: false)
                                        .accessibilityRemoveTraits(.isButton)
                                        .listRowBackground(Color.clear)
                                        .onAppear { model.loadMoreIfNeeded(.spotifyHistory, after: track.id) }
                                }
                            }
                        }
                    }
                    ListNote("Swipe a song to queue it, or paste a song link with Add Spotify Song in Up Next.")
                }
                .listStyle(.plain)
                .remoteList()
            }
        }
        .navigationTitle("Spotify")
    }

    private var hubName: String { session.hub?.name ?? "the Mac" }
    private var isLive: Bool { model.activeSource == .spotify }

    private var header: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            HStack(spacing: MC.Space.xs) {
                if isLive {
                    Circle().fill(MC.Status.playing).frame(width: 6, height: 6)
                }
                Text(status)
            }
            .font(MC.Font.captionEmphasis)
            .foregroundStyle(MC.Ink.secondary)
            Text("Choose music in Spotify on \(hubName). Play, pause and skip here control Spotify, and its sound goes to your speakers.")
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            if !isLive {
                Button {
                    if model.spotify == .running { model.selectSource(.spotify) } else { model.openSpotify() }
                } label: {
                    Text(model.spotify == .running ? "Play from Spotify" : "Open Spotify on \(hubName)")
                        .font(MC.Font.bodyEmphasis)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.vertical, MC.Space.s)
    }

    private var status: String {
        switch model.spotify {
        case .notInstalled: "Not installed on \(hubName)"
        case .notRunning: "Not open on \(hubName)"
        case .running: isLive ? "Playing to your speakers" : "Open on \(hubName), not in use"
        }
    }
}

// MARK: - Other app

private struct OtherAppView: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        Group {
            if let issue = model.health.shownIssues(for: .app).first {
                SourceIssueView(source: .app, issue: issue, hubName: session.hub?.name ?? "the Mac")
            } else {
                List {
                    let sounding = model.capturableApps.filter(\.isMakingSound)
                    let quiet = model.capturableApps.filter { !$0.isMakingSound }
                    if !sounding.isEmpty { Section("Making sound") { rows(sounding) } }
                    if !quiet.isEmpty { Section("Other open apps") { rows(quiet) } }
                    ListNote("Only the chosen app is captured, never alerts or other sounds.")
                }
                .listStyle(.plain)
                .remoteList()
            }
        }
        .navigationTitle("Other App")
    }

    private func rows(_ apps: [CapturableApp]) -> some View {
        ForEach(apps) { app in
            Button { model.captureApp(app.id) } label: {
                AppRow(app: app, isCaptured: model.activeSource == .app && model.capturedAppID == app.id)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
    }
}

private struct AppRow: View {
    @Environment(HubModel.self) private var model
    var app: CapturableApp
    var isCaptured: Bool

    var body: some View {
        HStack(spacing: MC.Space.m) {
            icon
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(app.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                if isCaptured {
                    Text("Capturing")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCaptured {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MC.accent)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCaptured ? "Capturing" : (app.isMakingSound ? "Making sound" : ""))
        .accessibilityAddTraits(isCaptured ? [.isButton, .isSelected] : .isButton)
    }

    /// The Mac sends the app's real icon as artwork; until it arrives, a quiet placeholder.
    @ViewBuilder private var icon: some View {
        if let data = model.artwork(app.iconArtworkID, maxPixel: 120) {
            ArtworkView(data: data, size: 32, isIcon: true)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MC.Surface.well)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "app.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(MC.Ink.tertiary)
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Files

private struct FilesView: View {
    @Environment(HubModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        Group {
            if model.files.isLoaded && model.files.items.isEmpty {
                ContentUnavailableView {
                    Label("No Files Yet", systemImage: "folder")
                } description: {
                    Text("Add audio files on \(hubName): drop them on Files in Multicast.")
                }
            } else {
                List {
                        ForEach(model.files.items) { file in
                            Button { model.playTrack(file.id, context: .files) } label: {
                                PhoneTrackRow(track: file,
                                              isCurrent: model.activeSource == .files && model.nowPlaying?.trackID == file.id,
                                              detail: [file.artist, file.format].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                              showsArtwork: file.artworkID != nil)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .swipeActions {
                                Button("Remove", role: .destructive) { model.removeFiles([file.id]) }
                            }
                            .queueActions(file, source: .files, play: { model.playTrack(file.id, context: .files) })
                            .onAppear { model.loadMoreIfNeeded(.files, after: file.id) }
                        }
                    ListNote("Files live on \(hubName). Add more there; swipe to remove one from the list.")
                }
                .listStyle(.plain)
                .remoteList()
            }
        }
        .navigationTitle("Files")
    }

    private var hubName: String { session.hub?.name ?? "the Mac" }
}

// MARK: - Queue

extension View {
    /// Play Next and Add to Queue: a leading swipe, and the long-press menu (with Play first).
    func queueActions(_ track: TrackItem, source: SourceKind, play: @escaping () -> Void) -> some View {
        modifier(QueueActions(track: track, source: source, play: play))
    }
}

private struct QueueActions: ViewModifier {
    @Environment(HubModel.self) private var model
    var track: TrackItem
    var source: SourceKind
    var play: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { model.playNext([track], from: source) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(MC.accent)
                Button { model.addToQueue([track], from: source) } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .tint(.gray)
            }
            .contextMenu {
                Button(action: play) { Label("Play", systemImage: "play") }
                Button { model.playNext([track], from: source) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { model.addToQueue([track], from: source) } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
    }
}

/// Up Next inside the Apple Music list: the hub's queue, whichever app plays each song.
/// Tap plays, swipe removes, Edit reorders.
struct UpNextSection: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        if model.queue.isHeld {
            ListNote("Something else is playing on the Mac. These songs wait; Next carries on with them.")
        }
        if model.upNext.isLoaded && model.upNext.items.isEmpty {
            Text("Swipe a song right to play it next or add it to the queue, from Apple Music, Spotify or Files.")
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        ForEach(model.upNext.items) { item in
            Button { model.playQueued(item.id) } label: {
                PhoneTrackRow(track: item.track, isCurrent: false, detail: detail(item))
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .accessibilityHint(item.source == .appleMusic ? "" : "Plays from \(item.source.title)")
            .onAppear { model.loadMoreIfNeeded(.upNext, after: item.id) }
        }
        .onDelete { offsets in model.removeFromQueue(offsets.map { model.upNext.items[$0].id }) }
        .onMove { model.moveInQueue(from: $0, to: $1) }
    }

    private func detail(_ item: QueueItem) -> String {
        switch item.source {
        case .appleMusic: item.track.artist
        default: [item.source.title, item.track.artist].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
    }
}

/// Up Next's own controls: Edit (reorder), Clear and Add Spotify Song.
struct UpNextToolbar: ToolbarContent {
    @Environment(HubModel.self) private var model
    @State private var askingForLink = false
    @State private var link = ""
    @State private var invalid = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { link = ""; askingForLink = true } label: {
                    Label("Add Spotify Song\u{2026}", systemImage: "link")
                }
                Button(role: .destructive) { model.clearQueue() } label: {
                    Label("Clear Up Next", systemImage: "xmark.circle")
                }
                .disabled(model.upNext.items.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Up Next options")
            .alert("Add Spotify Song", isPresented: $askingForLink) {
                TextField("Song link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add to Queue") { invalid = !model.addSpotifyLink(link) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In Spotify, choose Share \u{203A} Copy Song Link, then paste it here.")
            }
            .alert("That isn\u{2019}t a Spotify song link", isPresented: $invalid) {
                Button("OK", role: .cancel) {}
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            EditButton()
                .disabled(model.upNext.items.isEmpty)
        }
    }
}

/// Pin a Spotify playlist from a pasted share link.
struct PinSpotifyToolbar: ToolbarContent {
    @Environment(HubModel.self) private var model
    @State private var asking = false
    @State private var link = ""
    @State private var invalid = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { link = ""; asking = true } label: { Image(systemName: "pin") }
                .accessibilityLabel("Pin Spotify Playlist")
                .alert("Pin Spotify Playlist", isPresented: $asking) {
                    TextField("Playlist link", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Pin") { invalid = !model.pinSpotifyLink(link) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("In Spotify, choose Share \u{203A} Copy Link to Playlist, then paste it here. Spotify plays it; its songs aren\u{2019}t listed here.")
                }
                .alert("That isn\u{2019}t a Spotify playlist link", isPresented: $invalid) {
                    Button("OK", role: .cancel) {}
                }
        }
    }
}
