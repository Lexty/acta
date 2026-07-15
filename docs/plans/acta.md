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

This plan is deliberately **the core only**: simplify what exists, make it testable, make it correct
under concurrency, and make the outputs trustworthy. Tasks 1–9 are done and verified by a live run.
Tasks 10–13 are open.

Everything else — sleep/lid close, device changes, menu-bar timer, auto-stop on silence, calendar
metadata, the mic-activity prompt, silence trimming — is parked in `docs/backlog/acta-full-plan.md`
and is **not** to be implemented from this plan. It gets promoted back one item at a time, after the
core lands and is verified live. The backlog file lists the known defects each parked item still has.

Why the cut: two rounds of external review found progressively *more* defects (≈6, then ≈15), several
of them introduced while fixing the earlier round. The app already records reliably; the remaining
value is in protecting that, not in adding surface.

### Task 10: Always two tracks — drop combined from the pipeline, mix on demand

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

The only honest use for a mix is *listening back* to a meeting. That is an on-demand need, not a
reason to write a third file on every recording.

- [ ] `SegmentAssembler`: always assemble `system.wav` **and** `mic.wav`. Remove the mix from the pipeline and with it the special cases — building `combined` via intermediate wavs, the "mix impossible" vs "mix failed" distinction, and the mix-related guards on segment deletion
- [ ] `RecordingSettings` (ActaKit): remove `saveSystemTrack`, `saveMicTrack`, `saveCombinedTrack` and the whole `TrackSelection` type, plus the normalisation rule that forced `combined` when nothing was selected. Keep `segmentSeconds`, `archivePath`, `deleteSegmentsAfterAssembly`
- [ ] **Settings migration:** existing `UserDefaults` hold JSON with the removed keys (verified: `{"saveSystemTrack":true,"saveMicTrack":true,"saveCombinedTrack":false,...}`). Decoding must ignore unknown keys and keep the surviving ones — no crash, no reset to defaults. Unit-test with that exact legacy JSON
- [ ] **Define the shared `ProcessRunner` seam here** (protocol + real implementation), and have Export mix use it. Task 11 adopts this same seam for its fakes — do **not** introduce a second runner abstraction later. The runner takes an **explicitly resolved executable path**; resolution stays in `locateFFmpeg()` and is injectable
- [ ] `MenuContent`: drop the "Save tracks" section from Settings; add a per-recording **"Export mix"** action to the recordings list (next to "Open folder")
- [ ] `ExportMix` in `Acta`: `ffmpeg` `amix=inputs=2:duration=longest` over `system.wav`/`mic.wav` → `combined.wav`. Reuse `FFmpeg.mixArgs`. Write to a **temp file and rename atomically** — a failed or killed `ffmpeg` must never leave a plausible-looking `combined.wav`. `ffmpeg` missing → the existing actionable error; a track missing → clear message; an existing `combined.wav` → replaced only on success. Off the main actor via the `ProcessRunner` seam; serialise per folder (no double export)
- [ ] **Export must not race assembly or recovery**: snapshot/validate the identity of its input files (size + mtime, re-checked before commit) and refuse to run against a folder whose session is not `done`/`recovered`
- [ ] Recovery path: assemble both tracks the same way, no mix (`RecoveryManager` must not gain a mix branch)
- [ ] Update the generated `~/Acta/CLAUDE.md` (`MeetingStore.ensureArchiveRoot`): the archive holds `system.wav` + `mic.wav`; `combined.wav` appears only if exported on demand
- [ ] Update tests: delete `TrackSelection` tests; adapt `SegmentAssembler`/`RecordingSettings` tests; keep `FFmpeg.mixArgs` covered (still used by Export mix)
- [ ] Acceptance: `grep -rn "TrackSelection\|saveCombinedTrack\|saveSystemTrack\|saveMicTrack" Sources/` returns nothing; a recording produces exactly `system.wav` + `mic.wav` and no `combined.wav`; both decode fully with plausible durations; `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): record → only two files; press "Export mix" → a valid `combined.wav` (`ffprobe` duration > 0, non-silent); recordings that already contain `combined.wav` are untouched by recording/recovery

### Task 11: Process-based test seam and an approximate E2E harness

**This is the highest-leverage task in the plan, and the easiest to get wrong.** Today every
criterion that actually matters — audio was really recorded, a crash recovered, a stall was caught —
is marked `manual test (skipped - not automatable)`. So the autonomous loop verifies pure functions
and that the thing compiles, and nothing about the job the app exists to do. Two external review
rounds both named this the number one risk: the orchestration that loses recordings is exactly what
is untested, so every component can look right in isolation while being wired together wrong.

🪤 **The trap this task must avoid: becoming a sophisticated component test that never touches the
boundaries where recordings are actually lost.**

- [ ] **Crash tests must be process-based.** `kill -9` **cannot be simulated in-process**: throwing, cancelling a task or dropping an object all run cleanup, which is precisely what a `SIGKILL` does not. The harness must launch a **disposable child executable**, wait until it observes closed segments **plus an open tail**, `SIGKILL` that child, then run recovery **in a fresh process**. Anything less does not test process death, buffered writes, manifest state, or startup recovery discovery
- [ ] **A permanent negative control, not a one-off.** "Prove the harness can fail" must not mean hand-editing production code. Add an **injectable fault** (e.g. a writer decorator that acknowledges a buffer and drops the Nth) and a **permanent test** that runs the harness against that fault and asserts the harness **reports failure**. The outer test passes only because it observed the expected inner failure
- [ ] **One scheduler/clock abstraction**, used for every timed thing: sleeps, deadlines, debounce, the watchdog, pacing. It needs an explicit `advance(by:)` **and a way to drain all work made runnable by that advance**. Ban `Task.sleep`, `DispatchQueue.asyncAfter`, `Timer` and `Date()` in production code above the seam — otherwise tests grow real sleeps and races and go slow and flaky
- [ ] **Name the "real pipeline" boundary.** Scenarios must exercise the production lifecycle coordinator, recorder adapter, segment writers, manifest store, assembler, recovery scanner and controller-visible state. Every scenario **starts through the same canonical operation the UI calls** and asserts on **the same observable state the UI renders**. Tests that reach directly into `SegmentWriter`/`RecoveryManager`/a pure state machine can pass over broken wiring and are not acceptable as E2E
- [ ] `CaptureSource` protocol seam under `AudioRecorder` yielding (track, buffer, timestamp). Real implementation = ScreenCaptureKit; **nothing above the seam may know about `SCStream`**
- [ ] `FakeCaptureSource`: synthetic PCM **per track independently**, with control over level (silence / tone / speech-like), **format** (interleaved and non-interleaved, integer and float, differing channel counts), **stalls**, **errors**, and pacing driven by the injected clock
- [ ] **Injectable filesystem failure seam** — create, write, flush/sync, rename, free-space query, directory sync. Without it the `ENOSPC`/atomicity work in Task 13 can only be tested as pure decision logic. Filling a real volume is not an acceptable test
- [ ] **Permissions/TCC seam**, including a **capture-authorization-lost** event the coordinator can act on (Task 12 consumes it; Task 13 adds the policy)
- [ ] Adopt the **`ProcessRunner` seam defined in Task 10** for `ffmpeg`; do **not** define a second one. 🪤 **A stub earlier on `PATH` will not intercept `ffmpeg`** — the shipped `SegmentAssembler.locateFFmpeg()` checks `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` **before** `PATH` (verified in the source), and `ffmpeg` lives in `/opt/homebrew/bin` on this machine. Inject the resolved executable/runner instead
- [ ] Harness scenarios, at minimum: start → segments appear → stop → both tracks assembled and valid; **child SIGKILLed mid-recording → recovery in a fresh process assembles what survived**; a stalled track → the watchdog reacts; a failing and a **hanging** `ffmpeg` → error surfaced, segments intact
- [ ] **Keep it honest.** This is *approximate* E2E: it does **not** prove ScreenCaptureKit works, TCC prompts appear, or real audio is captured. Those stay manual. Say so in the task and **update `CLAUDE.md`**, whose current claims ("runtime audio and crash recovery are manual only", "validation only checks compilation/build/unit logic") become false the moment this lands. A green harness must never be read as "recording verified"
- [ ] Tasks 12 and 13 each add their scenarios to this harness (named in those tasks); any item later promoted from the backlog must do the same
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh` (with the E2E scenarios **and** the negative control inside it), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green

