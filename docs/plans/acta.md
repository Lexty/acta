# Plan: Acta — fault-tolerant online meeting recorder (macOS)

## Overview

A minimal macOS menu-bar app **Acta** that **only records** online meetings: system audio (the other
participants) + microphone, through a single `SCStream`. Works for any source (Slack, Teams, Google
Meet, etc.). Transcription and summarisation are **out of scope** — done separately (the user
already has `mlx_whisper` set up locally).

**Three mandatory recording properties:**
1. **Streaming writes to disk** — data is written incrementally as the meeting goes, not buffered in
   memory and finalised at the end.
2. **Fault tolerance** — after a machine restart/crash, whatever was recorded stays valid and is
   recovered.
3. **Self-diagnosis** — if recording fails to start or stalls, it is detected at once and healed
   (re-request permissions, restart the stream, clear error).

**Read `SPEC.md` before every task** (decisions, API coordinates, Xcode-free build recipe,
crash-safety approach). The `.claude/skills/crash-safe-recording` skill is mandatory for Tasks 2–4.

**Language: English only** across UI, code, docs and git — see `CLAUDE.md`.

Environment: Apple M3, macOS 26.2, Swift 6.3.3, CLT only (no full Xcode), SwiftPM. `ffmpeg` present.

**Definition of Done (v1):** start/stop recording from the menu bar; participant audio and microphone
written as separate streaming tracks; on a forced process kill/restart the already written segments
survive and are finalised automatically on the next launch; a failed start is diagnosed and
healed/reported; everything builds without full Xcode.

## Validation Commands
- `swift build -c release`
- `swift test` (under CLT-only this ONLY COMPILES the tests — there is no `xctest` host utility)
- `bash Scripts/test.sh` (real unit-test run via the executable runner; fails on error)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh`

### Task 1: Package skeleton and Xcode-free build
- [x] `Package.swift`: executable target `Acta` + testTarget `ActaTests`, platform macOS 14+, **no external dependencies** (added `ActaKit` — a library for testable logic — and `ActaTestRunner` — an executable test runner, because CLT-only cannot execute an xctest bundle)
- [x] Empty `Tests/ActaTests/` (stub) so `swift test` passes from the start
- [x] `Sources/Acta/ActaApp.swift`: `@main`, empty `MenuBarExtra` with an icon
- [x] `Resources/Info.plist` (`LSUIElement=true`, `CFBundleIdentifier=dev.personal.acta`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=14.0`) and `Resources/Acta.entitlements` (minimal, no sandbox)
- [x] `Scripts/bundle.sh` (`swift build -c release` → `Acta.app` + Info.plist + `codesign --force --sign - --identifier dev.personal.acta --entitlements`), `Scripts/run.sh`
- [x] Acceptance: `bash Scripts/bundle.sh` builds `Acta.app` without errors (verified); `open Acta.app` shows the menu-bar icon — manual test (skipped - not automatable, requires a GUI session)

### Task 2: Streaming two-track segment recording
- [x] `Permissions.swift`: check/request Screen Recording (`CGPreflightScreenCaptureAccess`) and Microphone
- [x] `AudioRecorder.swift`: a single `SCStream` (`capturesAudio=true`, `captureMicrophone=true`, `excludesCurrentProcessAudio=true`, minimal video config), `.audio`/`.microphone` buffers into separate writers
- [x] **Segmentation** (`SegmentWriter.swift`): write short segments (~10–15 s), each finalised as a valid file (`system/NNNN.wav`, `mic/NNNN.wav`). A crash loses ≤ one segment
- [x] Frequent flushes to disk; no buffering of the whole recording in memory (each buffer is written to the segment writer immediately; nothing accumulates in memory)
- [x] Unit test: the pure function building `ffmpeg` arguments (concat/mix) is covered (`FFmpeg.concatArgs`/`mixArgs`/`concatListContents` + segment layout `SegmentLayout`)
- [x] Acceptance: a 60 s recording creates several segments; each segment is valid (`ffprobe` duration > 0) — manual test (skipped - not automatable, requires TCC Screen Recording + Microphone and a live audio session)

