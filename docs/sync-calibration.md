# Sync calibration

Every speaker has a sync trim in milliseconds. Bluetooth speakers and bridged AirPlay receivers play later
than they report, so until now the trim was set by ear. **Calibrate sync** (Mac window, bottom of the Speakers
panel) measures it instead: the hub plays a short test sound on each speaker that is on, one at a time, listens
with a microphone, and sets the trims so the speakers are heard together.

## What happens

1. Music pauses (and resumes afterwards where it was). Pressing play, or choosing something to play, ends the
   calibration.
2. The engine's source becomes `CalibrationSource`: one second of silence, then a 0.25 s sweep from 900 Hz to
   6.5 kHz every second. It goes through the normal pipeline, so it takes the same road as music: the same
   timeline, the same sinks, the same trims. Sweep `k` starts a known number of frames after the first frame the
   engine reads, and the engine's `timelineChanged` event says when that first frame is due at the loudspeakers,
   so the moment each sweep is due is known on the hub's clock.
3. Every speaker but one is muted (`MulticastEngine.setMuted`; volumes are not touched). After a second for the
   mutes to land, five sweeps are listened to. For each, the microphone's recording from 150 ms before the sweep
   is due to 600 ms after is correlated with the sweep (`DelayEstimator`); the first strong, sharp peak is the
   sweep's arrival. A speaker is **measured** when at least three sweeps agree to within 2 ms (the result is
   their median), **not heard** when fewer than three were found, **unclear** when they were found but disagree.
4. `TrimPlanner` turns the delays into trims. One speaker is the reference and keeps its trim: the Mac's own
   speakers when they were measured, otherwise the earliest speaker (a speaker that under-reports its delay
   plays late, so the earliest is the one most likely to be on time; speakers that weren't measured stay in step
   with it). Every other measured speaker gets `reference − its own lateness`, clamped to the trim range
   (−500…500 ms; if moving all of them together brings them into range, that is done first).
5. Trims are set through the same path as trims set by hand, so they are remembered per speaker (per output for
   a phone) and shown in each speaker's details. Speakers that were not heard, or unclear, keep theirs.

It takes about seven seconds per speaker. The panel shows one line per speaker while it runs and after:
`Measuring…`, `Was 172 ms late · trim −172 ms`, `Couldn't hear this speaker`.

## Why a sweep, and why it is believed

Correlating with a sweep compresses its quarter second of energy into a peak about 0.2 ms wide, roughly 30 dB
above what the same sound achieves sample by sample. That is why it can be played quietly and still be found
under music or talk, and why the arrival is known to a fraction of a millisecond.

Three things keep a wrong answer out:

- **The floor of the whole recording.** The peak must stand 6.5 times above the correlation's robust noise floor.
  Noise alone reaches 4 to 5.
- **The floor around the peak.** A door, a voice or a key press is much louder than the quiet around it and lifts
  the correlation wherever it falls, but as a broad hump. The peak must also stand 6.5 times above the 60 ms just
  before it.
- **Agreement.** Three sweeps must agree to within 2 ms. Noise that happened to pass the first two tests lands
  anywhere in a 0.85 s window; three landing within 2 ms of each other is a chance of about one in tens of
  thousands.

Echo: the estimate is the first peak at least half as strong as the strongest one within the 30 ms before it,
so a reflection louder than the direct sound doesn't win.

## What cancels and what does not

The measured number for a speaker is `arrival at the microphone − moment the sweep was due`. It contains:

| Part | Same for every speaker? | Effect |
| --- | --- | --- |
| The speaker's unreported delay (Bluetooth codec, a bridge's buffer) | no | **This is what is corrected.** |
| The microphone's input latency (device latency + safety offset + stream latency are subtracted, but the report is not exact) | yes, with one microphone | Cancels: only differences between speakers are used. |
| Any error in where the sweeps sit on the timeline | yes | Cancels. |
| Sound travelling from the speaker to the microphone (2.9 ms per metre) | no | **Stays in, on purpose:** the speakers are lined up as heard at the microphone. |
| The trim a speaker already has | no | Taken out arithmetically, so a second run changes nothing. |

So the result is right at the microphone's position. With the Mac's microphone that is the Mac: a speaker 5 m
further away than another ends up playing 15 ms earlier, which is correct at the Mac and 15 ms wrong next to
that speaker. That is inherent to lining up by ear too. It is also why absolute numbers are not shown: on the
Mac this was developed on, its own speakers measure 27 ms *before* they are due, which is the microphone's and
the output's latency reports not adding up, not the speakers playing early.

A microphone on another clock (a phone) adds one more common term, see below.

## Limits

- **Other rooms.** A speaker the microphone can't hear is reported as such and left alone.
- **One listening position.** See above.
- **Delays outside −150…+600 ms** of the timeline are not found (the next sweep would be in the window). Trims
  reach ±500 ms, so little is lost.
- **Other sound from the Mac.** Calibration pauses what Multicast plays. Sound other apps play straight to the
  Mac's speakers keeps playing; calibration works through a fair amount of it but can come back "unclear".
- **Bluetooth microphones are never opened.** Opening a headset's microphone switches it to its call mode, which
  changes the output delay being measured. The Mac's built-in microphone is used when it has one, otherwise the
  default input unless that is Bluetooth or virtual; with neither, calibration says the microphone couldn't be
  used.
- **A stalled engine.** If the engine stalls for longer than its two-second buffer mid-run it skips packets, and
  sweeps after that are off by the skipped amount. Not detected; run it again if the Mac was badly overloaded.
