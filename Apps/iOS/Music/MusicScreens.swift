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
                    case .source(.macOutput): MacOutputScreen()
                    case .playlist(let p): PlaylistView(playlist: p)
                    case .folder(let f): FolderView(folder: f)
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
    /// Marks the row with its source (the combined library).
    var source: SourceKind? = nil

    var body: some View {
        HStack(spacing: MC.Space.m) {
            if showsArtwork {
                ArtworkView(data: model.artwork(track.artworkID, maxPixel: 200), size: 44, radius: MC.Radius.small + 2)
            }
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(track.title)
                    .font(MC.Font.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(MC.accent) : AnyShapeStyle(MC.Ink.primary))
                HStack(spacing: MC.Space.xs) {
                    if let source { PhoneSourceMark(source: source) }
                    Text(detail ?? track.artist)
                }
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
                        SourceRow(source: source, subtitle: subtitle(source), isLive: model.activeSource == source,
                                  title: source == .appleMusic ? model.libraryTitle : source.title,
                                  symbol: source == .appleMusic ? model.librarySymbol : source.symbolName)
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
            return model.libraryIsCombined ? "Apple Music and Spotify" : "Playlists and search"
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
        case .macOutput:
            return model.activeSource == .macOutput ? "Playing what the Mac plays" : "Whatever the Mac plays to \u{201C}Multicast\u{201D}"
        }
    }
}

