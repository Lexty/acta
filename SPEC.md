# Acta — implementation specification

> **Status:** specification for autonomous implementation (executor — ralphex).
> Self-contained: decisions are fixed, acceptance criteria are verifiable.
> When in doubt, pick the option that minimises dependencies and maximises recording reliability.
> **Language:** English only across UI, code, docs and git — see `CLAUDE.md`.

## 1. What this is and why

A personal, minimal **macOS menu-bar** app that **only records** online meetings (Slack, Teams,
Google Meet and **any** other audio source): system audio (the other participants) + microphone.
Transcription and summarisation are **out of scope** — done separately (the user already has
`mlx_whisper` set up locally).

**Three mandatory recording properties:**
1. **Streaming writes to disk** — incremental, as the meeting goes; never buffer it all in memory.
2. **Fault tolerance** — after a restart/crash, whatever was recorded is valid and gets recovered.
3. **Self-diagnosis** — if recording fails to start or stalls, it is detected at once and healed.

**Definition of Done (v1):** start/stop from the menu bar; system audio and microphone written as
separate streaming segment tracks; after `kill -9`/restart the recorded segments survive and are
finalised automatically on the next launch; a failed start is diagnosed and healed or reported;
everything builds without full Xcode.

## 2. Environment (facts)

- Apple M3, 16 GB, **macOS 26.2** (target `arm64-apple-macosx26`).
- **Swift 6.3.3**, **Command Line Tools only**, no full Xcode → build via SwiftPM.
- Installed: `ffmpeg` (concat/mix), `swiftlint` (via the `Scripts/lint.sh` wrapper).
- Project home: `/Users/<user>/dev/personal/acta`.

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
| Storage | one folder per recording: audio + `session.json` + `info.md` | returnable, agent-friendly |

## 4. Technical coordinates

- **ScreenCaptureKit** (see the `screencapturekit-audio` skill): one `SCStream`,
  `capturesAudio=true`, `captureMicrophone=true`, `excludesCurrentProcessAudio=true`,
  minimal video config; `.audio`/`.microphone` buffers → separate writers.
- **Crash-safe writing** (see the `crash-safe-recording` skill): write **short segments**, each
  finalised into a valid file; flush often; never buffer the whole recording in memory.
  Gotcha: an unfinalised `AVAssetWriter` file is usually corrupt after a hard crash — hence segments.
- **Assembly/mix** via `ffmpeg`:
  - concatenate a track's segments → `system.wav`, `mic.wav`;
  - mix both → `combined.wav` (`amix=inputs=2:duration=longest`).
- **Permissions (TCC):** Microphone (`NSMicrophoneUsageDescription`), Screen Recording
  (runtime; status via `CGPreflightScreenCaptureAccess()`, request via `CGRequestScreenCaptureAccess()`).

## 5. Project layout

```
acta/
  Package.swift                     # Acta executable + ActaKit + ActaTestRunner + ActaTests; no external deps
  Sources/Acta/
    ActaApp.swift                   # @main, MenuBarExtra, state idle/recording/error/recovered
    AudioRecorder.swift             # SCStream, separate tracks, streaming segment writes, flush
    SegmentWriter.swift             # segment rotation (~10-15 s), finalise each one
    RecoveryManager.swift           # on launch: find session.json status=recording → assemble segments
    SelfCheck.swift                 # verify data flow at start + watchdog + auto-heal
    Permissions.swift               # Screen Recording + Microphone
    MeetingStore.swift              # folders, session.json, info.md front-matter, recordings list
    Settings.swift                  # archive path, tracks, segment length, segment cleanup
    SourceDetector.swift            # (nice-to-have) title suggestion from running apps
  Sources/ActaKit/                  # pure, unit-testable logic (no I/O)
  Resources/{Info.plist, Acta.entitlements}
  Scripts/{bundle.sh, run.sh, lint.sh, test.sh}
  CLAUDE.md, SPEC.md, .swiftlint.yml
```

## 6. Storage format

`~/Acta/YYYY-MM-DD_HHMM__<slug>/`:
- While recording: `system/NNNN.wav`, `mic/NNNN.wav` (segments) + `session.json`
  (`status: recording|done|recovered`, `started_at`, config, segment count).
- After a clean stop or recovery: `system.wav`, `mic.wav`, `combined.wav`; segments are deleted or
  kept, per settings.
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
`status=recording`: assemble the surviving valid segments into `system/mic/combined.wav`, discard a
corrupt trailing segment without failing, set `status=recovered`, notify the user.

**Startup self-diagnosis** (`SelfCheck`). Within ~2 s of starting, confirm data is actually flowing
(current segment growing / buffers arriving). If not, determine the cause: no TCC permission →
request/guide; `SCStream` did not come up → restart (2–3 attempts); no audio device → clear error.
Never display "recording" when nothing is being written.

**Watchdog while recording.** If the buffer flow stalls for N seconds, flag it and try to restart the
stream while keeping the already written segments; on failure — surface an error in the UI.

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
  `combined.wav` is valid and contains the audio recorded before the crash.
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
