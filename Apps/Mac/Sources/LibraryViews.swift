import SwiftUI
import MulticastHubModel

// MARK: - Library

/// The library is playlists: pinned ones first, then every playlist, as artwork tiles. One
/// click opens a playlist (large artwork, Play and Shuffle, its songs); a pinned Spotify
/// playlist, which can't be listed, plays instead. Search finds songs and playlists and shows
/// its results only while there is a query.
struct AppleMusicBrowser: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        switch model.health.permission(.appleMusic) {
        case .granted: LibraryBrowser()
        case .notDetermined: connect
        case .denied: denied
        }
    }

    @AppStorage(SettingsKey.appleMusicBackend) private var backend = "musicApp"
    private var usesMusicApp: Bool { backend != "musicKit" }

    private var connect: some View {
        ContentUnavailableView {
            Label("Connect Apple Music", systemImage: "music.note")
        } description: {
            Text(usesMusicApp
                 ? "Multicast plays your library and playlists through the Music app, then sends them to every speaker you choose. Allow it to control Music."
                 : "Multicast plays your library and playlists itself, then sends them to every speaker you choose.")
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
            Text(usesMusicApp
                 ? "Allow Multicast to control Music under Automation in Privacy & Security to see your library here."
                 : "Allow it under Media & Apple Music in Privacy & Security to see your library here.")
        } actions: {
            // The hub opens the pane that holds its Apple Music player's permission.
            Button("Open Settings\u{2026}") { model.requestPermission(.appleMusic) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MC.Surface.canvas)
    }
}

private struct LibraryBrowser: View {
    @Environment(HubModel.self) private var model
    @State private var query = ""
    @State private var focusSearch = 0

    /// One search field above whatever shows beneath it. (It used to be a safe-area inset on a
    /// `Group`, which applies modifiers to each branch: every branch had its own field, so the
    /// first letter, which swaps the grid for the results, put up a new field without focus.)
    var body: some View {
        VStack(spacing: 0) {
            SourceHeader {
                SearchField(text: $query, prompt: "Search songs and playlists", focusRequest: focusSearch)
            }
            ZStack {
                if isSearching {
                    LibrarySearchResults(query: query, clear: { query = "" })
                } else if let playlist = model.openedPlaylist {
                    PlaylistDetail(playlist: playlist)
                        .transition(.opacity)
                } else {
                    PlaylistGrid()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MC.Surface.canvas)
        .onChange(of: query) { _, new in model.search(new) }
        .background {
            // Command-F reaches the library search, as Music's does.
            Button("Find") { focusSearch += 1 }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: Playlist grid

/// Pinned playlists, then the playlists and folders at the top of the library, as tiles
/// sized to fill the column; inside a folder, its playlists and sub-folders under a breadcrumb.
private struct PlaylistGrid: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        let tree = model.playlistTree
        let folder = model.openFolderID.flatMap(tree.item)
        GeometryReader { geo in
            let layout = TileLayout(width: geo.size.width - SourceHeaderMetrics.inset * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: MC.Space.l) {
                    SourceIssueNotice(source: .appleMusic)
                    if let folder {
                        FolderHeader(folder: folder, path: tree.path(to: folder.id))
                    }
                    if folder == nil, !model.pins.isEmpty {
                        GridTitle("Pinned")
                        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MC.Space.l) {
                            ForEach(model.pins) { pin in
                                PlaylistTile(name: pin.name, detail: pinDetail(pin), source: pin.source,
                                             artworkID: pin.artworkID, side: layout.side, isPinned: true,
                                             playlistID: pin.id, open: { open(pin) })
                            }
                        }
                    }
                    if folder == nil { GridTitle("Playlists") }
                    LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MC.Space.l) {
                        ForEach(tree.items(in: folder?.id)) { item in
                            PlaylistTile(name: item.name,
                                         detail: item.isFolder ? model.folderDetail(item) : songs(item.trackCount),
                                         source: nil, artworkID: item.artworkID,
                                         mosaic: item.isFolder ? tree.mosaic(for: item.id) : nil,
                                         side: layout.side, isPinned: model.isPinned(item.id), playlistID: item.id,
                                         open: { model.open(item) })
                        }
                    }
                    if model.playlists.isLoaded && tree.items(in: folder?.id).isEmpty {
                        Text(folder == nil ? "No playlists in your library yet." : "This folder is empty.")
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.secondary)
                    }
                    if folder == nil, model.spotify != .notInstalled {
                        SpotifyLinkField(kind: .playlist)
                    }
                }
                .padding(.horizontal, SourceHeaderMetrics.inset)
                .padding(.bottom, MC.Space.xl)
            }
        }
        .background(MC.Surface.canvas)
    }

    private func open(_ pin: PinnedPlaylist) {
        if pin.source == .spotify {
            model.playPlaylist(pin.id)
        } else if let p = model.playlists.items.first(where: { $0.id == pin.id }) {
            model.open(p)
        } else {
            model.showPlaylist(PlaylistItem(id: pin.id, name: pin.name, trackCount: pin.trackCount ?? 0,
                                            artworkID: pin.artworkID))
        }
    }

    private func pinDetail(_ pin: PinnedPlaylist) -> String {
        pin.source == .spotify ? "Spotify" : songs(pin.trackCount ?? 0)
    }
}