- **A speaker turned on mid-run** joins unmuted and is muted before the next sweep; one sweep may be spoilt
  (agreement catches it).

## Pieces

| Where | What |
| --- | --- |
| `MulticastCalibration` | `CalibrationSignal`/`CalibrationSource` (the sweep), `DelayEstimator`, `DelayMeasurement.combine`, `TrimPlanner`, `RecordingRing`. Arithmetic only: no device, no clock. |
| `MulticastHub/LocalHub+Calibration.swift` | The run: pause, solo each speaker, measure, plan, set trims, hand the engine back. |
| `MulticastHub/MacMicrophone.swift` | Core Audio IOProc on the input device into a `RecordingRing`, stamped with host time. |
| `MulticastHubModel/Calibration.swift` | `SyncCalibrationStatus` in `HubState.calibration` (absent when there is none, so older remotes are unaffected); `HubCommand.calibrateSync` and `.cancelSyncCalibration`. |
| `Apps/Mac/Window/SpeakersPanel.swift` | The "Sync" section. |

The commands and the state travel to remotes like any other, so the phone could start a calibration and show
its progress; it has no button for it yet.

Permission: Microphone (`NSMicrophoneUsageDescription`). Asked the first time Calibrate is pressed. Only the
last six seconds are held, in memory, and nothing is stored or sent.

## Verification

- Unit tests (`MulticastCalibrationTests`): a synthesized recording with a known delay, noise as loud as the
  sweep and an echo is recovered within 1 ms (within 0.2 ms when clean, at 16, 44.1 and 48 kHz); a reflection
  louder than the direct sound; an inverted speaker; noise alone (40 seeds), silence, a hum, clicks, a noise
  burst and a swelling chord are all refused; the trim arithmetic, clamping and reference choice.
- Hub tests (`CalibrationHubTests`): a fake session and a fake microphone that "hears" whatever is unmuted at
  that speaker's made-up delay plus its trim. Trims set, remembered and pushed to the session; one speaker
  audible at a time; unheard speakers untouched; refusal of the microphone; cancel; pause and resume of a file;
  play ending the run; shutdown mid-run.
- Live (`MULTICAST_LIVE_CALIBRATION=1 swift test --filter LiveCalibration`): the Mac's own speakers heard by its
  own microphone, measured with the trim at 0, +40 ms and 0. On a MacBook, at volume 0.08 with other audio
  playing from the same speakers: +40 ms of trim measured as +40.00 ms, the repeat within 0.01 ms, sweep-to-sweep
  spread 0.00 to 0.09 ms.

Not tested on real hardware: Bluetooth speakers, AirPlay speakers and bridges, a phone as a speaker, more than
one speaker at once, speakers in other rooms.

## Design: the phone as the microphone (not built)

The Mac's microphone lines the speakers up at the Mac. The person usually listens somewhere else, and may want
to calibrate rooms the Mac can't hear. A paired iPhone is a microphone they can carry there.

`CalibrationMicrophone` is the seam: the hub's run doesn't know where its recordings come from. A
`PhoneMicrophone` conforming to it would sit beside `PhoneSpeakerSink` in `MulticastRemote`:

- **Clock.** The phone already estimates its offset to the hub's clock for the phone-speaker link
  (`ClockEstimator`, sub-millisecond on Wi-Fi). The phone stamps what it records with its own host time and
  converts to hub time with that estimate. An error in the estimate is the same for every speaker measured in
  one run, so like the microphone's latency it cancels; only its drift during the run matters (microseconds).
- **What crosses the link.** Not audio. The hub sends the phone the signal's parameters and, per sweep, the
  hub-time window to look in; the phone runs `DelayEstimator` itself (the module has no macOS dependency, and a
  one-second correlation is tens of milliseconds on a phone) and answers with `arrival time, strength` or
  "nothing". A few dozen bytes per sweep, and no recording ever leaves the phone, which is also the easier
  privacy story. Two new control messages on the existing encrypted link: `listen(window)` and
  `heard(arrival?)`; the remote protocol version goes up by one and older phones simply aren't offered as
  microphones.
- **Capture on the phone.** `AVAudioEngine` input tap in `.measurement` mode (no voice processing, no automatic
  gain), buffers into the same `RecordingRing`, each stamped from `AVAudioTime.hostTime` less
  `AVAudioSession.inputLatency`. Needs `NSMicrophoneUsageDescription` in the iOS app. While the phone is also a
  speaker in the group, the session category has to be play-and-record, which changes its output route's
  latency: either refuse to use a phone that is currently a speaker as the microphone, or leave it out of the
  speakers being measured.
- **Flow.** On the phone: Speakers → Calibrate sync → "Stand where you listen and hold the phone up". It sends
  `calibrateSync` with itself named as the microphone (a new optional field; absent means the hub's own). The
  hub runs exactly as now. The progress the phone shows is `HubState.calibration`, which it already receives.
- **Several rooms.** One run per room, each lining up the speakers heard there. A speaker heard in two rooms
  ties them together: keep it as the reference in the second run (the planner's "preferred reference" input) so
  the second room is aligned to the first rather than to its own earliest speaker.

Size: the link messages and `PhoneMicrophone` on the hub side, capture and the estimator call on the phone, a
screen on the phone, and tests with a loopback link as the phone-speaker tests have. About the size of the
phone-speaker receiver; left out of this change.
