# Acta — implementation specification

> **Status:** specification for autonomous implementation (executor — ralphex).
> Self-contained: decisions are fixed, acceptance criteria are verifiable.
> When in doubt, pick the option that minimises dependencies and maximises recording reliability.
> **Language:** English only across UI, code, docs and git — see `AGENTS.md`.

## 1. What this is and why

A personal, minimal **macOS menu-bar** app that **only records** online meetings (Slack, Teams,
Google Meet and **any** other audio source): system audio (the other participants) + microphone.
Transcription and summarisation are **out of scope** — done separately (the user already has
`mlx_whisper` set up locally).

**Three mandatory recording properties:**
1. **Streaming writes to disk** — incremental, as the meeting goes; never buffer it all in memory.
2. **Fault tolerance** — after a restart/crash, whatever was recorded is valid and gets recovered.
3. **Self-diagnosis** — if recording fails to start or stalls, it is detected at once and healed.

### 1.1 Amendment (2026-09-11): Acta also holds the Mac's default input — opt-in

⚠️ **This widens "only records", and it is written here rather than smuggled past it.** The sentence
above is still the shape of the app: Acta records, and it does not transcribe, summarise, mix or edit.
But one feature reaches outside the recording, and the honest thing is to say so at the point the scope
is claimed.

Two features came out of the same problem — connecting a Bluetooth headset makes macOS switch the
system default input, so meetings get recorded through a headset microphone nobody chose. They are
**separate**, because only one of them needed this amendment:

**(A) Acta pins the microphone it records from.** `SCStreamConfiguration.microphoneCaptureDeviceID` is
set explicitly; unset means "System Default Microphone" (`SCStream.h`), so until this landed Acta
recorded through whatever macOS had most recently decided the default was. That is a **defect against
rule 3** — "never show recording when the right data is not being written" — not a new feature, and it
needs no scope change. It is always on: capture resolves against the user's priority list, or against
the system default if they ask for that explicitly, and a recording refuses to start rather than
silently follow something nobody chose.

**(B) Acta holds the Mac's default input on a user-ordered priority list.** This is the scope change.

- **The promise:** *while Acta is running*, the Mac's default input stays on your list — the
  highest-ranked available device wins, and it is restored when something else moves it. It holds while
  Acta is idle, not only while recording, which is the whole point: the headset connects before the
  meeting starts.
- **Opt-in, and off by default.** It writes `kAudioHardwarePropertyDefaultInputDevice`, which affects
  **every other application on the machine**. A feature with that reach is not something to switch on
  for somebody. Enabling it seeds a starting list rather than inventing a full ranking, and never
  overwrites a list the user already has.
- **It yields rather than fights.** If something keeps moving the input back, enforcement suspends
  itself and says so, rather than trading writes with another program indefinitely. Pause withdraws
  permission to write immediately — including during an operation already in flight.
- **What it does not promise, and the UI must not imply:** an application with its own selected input
  device (Slack, Teams and Meet all have one) need not follow the system default at all. (B) fixes the
  *system* default; per-app pickers stay the user's job, once.
- **(A) keeps working while (B) is paused or off.** They are different promises and deliberately do not
  share a switch: pausing enforcement of the *system* input must not change what Acta records from.

⚠️ **One measured dependency underneath both.** The CoreAudio device UID and
`AVCaptureDevice.uniqueID` are the same string — **measured on this machine, documented by Apple
nowhere as a single identity**. If a future macOS diverges, everything still compiles and either the
wrong microphone is recorded or capture fails. `Scripts/probe-microphone-identity.sh` checks it against
real hardware; see `AGENTS.md` for what that probe can and cannot claim.

**Definition of Done (v1):** start/stop from the menu bar; system audio and microphone written as
separate streaming segment tracks; after `kill -9`/restart the recorded segments survive and are
finalised automatically on the next launch; a failed start is diagnosed and healed or reported;
everything builds without full Xcode.

## 2. Environment (facts)

- Apple M3, 16 GB, **macOS 26.2** (target `arm64-apple-macosx26`).
- **Swift 6.3.3**, **Command Line Tools only**, no full Xcode → build via SwiftPM.
- Installed: `ffmpeg` (concat), `swiftlint` (via the `Scripts/lint.sh` wrapper).
- Project home: the working copy of this repository.

## 3. Fixed decisions

| Aspect | Decision | Why |
|---|---|---|
| App type | SwiftUI `MenuBarExtra`, `LSUIElement=true` | minimal, no Dock icon |
| Build | **SwiftPM** + bundling script + ad-hoc `codesign` | no full Xcode available |
| Dependencies | **none external** (no WhisperKit — no transcription) | simpler, more reliable |
| Audio capture | **a single `SCStream`**: system audio + microphone | works for any source app |
| Disk writes | **streaming, ~10–15 s segments** (each a valid file) | a crash loses ≤ one segment |
| Fault tolerance | `session.json` + recovery on launch (segment assembly) | survives restart/crash |
| Self-diagnosis | verify data flow at start + watchdog + auto-heal | never a "silent" recording |
| Tracks | **always two**: `system.wav` + `mic.wav`; no mix in the pipeline | separate tracks give "me vs. them" attribution; a mix is derived data and the most fragile assembly path |
| Storage | one folder per recording: audio + `session.json` + `info.md` | returnable, agent-friendly |

