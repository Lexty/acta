# Plan: Freeze the recording lifecycle as a characterization contract

## Overview

The UI (`ActaApp.swift`) already talks to exactly one pipeline object — `RecordingController` — plus
two plain value types it returns (`MeetingStore.Recording`, `SessionManifest.Status`). So the boundary
between UI and pipeline already exists in one place. What does **not** exist is a machine-checked
statement of *what that boundary does*: the whole recording lifecycle is proven only by hand and by
tests that drive `RecordingSession` directly, never `RecordingController` — the object the UI actually
calls.

This plan writes that statement, and nothing else. It **characterizes** the current, externally
visible behaviour of `RecordingController` by driving the real pipeline through it — using the
`CaptureSource` / `PermissionChecking` / `SelfCheckClock` seams a prior task added, which make a
successful, capture-backed recording reachable in-process — and asserting on the state the UI renders,
the `session.json` transitions, and the artifacts produced. It records behaviour **as it is today**,
faithfully, including the awkward combinations, because the point of a characterization contract is to
catch a *future* change, not to define a nicer design now.

**Why this and not the `ControlAPI` boundary itself.** External review of a combined
"boundary + typed errors + state stream + UI migration" task found it mis-models the state (a single
lifecycle enum cannot represent capture-live-while-idle, an archive error coexisting with recording, or
a fatal stall whose assembly is still running) and quietly bundles two or three tasks under a
"no behaviour change" banner that the state redesign itself violates. The disciplined order is: freeze
the behaviour first (this plan, no behaviour change, no new API), then introduce the observable
`ControlAPI` boundary and migrate the UI in a **separate** plan, protected by the contract this one
produces. That boundary plan is the in-process core of the agent-facing interface; the process-based
crash harness is the plan after it. Both stay in `docs/backlog/acta-full-plan.md`.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (the existing 223 tests **plus** the new characterization scenarios; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md` and every requirement in `CLAUDE.md`. The subject **is** the current source, so read it
directly and characterize what it does — do not change it: `RecordingController` (the lifecycle,
`phase`, the public `isRecording`/`isSaving`/`isBusy`/`hasWorkInFlight`, `errorMessage`,
`recoveredBanner`, `onLaunch`, `onAppear`, `stopAndWait`), `RecordingSession`, `SelfCheck`,
`MeetingStore`, `Diagnostics` (`StartupFailure`), and the Task-A/B seams. The existing controller test
already constructs a non-`shared` controller against a temp archive via
`RecordingController(settingsStore:makeSession:)` with an isolated `SettingsStore` and a factory that
builds `RecordingSession` from the fake source, injected permissions, injected clock and a counting
wake lock — **reuse that construction; it needs no production change.** The whole pipeline is shipped
and verified live (`v0.2.1`); this task puts a contract in front of it and re-implements none of it.

## Scope of this plan

**In:** characterization scenarios in `ActaTestRunner` that drive the real pipeline **through
`RecordingController`** and assert on its externally visible behaviour, freezing today's lifecycle,
observable state, manifest transitions and artifacts exactly as they are.

**Out, and staying parked (each is a later plan):** a `ControlAPI` façade type; a typed `ControlState`
stream; migrating the SwiftUI menu to consume a stream; introducing typed error categories on the
paths that currently produce display strings; a health/recovery signal that needs new plumbing through
`SelfCheck`; a manifest-store or assembler/ffmpeg-location fault seam; the process-based crash harness
(`SIGKILL` + fresh recovery process), the deterministic audio oracle, the filesystem fault seam; and
any socket / CLI transport. **This plan changes no production behaviour and adds no production API — no
new seam, initializer or field.** If a behaviour is reachable but not *observable* through today's
public surface, characterize what is observable and record the gap in the test; do not add plumbing to
observe it (that belongs to the boundary plan).

### Task 1: Characterize `RecordingController`'s lifecycle against the real pipeline

**Why.** A "no behaviour change" refactor of the lifecycle is coming (the observable boundary). "No
behaviour change" is not a contract a test can enforce; a frozen set of scenarios that drive the real
pipeline and assert on real states and artifacts is. This task records that contract. It also directly
extends the automated E2E reach: today the pipeline is characterized only at the `RecordingSession`
level, never at the `RecordingController` level the UI actually uses.

🪤 **Characterize, do not change.** Every checkbox is an assertion about behaviour that already exists.
If satisfying one seems to require editing `RecordingController`/`RecordingSession`/`SelfCheck` or
adding any seam/field, the scenario is wrong or belongs to a later plan — record what the code does, or
record the gap. Assert **only** through today's public surface; never read a `private`/`@Published
private` field.

- [x] **Drive `RecordingController`, not `RecordingSession`.** The scenarios go through the controller's own operations (`start`, `stop`, `stopAndWait`, `onLaunch`, `onAppear`) so the contract covers the coordinator the UI calls — its start/stop task orchestration, its guards, and the public state it exposes. Construct it against a **temp archive** exactly as the existing controller test does (`RecordingController(settingsStore:makeSession:)`, isolated `SettingsStore`, fake source / injected permissions / injected clock / counting wake lock); never touch `RecordingController.shared`
- [x] **Assert only on the public observable surface, as it is.** There is no `ControlState` enum today and this task does not add one. `isStopping` is `@Published private` — **not** observable; use the public derivations instead: `phase`, `isRecording`, `isSaving`, `isBusy`, `hasWorkInFlight`, `errorMessage`, `recoveredBanner`, `recordings`, `suggestedTitle`. ⚠️ Assert the **awkward truths**, not an idealized model, because those are what a refactor is most likely to break — and phrase each in terms of what is public:
  - during startup the capture is live while `phase == .idle` and `isBusy == true` (the self-check window, `isBusy` true via the internal starting flag);
  - after a fatal stall `phase == .error` while `isBusy`/`isSaving` stay true until the background assembly finishes (assembly still in flight is observable only as `isBusy`, not as a private flag);
  - `start()` clears any `recoveredBanner` and `errorMessage` before it begins (so the two banners are never both meaningfully live across a start — do not expect otherwise)
- [x] **Capture the `phase` transitions, do not poll for them.** `phase` is `@Published public private(set)`, so its projected publisher `$phase` is available; subscribe to it and **collect the ordered sequence** across an operation so a brief state such as `.saving` on a small fixture is not missed by sampling "after the await". ⚠️ The derived flags (`isBusy`/`isSaving`/`isRecording`/`hasWorkInFlight`) are **computed properties, not `@Published`** — there are no `$isBusy`-style publishers, and `isStopping` is private — so where a scenario needs one of those (the startup and fatal-stall `isBusy` windows), sample the computed value at the awaited points, or observe `objectWillChange` and read the public derivation on the main actor. Do not claim a per-flag publisher that does not exist. This needs no production change
- [x] **Frozen scenarios — the deliverable. Assert each dimension that *applies* to the scenario** (ordered published state; `session.json` status observed *during* the run, not only the final value; artifacts) — do **not** bolt meaningless assertions onto a scenario where a dimension is nonsensical (a denied start has no session directory to inspect):
  - **success**: the published sequence passes through `isBusy` true / `isRecording` true / `isSaving` true / back to `phase == .idle`; `session.json` observed at status `recording` **during** the run and `done` after; both track files assembled (defined below)
  - **failed start (permission denied)**: `phase == .error`; `errorMessage` equals the derived `StartupFailure.<denied case>.userMessage` (this boundary exposes only the rendered string, as the existing test does — assert that, and do **not** demand a typed failure cross the boundary, which is parked); **no wake lock left held, no phantom session directory left behind** (through the controller's existing `FailedStartCleanup`)
  - **fatal stall**: `phase` reaches `.error`; the audio recorded before the stall is still assembled once the background stop finishes — assert the **completion** (the tracks become valid and `isBusy` returns false), not just that the error appeared
  - **stop idempotence**: a second `stop`, and `stop` when not recording, cause **no observable change** — no published state transition, no new/changed artifact, and no second assembled result. (Do not assert "no manifest write": a rewrite of identical bytes is unobservable, so assert the observable no-change instead)
  - **recovery runs once**: `onLaunch` recovers an interrupted recording; then, with a **new** interrupted folder placed in the archive, a second `onLaunch` leaves that new folder **unrecovered** (the `didRunRecovery` guard). Banner stability is a secondary assertion; notification authorization is explicitly **outside** this claim (`Notifier.requestAuthorization()` runs before the guard, so "no-op" is scoped to recovery)
  - **start clears the recovery banner**: after a launch that sets `recoveredBanner`, calling `start()` clears `recoveredBanner` (and `errorMessage`) as it begins — assert the banner is cleared, since `start()` does this before doing anything else (this is the real behaviour; the two banners are not independently latched across a start)
  - **onAppear vs onLaunch**: `onAppear` refreshes the `recordings` list and does **not** run recovery — place an interrupted folder, call `onAppear`, assert it stays **unrecovered** and that `recordings` reflects the rescan. Do **not** assert that `suggestedTitle` was refreshed: it comes from the live `SourceDetector.detectedSource()`, which has no injected seam and is commonly empty, so its refresh is not deterministically observable here (record that as a gap). Do not write any scenario expecting `onAppear` to trigger or suppress recovery
- [x] ⚠️ **The dangerous concurrency windows, characterized exactly as the code handles them today** (the guards a lifecycle refactor could silently break):
  - `stop()` during startup (before `phase == .recording`) — distinct from the quit path; assert today's outcome
  - `stopAndWait()` during startup awaits the start in flight **then** stops, so capture that was live while `phase == .idle` is actually torn down — assert the fake source received its stop (a naive "stop only when recording" guard would miss this; the quit path depends on it)
  - a second `start()` while starting/recording does not begin a second capture (assert the fake source's start count did not increase)
  - `start()` immediately after a failed start / fatal-stall error — assert today's behaviour, whatever it is
- [x] **Define "assembled track" structurally** (the deterministic audio oracle is parked, so this is the floor, not frame-level fidelity): reuse the pipeline tests' existing check — an `AVAsset` with an audio track and a positive duration, and a file larger than a bare header. "Two paths exist" is not acceptance
- [x] **Not characterizable here — record the gaps, do not fake them.** Two behaviours are real but cannot be *induced* through today's public surface without a parked seam: an assembly failure at the controller level (`SegmentAssembler.locateFFmpeg()` checks absolute paths before `PATH`, so ffmpeg cannot be made "missing" from a test; assembly-failure is already covered at the `SegmentAssembler` layer), and an `openArchive()` failure (forcing `NSWorkspace.open` to fail needs a seam). State both as documented limitations in the test file rather than writing a scenario that cannot run honestly. Likewise `suggestedTitle` (from the un-seamed live `SourceDetector`) is not deterministically assertable and is left as a documented gap. `openArchive()`'s lifecycle-independence (it sets `errorMessage` without changing `phase`) is confirmed by review of the source, noted, and not exercised by a Finder-launching test
- [x] ⚠️ **No behaviour change.** The existing 223 tests stay green **unchanged** except for `import`s and constructor arguments; the new scenarios are additive. (The count in this plan was stale: the real baseline is **214**, measured by stashing the new files and re-running. Not one existing test needed even an import or a constructor argument changed — the three new files are the whole diff, and the 12 new scenarios take the suite to **226**.) Review judges **behavioural** assertions, not line counts: a scenario asserting `#expect(true)` or merely "does not throw" around the lifecycle characterizes nothing
- [x] Acceptance (automatable): the new scenarios run **in-process, with no TCC prompt and no audio device**, under the injected clock — assert the clock's **wait count** as the existing pipeline tests do, not wall-clock time
- [x] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green; no production source changed (this is a test-only task) and no existing assertion changed beyond imports/constructor arguments
- [x] Acceptance (review, not grep): a reviewer confirms each scenario drives the controller through a **public operation the UI calls** and asserts on **published state the UI renders** or a **durable artifact** — never a private field or an internal type reached around the boundary. A scenario that reconstructs the answer instead of observing it characterizes nothing
- [x] Morning check (needs a human, **not** a blocking checkbox): the app still starts, stops, shows state, lists recordings and recovers exactly as before — this task should not have changed any of that. **[manual — skipped, not automatable]** The claim rests on the diff rather than on a run: no production source was touched, so there is no mechanism by which the app's behaviour could differ. `bash Scripts/bundle.sh dev` builds and satisfies its designated requirement.

## Backlog (not this plan)

Next plan: the observable `ControlAPI` boundary — a typed lifecycle+notice state model (not a single
enum), typed error categories on the string paths, one state stream the UI and tests share, and the UI
migrated to consume it — protected by the contract this plan freezes. After that: the process-based
crash harness. After that: the out-of-process socket/CLI transport for agents. All recorded in
`docs/backlog/acta-full-plan.md`.
