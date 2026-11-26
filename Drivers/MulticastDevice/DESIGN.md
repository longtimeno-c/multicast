# Multicast as a Mac output device: design

Status: prototype built (driver, hub source, Mac output source in the apps, tests). Live checks
are recorded under "Verification" below.

## Build, install, uninstall

```bash
Drivers/MulticastDevice/build.sh                 # no admin rights; team-signed if Apps/Config/Local.xcconfig exists
sudo Drivers/MulticastDevice/install.sh          # copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
sudo Drivers/MulticastDevice/uninstall.sh        # removes it, restarts coreaudiod
```

Restarting coreaudiod stops all sound on the Mac for a moment. Then choose "Multicast" in System
Settings › Sound › Output (or an app's output menu) and choose "Mac output" as the hub's source.
`swift run multicast-cli play --mac-output --to "MacBook Air Speakers" --volume 0.1 --seconds 6`
plays it without the app.

## Layout

- `Core/`: pure C, shared by the driver and the `MulticastDeviceCore` SwiftPM target (tested in
  `Tests/MulticastDeviceCoreTests`): loopback ring keyed by sample time, zero time stamps, volume
  curve, latency frames.
- `Driver/MulticastDevice.c`: the AudioServerPlugIn (objects, properties, IO).
- `MulticastDevice.xcodeproj` + `Driver.xcconfig`: builds `MulticastDevice.driver`.
- Hub side: `OutputDeviceSource` (Sources/MulticastSources/macOS), `SourceKind.macOutput`,
  `LocalHub+MacOutput.swift`, `MacOutputView` (Mac) and `MacOutputScreen` (iPhone).


## Options

**(a) Our own AudioServerPlugIn loopback driver. Chosen.**
- A HAL plug-in in /Library/Audio/Plug-Ins/HAL exposes two devices that share one ring and one clock:
  - "Multicast": visible, output only, stereo Float32, 44.1 kHz by default (48 kHz also offered). It has volume and mute controls.
  - "Multicast Loopback": hidden (`kAudioDevicePropertyIsHidden`), input only. The hub opens it by UID.
- WriteMix copies the output mix, after volume and mute, into a ring indexed by sample time. ReadInput reads the same sample times back.
  - Frames outside the current contiguous write run read as zeros, so stale audio never leaks out.
- Clock: zero timestamps are computed without state from a shared host-time anchor at the nominal rate. The device therefore ticks at exactly 44,100 frames per host second, the same clock as the engine's pacer, so at 44.1 kHz there is no drift.
  - At 48 kHz, the hub resamples with `PipelineConverter`. `LiveFillController` absorbs jitter, as it does for taps.
- Latency: a custom property (CFPropertyList, seconds) lets the hub publish its group latency (1–3 s buffer setting). The driver reports that latency, plus a small safety offset, as `kAudioDevicePropertyLatency` and notifies listeners, so video apps delay their picture to keep A/V sync.
- Volume and mute: the keyboard volume keys act on "Multicast" and scale what reaches the speakers. The hub's master and per-speaker volumes stay independent.
- The Mac's own speakers are silent while "Multicast" is the output. To hear the Mac too, select "MacBook Air Speakers" as a hub speaker.
  - The hub must never list the Multicast devices as speakers, or audio would loop back. Filter them by UID in local output discovery.
- Permission: reading an input device needs Microphone permission. That means adding `NSMicrophoneUsageDescription` to Apps/Mac/Info.plist; the entitlement `com.apple.security.device.audio-input` is already there. The mic indicator shows while the hub reads.
- Install: copy the bundle to /Library/Audio/Plug-Ins/HAL, then run `sudo killall coreaudiod`. Uninstall: remove the bundle and restart coreaudiod again. Both need sudo and interrupt all audio for a moment.
- Signing: Apple Development signing is enough locally. One open-source driver project reports that macOS 26 needs a paid-team signature to load HAL drivers (unverified). Distribution would need Developer ID signing and notarization.

**(b) Process taps plus "follow the system output". No driver.**
- No install step. But there is no selectable "Multicast" device: what the user picks is still a real output, so the Mac's speakers play the audio un-delayed unless the tap mutes it.
- No latency reporting to apps, so video falls out of sync.
- Apple staff recommend taps when loopback is the only goal. But we need a device users can pick, so taps can't do this.

**(c) Something newer in macOS 26.**
- Nothing found. AudioDriverKit is for physical hardware only, and Apple staff point virtual devices to AudioServerPlugIn.
- macOS 26 adds Swift wrappers for HAL objects and taps, but no API to create a driverless virtual output device.

## DRM: open, must be tested after install
- Web reports say Apple Music (and other streaming apps) mute their audio while screen recording is active. No source tests BlackHole-style devices on current macOS.
- Spotify on the Mac has no output picker of its own and follows the system output. It is widely used with loopback devices.
- Music follows the system output for local playback.
- Verify both empirically once the driver is installed.

## Plan (remaining)
1. Drivers/MulticastDevice/Core: pure C (ring with run tracking, clock math, volume dB↔scalar, latency frames). Also a SwiftPM C target (`path:`) so `swift test` covers it.
2. Drivers/MulticastDevice/Driver: the plug-in in C, an Info.plist (factory UUID 73A4D90D-EFEC-424B-944E-A54F34FC337C, type 443ABAB8-E7B3-491A-B985-BEB9187030DB), and its own small xcodeproj (bundle, `WRAPPER_EXTENSION = driver`). It includes Apps/Config/Local.xcconfig for signing.
3. `LoopbackDeviceSource` in MulticastSources/macOS: an IOProc on the hidden device, then a float ring, then a `PipelineConverter` thread, then a PCM ring with `LiveFillController`. Modelled on AppAudioTapSource.
4. `SourceKind.macOutput` ("Mac output"). Every exhaustive switch needs a case: LocalHub, Sources.swift, MockHubBackend, Mac RootView, iOS MusicScreens and RemoteScenes.
   - Older remotes can't decode the new case. Note this.
5. install.sh and uninstall.sh, which the user runs with sudo.
