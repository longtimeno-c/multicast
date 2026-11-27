# Tuning speaker sync

Every speaker has a sync trim in milliseconds. Bluetooth speakers and bridged AirPlay receivers play later
than they report, so until now the trim was set by ear. Tuning measures it instead: the hub plays a short test
sound on ONE speaker, a microphone listens for it, and that speaker's trim is set so it is heard in step with
the speakers tuned before.

- **One speaker at a time, at your own pace.** Pick a speaker, walk to it, start. The next one whenever you
  like, in any order, today or next week.
- **Two microphones.** On the iPhone (Speakers → Tune Speaker Sync), the phone in your hand listens, held next
  to the speaker: this is the one for a whole house. On the Mac (Speakers panel → Sync → Tune), the Mac's own
  microphone listens: for speakers near the Mac. "Tune All in Turn" on the Mac does every speaker that is on.
- **Saved on the Mac, per speaker.** Each measurement is kept with the speaker's volume and trim
  (`HubSettings.SpeakerPreset.calibration`; a phone that is a speaker has one per output it plays through). It
  survives restarts, and is applied when the speaker joins like any trim.

## What happens

1. Music pauses (and resumes afterwards where it was). Pressing play, or choosing something to play, ends the
   tuning. A speaker that is off is turned on for its measurement and off again.
2. The microphone starts, then the engine's source becomes `CalibrationSource`: one second of silence, then a
   0.25 s sweep from 900 Hz to 6.5 kHz every second. It goes through the normal pipeline, so it takes the same
   road as music: the same timeline, the same sinks, the same trims. The engine's `timelineChanged` event says
   when the source's first frame is due at the loudspeakers, so the moment each sweep is due is known.
3. Every other speaker is muted (`MulticastEngine.setMuted`; volumes are not touched). Five sweeps are listened
   to. For each, the microphone is asked what it heard from 150 ms before the sweep was due to 600 ms after; it
   correlates that stretch with the sweep (`DelayEstimator`) and answers with when the sweep arrived, how
   clearly, and a small picture of the search. The speaker is **measured** when at least three sweeps agree to
   within 2 ms (their median), **not heard** when fewer than three were found, **too noisy** when they were
   found but disagree.
4. The measurement is stored as the speaker's lateness with no trim, with the microphone it was made through.
   `TrimPlanner` then works out the trims of EVERY speaker measured through that microphone, present or not.
   One is the reference and keeps its trim: the Mac's own speakers if they were measured, otherwise the
   earliest speaker (a speaker that under-reports its delay plays late, so the earliest is the one most likely
   to be on time). Every other gets `reference − its own lateness`, within −500…500 ms.
   So the first speaker you tune changes nothing by itself ("the others line up to this one"); from the second
   on, each lands in step, and a speaker tuned earlier is moved without being measured again if a later one
   turns out to be the earlier of the two.
5. A trim nudged by hand afterwards is kept: the stored measurement moves with it, so later tunings go on
   giving that trim. Measurements made through different microphones are kept apart (see below).

About ten seconds per speaker, plus the time a network speaker takes to connect.

## What you see

The same stage on the iPhone and the Mac (`Apps/Shared/Components/TuningStage.swift`), drawn from what the hub
publishes in `HubState.calibration`, not from a canned loop:

- **The sweeps travelling** from the speaker to the microphone: each leaves when the timeline says it is due
  and lands a second later, which is when the microphone's answer for it arrives; the ring at the microphone is
  green when it was heard.
- **The scope**: for each sweep, the microphone's search across its listening window, a spike where the sweep
  arrived over the room's floor. Sweeps stack; three dots fill as they agree. Its height is the microphone's
  confidence, so noise is low grass and a heard sweep stands tall.
- **On the iPhone, the room's live waveform** under the microphone, from the phone's own input.
- **The result**: "In sync", the speaker's mark sliding into step from where it was ("172 ms"), the trim before
  and now, a success haptic. When it couldn't be heard or the room was too noisy: what happened and one next
  step, with Try Again.

Reduce Motion replaces the travelling sweeps with a row of marks that fill; nothing loops. VoiceOver reads the
readout and announces the result. Review scenes: `-MCScene tune`, `tune-ready`, `tune-starting`,
`tune-listening`, `tune-in-sync`, `tune-reference`, `tune-not-heard`, `tune-noisy`, `tune-refused` on the
iPhone (`tune` plays a whole tuning on the mock hub); `tuning-*.png` from the Mac's `--snapshot`.

## The iPhone as the microphone

`CalibrationMicrophone` is the seam: the hub's run doesn't know where its answers come from. Over the paired,
encrypted link (protocol version 6):

- The phone sends `tuneSpeaker`. The hub starts the same run as for its own microphone, with a
  `RemoteMicrophone` whose every call is a question to the phone (`microphoneRequest` / `microphoneAnswer`).
- **No audio leaves the phone.** It records into a six-second ring, runs `DelayEstimator` itself, and answers
  with the arrival time, a strength and 96 bytes of search picture.
