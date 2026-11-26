import MulticastAudio
import MulticastHubModel

// The hub's Apple Music player: library, playlists, search and up next as paged hub lists,
// transport and now playing, and the sound as a capture `AudioSource`.
//
// Two backends behind `AppleMusicProviding`:
//  - `MusicAppPlayer` drives the system Music app with Apple Events and taps the Music process.
//    Needs Automation (Music) and System Audio Recording; no developer team. Proven path: see
//    `MusicAppCaptureProbe`.
//  - `MusicKitPlayer` uses MusicKit's `ApplicationMusicPlayer` in-process. Needs the app signed
//    under the MusicKit-enabled team and the Apple Music permission; which process renders its
//    audio is what `MusicKitRenderProbe` measures. Not proven yet.
//
// DRM: neither backend ever sees decoded samples from Apple's APIs. The sound is read from the
// rendering process with a Core Audio process tap (`AppAudioTapSource`), muted on the Mac while
// Multicast reads it, then played on every selected speaker in sync like any other source.
public enum MulticastAppleMusicModule {
    public static let isImplemented = true
}
