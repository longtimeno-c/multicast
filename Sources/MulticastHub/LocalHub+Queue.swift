import Foundation
import MulticastHubModel

/// The last thing the owning app said about the queue's current song.
struct QueueSample: Equatable, Sendable {
    var position: TimeInterval
    var asOf: Date
    var isPlaying: Bool
    var duration: TimeInterval?

    func position(at now: Date) -> TimeInterval {
        let p = position + (isPlaying ? max(0, now.timeIntervalSince(asOf)) : 0)
        return duration.map { min($0, p) } ?? p
    }
}

// MARK: - The hub's play queue
//
// One `PlayQueue` holds Apple Music, Spotify and file songs together. The hub plays the current
// entry with whichever app owns it, switching the captured source as it goes (the speakers stay
// selected throughout), and starts the next entry when the current one ends:
//
//  - Apple Music: the Music app plays one library track and stops (`playOnce`), so Music never
//    carries on into its own Up Next.
//  - Spotify: `play track "spotify:track:…"`.
//  - Files: the file source, gapless from one queued file to the next.
//
// The end of a song is found two ways, whichever comes first: a timer at the end extrapolated
// from the app's last report, and `QueueAdvancePolicy` applied to every report (stopped,
// paused at the end, or moved on by itself). A report of another song well before the end means
// someone played something in Music or Spotify directly: the queue is held (the hub follows that
// app as before) until Next or a choice in Up Next carries on. After the last song, playback
// stops.
extension LocalHub {
    var queueDriving: Bool { playQueue.current != nil && !queueHeld }

    /// While the queue is starting or changing songs, the app's own play/pause reports are not
    /// followed (they still describe the song before).
    var queueSuppressesFollow: Bool {
        guard queueDriving else { return false }
        return queueAdvancing || deps.now().timeIntervalSince(queueStartedAt) < QueueAdvancePolicy.startGrace
    }

    func renderQueue() -> QueueStatus {
        QueueStatus(currentID: queueHeld ? nil : playQueue.current?.id,
                    currentSource: queueHeld ? nil : playQueue.current?.source,
                    upcomingCount: playQueue.upcoming.count,
                    isHeld: queueHeld && !playQueue.upcoming.isEmpty)
    }

    func queuePage(_ page: PageRequest) -> Page<QueueItem> { .slice(playQueue.upcoming, page) }

    func queueMintedArtwork(_ id: ArtworkID) -> Bool {
        if settings.pins.contains(where: { $0.artworkID == id }) { return true }
        if playQueue.current?.track.artworkID == id { return true }
        return playQueue.upcoming.contains { $0.track.artworkID == id } || playQueue.history.contains { $0.track.artworkID == id }
    }

    /// Spotify's current song first, then the earlier ones this session.
    func spotifyHistoryListed() -> [TrackItem] {
        guard let np = spotifyNow, np.hasTrack else { return spotifyHistory }
        let now = spotifyTrack(np)
        return [now] + spotifyHistory.filter { $0.id != now.id }
    }

    private func queueChanged() {
        content.upNext &+= 1
        publish()
    }

    // MARK: Commands

    /// Play with nothing chosen yet and songs queued: the queue starts.
    func queueAwarePlay() async throws {
        if activeSource == nil || (playQueue.current == nil && !queueHeld && !wantsPlay), !playQueue.upcoming.isEmpty {
            guard let next = playQueue.advance() else { return }
            queueHeld = false
            try await startQueueEntry(next, flush: true)
            return
        }
        try await play()
    }

    /// Next / Previous go through the queue whenever it has somewhere to go.
    func queueSkip(forward: Bool) async throws {
        if forward {
            if !playQueue.upcoming.isEmpty, let next = playQueue.advance() {
                queueHeld = false
                try await startQueueEntry(next, flush: true)
                return
            }
            if queueDriving {
                await finishPlayQueue()
                return
            }
        } else if queueDriving, let current = playQueue.current {
            if queuedPosition() > configuration.restartThreshold || playQueue.history.isEmpty {
                try await restartQueueEntry(current)
            } else if let previous = playQueue.goBack() {
                try await startQueueEntry(previous, flush: true)
            }
            return
        }
        try await skip(forward: forward)
    }

    private func queuedPosition() -> TimeInterval {
        guard let current = playQueue.current else { return 0 }
        switch current.source {
        case .files: return currentPosition()
        default: return queueSample?.position(at: deps.now()) ?? 0
        }
    }