- **Clocks.** The phone has its own. Before listening and before every question the hub makes an NTP-style
  exchange with it and keeps the best (`ClockEstimator`); the two clocks are then known to about half the
  link's round trip, typically well under a millisecond at home. Questions are asked in the phone's time.
- A hub or phone on an older version is never sent the new messages; the phone says the Mac needs updating.

Measurements are stored under the microphone that made them ("hub", or "phone:" + the phone's id) and only
compared within one microphone, because each has its own unknown delay. Tune the whole house with one phone
and everything lines up; a speaker tuned with the Mac and another with the phone are not compared with each
other (the later tuning of a speaker replaces its earlier one).

**The phone tuning the speaker it is itself playing through** (a Bluetooth speaker connected to the phone): it
works the same way, the phone's own microphone listening to the phone's output. For that the phone's audio
session becomes play-and-record with Bluetooth kept on A2DP. This path has not been run on a real phone, and
iOS may report a different output delay in that mode than in plain playback, which would put a constant few
milliseconds into that one measurement. Treat it as experimental until checked on a device.

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

So the result is right where the microphone was. Held next to each speaker in turn (the iPhone), that lines up
when the speakers EMIT, which is what a house of rooms wants. With the Mac's microphone it lines up arrival at
the Mac: a speaker 5 m further away ends up 15 ms earlier, right at the Mac and 15 ms off next to that speaker. It is also why absolute numbers are not shown: on the
Mac this was developed on, its own speakers measure 27 ms *before* they are due, which is the microphone's and
the output's latency reports not adding up, not the speakers playing early.

A phone adds its clock estimate's error (under a millisecond within one tuning, a millisecond or two between
tunings on different days).

## Limits

- **Out of earshot.** A speaker the microphone can't hear is reported as such and left alone: walk to it with
  the iPhone.
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
| `MulticastCalibration/CalibrationMicrophone.swift` | The microphone seam and `HeardSweep`, shared by the Mac's and the phone's. |
| `MulticastHub/LocalHub+Calibration.swift` | The run: pause, solo the speaker, measure, store, plan, set trims, hand the engine back. |
| `MulticastHub/MacMicrophone.swift` | Core Audio IOProc on the input device into a `RecordingRing`, stamped with host time. |
| `MulticastRemote/RemoteMicrophone.swift` | The phone's microphone as the hub sees it (questions over the link, clock exchange), and the phone's responder. |
| `MulticastHubModel/Calibration.swift` | `SyncCalibrationStatus` in `HubState.calibration`; `SpeakerItem.tunedAt`; `HubCommand.calibrateSpeakerSync`, `.calibrateSync`, `.cancelSyncCalibration`. All optional on the wire, so older remotes are unaffected. |
| `Apps/Shared/Components/TuningStage.swift` | The stage both apps draw. |
| `Apps/iOS/Tuning/` | The phone's microphone (`AVAudioEngine` input tap), the tuning model and screens. |
| `Apps/Mac/Window/SpeakersPanel.swift` | The "Sync" section. |

Permission: Microphone (`NSMicrophoneUsageDescription`, on the Mac and on the iPhone). Asked the first time a
tuning starts on that device. Only the
last six seconds are held, in memory, and nothing is stored or sent.

## Verification

- Unit tests (`MulticastCalibrationTests`): a synthesized recording with a known delay, noise as loud as the
  sweep and an echo is recovered within 1 ms (within 0.2 ms when clean, at 16, 44.1 and 48 kHz); a reflection
  louder than the direct sound; an inverted speaker; noise alone (40 seeds), silence, a hum, clicks, a noise
  burst and a swelling chord are all refused; the trim arithmetic, clamping and reference choice.
- Hub tests (`CalibrationHubTests`): a fake session and a fake microphone that "hears" whatever is unmuted at
  that speaker's made-up delay plus its trim. Speakers tuned one at a time line up with those tuned before, in
  either order; a speaker that is off is turned on for its measurement only; tunings survive a restart and later
  ones line up with them; a trim nudged by hand is kept; a phone's microphone is kept apart from the Mac's; the
  sweeps are published as they are heard; refusal, cancel, pause and resume, shutdown mid-run.
- Link tests (`MicrophoneLinkTests`): a real hub server and remote over 127.0.0.1 with a made-up microphone on
  the phone's side: the hub's question arrives in the phone's time and the answer comes back in the hub's,
  within the clock exchange's error; refusals; an older hub is never sent the new messages; the phone leaving.
- Live (`MULTICAST_LIVE_CALIBRATION=1 swift test --filter LiveCalibration`): the Mac's own speakers heard by its
  own microphone, measured with the trim at 0, +40 ms and 0. On a MacBook, at volume 0.08 with other audio
  playing from the same speakers: +40 ms of trim measured as +40.00 ms, the repeat within 0.01 ms, sweep-to-sweep
  spread 0.00 to 0.09 ms.

Not tested on real hardware: the iPhone as the microphone (its capture, audio session and clock on a real
device), Bluetooth speakers, AirPlay speakers and bridges, a phone as a speaker (and a phone measuring its own
output), more than one real speaker.