### Task 3: Fault tolerance and recovery after restart
- [x] `session.json` in the recording folder: `status` (recording/done/recovered), `started_at`, config, segment count — kept up to date (`SessionManifest` in ActaKit — pure JSON logic, snake_case + ISO-8601; `SessionManifestStore` — atomic write/read from the FS; written on start/stop via `RecordingSession`)
- [x] Clean stop: `status=done`, concatenate segments into `system.wav`/`mic.wav` + combined `combined.wav` via `ffmpeg`, delete segments (or keep them — per settings) (`RecordingSession.stop(deleteSegments:)` → `SegmentAssembler.assemble`; if assembly fails the marker stays `recording` so recovery retries — data is not lost)
- [x] `RecoveryManager.swift`: on app launch find folders with `session.json status=recording` (crash/restart happened) → assemble surviving segments, `status=recovered` (scans the archive, `Recovery.needsRecovery`, a failure in one folder is isolated, segments are kept as raw material during recovery)
- [x] Unit tests: recovery logic (build the correct assembly list from a set of segments; a corrupt trailing segment is dropped without failing) (`RecoveryTests`: `Recovery.recoveryPlan` — ordering/junk filtering/dropping a corrupt last segment by size; round-trip and hand-written JSON for `SessionManifest`)
- [x] Acceptance: kill the process during recording (`kill -9`), relaunch `Acta.app` → the unfinished recording is finalised automatically, `combined.wav` is valid and contains the audio recorded before the crash — manual test (skipped - not automatable, requires TCC Screen Recording + Microphone, a live audio session and `kill -9`)

### Task 4: Startup self-diagnosis and watchdog
- [x] `SelfCheck.swift`: within ~2 s of starting, verify data is actually flowing (segment growing / buffers arriving). If not — diagnose the cause (no TCC permission, `SCStream` did not start, no audio device) (`SelfCheck.verifyStartAndHeal` polls `AudioRecorder.receivedBufferCount`; the diagnosis is the pure `SelfDiagnosis.diagnose` in ActaKit)
- [x] Auto-healing: no permission → request/guide; stream did not come up → restart (2–3 attempts); still failing → **a clear error in the menu bar**, never a "silent" recording status (`SelfDiagnosis.action` picks the action; `RecordingSession.start` throws `StartupFailure` with `userMessage` on failure, stopping the recorder first; `AudioRecorder.restart` restarts the stream while keeping segments)
- [x] Watchdog while recording: the buffer flow stalls for N seconds → flag it and restart the stream, keeping the already written segments (`SelfCheck.runWatchdog` over `FlowWatchdog`; `SegmentWriter.finishAndAdvance` advances the index so a restart does not overwrite a closed segment; the task starts in `RecordingSession.start` and is cancelled in `stop`)
- [x] Tracks are diagnosed separately: a live track must not mask a dead one (that is half the meeting). A breakage is "the track's buffers arrive but the writer accepted none" (`TrackFlow.isWriteBroken`) — at startup that is `SelfDiagnosis.brokenTrack` → `.diskWriteFailed`, during recording it is a per-track `TrackWatchdog` in addition to the aggregate `FlowWatchdog`. A silent source (no buffers at all) is **not** treated as a breakage — silence in a meeting room is indistinguishable from a dead device, so it is only logged
- [x] Unit tests: the "data is not flowing" detector on a fake source; action selection by failure type (`DiagnosticsTests`: `isDataFlowing`/`diagnose` over snapshots, `action` by type and remaining attempts, `FlowWatchdog`/`TrackWatchdog` over synthetic counter sequences, a dead track alongside a live one — 27 tests)
- [x] Acceptance: starting a recording without Screen Recording granted → the app immediately shows a clear error and how to fix it, instead of recording nothing — manual test (skipped - not automatable, requires a TCC session and GUI; the logic is covered by `diagnoseNoScreenRecordingFirst`/`failureMessagesAreNonEmptyAndActionable`)