    private func restartQueueEntry(_ e: QueueItem) async throws {
        switch e.source {
        case .appleMusic, .files: try await seek(to: 0)
        default: try await startQueueEntry(e, flush: true)
        }
    }

    func queuePlayTrack(id: String, context: TrackContext) async throws {
        switch context {
        case .upNext:
            guard let entry = playQueue.jump(to: id) else {
                throw HubCommandError(.notFound, "That song is no longer in Up Next.")
            }
            queueHeld = false
            try await startQueueEntry(entry, flush: true)
            return
        case .files:
            guard queue.entry(id: id) != nil else { throw HubCommandError(.notFound, "That file is no longer in the list.") }
            playQueue.play(queue.tracks, source: .files, startingAt: id)
        case .spotifyHistory:
            let list = spotifyHistoryListed().filter { $0.id.hasPrefix("spotify:track:") }
            guard playQueue.play(list, source: .spotify, startingAt: id) else {
                throw HubCommandError(.notFound, "Spotify didn\u{2019}t say which song that was, so it can\u{2019}t be played again.")
            }
        case .songs, .playlist, .search:
            let player = try requireMusicPlayer()
            let list: [TrackItem]
            switch context {
            case .playlist(let pid): list = try await Self.collect { try await player.tracks(inPlaylist: pid, $0) }
            case .search(let q): list = try await Self.collect { try await player.search(q, $0) }
            default: list = try await Self.collect { try await player.songs($0) }
            }
            guard playQueue.play(list, source: .appleMusic, startingAt: id) else {
                throw HubCommandError(.notFound, "That song is no longer in your library.")
            }
        }
        queueHeld = false
        guard let current = playQueue.current else { return }
        try await startQueueEntry(current, flush: true)
    }

    func queuePlayPlaylist(id: String, shuffled: Bool) async throws {
        if id.hasPrefix("spotify:") {
            try await playSpotifyContext(id, shuffled: shuffled)
            return
        }
        let player = try requireMusicPlayer()
        let list = try await Self.collect { try await player.tracks(inPlaylist: id, $0) }
        guard !list.isEmpty else { throw HubCommandError(.unavailable, "That playlist is empty.") }
        var rng = SystemRandomNumberGenerator()
        playQueue.play(list, source: .appleMusic, shuffled: shuffled, using: &rng)
        queueHeld = false
        guard let current = playQueue.current else { return }
        try await startQueueEntry(current, flush: true)
    }

    /// A Spotify playlist plays in Spotify (its songs can't be listed without a Client ID): the
    /// queue waits, as it does when Spotify is played directly.
    private func playSpotifyContext(_ uri: String, shuffled: Bool) async throws {
        try await ensureSpotifyOpen()
        if activeSource != .spotify { try await selectSource(.spotify) }
        holdQueue()
        wantsPlay = hasPlayableSpeaker
        let spotify = deps.spotify
        try await mediaCommand { try await spotify.play(uri: uri, shuffled: shuffled) }
        publish()
        enqueue { [self] in
            await self.reanchor()
            await self.reconcileAndPublish()
        }
        if !hasPlayableSpeaker { throw HubCommandError(.unavailable, Self.needsSpeaker) }
    }

    func addToQueue(_ tracks: [TrackItem], source: SourceKind, placement: QueuePlacement) throws {
        let accepted: [TrackItem]
        switch source {
        case .appleMusic:
            _ = try requireMusicPlayer()
            accepted = tracks
        case .spotify:
            accepted = tracks.filter { SpotifyLink.trackURI(from: $0.id) == $0.id }
            guard !accepted.isEmpty || tracks.isEmpty else {
                throw HubCommandError(.notFound, "Spotify didn\u{2019}t say which song that was, so it can\u{2019}t be queued.")
            }
        case .files:
            accepted = tracks.compactMap { queue.entry(id: $0.id)?.track }
        case .app:
            throw HubCommandError(.unsupported, "A captured app can\u{2019}t be queued.")
        }
        guard !accepted.isEmpty else { return }
        playQueue.insert(accepted, source: source, at: placement)
        queueChanged()
    }