private struct SourceRow: View {
    var source: SourceKind
    var subtitle: String
    var isLive: Bool
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(MC.Ink.body)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(title)
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
        .navigationTitle(model.libraryTitle)
        .searchable(text: $nav.librarySearch, prompt: "Search your library")
        .onChange(of: nav.librarySearch) { _, q in model.search(q) }
        .onAppear { if !nav.librarySearch.isEmpty { model.search(nav.librarySearch) } }
    }

    private var isSearching: Bool { !session.navigation.librarySearch.isEmpty }

    /// The library is playlists: pinned ones in a shelf, then every playlist. Search finds
    /// songs and playlists and shows them only while there is a query.
    private var library: some View {
        List {
            if isSearching {
                searchResults
            } else {
                if !model.pins.isEmpty {
                    Section {
                        PinnedShelf(artworkSize: 132)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } header: {
                        LibraryHeader("Pinned")
                    }
                }
                Section {
                    playlists(model.playlistTree.items(in: nil))
                    if model.playlists.isLoaded && model.playlists.items.isEmpty {
                        Text("No playlists in your library yet.")
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.secondary)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    LibraryHeader("Playlists")
                }
            }
        }
        .listStyle(.plain)
        .remoteList()
        .toolbar {
            if !isSearching && model.spotify != .notInstalled { PinSpotifyToolbar() }
            ToolbarItem(placement: .topBarTrailing) { UpNextButton() }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let q = session.navigation.librarySearch
        let matching = model.playlists.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let spotifyMatching = combined ? model.spotifyPins.filter { $0.name.localizedCaseInsensitiveContains(q) } : []
        if !matching.isEmpty || !spotifyMatching.isEmpty {
            Section("Playlists") {
                spotifyPlaylists(spotifyMatching)
                playlists(matching, showsLocation: true)
            }
        }
        let spotifySongMatches = combined ? model.spotifySessionSongs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        } : []
        if !spotifySongMatches.isEmpty {
            Section("Spotify this session") { spotifySongs(spotifySongMatches) }
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

    private var combined: Bool { model.libraryIsCombined }

    /// Pinned Spotify playlists: Spotify plays them, so a tap plays.
    private func spotifyPlaylists(_ pins: [PinnedPlaylist]) -> some View {
        ForEach(pins) { pin in
            Button { model.playPlaylist(pin.id) } label: {
                HStack(spacing: MC.Space.m) {
                    ArtworkView(data: model.artwork(pin.artworkID, maxPixel: 200), size: 56, radius: MC.Radius.medium)
                    VStack(alignment: .leading, spacing: MC.Space.xxs) {
                        Text(pin.name)
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.primary)
                        HStack(spacing: MC.Space.xs) {
                            PhoneSourceMark(source: .spotify)
                            Text("Plays in Spotify")
                        }
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { model.playPlaylist(pin.id) } label: { Label("Play", systemImage: "play") }
                Button { model.playPlaylist(pin.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                Button { model.unpin(pin.id) } label: { Label("Unpin", systemImage: "pin.slash") }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func spotifySongs(_ items: [TrackItem]) -> some View {
        ForEach(items) { track in
            Button { model.playTrack(track.id, context: .spotifyHistory) } label: {
                PhoneTrackRow(track: track, isCurrent: model.activeSource == .spotify && model.nowPlaying?.trackID == track.id,
                              source: .spotify)
            }
            .buttonStyle(.plain)
            .queueActions(track, source: .spotify, play: { model.playTrack(track.id, context: .spotifyHistory) })
            .listRowBackground(Color.clear)
        }
    }

    private func playlists(_ items: [PlaylistItem], showsLocation: Bool = false) -> some View {
        PlaylistRows(items: items, showsLocation: showsLocation)
    }

    private func tracks(_ items: [TrackItem], list: HubModel.ListKey, context: TrackContext) -> some View {
        ForEach(items) { track in
            Button { model.playTrack(track.id, context: context) } label: {
                PhoneTrackRow(track: track, isCurrent: isCurrent(track), source: combined ? .appleMusic : nil)
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

/// Playlists and folders as rows: a folder opens to its contents, a playlist to its songs.
private struct PlaylistRows: View {
    @Environment(HubModel.self) private var model
    var items: [PlaylistItem]
    /// Search results say which folder each one is in.
    var showsLocation = false

    var body: some View {
        ForEach(items) { item in
            NavigationLink(value: item.isFolder ? RemoteNavigation.MusicRoute.folder(item) : .playlist(item)) {
                PlaylistRow(playlist: item,
                            within: showsLocation ? model.playlistTree.path(to: item.id).map(\.name) : [])
            }
            .contextMenu {
                Button { model.playPlaylist(item.id) } label: { Label("Play", systemImage: "play") }
                Button { model.playPlaylist(item.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            .listRowBackground(Color.clear)
        }
    }
}

private struct PlaylistRow: View {
    @Environment(HubModel.self) private var model
    var playlist: PlaylistItem
    var within: [String] = []

    var body: some View {
        HStack(spacing: MC.Space.m) {
            if playlist.isFolder {
                FolderArtwork(artworkIDs: model.playlistTree.mosaic(for: playlist.id), side: 56, maxPixel: 200)
            } else {
                ArtworkView(data: model.artwork(playlist.artworkID, maxPixel: 200), size: 56, radius: MC.Radius.medium)
            }
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(playlist.name)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.primary)
                HStack(spacing: MC.Space.xs) {
                    if playlist.isFolder {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityLabel("Folder")
                    }
                    Text(detail).monospacedDigit()
                }
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.secondary)
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let base = playlist.isFolder ? model.folderDetail(playlist)
            : (playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs")
        return within.isEmpty ? base : "\(base) \u{00B7} in \(within.joined(separator: " \u{203A} "))"
    }
}

/// A playlist folder: its mosaic, Play and Shuffle (everything inside, as Music plays a
/// folder), then its sub-folders and playlists. The back button names the way out.
private struct FolderView: View {
    @Environment(HubModel.self) private var model
    var folder: PlaylistItem

    var body: some View {
        List {
            VStack(spacing: MC.Space.m) {
                FolderArtwork(artworkIDs: model.playlistTree.mosaic(for: folder.id), side: 200, maxPixel: 600)
                VStack(spacing: MC.Space.xxs) {
                    Text(folder.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MC.Ink.primary)
                    Text("Folder \u{00B7} \(model.folderDetail(folder))")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .monospacedDigit()
                }
                .multilineTextAlignment(.center)
                HStack(spacing: MC.Space.m) {
                    Button { model.playPlaylist(folder.id) } label: {
                        // An explicit icon and title, centred together in the capsule.
                        HStack(spacing: MC.Space.s) {
                            Image(systemName: "play.fill").accessibilityHidden(true)
                            Text("Play")
                        }
                        .font(MC.Font.bodyEmphasis)
                        .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Play everything in \(folder.name)")
                    Button { model.playPlaylist(folder.id, shuffled: true) } label: {
                        // An explicit icon and title, centred together in the capsule.
                        HStack(spacing: MC.Space.s) {
                            Image(systemName: "shuffle").accessibilityHidden(true)
                            Text("Shuffle")
                        }
                        .font(MC.Font.bodyEmphasis)
                        .frame(minWidth: 112)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Shuffle everything in \(folder.name)")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .padding(.top, MC.Space.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MC.Space.m)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            let items = model.playlistTree.items(in: folder.id)
            PlaylistRows(items: items)
            if items.isEmpty && model.playlists.isLoaded {
                Text("This folder is empty.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .remoteList()
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
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
                    if model.libraryIsCombined {
                        ListNote("Songs Spotify played this session, and pinned Spotify playlists, are in Library with your Apple Music.")
                    } else if !model.spotifyHistory.items.isEmpty {
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
                    if !model.libraryIsCombined {
                        ListNote("Swipe a song to queue it, or paste a song link with Add Spotify Song in Up Next.")
                    }
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

/// The source of a row in the combined library: a small glyph, named for VoiceOver.
struct PhoneSourceMark: View {
    var source: SourceKind

    var body: some View {
        Image(systemName: source.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MC.Ink.tertiary)
            .accessibilityLabel(source.title)
    }
}

/// A library section title, quiet and in the list's own type.
private struct LibraryHeader: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(MC.Ink.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Opens Up Next from anywhere.
struct UpNextButton: View {
    @Environment(RemoteSession.self) private var session
    var body: some View {
        Button { session.navigation.showsUpNext = true } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Up Next")
    }
}

/// What is playing, then the hub's queue: tap plays a song, swipe removes, Edit reorders,
/// Shuffle and Clear act on the whole list.
struct UpNextSheet: View {
    @Environment(HubModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let info = model.nowPlaying {
                    Section {
                        HStack(spacing: MC.Space.m) {
                            ArtworkView(data: model.artwork(info.artworkID, maxPixel: 200), size: 56, radius: MC.Radius.medium,
                                        isIcon: info.artworkIsIcon)
                            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                                Text(info.title).font(MC.Font.bodyEmphasis).foregroundStyle(MC.Ink.primary)
                                Text(info.artist).font(MC.Font.caption).foregroundStyle(MC.Ink.secondary)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Color.clear)
                    } header: {
                        LibraryHeader("Now Playing")
                    }
                }
                Section {
                    UpNextSection()
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        LibraryHeader("Up Next")
                        Spacer(minLength: MC.Space.s)
                        let on = model.queue.isShuffled
                        Button(action: model.toggleShuffle) {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(MC.Font.captionEmphasis)
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? MC.accent : .gray)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(model.upNext.items.isEmpty && !on)
                        .accessibilityValue(on ? "On" : "Off")
                    }
                }
            }
            .listStyle(.plain)
            .remoteList()
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                UpNextToolbar()
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(MC.Surface.canvas)
    }
}