### Task 5: Recording store and list
- [x] `MeetingStore.swift`: folder `~/Acta/YYYY-MM-DD_HHMM__<slug>/` with audio and `info.md` (YAML front-matter: `title,date,source,duration,status`) (FS side in the `Acta` target: `createMeetingDirectory` with a de-duplicating suffix, `writeInfo`, `listRecordings` driven by `session.json`, `~/Acta/CLAUDE.md`; pure layout/serialisation logic — `MeetingArchive`/`MeetingInfo` in ActaKit: slug from title, folder name, YAML front-matter with double-quoted escaping, `duration` as HH:MM:SS)
- [x] Unit tests: slug generation and YAML front-matter serialisation (pure functions) (`MeetingArchiveTests`: slug — case/separator folding/Cyrillic/fallback/truncation; folder name; `formatDuration`; front-matter fields and special-character escaping — 12 tests)
- [x] Acceptance: the folder is created; `info.md` parses as YAML — manual test (skipped - not automatable without a YAML parser under CLT-only; pure slug/folder-name/front-matter generation is unit-tested, FS layout is `MeetingStore`)

### Task 6: Menu-bar UX
- [x] Start/stop, recording timer, state indicator (idle/recording/error/recovered) (`RecordingController` — a @MainActor view model: idle/recording/error phase + recovery banner, per-second `elapsedString` timer; `MenuContent` in `ActaApp.swift` shows the state icon/colour/text and a monospaced timer; start/stop drive `RecordingSession`)
- [x] Title field (optional suggestion from running apps via `NSWorkspace`) (`SourceDetector` collects running app names via `NSWorkspace`, pure matching — `MeetingSource.detect`/`suggestedTitle` in ActaKit; the `title` field is pre-filled with the suggestion, empty → auto title on start)
- [x] Recent recordings list, "open folder" action; self-diagnosis errors shown prominently (`MenuContent.recordingsList` via `MeetingStore.listRecordings`, folder button → `openInFinder`/`activateFileViewerSelecting`; a start failure from `StartupFailure.userMessage` is shown as a red banner rather than a silent recording)
- [x] Local notification when a recording is saved/recovered (`Notifier` over `UNUserNotificationCenter`, safe outside an `.app`; notifications are sent on a clean stop and on auto-recovery at launch)
- [x] Acceptance: the whole cycle is reachable from the menu bar with the mouse; start errors and recovery are visible in the UI — manual test (skipped - not automatable, requires a GUI session and TCC; UI state/source-suggestion logic is covered by `MeetingSourceTests`, bundling by `bash Scripts/bundle.sh`)

### Task 7: Settings
- [x] `Settings.swift`: archive path; which tracks to keep (system/mic/combined); segment length; whether to delete segments after assembly (pure `RecordingSettings` model in ActaKit — Codable + normalisation: clamp segment length to `[5,120]`, force `combined` when nothing is selected, resolve `~`/absolute archive paths; persistence in UserDefaults — `SettingsStore` in the `Acta` target; application — `RecordingSession(settings:)` passes segment length and `TrackSelection`/`deleteSegments` into `SegmentAssembler.assemble(tracks:)`, `combined` is built via intermediate wavs even when `system`/`mic` are deselected; UI — the Settings section in `MenuContent`; unit tests — `RecordingSettingsTests`: defaults, clamping/idempotent normalisation, path resolution, `TrackSelection`, Codable round-trip and partial JSON — 14 tests)
- [x] Acceptance: changing the archive path and segment length takes effect for a new recording (in code: `RecordingController` reads settings at the start of every recording — `store`/`archiveRoot` are derived from current settings, `performStart` snapshots `settings.normalized()` for the folder and `RecordingSession`; path resolution/length clamping are unit-tested) — live GUI run manual (skipped - not automatable, requires the menu bar and TCC)

### Task 8: Defects found by the live run

Context: on 2026-07-15 an end-to-end live run was performed (build, 104 unit tests, a real recording,
`kill -9` during recording, auto-recovery). The core design is confirmed and works. Below are three
real defects found by that run. Priority: 8.1 (data loss) → 8.2 → 8.3.

**Run facts** (recording `~/Acta/2026-01-15_1621__slack-2026-01-15-16-21/`, `segment_seconds=15`):
at the moment of `kill -9` there were 12 segments on disk (`system/0000..0011.wav`,
`mic/0000..0011.wav`); recovery assembled 11 → `165.0 s`; before the crash `session.json` contained
`"segment_count": 0`; a previous recording had `info.md duration: 00:00:29` with `23.66 s` of actual audio.