    func addSpotifyLink(_ link: String, placement: QueuePlacement) async throws {
        guard let uri = SpotifyLink.trackURI(from: link) else {
            throw HubCommandError(.notFound, "That isn\u{2019}t a link to a Spotify song.")
        }
        var track = spotifyHistoryListed().first { $0.id == uri }
        if track == nil {
            let embed = await SpotifyLink.webURL(forURI: uri).asyncFlatMap { await self.deps.system.spotifyEmbed(for: $0) }
            track = TrackItem(id: uri, title: embed?.title ?? "Spotify song", artist: "Spotify", album: "", duration: 0,
                              artworkID: embed?.thumbnailURL.map { "hub.url:\($0.absoluteString)" })
        }
        guard let track else { return }
        playQueue.insert([track], source: .spotify, at: placement)
        queueChanged()
    }

    func removeFromQueue(_ ids: [String]) {
        playQueue.remove(ids: Set(ids))
        queueChanged()
    }

    func moveInQueue(_ ids: [String], toOffset offset: Int) {
        playQueue.move(ids: ids, toOffset: offset)
        queueChanged()
    }

    func clearQueue() {
        playQueue.clearUpcoming()
        queueHeld = false
        queueChanged()
    }

    /// Someone chose a source or an app themselves: the queue waits.
    func holdQueue() {
        guard playQueue.current != nil || !playQueue.upcoming.isEmpty else { return }
        playQueue.dropCurrent()
        queueHeld = true
        queueAdvancing = false
        queueEndTimer?.cancel()
        queueEndTimer = nil
        queueChanged()
    }

    /// Removed files leave the queue too.
    func dropQueuedFiles(_ ids: Set<String>) {
        let gone = Set(playQueue.upcoming.filter { $0.source == .files && ids.contains($0.track.id) }.map(\.id))
        guard !gone.isEmpty else { return }
        playQueue.remove(ids: gone)
        content.upNext &+= 1
    }

    static func collect(limit: Int = 10_000, _ load: (PageRequest) async throws -> Page<TrackItem>) async throws -> [TrackItem] {
        var out: [TrackItem] = []
        var request = PageRequest(limit: 500)
        while out.count < limit {
            let page = try await load(request)
            out += page.items
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            request = PageRequest(cursor: next, limit: 500)
        }
        return out
    }

    // MARK: Starting entries

    private func ensureSpotifyOpen() async throws {
        guard deps.apps.isInstalled(Self.spotifyBundleID) else {
            throw HubCommandError(.unavailable, "Spotify isn\u{2019}t installed on this Mac.")
        }
        if deps.apps.isRunning(Self.spotifyBundleID) { return }
        do { try await deps.apps.launch(Self.spotifyBundleID) } catch {
            throw HubCommandError(.failed, "Spotify didn\u{2019}t open.")
        }
        for _ in 0..<60 where !deps.apps.isRunning(Self.spotifyBundleID) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refreshApps()
        guard deps.apps.isRunning(Self.spotifyBundleID) else {
            throw HubCommandError(.unavailable, "Spotify didn\u{2019}t finish opening.")
        }
    }

    /// Plays `entry` (already current) with its app. `flush` drops audio already sent to the
    /// speakers: wanted when someone skips, not when a song ends by itself.
    func startQueueEntry(_ entry: QueueItem, flush: Bool) async throws {
        queueEndTimer?.cancel()
        queueEndTimer = nil
        queueSample = nil
        queueStartedAt = deps.now()
        queueAdvancing = true
        defer { queueAdvancing = false }
        content.upNext &+= 1
        let speakers = hasPlayableSpeaker
        do {
            switch entry.source {
            case .appleMusic:
                let player = try requireMusicPlayer()
                if activeSource != .appleMusic { try await selectSource(.appleMusic) }
                wantsPlay = speakers
                try await player.playOnce(trackID: entry.track.id)
            case .spotify:
                try await ensureSpotifyOpen()
                if activeSource != .spotify { try await selectSource(.spotify) }
                wantsPlay = speakers
                let spotify = deps.spotify
                try await mediaCommand { try await spotify.play(uri: entry.track.id, shuffled: nil) }
            case .files:
                if activeSource != .files { leaveActiveSource() }
                guard queue.select(id: entry.track.id) else {
                    throw HubCommandError(.notFound, "That file is no longer in the list.")
                }
                activeSource = .files
                wantsPlay = speakers
                try await loadCurrentFile()
            case .app:
                throw HubCommandError(.unsupported, "A captured app can\u{2019}t be queued.")
            }
        } catch {
            // The song can't play: leave it, stopped, so the person sees what failed.
            wantsPlay = false
            publish()
            enqueue { [self] in await self.reconcileAndPublish() }
            throw error
        }
        queueStartedAt = deps.now()
        publish()
        enqueue { [self] in
            if flush, entry.source != .files { await self.reanchor() }
            await self.reconcileAndPublish()
        }
        if !speakers { throw HubCommandError(.unavailable, Self.needsSpeaker) }
    }

