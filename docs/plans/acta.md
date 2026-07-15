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

## Scope of this plan

**One open task.** Tasks 1–9 are done and verified by a live run. Task 10 is the only work in flight.

Everything else lives in `docs/backlog/acta-full-plan.md` — outside `docs/plans/` so it cannot be
selected — and is **not** to be implemented from this plan.

Why one task: four rounds of external review of a large plan found ≈6, then ≈15, then 1 blocker, then
2 blockers, with several of each round's defects introduced while fixing the previous round's. Almost
all of them were **between** tasks — one task's contract contradicting another's. A one-task plan
cannot have that class of defect. The app already records reliably; the seams for everything else are
easier to design from real code than from a document.

**This document is the target, not evidence.** `SPEC.md` and `CLAUDE.md` describe design that is in
places aspirational or now stale. Never close a checkbox because a document says so — close it
because the code and the validation commands say so.

### Task 10: Extract `ActaRuntime` (mechanical move, no behaviour change)

**Why this is the only task.** `ActaTestRunner` depends only on `ActaKit`, while the entire pipeline —
`RecordingController`, `RecordingSession`, `RecoveryManager`, `SegmentWriter`, `SegmentAssembler`,
`MeetingStore`, `SelfCheck`, `AudioRecorder` — lives in the **`Acta` executable target**. SwiftPM
**cannot import an executable target** (verified in `Package.swift`). So nothing above pure logic can
ever be tested end-to-end, which is why every criterion that matters is currently marked
`manual test (skipped - not automatable)`. Until this move happens, no test infrastructure is
buildable at all. Everything parked in the backlog depends on it.

🪤 **The trap in this task is "while I'm here, let me improve X".** Do not. This is a **mechanical
move**. Every seam, fake, façade, clock, filesystem abstraction and harness is **explicitly out of
scope** and lives in the backlog. They are easier to design once the code is importable and the real
boundaries are visible — that is precisely why they are not here.

- [ ] Add an `ActaRuntime` library target depending on `ActaKit`. Add it to `Package.swift` products if needed for the executables to import it
- [ ] **Move, do not rewrite.** `Sources/Acta` keeps **only `ActaApp.swift`** (`@main`, the SwiftUI scene and views). All 16 other files move to `Sources/ActaRuntime` unchanged: `ArchiveOpener`, `AudioRecorder`, `ElapsedTimer`, `FailedStartCleanup`, `MeetingStore`, `Notifier`, `Permissions`, `RecordingController`, `RecordingSession`, `RecoveryManager`, `SegmentAssembler`, `SegmentWriter`, `SelfCheck`, `SessionManifestStore`, `Settings`, `SourceDetector`. (`ArchiveOpener`, `SourceDetector` and `RecordingController` import AppKit/SwiftUI — that is fine, a library target may import them; do not restructure them to avoid it)
- [ ] `Acta` executable depends on `ActaRuntime`; `ActaTestRunner` depends on `ActaRuntime` **and** `ActaKit`
- [ ] Access control: whatever must cross the target boundary becomes `public` — **mechanically**. Do not take the opportunity to redesign, narrow or "clean up" the API surface. A `public` keyword is the whole change
- [ ] **No production source may be copied or duplicated into the test runner**
- [ ] Existing tests in `ActaTestRunner` keep passing **unchanged**, except for `import` lines. Assertions may **not** be deleted, broadened, skipped, or converted into "does not throw"
- [ ] Link proof (this is what makes the blocker gone): a smoke test in `ActaTestRunner` that does `import ActaRuntime` and constructs the pipeline types it previously could not reach. It only has to compile, link and run — it is not an E2E test and must not pretend to be one
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh` (all existing tests green, plus the link smoke test), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` (codesign valid) all pass
- [ ] Acceptance: `ls Sources/Acta` lists exactly `ActaApp.swift`; `ls Sources/ActaRuntime` lists the 16 moved files; `grep -rn "import ActaRuntime" Sources/Acta Sources/ActaTestRunner` shows both importing it
- [ ] Acceptance (manual, needs a human): `Acta.app` launches, records, stops and recovers exactly as before — this move must be invisible in behaviour

**Explicitly NOT in this task** (all parked): the `ControlAPI` façade; `CaptureSource`; fake capture;
the clock/scheduler abstraction; the filesystem or `SegmentSink` seam; `ProcessRunner`; the
permissions seam; characterization scenarios; the process harness; the negative control; dropping
`combined` from the pipeline; any change to the lifecycle, storage format or behaviour.

## Backlog

`docs/backlog/acta-full-plan.md` holds everything else, in the order it should be promoted, plus the
recorded review findings that each parked item still needs fixed **before** it is promoted. Promote
one at a time, after this task has landed and been verified live.