### Task 12: One serialized recording lifecycle

**Why this exists.** Several actors can already mutate a live recording — manual stop, watchdog
restart, stream error, app termination — and every parked backlog item adds more. Without a single
owner they race.

This is not speculative: the shipped bug history is *entirely* this class — "isStopping symmetric to
isStarting", "await watchdogTask.value before stopping the recorder, otherwise the watchdog's rest()
could bring up a new SCStream after assembly", "run recovery once per launch, not on every menu
open", "the restart budget was a quota for the whole recording rather than per incident". Those were
found by review, one at a time, after the fact. The coordinator is how we stop finding them one at a
time.

- [ ] A single serialized lifecycle owning every transition of a recording (one actor/queue). All mutations go through it; nothing touches `AudioRecorder`/`SegmentWriter`/the manifest directly
- [ ] **Generation/epoch IDs and operation tokens.** "A stale completion must not resurrect a stopped session" is solved by a session generation + per-operation token, not by ad-hoc state checks. The state machine **rejects any completion whose token is no longer current** — start, restart, segment closure, manifest write, assembly, export. Task 13's alignment metadata records the generation, so design the ID now
- [ ] Explicit precedence, encoded and tested: **stop beats restart**; duplicate/burst events coalesce; **capture-authorization-lost** (from the Task 11 seam) is terminal
- [ ] Every operation **idempotent**: a second stop or a repeated event is a no-op, not a second path
- [ ] Pure state machine in `ActaKit` (events → transitions + emitted effects); I/O stays in `Acta`
- [ ] Two test layers, kept distinct: **fake effects** for exhaustive state-machine ordering (cheap, combinatorial), and **the Task 11 harness with real writers** for the integration scenarios. Do not conflate them
- [ ] Scenarios: stop racing a restart; restart completing after stop; restart completing after an error; two stops; error during assembly; termination mid-recording; authorization lost mid-recording
- [ ] Refactor the existing `RecordingSession`/`SelfCheck`/`RecordingController` interactions onto the coordinator **without changing observable behaviour** — the existing tests must stay green
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green, including the harness scenarios above
- [ ] Acceptance (manual, needs a human): a live record → stop → `kill -9` → recover cycle behaves as before the refactor (the automated approximation is the harness; this is the real-hardware confirmation)

