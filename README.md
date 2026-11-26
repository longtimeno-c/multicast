# Multicast

One audio stream, played in sync on every speaker in the house: AirPlay 1, AirPlay 2 and local/Bluetooth
outputs, the way iTunes for Windows used to. The Mac is the hub: it plays Apple Music, captures Spotify or any
other app, or plays DRM-free files, and sends the sound to the speakers you pick. An iPhone app is its remote,
like the old iTunes Remote: speakers, per-speaker volume and sync trim, master volume, transport, now playing,
choice of source and the Apple Music library, all on the Mac.

Apple frameworks only; no third-party code.

## Architecture

```
iPhone: Multicast Remote ── HubModel ── RemoteHubBackend ─┐  Bonjour _multicast-hub._tcp,
Mac:    Multicast (window, menu bar) ── HubModel ─────────┤  6-digit pairing, ChaCha20-Poly1305 session
                                                          ▼
        HubServer ──► LocalHub (HubBackend) ──► MulticastSession ──► MulticastEngine (pacer + fan-out)
                        │  sources: Files, Spotify / any app (process taps), Apple Music (Music app)
                        └─ speakers: SpeakerDirectory ──► RAOP sinks (AirPlay 1/2) + Core Audio sinks
```

- `MulticastHubModel` is the seam: UI value types, `HubState`, the Codable `HubCommand`/`HubQuery` vocabulary and the
  `HubBackend` protocol. Every UI (Mac window, menu bar, iPhone) talks only to a `HubBackend`.
- `LocalHub` (`MulticastHub`) is the real backend on the Mac; `RemoteHubBackend` (`MulticastRemote`) is the same
  protocol over the network; `MockHubBackend` (`Apps/Shared/Mock`) drives previews and snapshots.
- `HubServer` serves one `HubBackend` to any number of paired remotes.

## Modules

- `Sources/MulticastAudio` — contracts shared by every module (PCM format, timeline, source/sink protocols)
- `Sources/MulticastDiscovery` — Bonjour discovery of AirPlay speakers
- `Sources/MulticastRAOP` — AirPlay (RAOP) sender; AirPlay 2 devices are driven over RAOP after `POST /auth-setup`
- `Sources/MulticastLocalOutput` — local and Bluetooth outputs
- `Sources/MulticastSources` — tone, file and app-audio capture sources
- `Sources/MulticastEngine` — pacing clock and fan-out
- `Sources/MulticastKit` — `SpeakerDirectory`, `SinkFactory` and `MulticastSession` (the façade over all of the above)
- `Sources/MulticastHubModel` — the UI seam described above (no dependencies; macOS and iOS)
- `Sources/MulticastHub` — `LocalHub`, the hub backend; `AppleMusicHubPlayer` connects the Apple Music player to it
- `Sources/MulticastAppleMusic` — Apple Music for the hub: `MusicAppPlayer` (the Music app over Apple Events, the
  default) and `MusicKitPlayer` (MusicKit, unproven, see Limitations)
- `Sources/MulticastRemote` — `HubServer`, `RemoteHubBackend`, `HubBrowser`, pairing and the encrypted session
- `Sources/multicast-cli` — play to speakers from the command line
- `Sources/multicast-hub` — the hub without its window (same `LocalHub` and `HubServer` as the app)
- `Sources/multicast-remote-cli` — a scripted remote: pairs and drives a hub like the iPhone app does
- `Sources/raop-probe` — low-level RAOP test tool

```bash
swift build
swift test
```

## Apps

`Apps/Multicast.xcodeproj` has two targets. Per-target settings (bundle id, Info.plist, entitlements, signing,
deployment target) live in `Apps/Config/Mac.xcconfig` and `Apps/Config/iOS.xcconfig`.

```bash
# The Mac hub app
xcodebuild -project Apps/Multicast.xcodeproj -scheme Multicast -derivedDataPath .build-xcode build
open .build-xcode/Build/Products/Debug/Multicast.app

# The iPhone remote (simulator)
xcodebuild -project Apps/Multicast.xcodeproj -scheme "Multicast Remote" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-xcode-ios build
xcrun simctl install booted ".build-xcode-ios/Build/Products/Debug-iphonesimulator/Multicast Remote.app"
xcrun simctl launch booted io.github.longtimeno-c.multicast.remote
```

**Mac app (`Multicast`).** Runs the real hub: it finds the speakers, plays the chosen source, serves iPhone
remotes and lives on in the menu bar. Launch options:

- `--mock` — run on the mock hub (no audio, no network).
- `--snapshot <dir>` — render review PNGs of key states (mock data) and exit.
- `--pairing-code-log <file>` — also write each pairing code to `<file>` (mode 0600) so a script can pair.
- Audio files opened with Multicast (Finder's Open With, or `open -a Multicast.app song.flac`) are added to Files.
- Quit (or `kill <pid>`) disconnects every speaker and removes capture taps before the app exits.

Settings: menu-bar extra, buffer (1–3 s), which Apple Music player to use, and **Remotes**: the paired iPhones, each
with Remove (after a confirmation it is disconnected at once and must pair again).

**iPhone app (`Multicast Remote`).** Lists the Macs on the network; choose one to pair. With no launch arguments it
is the real remote. `-MCScene <name>` (`mock`, `pair`, `pairing`, `speakers`, `now-playing`, `playlists`, … see
`Apps/iOS/Support/RemoteScenes.swift`) and `-MCAppearance light|dark` launch fixed review scenes on the mock hub.

### Pairing

1. Open Multicast on the Mac and Multicast Remote on the iPhone, on the same network.
2. On the iPhone, choose the Mac. The Mac shows a 6-digit code in a small window.
3. Type the code on the iPhone. Done: from now on the iPhone reconnects by itself.

A wrong code asks the Mac for a new one; three failures in a row lock pairing for a minute (doubling, up to an
hour). Pairing keys live in the Keychain on both sides. An iPhone drops its key only when you choose Forget, or
when the Mac removes it inside the encrypted session; a Mac that merely fails to recognise the pairing (or anything
on the network answering with its id) shows as unreachable and the iPhone keeps retrying. The protocol and its threat model are described in
`Sources/MulticastRemote/Crypto.swift`.

### Permissions the Mac asks for

| Permission | Needed for | Without it |
|---|---|---|
| Local Network | finding AirPlay speakers, and letting iPhones find the Mac | only this Mac's own outputs; remotes can't connect (shown in Settings and the speakers list) |
| System Audio Recording | Spotify, other apps and Apple Music (all captured) | those sources play silence; shown on the source |
| Automation (Spotify, Music) | now playing and play/pause/skip; the Music app player | Spotify plays but can't be controlled; Apple Music unavailable |

Multicast never asks unprompted: each prompt follows a button press ("Allow…"), and a refusal points to the
right pane of Privacy & Security.

The Mac app is signed "to run locally" (ad hoc). macOS treats every rebuild as a new app, so it may ask again
for these permissions and for Keychain access to the pairing keys. Signing with your own team avoids that (see
`Apps/Config/Mac.xcconfig`).

## Command line

```bash
# Every speaker this Mac can play to (this Mac's own AirPlay receiver is hidden; --show-self shows it)
swift run multicast-cli list

# A quiet 440 Hz tone on three speakers at once, for 8 s
swift run multicast-cli play --tone --to "MacBook Air Speakers" --to "Main Bedroom" --to "Hall Sonos" --volume 0.12 --seconds 8

# A file on two speakers, the bridge trimmed 40 ms later
swift run multicast-cli play --file song.m4a --to "Main Bedroom" --to "Hall Sonos" --offset "Main Bedroom=40"

# Capture one app (or, without --app, everything except this process) — macOS 14.2+
swift run multicast-cli play --capture --app com.spotify.client --to "Hall Sonos"

# Add and remove speakers while playing (seconds after audio starts)
swift run multicast-cli play --tone --to "Main Bedroom" --add-at "2:Hall Sonos" --remove-at "5:Main Bedroom"
```

- `--to` takes a speaker name, a unique name prefix or an id (`multicast-cli list` shows ids).
- `--volume` is per speaker, 0…1 (default 0.12), and reaches each speaker before any audio.
- `--seconds` is audible time (default 8), fade included: the run reports the measured audible time at the end. The audio fades out at the end; Ctrl-C fades out and tears
  every connection down (a second Ctrl-C skips the fade). Exit codes: 0 ok, 1 a speaker failed, 2 usage, 130 interrupted.
- `--latency-ms` sets the group latency (default 2000). `--verbose` prints the RTSP exchange.
- Two advertisements of one physical device (an AirConnect bridge and the native AirPlay 2 receiver) are refused together.
- A status line every second shows each speaker's state, RTP packets sent, retransmit requests and timing replies
  (network) or sync error and rate correction (local).

### Headless hub and scripted remote

```bash
# The hub without a window, serving remotes; a file added to Files; stops after 10 minutes
swift run multicast-hub --name "Test Hub" --add song.m4a --store /tmp/hub-keys.json \
    --pairing-code-log /tmp/code.txt --seconds 600

# A remote that pairs (reading the code file), turns three speakers on at 0.1, plays the file,
# changes a volume, turns one speaker off mid-stream and stops, printing every state change it sees
swift run multicast-remote-cli run --hub "Test Hub" --store /tmp/remote-keys.json --code-file /tmp/code.txt \
    pair "volume=Main Bedroom:0.1" "on=Main Bedroom" "volume=Hall Sonos:0.1" "on=Hall Sonos" \
    "play-file=song" "expect=Hall Sonos:playing" sleep=3 "volume=Hall Sonos:0.08" "off=Main Bedroom" sleep=2 pause
```

`multicast-remote-cli hubs` lists the hubs on the network; the full list of steps is in the header of
`Sources/multicast-remote-cli/main.swift`. `--store` keeps pairing keys in a 0600 file instead of the Keychain.

## Limitations

- **Sync is verified by protocol and state, not by ear.** Speakers report playing, RTP counters and timing
  replies are healthy, but nobody has listened to confirm the rooms line up.
- **AirPlay 1 bridges (AirConnect and similar) need a sync trim.** They add their own delay; set it per speaker
  (speaker details → Sync trim).
- **Apple Music** plays through the Music app (Apple Events plus a capture of Music's audio). It needs Automation
  and System Audio Recording; neither has been granted on a test machine yet, so library, play and capture are
  unverified live. Music doesn't expose Up Next to Apple Events: Up Next is approximated, and queue editing is not
  offered. The MusicKit player is built but unproven (which process renders its audio is unknown).
- **iPhone-only mode** (playing to speakers from the phone without a Mac) is not built yet.
- The remote link has not been reviewed by a third party; its threat model and gaps are in `Crypto.swift`.