    /// The last song ended: stop (the media app too, so Spotify's autoplay stays quiet).
    func finishPlayQueue() async {
        queueEndTimer?.cancel()
        queueEndTimer = nil
        queueSample = nil
        let source = activeSource
        playQueue.advance()
        wantsPlay = false
        freezePosition()
        content.upNext &+= 1
        publish()
        enqueue { [self] in
            await self.pauseMediaApp(source)
            await self.reconcileAndPublish()
        }
    }

    /// The current song ended by itself.
    private func queueEntryEnded(_ endedID: String) async {
        guard queueDriving, playQueue.current?.id == endedID, !queueAdvancing else { return }
        if playQueue.upcoming.isEmpty {
            await finishPlayQueue()
            return
        }
        guard let next = playQueue.advance() else { return }
        do { try await startQueueEntry(next, flush: false) } catch {
            // A song that can't play (gone from the library, Spotify closed) is skipped once.
            if let after = playQueue.upcoming.first, after.id != next.id {
                await queueEntryEnded(next.id)
            }
        }
    }

    // MARK: Watching the owning app

    /// Called with every Apple Music and Spotify report, before the hub follows its play state.
    func queueObserve() {
        guard queueDriving, let current = playQueue.current,
              current.source == activeSource, current.source == .appleMusic || current.source == .spotify,
              !queueAdvancing else { return }
        let now = deps.now()
        let observation: QueuePlayerObservation
        let sample: QueueSample
        switch current.source {
        case .appleMusic:
            let s = musicStatus
            let state: QueuePlayerObservation.State = s.isPlaying ? .playing : (s.nowPlaying == nil ? .stopped : .paused)
            observation = QueuePlayerObservation(state: state, trackID: s.nowPlaying?.trackID,
                                                 position: s.position, duration: s.nowPlaying?.duration)
            sample = QueueSample(position: s.position, asOf: s.positionAsOf, isPlaying: s.isPlaying, duration: s.nowPlaying?.duration)
        default:
            guard let np = spotifyNow else { return }
            let state: QueuePlayerObservation.State = switch np.state {
            case .playing: .playing
            case .stopped: .stopped
            default: .paused
            }
            observation = QueuePlayerObservation(state: state, trackID: np.trackID, position: np.position ?? 0, duration: np.duration)
            sample = QueueSample(position: np.position ?? 0, asOf: np.sampledAt, isPlaying: np.state == .playing, duration: np.duration)
        }
        let decision = QueueAdvancePolicy.decide(
            expectedTrackID: current.track.id, observation: observation,
            lastPosition: queueSample?.position(at: now), lastDuration: queueSample?.duration,
            sinceStart: now.timeIntervalSince(queueStartedAt), hasStarted: queueSample != nil)
        switch decision {
        case .wait:
            if observation.trackID == current.track.id {
                queueSample = sample
                scheduleQueueEnd(for: current, sample: sample)
            }
        case .ended:
            queueAdvancing = false
            let id = current.id
            queueAdvancing = true
            enqueueQueueEnd(id)
        case .externalTakeover:
            holdQueue()
        }
    }

    private func enqueueQueueEnd(_ id: String) {
        // Off the report's call stack: the follow-up logic of this report must see
        // `queueAdvancing` and leave play state alone.
        Task { [weak self] in
            await self?.clearAdvancingAndEnd(id)
        }
    }

    private func clearAdvancingAndEnd(_ id: String) async {
        queueAdvancing = false
        await queueEntryEnded(id)
    }

