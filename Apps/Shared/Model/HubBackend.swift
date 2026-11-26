import Foundation

// MARK: - The backend seam
//
// `HubBackend` is the only thing the UI talks to. `MockHubBackend` implements it today; the real
// one will wrap MulticastKit (discovery, RAOP sinks, local outputs, capture sources, the engine)
// and translate into the value types in HubTypes.swift. The iOS remote implements it too, as a
// network client of the Mac hub, which is why state comes in small slices and artwork by id.
//
// Contract for implementers:
//  - Each `…States()` call returns an independent stream that yields the slice's current value
//    at once, then again whenever that slice changes (and only then). Finish it on shutdown.
//    Slices: speakers + master (changes at drag rate), playback, sources (library, files, apps,
//    Spotify; large, rare), status (reachability and permissions). Levels stream separately at
//    about 20 Hz while audio flows and send one `.silent` when it stops.
//  - Artwork is referenced by `ArtworkID`; `artwork(id:)` returns the encoded image once and the
//    model caches it, so no slice ever carries image bytes.
//  - Commands arrive in order, one at a time (the model serialises them). They return once the
//    request is accepted, not when it completes: enabling a speaker returns at once and the
//    speaker then moves through `.connecting` to `.playing` or `.failed(reason:)`.
//  - Speaker failures belong in the speaker's state, not in a thrown error. Throw only when a
//    request can't be accepted at all; the model then rolls back its optimistic change to the
//    last published state and shows the error for transport and source commands.
//  - Volume and trim arrive at most every 50 ms during a drag plus a final value. Echo the value
//    you applied in the next speakers slice; the model holds its own value until the echo
//    matches (or 500 ms pass), so the slider never snaps back under the pointer.
//  - Volume and trim are legal while a speaker is off: they are its preset, applied on connect.
//  - Volumes are 0…1. A speaker plays at its own volume × the master.
protocol HubBackend: AnyObject, Sendable {
    func speakerStates() async -> AsyncStream<SpeakersState>
    func playbackStates() async -> AsyncStream<PlaybackState>
    func sourceStates() async -> AsyncStream<SourcesState>
    func statusStates() async -> AsyncStream<HubStatus>
    func levels() async -> AsyncStream<StereoLevels>
    func artwork(id: ArtworkID) async -> Data?

    // Transport
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws

    // Sources
    func selectSource(_ source: SourceKind) async throws
    func playTrack(id: String) async throws
    func playPlaylist(id: String) async throws
    func captureApp(bundleID: String) async throws
    func addFiles(_ urls: [URL]) async throws
    func openSpotify() async throws
    /// Shows the system prompt, or reports `.denied` so the UI can send people to Settings.
    func requestPermission(_ permission: HubPermission) async throws

    // Speakers
    func setSpeaker(_ id: SpeakerID, enabled: Bool) async throws
    func setSpeaker(_ id: SpeakerID, volume: Double) async throws
    func setSpeaker(_ id: SpeakerID, syncTrimMs: Int) async throws
    func retrySpeaker(_ id: SpeakerID) async throws
    func setMasterVolume(_ volume: Double) async throws
}
