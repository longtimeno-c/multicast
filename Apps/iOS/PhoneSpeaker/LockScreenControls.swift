import Foundation
import MediaPlayer
import MulticastHubModel
import Observation
import UIKit

/// The hub's current item on this iPhone's lock screen and in Control Centre, with play/pause,
/// next, previous and the scrubber sent to the Mac as hub commands.
///
/// Only while "This iPhone" is on. iOS shows these controls for the app that is playing audio,
/// and keeps that app running with the screen locked; as a speaker the app is exactly that, so
/// the link to the Mac stays up and what is shown stays current. As a remote alone the app
/// plays nothing, iOS suspends it, and there is nothing honest to show.
///
/// What to show and which controls are live is `LockScreenPlayback` (MulticastHubModel, unit
/// tested); this class copies it into `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
@MainActor
final class LockScreenControls {
    private weak var session: RemoteSession?
    private var installed: [(command: MPRemoteCommand, target: Any)] = []
    /// What the system was last told, so the same state isn't published twice.
    private var shown: LockScreenPlayback?
    private var shownArtwork: ArtworkID?
    /// The current item's picture, decoded once per track.
    private var artwork: (id: ArtworkID, item: MPMediaItemArtwork)?

    /// The size artwork is asked for: the full player's, so both share one cached copy.
    private static let artworkPixels = HubModel.defaultArtworkPixels

    func start(session: RemoteSession) {
        guard self.session == nil else { return }
        self.session = session
        install()
        refresh()
    }

    // MARK: State → system

    /// Reads what to show, publishes it, and runs again when anything it read changes.
    private func refresh() {
        guard let session else { return }
        let reading = withObservationTracking {
            Self.read(session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        publish(reading.playback, artwork: reading.artwork)
    }

    private static func read(_ session: RemoteSession) -> (playback: LockScreenPlayback?, artwork: Data?) {
        guard session.phoneSpeaker.isOn, let model = session.model,
              let playback = LockScreenPlayback(nowPlaying: model.nowPlaying, transport: model.transport,
                                                source: model.activeSource, at: .now) else { return (nil, nil) }
        // Asks the hub on a miss; the model's artwork cache moving re-runs `refresh`.
        return (playback, model.artwork(playback.artworkID, maxPixel: artworkPixels))
    }

    private func publish(_ playback: LockScreenPlayback?, artwork data: Data?) {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        guard let playback else {
            if shown != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            shown = nil
            shownArtwork = nil
            artwork = nil
            enable(.none, in: commands)
            return
        }

        if artwork?.id != playback.artworkID { artwork = nil }
        if artwork == nil, let id = playback.artworkID, let data, let item = Self.makeArtwork(data) {
            artwork = (id, item)
        }
        if let shown, playback.continues(shown), shownArtwork == artwork?.id { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playback.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playback.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: playback.isLive,
        ]
        if let artist = playback.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = playback.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = playback.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let elapsed = playback.elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork.item }
        center.nowPlayingInfo = info
        center.playbackState = playback.isPlaying ? .playing : .paused
        enable(playback.commands, in: commands)
        shown = playback
        shownArtwork = artwork?.id
    }

    private func enable(_ on: LockScreenPlayback.Commands, in commands: MPRemoteCommandCenter) {
        commands.playCommand.isEnabled = on.playPause
        commands.pauseCommand.isEnabled = on.playPause
        commands.togglePlayPauseCommand.isEnabled = on.playPause
        commands.nextTrackCommand.isEnabled = on.next
        commands.previousTrackCommand.isEnabled = on.previous
        commands.changePlaybackPositionCommand.isEnabled = on.seek
    }

    /// The system calls the image closure off the main thread, so it is built outside the main
    /// actor and captures only the decoded image.
    nonisolated private static func makeArtwork(_ data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: System → hub

    private func install() {
        let commands = MPRemoteCommandCenter.shared()
        add(commands.playCommand) { _ in .play }
        add(commands.pauseCommand) { _ in .pause }
        add(commands.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(commands.nextTrackCommand) { _ in .next }
        add(commands.previousTrackCommand) { _ in .previous }
        add(commands.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(position: $0.positionTime) }
        }
        enable(.none, in: commands)
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @Sendable (MPRemoteCommandEvent) -> LockScreenPlayback.Action?) {
        let target = command.addTarget { [weak self] event in
            // Remote command handlers run on the main thread.
            MainActor.assumeIsolated {
                guard let self, let action = action(event) else { return .commandFailed }
                return self.perform(action)
            }
        }
        installed.append((command, target))
    }

    /// Decided against the state as it is now, then sent the way a tap in the app is: through
    /// the hub model, which shows the result at once and rolls back if the Mac refuses.
    private func perform(_ action: LockScreenPlayback.Action) -> MPRemoteCommandHandlerStatus {
        guard let session, session.phoneSpeaker.isOn, let model = session.model,
              let playback = LockScreenPlayback(nowPlaying: model.nowPlaying, transport: model.transport,
                                                source: model.activeSource, at: .now) else { return .noActionableNowPlayingItem }
        guard let command = playback.command(for: action) else {
            // Play while playing (or Pause while paused) is already so; anything else is refused.
            switch action {
            case .play, .pause: return .success
            default: return .commandFailed
            }
        }
        switch command {
        case .play, .pause: model.togglePlayPause()
        case .next: model.next()
        case .previous: model.previous()
        case .seek(let position): model.seek(to: position)
        default: return .commandFailed
        }
        return .success
    }
}