    /// A timer at the extrapolated end, so the next song starts without waiting for a poll.
    /// Spotify is cut a moment early (or it would start its own autoplay); Music stops by itself.
    private func scheduleQueueEnd(for entry: QueueItem, sample: QueueSample) {
        queueEndTimer?.cancel()
        queueEndTimer = nil
        guard sample.isPlaying, let d = sample.duration, d > 0 else { return }
        let remaining = max(0, d - sample.position(at: deps.now()))
        let lead: TimeInterval = entry.source == .spotify ? -0.25 : 0.25
        let wait = max(0, remaining + lead)
        let id = entry.id
        queueEndTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            guard !Task.isCancelled else { return }
            await self?.queueTimerFired(id)
        }
    }

    private func queueTimerFired(_ id: String) async {
        guard queueDriving, playQueue.current?.id == id, let s = queueSample, s.isPlaying,
              let d = s.duration, s.position(at: deps.now()) >= d - 0.5 else { return }
        await queueEntryEnded(id)
    }

    /// A file ended while the queue plays files: the next queued file continues on the same
    /// timeline; anything else starts once the tail has been heard. Returns false when the
    /// queue isn't playing files (the Files source then carries on by itself).
    func queueHandlesFileEnd(audibleIn delay: TimeInterval) -> Bool {
        guard queueDriving, let current = playQueue.current, current.source == .files else { return false }
        if let next = playQueue.upcoming.first, next.source == .files, queue.select(id: next.track.id),
           let entry = queue.current {
            playQueue.advance()
            content.upNext &+= 1
            queueStartedAt = deps.now()
            setPosition(0, audibleIn: delay)
            publish()
            enqueue { [self] in
                do {
                    let source = try await self.deps.sources.openFile(entry.url)
                    await self.applyEngineSource(source, kind: .files)
                } catch {
                    await self.fileFailedToOpen()
                }
            }
            return true
        }
        let id = current.id
        let wait = UInt64(max(0, delay) * 1e9)
        endingTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            guard !Task.isCancelled else { return }
            await self?.fileQueueEntryEnded(id)
        }
        return true
    }

    private func fileQueueEntryEnded(_ id: String) async {
        endingTask = nil
        await queueEntryEnded(id)
        if !queueDriving, activeSource == .files {
            queue.rewind()
            fileNeedsReload = true
            setPosition(0)
            await deps.session.stop()
            publish()
        }
    }

    // MARK: Pinned playlists

    var pins: [PinnedPlaylist] { settings.pins }

    func pinPlaylist(id: String) async throws {
        guard !settings.pins.contains(where: { $0.id == id }) else { return }
        guard settings.pins.count < PinnedPlaylist.limit else {
            throw HubCommandError(.unavailable, "Unpin a playlist first (up to \(PinnedPlaylist.limit)).")
        }
        let player = try requireMusicPlayer()
        var request = PageRequest(limit: 500)
        var found: PlaylistItem?
        for _ in 0..<10 {
            let page = try await player.playlists(request)
            if let p = page.items.first(where: { $0.id == id }) { found = p; break }
            guard let next = page.nextCursor else { break }
            request = PageRequest(cursor: next, limit: 500)
        }
        guard let p = found else { throw HubCommandError(.notFound, "That playlist is no longer in your library.") }
        settings.pins.append(PinnedPlaylist(id: p.id, source: .appleMusic, name: p.name, artworkID: p.artworkID, trackCount: p.trackCount))
        deps.settings.save(settings)
        publish()
    }

    func pinSpotifyLink(_ link: String) async throws {
        guard let uri = SpotifyLink.playlistURI(from: link) else {
            throw HubCommandError(.notFound, "That isn\u{2019}t a link to a Spotify playlist.")
        }
        guard !settings.pins.contains(where: { $0.id == uri }) else { return }
        guard settings.pins.count < PinnedPlaylist.limit else {
            throw HubCommandError(.unavailable, "Unpin a playlist first (up to \(PinnedPlaylist.limit)).")
        }
        let embed = await SpotifyLink.webURL(forURI: uri).asyncFlatMap { await self.deps.system.spotifyEmbed(for: $0) }
        settings.pins.append(PinnedPlaylist(id: uri, source: .spotify, name: embed?.title ?? "Spotify playlist",
                                            artworkID: embed?.thumbnailURL.map { "hub.url:\($0.absoluteString)" }))
        deps.settings.save(settings)
        publish()
    }

    func unpinPlaylist(id: String) {
        guard settings.pins.contains(where: { $0.id == id }) else { return }
        settings.pins.removeAll { $0.id == id }
        deps.settings.save(settings)
        publish()
    }
}

extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async -> U?) async -> U? {
        guard let self else { return nil }
        return await transform(self)
    }
}