#### 8.1 A valid last segment is discarded (data loss)
Recovery threw away `system/0011.wav` even though the segment is **not corrupt**: `ffprobe` reads it
as a valid **2.92 s** of real audio. The "last segment is suspicious → bin it" rule is too coarse and
discards data that could be saved. This breaks the "we lose at most one segment" promise.
Correct behaviour: try to use the last segment — if it is valid, include it; if the header is
unfinished, **repair it from the actual file size** (truncating to a whole number of frames); only if
there is no data at all, drop it.
- [x] In `Recovery.recoveryPlan` (ActaKit) replace the unconditional rejection of the last segment with: valid → include; header unfinished → repair from actual size; empty/junk → drop (`Recovery.action` → `.include`/`.repair(WAV.HeaderRepair)`/`nil`; the plan is now `[PlannedSegment]`, and `SegmentAssembler.preparedSegments` applies the repair to the file — sizes written, file truncated to whole frames — right before `ffmpeg`)
- [x] Reuse the existing WAV-header validation logic (tests `finalizedHeaderAccepted`, `headerPromisingMoreThanFileHasRejected`, `headerWithoutChunksRejected`) — apply it as "repair", not only as "reject" (the chunk walk/PCM validation moved to a shared pure `WAV` in ActaKit: `WAV.layout`/`headerRepair`/`durationSeconds`; `Recovery.isFinalizedWAVHeader` keeps its semantics on top of it and now only answers "is a repair needed")
- [x] Unit tests: last segment valid → included; header unfinished but data present → repaired and included (duration = actual data); file empty/0 frames → dropped without failing (`WAVTests` — 12 tests: duration from data/clamping/header-only, repair sizes + truncation to whole frames, round-trip read-back, `FLLR` padding; `RecoveryTests.recoveryPlanRepairsLastSegmentWithUnfinalizedHeader`/`recoveryPlanKeepsEveryLiveRunSegment`)
- [x] Acceptance: `swift build -c release` + `bash Scripts/test.sh` green (120 tests); for the segment set in the run facts above the recovery plan yields **12** segments (≈167.9 s), not 11 — verified in the unit test **and** against the real crash artifacts: `Recovery.action` on the actual `system/0011.wav` returns `.repair`, after which `ffprobe` reads it as valid 2.92 s and `ffmpeg -f concat -c copy` over all 12 assembles **167.92 s** with a clean decode

#### 8.2 `segment_count` in `session.json` is never updated during recording
Before the crash the manifest held `"segment_count": 0` while 12 real segments were on disk. Today
this does not break recovery (which scans the FS), but the field is useless and misleading: had
recovery trusted it, it would have concluded there were no segments and lost the whole recording.
- [x] Update `segment_count` in `session.json` as each segment is closed (atomic write, no races with audio writing) (`SegmentWriter.onSegmentFinalized` fires on segment close → `AudioRecorder.countFinalizedSegment` folds both tracks into a lock-guarded `SegmentProgress` → `RecordingSession.persistSegmentCount` writes the marker on its own serial `manifestQueue`, so the disk write never lands on the audio queue; the counter only ever grows and never rewrites `status`, and `stop()` drains the queue before the final write so a late update cannot turn `done` back into `recording`)
- [x] Recovery **must not trust** the counter as the source of truth — the FS stays primary (the counter is informational/diagnostic only) (`Recovery.recoveryPlan` takes only file names/sizes/headers — the manifest is not among its inputs and cannot be; documented on both the plan and `SegmentProgress`)
- [x] Unit tests: the counter grows as segments are closed; when the counter and the FS disagree, recovery follows the FS (`SegmentProgressTests` — 3 tests: the count grows per closed segment and reports the leading track; a plan built from 3 on-disk segments while the manifest still says `0`)
- [x] Acceptance: while recording, `session.json` shows a number matching the count of closed segments on disk — live GUI run manual (skipped - not automatable, needs TCC + a real audio session); the wiring is unit-tested end to end as pure logic