### Task 13: Recording durability — locking, timeline, atomic commits, disk failures

Everything so far protects against a process dying. These are the failures that survive that: the
data is written but wrong, or unrecoverable, or the disk says no. Order within the task matters —
locking comes first.

- [ ] **Single-instance locking FIRST, before any recovery scan.** Two Acta processes must not record into or recover the same archive. This is a precondition for orphan scanning: a scan that looks for segment layouts without a valid manifest would otherwise mistake **another live process's in-progress recording** for an orphan
- [ ] **Persisted timeline (this is what makes alignment crash-safe).** Record, durably, per segment: recording time origin, track, segment index, segment start/end timestamps, format and frame count, discontinuity/gap reason, and the lifecycle generation (Task 12). "Remember each segment's start timestamp" in memory is not crash-safe, and orphan recovery cannot reconstruct alignment without this on disk
- [ ] **Track alignment (the dangerous one).** The two tracks are concatenated independently. Any difference in segment count or restart timing — watchdog restarts cause this today — silently drifts "me" against "them" and destroys the attribution the two-track design exists for. Policy: **preserve a shared media timeline**; pad only the asymmetric per-track gaps needed to keep both tracks on it; both outputs get **identical timeline treatment**. Test via the harness: differing segment counts and a mid-recording restart must stay aligned
- [ ] **Asymmetric capture policy.** Decide and implement what happens when one track produced **no buffers at all** (a dead or muted-at-OS-level mic). "Both tracks always produced" must not make a perfectly good system-only meeting impossible to finalise. Options to choose between explicitly: a zero-filled aligned track, or a finalised recording with one track marked absent in `info.md`. Not "recoverable forever"
- [ ] **Paired atomic commit.** Renaming `system.wav.tmp` and `mic.wav.tmp` independently allows a crash between the two renames, leaving files from **different assembly generations**. Use generation-tagged outputs plus a single atomic commit marker/index, or define recovery that detects a partial pair and finishes or rolls it back. Validate (header + duration > 0) before commit
- [ ] **Never delete segments until both final tracks are validated and committed.** `deleteSegmentsAfterAssembly` defaults to true; deleting on an unvalidated assembly destroys the only copy
- [ ] **Partial assembly.** If `system` succeeds and `mic` fails: do not destroy the successful track or the segments, do not mark `done`, leave it recoverable, and say so in the UI
- [ ] **`ffmpeg` hang/failure.** A stuck child leaves the app in "Saving…" forever. Generous timeout, capture exit status and stderr, actionable error, segments preserved on every failure path. Test through the injected `ProcessRunner` (Task 10/11) — **not** via a `PATH` stub, which `locateFFmpeg()` would not pick up
- [ ] **Disk space.** Two PCM tracks cost ~1.38 GB/hour (measured). Check free space before start and warn; during recording fail **visibly** below a safety margin. Handle `ENOSPC` on segment writes, manifest updates, assembly and export — tested through the injectable filesystem seam (Task 11)
- [ ] **Archive becomes unavailable mid-recording** (volume unmounted, directory deleted, path read-only). Be honest about what is possible: Acta **cannot** preserve data that lived only on a vanished volume, and must not invent a failover. Required behaviour: stop claiming a healthy recording **immediately**, preserve whatever is still accessible, and never delete or overwrite anything on reconnection
- [ ] **Capture authorization revoked mid-recording** → the terminal event from Task 11/12; visible error state, segments preserved, never keep showing "recording"
- [ ] **Durability honesty.** Atomic rename prevents a torn manifest but does **not** by itself survive sudden power loss without syncing the file and its parent directory. Decide what to implement, then **state plainly in `SPEC.md`** what is guaranteed against **process death** versus **sudden power loss** — do not imply both. Also fix the stale SPEC claim that a crash loses "at most the last segment": the live run showed `SegmentRepair` recovering a 9.4 s open tail, so the honest claim is "at most the unrepairable remainder of the open segment"
- [ ] Unit tests for the pure parts (timeline/alignment computation, orphan detection, commit-point decisions); harness tests for the failure paths (timeout, `ENOSPC`, partial assembly, partial commit, orphan with a corrupt manifest)
- [ ] **Orphaned segments.** Recovery keys on `session.json status=recording`; a manifest truncated by power loss orphans a whole segment directory **forever**. With locking in place, scan for a recognisable segment layout whose manifest is missing or corrupt, reconstruct what the persisted timeline allows, mark it `recovered`, and **never silently delete**
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): delete `session.json` from an interrupted recording → segments still recovered on next launch; inject a hanging `ffmpeg` → clear error, segments intact, app not stuck in "Saving…"

## Backlog

Parked, **not** in scope for this plan: sleep/lid close, audio device changes, menu-bar timer,
auto-stop on silence, calendar metadata, mic-activity prompt, silence trimming.

They live in `docs/backlog/acta-full-plan.md`, together with the defects each still carries. Promote
one at a time, only after the core above has landed and been verified on real hardware — and re-fix
the listed defects as part of promoting it.