func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

/// Columns for a tile grid: as many as fit at 112pt or more, filling the width exactly.
private struct TileLayout {
    let side: CGFloat
    let columns: [GridItem]

    init(width: CGFloat, minimum: CGFloat = 112, spacing: CGFloat = MC.Space.l) {
        let w = max(width, minimum)
        let n = max(2, Int((w + spacing) / (minimum + spacing)))
        side = floor((w - spacing * CGFloat(n - 1)) / CGFloat(n))
        columns = Array(repeating: GridItem(.fixed(side), spacing: spacing, alignment: .topLeading), count: n)
    }
}

private struct GridTitle: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(MC.Font.title)
            .foregroundStyle(MC.Ink.primary)
            .padding(.top, MC.Space.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A playlist as artwork over its full name (two lines) and a quiet detail line.
private struct PlaylistTile: View {
    @Environment(HubModel.self) private var model
    var name: String
    var detail: String
    var source: SourceKind?
    var artworkID: ArtworkID?
    /// A folder: the covers of the playlists inside it.
    var mosaic: [ArtworkID]? = nil
    var side: CGFloat
    var isPinned: Bool
    var playlistID: String
    var open: () -> Void
    @State private var activation = RowActivation()

    var body: some View {
        Button { activation.once(open) } label: {
            VStack(alignment: .leading, spacing: MC.Space.s) {
                if let mosaic {
                    FolderArtwork(artworkIDs: mosaic, side: side, maxPixel: 300)
                } else {
                    ArtworkView(data: model.artwork(artworkID, maxPixel: 400), size: side, radius: MC.Radius.medium)
                }
                VStack(alignment: .leading, spacing: MC.Space.xxs) {
                    Text(name)
                        .font(MC.Font.body)
                        .foregroundStyle(MC.Ink.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: MC.Space.xs) {
                        if source == .spotify { SourceMark(source: .spotify) }
                        if mosaic != nil {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(detail).monospacedDigit()
                    }
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(1)
                }
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source == .spotify ? "Play \(name) in Spotify" : "Open \(name)")
        .accessibilityAddTraits(mosaic != nil ? .isButton : [])
        .contextMenu {
            if source != .spotify { Button("Open", action: open) }
            Button("Play") { model.playPlaylist(playlistID) }
            Button("Shuffle") { model.playPlaylist(playlistID, shuffled: true) }
            Divider()
            if isPinned {
                Button("Unpin") { model.unpin(playlistID) }
            } else {
                Button("Pin to Top") { model.pin(playlistID) }
                    .disabled(model.pins.count >= PinnedPlaylist.limit)
            }
        }
        .accessibilityLabel(mosaic != nil ? "Folder \(name), \(detail)" : "\(name), \(detail)")
        .accessibilityHint(source == .spotify ? "Plays the playlist in Spotify" : "Opens the playlist")
    }
}

// MARK: Playlist detail

/// An open playlist: the way back, large artwork, its name and length, Play and Shuffle, then
/// its songs. A click on a song plays it and queues the rest.
private struct PlaylistDetail: View {
    @Environment(HubModel.self) private var model
    var playlist: PlaylistItem
    @State private var selection: String?
    @State private var activation = RowActivation()

    var body: some View {
        List(selection: $selection) {
            header
                .selectionDisabled()
                .sourceRow()
            ForEach(model.playlistTracks.items) { track in
                TrackRow(track: track, isCurrent: model.activeSource == .appleMusic && model.nowPlaying?.trackID == track.id)
                    .rowClick { play(track.id) }
                    .tag(track.id)
                    .sourceRow()
                    .onAppear { model.loadMoreIfNeeded(.playlist, after: track.id) }
            }
        }
        .sourceList()
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Play") { ids.first.map(play) }
            QueueMenuItems(tracks: model.playlistTracks.items.filter { ids.contains($0.id) }, source: .appleMusic)
        } primaryAction: { ids in
            ids.first.map(play)
        }
    }

    private func play(_ id: String) {
        activation.once { model.playTrack(id, context: .playlist(id: playlist.id)) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            Breadcrumb(path: model.playlistTree.path(to: playlist.id), current: nil)

            HStack(alignment: .bottom, spacing: MC.Space.l) {
                ArtworkView(data: model.artwork(playlist.artworkID, maxPixel: 600), size: 148, radius: MC.Radius.large)
                VStack(alignment: .leading, spacing: MC.Space.s) {
                    Text(playlist.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MC.Ink.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(songs(count))
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .monospacedDigit()
                    HStack(spacing: MC.Space.s) {
                        Button { model.playPlaylist(playlist.id) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .help("Play this playlist from the top")
                        Button { model.playPlaylist(playlist.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .help("Play this playlist in a random order")
                        let pinned = model.isPinned(playlist.id)
                        Button { pinned ? model.unpin(playlist.id) : model.pin(playlist.id) } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.borderless)
                        .help(pinned ? "Unpin" : "Pin to the top of the library")
                        .accessibilityLabel(pinned ? "Unpin" : "Pin to Top")
                    }
                    .padding(.top, MC.Space.xs)
                }
            }
        }
        .padding(.top, MC.Space.xs)
        .padding(.bottom, MC.Space.m)
    }

    private var count: Int { model.playlistTracks.totalCount ?? playlist.trackCount }
}

// MARK: Search

/// Songs and playlists matching the query, shown only while searching.
private struct LibrarySearchResults: View {
    @Environment(HubModel.self) private var model
    var query: String
    /// Ends the search, so what a result opened shows.
    var clear: () -> Void
    @State private var selection: String?
    @State private var activation = RowActivation()

    var body: some View {
        List(selection: $selection) {
            SourceIssueNotice(source: .appleMusic)
            if !playlists.isEmpty {
                SourceSectionTitle("Playlists", isFirst: true)
                ForEach(playlists) { playlist in
                    SearchPlaylistRow(name: playlist.name,
                                      detail: playlist.isFolder ? model.folderDetail(playlist) : songs(playlist.trackCount),
                                      artworkID: playlist.artworkID, isFolder: playlist.isFolder,
                                      within: model.playlistTree.path(to: playlist.id).map(\.name))
                        .rowClick { activation.once { openFromSearch(playlist) } }
                        .tag("playlist:" + playlist.id)
                        .sourceRow()
                }
            }
            if !spotifyPins.isEmpty {
                ForEach(spotifyPins) { pin in
                    SearchPlaylistRow(name: pin.name, detail: "Spotify", artworkID: pin.artworkID, source: .spotify)
                        .rowClick { activation.once { model.playPlaylist(pin.id) } }
                        .tag("playlist:" + pin.id)
                        .sourceRow()
                }
            }
            SourceSectionTitle("Songs", isFirst: playlists.isEmpty && spotifyPins.isEmpty)
            if model.searchResults.isLoaded && model.searchResults.items.isEmpty && spotifySongs.isEmpty {
                Text("No songs match \u{201C}\(query)\u{201D}.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
                    .selectionDisabled()
                    .sourceRow()
            }
            ForEach(spotifySongs) { track in
                TrackRow(track: track, isCurrent: model.activeSource == .spotify && model.nowPlaying?.trackID == track.id,
                         source: .spotify)
                    .rowClick { activation.once { model.playTrack(track.id, context: .spotifyHistory) } }
                    .tag(track.id)
                    .sourceRow()
            }
            ForEach(model.searchResults.items) { track in
                TrackRow(track: track, isCurrent: model.activeSource == .appleMusic && model.nowPlaying?.trackID == track.id)
                    .rowClick { play(track.id) }
                    .tag(track.id)
                    .sourceRow()
                    .onAppear { model.loadMoreIfNeeded(.search, after: track.id) }
            }
        }
        .sourceList()
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, id.hasPrefix("playlist:") {
                let pid = String(id.dropFirst("playlist:".count))
                Button("Play") { model.playPlaylist(pid) }
                Button("Shuffle") { model.playPlaylist(pid, shuffled: true) }
            } else if let id = ids.first, id.hasPrefix("spotify:track:") {
                Button("Play") { model.playTrack(id, context: .spotifyHistory) }
                QueueMenuItems(tracks: spotifySongs.filter { ids.contains($0.id) }, source: .spotify)
            } else {
                Button("Play") { ids.first.map(play) }
                QueueMenuItems(tracks: model.searchResults.items.filter { ids.contains($0.id) }, source: .appleMusic)
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if id.hasPrefix("playlist:") {
                let pid = String(id.dropFirst("playlist:".count))
                if let p = model.playlists.items.first(where: { $0.id == pid }) { openFromSearch(p) } else { model.playPlaylist(pid) }
            } else if id.hasPrefix("spotify:track:") {
                model.playTrack(id, context: .spotifyHistory)
            } else {
                play(id)
            }
        }
    }

    private func play(_ id: String) {
        activation.once { model.playTrack(id, context: .search(query: model.searchQuery)) }
    }

    /// A folder opens in place (its parent is where Back goes); a playlist opens inside its folder.
    private func openFromSearch(_ item: PlaylistItem) {
        if item.isFolder {
            model.openFolder(item.id)
        } else {
            model.openFolder(item.parentID)
            model.showPlaylist(item)
        }
        clear()
    }

    private var playlists: [PlaylistItem] {
        model.playlists.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var spotifyPins: [PinnedPlaylist] {
        model.spotifyPins.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var spotifySongs: [TrackItem] {
        model.spotifySessionSongs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct SearchPlaylistRow: View {
    @Environment(HubModel.self) private var model
    var name: String
    var detail: String
    var artworkID: ArtworkID?
    var source: SourceKind? = nil
    var isFolder = false
    /// The folders it sits in, top first.
    var within: [String] = []

    var body: some View {
        HStack(spacing: MC.Space.m) {
            if isFolder {
                FolderArtwork(artworkIDs: [], side: 32, maxPixel: 100)
            } else {
                ArtworkView(data: model.artwork(artworkID), size: 32, radius: MC.Radius.small)
            }
            VStack(alignment: .leading, spacing: MC.Space.xxs) {
                Text(name).font(MC.Font.body).foregroundStyle(MC.Ink.primary).lineLimit(1)
                HStack(spacing: MC.Space.xs) {
                    if let source { SourceMark(source: source) }
                    Text(within.isEmpty ? detail : "\(detail) \u{00B7} in \(within.joined(separator: " \u{203A} "))")
                        .monospacedDigit()
                }
                .font(MC.Font.caption).foregroundStyle(MC.Ink.secondary)
            }
            Spacer(minLength: MC.Space.s)
        }
        .padding(.vertical, MC.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Folders

/// Playlists › Folder › Folder: every step but the current one goes back there.
private struct Breadcrumb: View {
    @Environment(HubModel.self) private var model
    var path: [PlaylistItem]
    /// The open folder, shown last and not clickable; nil inside a playlist.
    var current: PlaylistItem?

    var body: some View {
        HStack(spacing: MC.Space.xs) {
            Button { go(nil) } label: {
                Label("Playlists", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to playlists")
            ForEach(path) { folder in
                separator
                Button(folder.name) { go(folder.id) }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
            }
            if let current {
                separator
                Text(current.name)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .font(MC.Font.body)
        .background {
            Button("Back") { back() }
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(MC.Ink.tertiary)
            .accessibilityHidden(true)
    }

    private func go(_ folderID: String?) {
        model.openFolder(folderID)
    }

    /// Command-[ goes one step up: out of a playlist into its folder, or out of a folder into
    /// its parent; `path` ends with exactly that folder (or is empty: the top).
    private func back() { model.openFolder(path.last?.id) }
}

/// Above an open folder: the breadcrumb, then the folder with Play and Shuffle (everything
/// inside it, as Music plays a folder).
private struct FolderHeader: View {
    @Environment(HubModel.self) private var model
    var folder: PlaylistItem
    var path: [PlaylistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Space.m) {
            Breadcrumb(path: path, current: folder)
            HStack(alignment: .bottom, spacing: MC.Space.l) {
                FolderArtwork(artworkIDs: model.playlistTree.mosaic(for: folder.id), side: 112, maxPixel: 400)
                VStack(alignment: .leading, spacing: MC.Space.s) {
                    Text(folder.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MC.Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Folder \u{00B7} \(model.folderDetail(folder))")
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .monospacedDigit()
                    HStack(spacing: MC.Space.s) {
                        Button { model.playPlaylist(folder.id) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .help("Play every playlist in this folder")
                        Button { model.playPlaylist(folder.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .help("Play everything in this folder in a random order")
                    }
                    .padding(.top, MC.Space.xs)
                }
            }
        }
        .padding(.top, MC.Space.xs)
    }
}