#### 8.3 `duration` is overstated by SCStream startup latency
A cleanly stopped recording reported `info.md duration: 00:00:29` with `23.66 s` of actual audio
(~5.3 s off). The cause is not data loss: duration is computed from wall-clock (start→stop) while
`SCStream` does not come up instantly and no audio flows for the first seconds.
(Confirmation: on recovery `duration` = 165 s = 11×15 — it matches the audio.)
- [x] Compute `duration` for `info.md` from the **actual duration of the assembled audio**, not from the clock (`SegmentAssembler.Result.durationSeconds` — measured by `WAV.durationSeconds` over the assembled `combined.wav`/`system.wav`/`mic.wav`; `RecordingController.savedDuration` uses it on a clean stop and on a fatal stall, `RecoveryManager` on recovery; the wall clock stays only as a fallback for when assembly failed and there is nothing to measure)
- [x] Unit test: duration computed from segment/audio lengths rather than from a time interval (`WAVTests.durationComesFromDataNotFromTheClock` and neighbours: an unfinalised header measured from real file size, a declared size clamped to what the file holds, header-only file → 0)
- [x] Acceptance: `duration` in `info.md` matches `ffprobe` on `combined.wav` (tolerance ≤ 0.5 s) — verified on the assembled real recording: `WAV.durationSeconds` = 167.92 s vs `ffprobe` 167.92 s (0.00 s apart; `info.md` rounds to 168)

### Task 9: Translate UI and code to English

The project convention is **English only** (see `CLAUDE.md`): UI, code, comments, docs, git.
Docs, skills, scripts and git history have already been converted. What remains is the app itself:
user-facing strings and Russian comments left in the Swift sources.