## 4. Technical coordinates

- **ScreenCaptureKit** (see the `screencapturekit-audio` skill): one `SCStream`,
  `capturesAudio=true`, `captureMicrophone=true`, `excludesCurrentProcessAudio=true`,
  minimal video config; `.audio`/`.microphone` buffers → separate writers.
- **Crash-safe writing** (see the `crash-safe-recording` skill): write **short segments**, each
  finalised into a valid file; flush often; never buffer the whole recording in memory.
  Gotcha: an unfinalised `AVAssetWriter` file is usually corrupt after a hard crash — hence segments.
- **Assembly** via `ffmpeg`: concatenate each track's segments → `system.wav`, `mic.wav`.
  Both tracks are always produced; there is **no mix in the pipeline**. A mix (`combined.wav`,
  `amix=inputs=2:duration=longest`) is **not produced at all** for now: an on-demand "Export mix"
  action is backlog, not shipped code, so until it lands the one case where a mix helps — listening
  back to a meeting as a whole — is served by running `ffmpeg` by hand. There is no mix code left to
  reuse: `FFmpeg.mixArgs` was removed with the rest, since an argument builder for a file nothing
  produces reads as live code. The recipe above is the record of it; Export mix re-adds it against a
  real export path.
- **Permissions (TCC):** Microphone (`NSMicrophoneUsageDescription`), Screen Recording
  (runtime; status via `CGPreflightScreenCaptureAccess()`, request via `CGRequestScreenCaptureAccess()`).

## 5. Project layout

```
acta/
  Package.swift                     # Acta executable + ActaControlProtocol + ActaKit + ActaRuntime + ActaTestRunner + ActaTests; no external deps
  Sources/Acta/
    ActaApp.swift                   # @main, MenuBarExtra, state idle/recording/error/recovered — the ONLY file here
  Sources/ActaControlProtocol/      # the wire protocol; Foundation-only, declares NO package dependencies
    Envelope.swift                  # {version,id,command/result/error/event}, exact-version policy, the JSON codec
    Command.swift                   # the command algebra; an unknown `type` decodes to .unsupportedCommand
    CommandResult.swift             # the result algebra (state/recordings/settings/title/ok)
    WireError.swift                 # the complete, frozen error-code set
    WireValues.swift                # WireControlState, WireSettings, RecordingSummary
    WireMessageCode.swift           # the stable machine codes for ControllerMessage prose
    RecordingID.swift               # the opaque "v1:<base64url>" recording id
    JSONLinesFramer.swift           # FrameReader/FrameWriter — payload + LF, directional size limits
  Sources/ActaRuntime/              # the pipeline (a library: SwiftPM cannot import an executable target)
    ControlAPI.swift                # typed @MainActor façade over RecordingController: commands + states()
    ControlState.swift              # the typed state (operation/lifecycleFailure/notice/recoveryNotice)
    ControlState+Mapping.swift      # pure ControllerSnapshot → ControlState translation
    ControlServing.swift            # the narrow surface a transport may reach for; ControlAPI conforms
    ControlDispatcher.swift         # Command → ControlServing call → CommandResult; the transport policy
    WireProjection.swift            # pure ControlState → WireControlState projection + ControlRecordingLookup
    ControlEndpoint.swift           # secure Unix-socket bind (flock'd init, stale-socket recovery, device/inode teardown)
    ControlSocketServer.swift       # non-blocking accept loop, ~16-connection cap, synchronous bounded shutdown
    ControlConnection.swift         # serves one connection: read request, dispatch, reply; watch streaming
    ControlConnectionIO.swift       # non-blocking read/write over one fd via DispatchSource, SO_NOSIGPIPE, deadlines
    ControlSocketHost.swift         # app-side lifecycle owner; synchronous bounded teardown()
    RecordingController.swift       # UI-facing observable state, start/stop wiring
    RecordingSession.swift          # one recording's lifecycle: marker, capture, assembly, wake lock
    AudioRecorder.swift             # SCStream, separate tracks, streaming segment writes, flush
    SegmentWriter.swift             # segment rotation (~10-15 s), finalise each one
    SegmentAssembler.swift          # ffmpeg concat (two tracks, no mix)
    RecoveryManager.swift           # on launch: find session.json status=recording → assemble segments
    SelfCheck.swift                 # verify data flow at start + watchdog + auto-heal
    SystemPermissions.swift         # Screen Recording + Microphone (behind the PermissionChecking seam)
    MeetingStore.swift              # folders, session.json, info.md front-matter, recordings list
    Settings.swift                  # archive path, segment length, segment cleanup
    BuildFlavor.swift               # stable/dev flavor, log subsystem, build revision
    SourceDetector.swift            # (nice-to-have) title suggestion from running apps
  Sources/ActaKit/                  # pure, unit-testable logic (no I/O); exceptions: SegmentRepair, DisplayWakeLock
  Sources/ActaTestRunner/           # where tests actually live (swift-testing @Test)
  Resources/{Info.plist, Acta.entitlements}
  Scripts/{bundle.sh, run.sh, lint.sh, test.sh}
  AGENTS.md, CLAUDE.md, SPEC.md, .swiftlint.yml
```

## 6. Storage format

`~/Acta/YYYY-MM-DD_HHMM__<slug>/`:
- While recording: `system/NNNN.wav`, `mic/NNNN.wav` (segments) + `session.json`
  (`status: recording|done|recovered`, `started_at`, config, segment count).
- After a clean stop or recovery: **`system.wav` and `mic.wav`, always both**; segments are deleted
  or kept, per settings. `combined.wav` is **not** produced — an on-demand "Export mix" action is
  backlog; a `combined.wav` in an older folder is left where it is rather than scrubbed.
- `info.md` — YAML front-matter: `title, date, source, duration, status`.
- `~/Acta/CLAUDE.md` — describes the archive as working context for the user's Claude Code.

## 7. Fault tolerance and self-diagnosis (the core of v1)

**Streaming segment writes.** Each track is written in ~10–15 s segments; a segment is finalised and
stays valid regardless of what happens next. Flush to disk often. A hard crash/restart therefore
loses at most the last, unfinalised segment.

**Session marker.** `session.json` is created at start (`status=recording`) and kept up to date. A
clean stop → `status=done` + assembly. Finding `status=recording` at launch means the recording was
interrupted abnormally.

**Recovery on launch** (`RecoveryManager`). Scan the archive at startup; for every folder with
`status=recording`: assemble the surviving valid segments into `system.wav` and `mic.wav` (both, no
mix on this path), repair a truncated trailing segment from its actual size and drop it only if it
holds no data, set `status=recovered`, notify the user.

**Startup self-diagnosis** (`SelfCheck`). Within ~2 s of starting, confirm data is actually flowing
(current segment growing / buffers arriving). If not, determine the cause: no TCC permission →
request/guide; `SCStream` did not come up → restart (2–3 attempts); no audio device → clear error.
Never display "recording" when nothing is being written.

**Watchdog while recording.** If the buffer flow stalls for N seconds, flag it and try to restart the
stream while keeping the already written segments; on failure — surface an error in the UI.

**The display is held awake while recording** (`DisplayWakeLock`). ScreenCaptureKit is a *screen*
capture API: when the display goes idle it loses its display, reports `"Failed to find any displays
or windows to capture"` and the capture dies — proven live on 2026-07-15, where a recording stopped
by itself after 2:20 the same second `pmset -g log` says `Display is turned off`. Sitting in a
meeting *listening* is exactly the inactivity that puts a display to sleep, so this hits every other
meeting. For the span of a recording — and only that span — Acta holds a
`ProcessInfo.beginActivity([.idleDisplaySleepDisabled, .idleSystemSleepDisabled])` assertion, visible
in `pmset -g assertions` under a human-readable reason. Letting the display sleep and reconnecting on
wake was rejected: it leaves a hole in the audio for the whole sleep, the worst trade a recorder can
make.

⚠️ **The honest limit:** an activity assertion only prevents **idle** sleep. Closing the lid, a hot
corner, or an explicit Sleep will still tear the stream down, and for those the watchdog remains the
only defence — it stops the recording and says so. This fixes the everyday failure, not every failure.

## 8. Xcode-free build recipe (`Scripts/bundle.sh`) — see the `swiftpm-macos-app-bundle` skill
1. `swift build -c release` → `.build/release/Acta`.
2. Assemble `Acta.app/Contents/{MacOS,Resources}` + `Info.plist`
   (`CFBundleIdentifier=dev.personal.acta` — fixed, for TCC stability; `LSUIElement=true`;
   `NSMicrophoneUsageDescription`; `LSMinimumSystemVersion=14.0`).
3. `codesign --force --sign - --identifier dev.personal.acta --entitlements Resources/Acta.entitlements Acta.app`.

## 9. Implementation order and acceptance

Follow the tasks in `docs/plans/acta.md`; each has a verifiable criterion. The key ones:
- Task 2: a 60 s recording → several valid segments (`ffprobe` duration > 0 for each).
- Task 3: `kill -9` while recording → relaunch → the unfinished recording is finalised automatically,
  `system.wav`/`mic.wav` are valid and contain the audio recorded before the crash.
- Task 4: starting without Screen Recording → an immediate, actionable error rather than a silent "rec".

## 10. Risks and notes
- **Audio-only ScreenCaptureKit** still needs a display content filter → minimal video config, ignore `.screen`.
- **TCC + ad-hoc signing:** keep `CFBundleIdentifier`/`--identifier` stable, otherwise Screen Recording
  must be granted again after every rebuild.
- **Segment format:** pick a container that yields a valid file per segment (WAV/CAF); if in doubt,
  write raw PCM per segment and build the WAV on finalisation/recovery.
- **Privacy/ethics:** recording calls with other people may require their consent — the user's responsibility.

## 11. References
- ScreenCaptureKit / microphone: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- Audio+mic guide: https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