- [x] Translate all user-facing UI strings to English (menu bar, buttons, statuses, banners, errors, notifications) (`ActaApp.swift` — "Ready to record"/"Recording"/"Saving…"/"Error", "Start Recording"/"Stop", "Title"/"Meeting title", "Recent Recordings"/"No recordings yet", "Open Archive", "Open folder in Finder", "Quit", the Settings section — "Archive folder"/"Save tracks"/"System audio (system.wav)"/"Microphone (mic.wav)"/"Mix (combined.wav)"/"Segment length: N s"/"Delete segments after assembly", statuses "saved"/"recovered"/"unfinished"; `RecordingController.swift` — the recovery banner "Recovered 1 interrupted recording.", notifications "Recordings recovered"/"Recording saved", the ffmpeg-missing and assembly-failed messages)
- [x] Translate Russian comments in the Swift sources to English (e.g. the header comment in `Package.swift`); keep the technical detail, do not drop it (all 37 files: `Package.swift` keeps the full CLT-only rationale for why `ActaKit`/`ActaTestRunner` exist; the crash-safety, watchdog, `manifestQueue` ordering and header-repair reasoning is preserved sentence-for-sentence, along with every live-run number cited in the tests)
- [x] Translate the generated archive file `~/Acta/CLAUDE.md` written by `MeetingStore` to English (the `ensureArchiveRoot` literal — folder layout, `system.wav`/`mic.wav`/`combined.wav`, `info.md`, `session.json`, the `mlx_whisper` note)
- [x] Error/log messages produced by the code (including `StartupFailure.userMessage`) must be English and actionable (every `os.Logger` call across `Acta`; `Diagnostics.userMessage` now names the exact System Settings path, e.g. "No Screen Recording access. Grant it in System Settings > Privacy & Security > Screen Recording, then restart Acta."; track names are "system audio"/"microphone")
- [x] Unit tests that assert on Russian strings must be updated accordingly (`MeetingSourceTests` → "Meeting 2023-11-14 22:13"; `DiagnosticsTests` → `.contains("Screen Recording")`; `WAVTests.Issue.record` → English. `MeetingArchiveTests.slugKeepsUnicodeLetters` is **kept** — `MeetingArchive.slug` deliberately supports Cyrillic titles (valid in macOS file names), so the test retains its exact behaviour with both strings written as `\u{…}` escapes to keep the sources ASCII-only)
- [x] Translate `Resources/`: `NSMicrophoneUsageDescription` in `Info.plist` (macOS shows it verbatim in the TCC microphone dialog — the most visible string the app has) and the comments in `Acta.entitlements`. Missed on the first pass because the acceptance grep below was scoped to `Sources/ Tests/ Package.swift` and never looked at `Resources/`
- [x] Acceptance: `grep -rP '[\x{0400}-\x{04FF}]' --exclude-dir=.git --exclude-dir=.build .` returns nothing — repo-wide, **not** scoped to `Sources/`: the narrow grep is exactly what let a Russian TCC prompt through. Plus `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh` (exit 0) and `bash Scripts/bundle.sh` (codesign valid) all green. Note: `os.Logger` takes an `OSLogMessage`, not a `String`, so long log lines are wrapped with `"""` + `\` continuations rather than `+` concatenation

### Task 10: Offer to record when another app starts using the microphone

Problem this solves: the recording is easy to forget. When a call starts, some app (Slack, Teams,
Meet in a browser, …) opens the microphone — that is a reliable "a meeting is probably starting"
signal. Acta should notice it and offer to record **once**, with a button, without stealing focus.

Read the `.claude/skills/mic-activity-detection` skill before starting — it holds the verified API
facts and the gotchas (unreliable `IsRunningInput` listeners, Bluetooth mics, the Swift listener
removal bug). **Do not invent CoreAudio API — check the docs.**

Decided behaviour (agreed with the user):
- Trigger on **any** app, not an allow-list — a new meeting tool must not be missed.
- **Dwell filter ≥ 5 s**: only treat sustained input as a real session; this drops Siri and short
  device probes.
- The notification names the app ("Slack is using the microphone. Record this meeting?").
- **Once per activation**: fire on the idle → active transition only; do not repeat while the mic
  stays busy, and do not re-prompt if the user ignored/dismissed that activation. Re-arm only after
  the mic goes idle again.
- Never prompt while Acta is already recording.
- Ignore list in Settings (by bundle identifier) + a master toggle to disable the whole feature.

- [ ] `MicActivityMonitor.swift` (in `Acta`): enumerate `kAudioHardwarePropertyProcessObjectList`, read `kAudioProcessPropertyPID` + `kAudioProcessPropertyIsRunningInput`, map PID → `NSRunningApplication`. Use a listener **plus** a light poll (1–2 s) — per the skill, `IsRunningInput` listeners are unreliable on their own
- [ ] **Exclude Acta's own PID**, otherwise recording triggers the monitor on itself
- [ ] Pure logic in `ActaKit` (`MicActivity`): given snapshots of (pid, bundleID, isRunningInput, timestamp) decide `shouldPrompt` — dwell threshold, idle→active edge, one-shot per activation, re-arm on idle, ignore list, self-exclusion. No I/O here so it is unit-testable
- [ ] Actionable notification: `UNNotificationCategory` + `UNNotificationAction` "Start Recording"; handle the response in `UNUserNotificationCenterDelegate` and start recording with the detected app as the title source (reuse `MeetingSource`/`suggestedTitle`). Extend the existing `Notifier`
- [ ] Settings: master toggle (default on) + ignore list by bundle identifier; extend `RecordingSettings` (Codable + normalisation) and the Settings section in `MenuContent`
- [ ] Unit tests for `MicActivity` (pure): blip < 5 s → no prompt; sustained ≥ 5 s → exactly one prompt; still active → no second prompt; idle then active again → prompts again; ignored bundle → no prompt; Acta's own PID → no prompt
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): start a Slack/Meet call → within ~5 s a notification with a "Start Recording" button appears naming the app; pressing it starts a recording; no second notification for the same call; Siri or a 1–2 s mic blip produces no notification; starting a recording from the menu bar does not trigger a self-prompt

### Task 11: Attach calendar event data to the recording

Problem this solves: a recording is currently identified by "Slack — 2026-07-15 18:28". If the
meeting is in the calendar, the archive should carry the real thing — title, agenda, participants —
so it is searchable and worth returning to. This is the metadata the whole archive idea rests on.

Read the `.claude/skills/eventkit-calendar` skill first — it holds the verified API facts and the
macOS 14+ authorization trap. **Do not invent EventKit API — check the docs.**

Design:
- **Drift between the calendar and reality is the norm, not the exception** — the matcher must
  tolerate it. Real cases that must all work:
  - the call is at 15:00, you join and hit record at 15:08 (started late);
  - you hit record at 14:50, before the scheduled start (started early);
  - the 15:00–15:30 meeting actually ran 15:35–16:05, so at record time the calendar event has
    **already ended** and there is no overlap at all;
  - you start recording 40 minutes into a long meeting.
  A naive "event covering the recording start" rule fails cases 2 and 3.
- **Two-phase matching.** The folder is created at start, so a provisional match is needed then; the
  full picture only exists at stop. Do a provisional match at start (for the title/folder) and
  **re-match at stop** over the full recording interval to finalise `info.md`. Do **not** rename the
  folder afterwards — record the final event in `info.md` instead.
- **Graceful degradation is mandatory**: no permission, no calendar, or no match → record exactly as
  today, just without calendar metadata. Calendar access is never a precondition for recording.
- The event title becomes the recording title **only when the user did not type one** (an explicit
  title always wins). This also improves the folder slug.
- Keep matching **pure** in `ActaKit`; EventKit I/O stays in `Acta`.

- [ ] `Resources/Info.plist`: add **`NSCalendarsFullAccessUsageDescription`** (English, per convention; macOS shows it verbatim). Without this key TCC refuses before EventKit is reached and no prompt ever appears
- [ ] `CalendarService.swift` (in `Acta`): `requestFullAccessToEvents()`, status `.fullAccess`; fetch events via `predicateForEvents(withStart:end:calendars:)` over a **widened** window (recording interval expanded by the drift tolerance on both sides — note the predicate returns events *overlapping* the range, not only those starting in it). Never block or fail a recording on calendar errors
- [ ] Pure `CalendarMatch` in `ActaKit`: given plain structs (title, start, end, isAllDay, currentUserStatus, …) + the recording interval → best match, **tolerant of calendar/reality drift**. Tiered rules, applied in order:
  1. **Maximum overlap** with the recording interval wins (handles joining late and recording the middle of a long meeting);
  2. no overlap at all → **nearest event by start time** within the drift tolerance (handles recording before the scheduled start, and a meeting that ran so late the event had already ended);
  3. nothing within tolerance → **no match** (and the recording proceeds normally).
  Always: **exclude/de-prioritise all-day events** (otherwise every recording matches "Vacation"); de-prioritise events the current user declined; break ties deterministically (shortest event, then earliest start, then `event_id`) — never arbitrary
- [ ] Extend `MeetingInfo` (ActaKit) + `info.md`: front-matter gains `event_title`, `event_start`, `event_end`, `organizer`, `attendees` (list), `location`, `calendar`, `event_url`, `event_id`; the event **notes/agenda** go into the `info.md` body under a heading (they can be long and multi-line — front-matter is the wrong place). Keep the existing YAML escaping rules
- [ ] Attendees: take `name` from `EKParticipant`; for the email use the `mailto:` `url` — **verify against the SDK** whether a public `emailAddress` exists before using it. Mark the current user via `isCurrentUser`
- [ ] Title: use the matched event title when the user left the title empty; an explicitly typed title always wins. Feed the same value to `MeetingArchive.slug` for the folder name
- [ ] Settings: master toggle for calendar lookup (default on) + **drift tolerance in minutes** (default 15; this is the knob for how far the calendar may disagree with reality); extend `RecordingSettings` (Codable + normalisation, clamp to a sane range) and the Settings section
- [ ] Never log event notes — they routinely contain join links and passcodes (they stay local, but must not leak into `os.Logger`)
- [ ] Unit tests for `CalendarMatch` (pure, no calendar needed) — **the drift cases are the point**:
  - recording fully inside the event (joined on time) → matched;
  - recording starts 8 min after the event start (joined late) → matched by overlap;
  - recording starts 10 min **before** the event start, no overlap yet → matched by nearest-start within tolerance;
  - event 15:00–15:30 but recording 15:35–16:05 (meeting ran late, **zero overlap, event already ended**) → matched by nearest-start within tolerance;
  - same but the recording starts 2 h later → **no match**;
  - recording covers the middle of a long meeting → matched by overlap;
  - two overlapping events → the one with the larger overlap wins; equal overlap → deterministic tie-break;
  - all-day event alongside a real one → the real one wins; all-day only → no match;
  - declined event de-prioritised;
  - nothing within tolerance → no match, recording still proceeds
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): with a real meeting in the calendar, start a recording → `info.md` front-matter carries the event title/participants/organizer and the agenda appears in the body; the folder is named after the event. **Drift check:** start a recording ~10 min after the scheduled start and confirm the event is still matched. **Degradation check:** deny Calendar access → recording proceeds normally, no calendar fields, no crash

Synergy with Task 10: once this lands, the mic-activity notification can name the meeting
("Record 'Weekly sync'?") instead of just the app. Wire it up if both tasks are done.

### Task 12: Always two tracks — drop combined from the pipeline, mix on demand

This task **removes** code. `combined.wav` is derived data and it costs three ways:

1. **A full extra copy on disk** — a 100 s recording is ~19 MB per track; the mix adds ~19 MB more
   for something `ffmpeg` reproduces in seconds.
2. **It is the most fragile path in assembly.** Nearly every bug from the review history clusters
   around the mix: "mix impossible was indistinguishable from mix failed", "combined is built via
   intermediate wavs even when system/mic are deselected", "do not delete the only copies of audio
   when the mix failed". Removing the mix deletes that whole class of failures.
3. **It destroys the attribution the two tracks exist for.** Separate `system`/`mic` give
   "me vs. them" for free; the mix collapses it back into a single blur. For transcription two files
   are strictly better — run each one and you know who said what.

The only honest use for a mix is *listening back* to a meeting, where two files are awkward. That is
an on-demand need, not a reason to write a third file on every recording.

Decided (agreed with the user): **always write both tracks**; no mix in the recording pipeline;
provide an on-demand "Export mix" action. The track-selection setting disappears with it.

- [ ] `SegmentAssembler`: always assemble `system.wav` **and** `mic.wav`. Remove the mix from the pipeline and with it the special cases — building `combined` via intermediate wavs, the "mix impossible" vs "mix failed" distinction, and the mix-related guards on segment deletion
- [ ] `RecordingSettings` (ActaKit): remove `saveSystemTrack`, `saveMicTrack`, `saveCombinedTrack` and the whole `TrackSelection` type, plus the normalisation rule that forced `combined` when nothing was selected. Keep `segmentSeconds`, `archivePath`, `deleteSegmentsAfterAssembly`
- [ ] **Settings migration:** existing `UserDefaults` hold JSON with the removed keys (verified: `{"saveSystemTrack":true,"saveMicTrack":true,"saveCombinedTrack":false,...}`). Decoding must ignore unknown keys and keep the surviving ones — no crash, no reset to defaults. Cover with a unit test using that exact legacy JSON
- [ ] `MenuContent`: drop the "Save tracks" section from Settings; add a per-recording **"Export mix"** action to the recordings list (next to "Open folder")
- [ ] `ExportMix` in `Acta`: run `ffmpeg` `amix=inputs=2:duration=longest` over `system.wav`/`mic.wav` → `combined.wav` in the same folder. Reuse `FFmpeg.mixArgs` and `SegmentAssembler.locateFFmpeg()`. Handle honestly: `ffmpeg` missing → the existing actionable error; a track file missing → clear message; `combined.wav` already present → overwrite. Run off the main actor; never block the UI
- [ ] Recovery path: assemble both tracks the same way, no mix (`RecoveryManager` must not gain a mix branch)
- [ ] Update the generated `~/Acta/CLAUDE.md` (`MeetingStore.ensureArchiveRoot`): the archive holds `system.wav` + `mic.wav`; `combined.wav` appears only if exported on demand
- [ ] Update tests: delete `TrackSelection` tests; adapt `SegmentAssembler`/`RecordingSettings` tests; keep `FFmpeg.mixArgs` covered (it is still used by Export mix)
- [ ] Acceptance: `grep -rn "TrackSelection\|saveCombinedTrack\|saveSystemTrack\|saveMicTrack" Sources/` returns nothing; a recording produces exactly `system.wav` + `mic.wav` and no `combined.wav`; `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): record → only two files appear; press "Export mix" → a valid `combined.wav` is produced (`ffprobe` duration > 0, non-silent); existing recordings that already contain `combined.wav` are left untouched
