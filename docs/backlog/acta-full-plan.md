# Backlog (NOT for execution)

> A **backup and staging area**, not a plan to run. Kept outside `docs/plans/` so ralphex cannot
> select it. `docs/plans/acta.md` holds the single task that is actually in flight.
>
> **Why this exists.** Four rounds of external review of a large plan found ≈6, then ≈15, then 1
> blocker, then 2 blockers — several of each round's defects introduced while fixing the previous
> round's. The defects were almost all **between** tasks: one task's contract contradicting another's.
> So the plan was cut to a single task. A one-task plan cannot have that class of defect.
>
> Promote **one item at a time**, only after the in-flight task has landed and been verified live —
> and re-fix the recorded findings as part of promoting it.

---

## Found live on 2026-07-15 — two defects, both proven on real hardware

### 1. The display going dark kills the recording (severe, everyday)

Observed, not theorised. A dev-build recording started 21:09:47 local and stopped on its own at
~21:12:07. `pmset -g log` shows **`Display is turned off` at 21:12:09** — the same moment.

Chain: the display sleeps → ScreenCaptureKit (a *screen* capture API) loses the stream → the watchdog
sees no buffers → restarts → fails while the display is off → exhausts its budget → stops the
recording and reports an error. `session.json` ends at `status: done` with a clean assembly, which is
why it looks like a normal stop rather than a crash.

**The app behaved exactly as designed** (Task 4: never show "recording" when nothing is written). The
design is what is wrong.

The parked "Survive sleep and lid close" item **underestimates this**. Its own text says
`screensDidSleepNotification` is "a different event — the screen sleeping does not mean the system
slept", and treats it as the lesser case. It is the **greater** case: system sleep and lid close are
occasional, while the display goes dark after a few minutes of inactivity. Sitting in a meeting
listening, not touching the keyboard, is the *normal* state — and it kills the recording. This is a
failure on every other meeting, not an edge case.

When promoting that item: handle `screensDidSleepNotification` **first and primarily**, keep the
stream alive across display sleep (or re-establish it immediately and account for the gap), and only
then worry about system sleep. Verify by letting the display sleep during a recording — that is now a
required acceptance test, not an optional one.

### 2. Logging: works, but lives in the wrong place

⚠️ **Correction.** An earlier version of this entry claimed the app produced no retrievable logs and
that failures were uninvestigable. **That was wrong** — a broken diagnostic, not a defect. In the
investigating shell `log` is a **zsh builtin**, so every `log show …` query silently returned nothing.
Through `/usr/bin/log` the record is complete and persisted, and it explains the incident above
better than `pmset` did, quoting macOS itself:

```
21:12:09.818  AudioRecorder  Stream stopped with an error:
                             "Failed to find any displays or windows to capture"
21:12:16.546  SelfCheck      Watchdog: recording stalled, restarting stream (attempts left: 2)
21:12:22.825  SelfCheck      Watchdog: recording stalled, restarting stream (attempts left: 1)
21:12:29.199  SelfCheck      Watchdog: recording stalled, restarting stream (attempts left: 0)
21:12:35.501  SelfCheck      Watchdog: recording stalled, giving up
21:12:35.508  RecordingController  Watchdog: data stream is gone — recording stopped, error shown
```

The self-diagnosis of Task 4 works, and it says exactly what happened. Read the logs with
**`/usr/bin/log show --info --debug --predicate 'subsystem == "dev.personal.acta"'`** — note the
absolute path.

What is genuinely worth improving (convenience, not a hole):
- `AppInfo.bundleID` is a **hardcoded** `"dev.personal.acta"` used as the `Logger` subsystem, so both
  flavors log under the same subsystem and cannot be told apart. It is used *only* for logging —
  identity comes from `Info.plist` — so the flavor split is otherwise unaffected. Derive it from the
  real bundle identifier.
- `log.info` (14 call sites) is not persisted by `os_log`, so "session started/stopped" is gone by
  the time anyone investigates. Lifecycle events should use a persisted level.
- The record lives in the **system log store**, which rotates and is keyed by time rather than by
  recording. Nice to have: a **durable event journal in the recording folder itself** (e.g.
  `events.log` beside the audio) with every lifecycle transition — start, stall, restart, stop and
  its reason, assembly, recovery. Local, private, sits with the audio it explains, survives
app restarts and log rotation. This is the persisted form of the `ControlAPI` event/trace stream
already designed in the parked harness work — build them as one thing, not two.

Also: lifecycle events must be logged at a **persisted** level, not `.info`; and the subsystem must
come from the real bundle identifier so the two flavors are distinguishable.

---

## Round 4 review findings — apply these when promoting the relevant item

These are real defects found in the parked text below. They are **not fixed** in it.

**Blocker — the timeline cannot describe the open tail.** "One atomic sidecar per *finalised*
segment" leaves the segment that is open at `SIGKILL` with no descriptor — and that is exactly the
9.4 s tail the live run recovered via `SegmentRepair`. Frame count and duration can be derived from
the repaired WAV; its start position, gaps, format transitions and relationship to the other track
cannot. Alignment and orphan recovery therefore cannot be implemented honestly. Required ordering:
**persist an open-segment descriptor atomically before the first audio frame** → sync → write audio →
close/repair the WAV → atomically publish the final sidecar.

**Blocker — scheduler ownership.** `ProcessRunner` (parked task 10) requires a timeout driven by the
injected scheduler, but the scheduler is not introduced until the harness work. An agent going in
numeric order would invent a temporary clock, implement part of a later task early, or use wall time
and rewrite it. **There must be exactly one clock abstraction from its first use** — introduce it
wherever it is first needed, or move the full runner into the task that owns the clock.

**The filesystem seam is not implementable as written.** Segment audio is written by media machinery
to a URL, not through `create`/`write`/`rename` calls that can be intercepted, so an injected
filesystem **cannot produce `ENOSPC` during a real segment write**. The disk-failure work would then
test manifest failures while claiming to test audio-write failure. Define a `SegmentSink`/writer
adapter as the fault boundary, or give the filesystem interface ownership of opened handles.

**ControlAPI — the façade earns its place; the envelope does not.** Keep: one in-process façade used
by both UI and harness, plain value parameters/results/state, typed error identifiers, an
`AsyncStream<ControlState>` the UI actually consumes, and the privacy/visible-recording invariant.
Drop for now: a universal `Codable` request envelope and an API version field. The argument that "a
scenario is just a list of commands" is **wrong**: scenarios also need scheduler advancement, capture
faults, filesystem faults, process behaviour, readiness coordination, `SIGKILL`, expected traces and
durable-output assertions — those are harness directives, not `ControlAPI` operations, so a scenario
format exists either way. Keep a harness-only scenario enum. Make types `Codable` only where free.

**Split the harness work** into: (a) runtime extraction; (b) canonical control boundary + typed
state/errors + state stream + **characterization scenarios recorded here**, so the lifecycle refactor
has a frozen contract *before* anything changes behaviour; (c) deterministic infrastructure (fake
capture, virtual scheduler with transitive quiescence, filesystem/`SegmentSink` faults, permission
seam, fake process runner); (d) the process harness (child modes, readiness protocol, exact-PID
`SIGKILL` + `waitpid`, fresh-process recovery, audio oracle, permanent negative control).

**Fix specifications at the task that first invalidates them**, not "eventually". The agent is told to
read `SPEC.md` and `CLAUDE.md` before every task, so a stale statement misleads every task until it is
fixed. `SPEC.md` still claims a crash loses at most the last unfinalised segment (the repaired tail
disproves it) and still describes the pre-`ActaRuntime` layout. `CLAUDE.md` still says runtime/crash
behaviour is manual-only and that testable decisions belong in `ActaKit`.

**Smaller, all real:**
- Generation-tagged outputs conflict with the fixed public names `system.wav`/`mic.wav`. Decide that
  those are **logical names resolved through the commit marker**, physical files are generation-tagged,
  and that `list`, export, the UI, validation and recovery **all** use the resolver — otherwise someone
  restores fixed-name aliases and recreates the mixed-generation window.
- The timeline's recording-level **origin cannot live only in `session.json`**, because orphan recovery
  must work when that file is missing or corrupt. Put it in an independent durable file, or repeat
  enough origin data in every segment descriptor.
- Define **timeline retention** when `deleteSegmentsAfterAssembly=true`: do sidecars disappear with the
  segments (losing forensic/validation ability) or remain (and how do scanners tell them from orphans)?
- Alignment says outputs are "committed as one generation", but the paired commit arrives in a later
  task. Say **"prepared as one candidate generation"**; publication belongs to the commit task.
- **`recoverNow()` vs "recovery occurs once at launch"** need distinct semantics: automatic recovery is
  once per process launch; an explicit command may rescan idempotently.
- **Recordings need a stable ID.** `list()` and `exportMix(id:)` require identity, but folder names get
  de-duplicating suffixes and the commit work changes physical output identity. A persisted UUID is the
  simplest answer.

---

## Next up: the refined core, parked pending the in-flight extraction

Promote in this order, one at a time, after applying the findings above. These are the tasks as they
stood at the cut — **they still contain the defects listed above**.

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
- [ ] `RecordingSettings` (ActaKit): remove `saveSystemTrack`, `saveMicTrack`, `saveCombinedTrack` and the whole `TrackSelection` type, plus the normalisation rule that forced `combined` when nothing was selected. Keep `segmentSeconds`, `archivePath`, `deleteSegmentsAfterAssembly`. No migration needed for the removed keys beyond ignoring unknown ones
- [ ] **Define the shared `ProcessRunner` seam here** (protocol + real implementation); Task 11 adopts it for fakes — do **not** introduce a second runner abstraction later. Contract must cover: an **explicitly resolved executable path** (resolution stays in `locateFFmpeg()` and is injectable), arguments, working directory, **bounded** stdout/stderr capture, **exit status vs termination by signal**, a **timeout driven by the injected scheduler** (not wall time), terminate → grace interval → force kill, cancellation, and **guaranteed child reaping**
- [ ] `MenuContent`: drop the "Save tracks" section from Settings; add a per-recording **"Export mix"** action to the recordings list (next to "Open folder")
- [ ] `ExportMix` in `Acta`: `ffmpeg` `amix=inputs=2:duration=longest` over `system.wav`/`mic.wav` → `combined.wav`. Reuse `FFmpeg.mixArgs`. Write to a **temp file and rename atomically** — a failed or killed `ffmpeg` must never leave a plausible-looking `combined.wav`. `ffmpeg` missing → the existing actionable error; a track missing → clear message; an existing `combined.wav` → replaced only on success. Off the main actor via the `ProcessRunner` seam
- [ ] Export guards: refuse to run against a folder whose session is not `done`/`recovered`; snapshot and re-validate input identity (size + mtime) before commit; serialise per folder. ⚠️ **This serialisation is in-process and provisional**: size+mtime revalidation narrows but does not close the TOCTOU window before rename. Task 13 brings export under the archive lock, and Task 15 under the commit discipline. Do **not** treat Task 10's export as permanently race-safe
- [ ] Recovery path: assemble both tracks the same way, no mix (`RecoveryManager` must not gain a mix branch)
- [ ] Update the generated `~/Acta/CLAUDE.md` (`MeetingStore.ensureArchiveRoot`): the archive holds `system.wav` + `mic.wav`; `combined.wav` appears only if exported on demand
- [ ] Update tests: delete `TrackSelection` tests; adapt `SegmentAssembler`/`RecordingSettings` tests; keep `FFmpeg.mixArgs` covered (still used by Export mix)
- [ ] Acceptance: `grep -rn "TrackSelection\|saveCombinedTrack\|saveSystemTrack\|saveMicTrack" Sources/` returns nothing; a recording produces **exactly two final audio files** (`system.wav`, `mic.wav`; the folder of course also holds `session.json`/`info.md`, and segments if retained) and no `combined.wav`; both decode fully with plausible durations; `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): record → only the two final audio files; press "Export mix" → a valid `combined.wav` (`ffprobe` duration > 0, non-silent)

### Task 11: Extract `ActaRuntime`, then build a process-based E2E harness

**This is the highest-leverage task in the plan, and the easiest to get wrong.** Today every
criterion that actually matters — audio was really recorded, a crash recovered, a stall was caught —
is marked `manual test (skipped - not automatable)`. So the autonomous loop verifies pure functions
and that the thing compiles, and nothing about the job the app exists to do. Three external review
rounds all named this the number one risk.

🪤 **Blocker, verified in the source.** `ActaTestRunner` depends only on `ActaKit`, while
`RecordingController`, `RecordingSession`, `RecoveryManager`, `SegmentWriter`, `SegmentAssembler` and
`MeetingStore` all live in the **`Acta` executable target** — and SwiftPM **cannot import an
executable target**. As written, a real harness is unbuildable. Faced with that, an agent will do one
of three things, and all three defeat the task: test only `ActaKit`, duplicate the orchestration in a
test-only harness, or build a parallel "test coordinator" the UI never calls. So the extraction comes
first and is not optional.

- [ ] **Extract `ActaRuntime`** — an importable library target depending on `ActaKit`. It owns the non-UI production pipeline: lifecycle coordinator, recorder adapter, segment writers, manifest store, assembler, recovery scanner, filesystem/process implementations, and the UI-facing observable state. **Both** `Acta` and `ActaTestRunner` depend on it. The `Acta` executable keeps only SwiftUI/AppKit wiring and the real ScreenCaptureKit adapter. **No production source may be copied or reimplemented in the test runner**
- [ ] `CaptureSource` protocol seam under the recorder yielding (track, buffer, timestamp). Real implementation = ScreenCaptureKit, living in `Acta`; **nothing in `ActaRuntime` may know about `SCStream`**
- [ ] `FakeCaptureSource`: **deterministic** synthetic PCM **per track independently**, with control over level (silence / tone / speech-like), **format** (interleaved and non-interleaved, integer and float, differing channel counts), **stalls**, **errors**, and pacing driven by the injected scheduler
- [ ] **One injected time service, two concepts**: a **monotonic** clock for scheduling, deadlines and `advance(by:)`; and **wall time** for `started_at`, titles and metadata. Do not pretend wall time does not exist — ban raw `Date()` for *scheduling* above the seam, not for metadata. File mtimes remain filesystem observations, not scheduler time
- [ ] **`advance(by:)` must drain to quiescence**: after an advance, run everything made runnable — *including work transitively scheduled by that work* — until nothing is immediately runnable. Otherwise actor hops keep the tests racy
- [ ] **Injectable filesystem seam** — create, write, flush/sync, rename, free-space query, directory sync. ⚠️ **The whole production pipeline must go through it**: a seam around manifest writes while `SegmentWriter`, `SegmentRepair`, assembly or export still call `FileManager` directly gives false confidence. Filling a real volume is not an acceptable test
- [ ] **Permissions/TCC seam**, including a **capture-authorization-lost** event the coordinator can act on (Task 12 consumes it; Task 16 adds the policy)
- [ ] Adopt the **`ProcessRunner` seam from Task 10**. 🪤 **A stub earlier on `PATH` will not intercept `ffmpeg`** — `locateFFmpeg()` checks `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` **before** `PATH` (verified in source), and ffmpeg lives in `/opt/homebrew/bin` here. Inject the resolved executable/runner instead
- [ ] **Name the "real pipeline" boundary.** Every scenario **starts through the same canonical operation the UI calls** and asserts on **the same observable state the UI renders**. Tests that reach directly into `SegmentWriter`/`RecoveryManager`/a pure state machine can pass over broken wiring and do not count as E2E

**The canonical operation is an in-process `ControlAPI`.** This is not scope creep: the command
envelope and the event stream **replace test scaffolding that would otherwise be written anyway**, so
they are cheaper to build than to avoid. The out-of-process transport is a different matter and stays
parked (see the end of this task).

- [ ] **One façade, one entry point.** Every operation the app performs goes through `ControlAPI` in `ActaRuntime`: `start(title:)`, `stop()`, `status()`, `list()`, `exportMix(id:)`, `getSettings()`, `setSettings(...)`, `recoverNow()`. The SwiftUI menu bar calls **only** this; no UI path may reach into the coordinator, recorder or store directly. The harness is a second client. (This *is* the "one canonical operation" the E2E boundary requires)
- [ ] **Structured, `Codable` requests and results.** Rationale: the harness needs `ActaHarness record --scenario <file>` regardless — with a command envelope, a scenario file is simply a **list of commands**, and no bespoke scenario format has to be invented and maintained alongside the façade
- [ ] **An event/trace stream**: state changed, recording started/stopped, error, recovered. Rationale: the characterization contract below demands *externally visible state traces* — this stream **is** that trace. Without it, an ad-hoc "what happened" recorder gets written for the tests only; with it, the same mechanism serves the product and the tests
- [ ] **No UI types across the boundary.** Parameters, results and events are plain data — no SwiftUI/AppKit types in the signatures. Observable state is plain values the UI adapts, not UI-bound state the runtime owns
- [ ] **Typed error categories** with stable identifiers, not display strings. A display string may be *derived* from a category; the category is what crosses the boundary and what tests assert on
- [ ] An **API version** field in the envelope — one field, no compatibility code (there is nothing to be compatible with yet)
- [ ] ⚠️ **Privacy invariant, applies from the moment the envelope exists:** anything able to invoke `start` can record the user. An API-initiated recording obeys the **same** invariant as a UI-initiated one — visible state, never a silent recording. There is no "quiet mode" and there will not be one
- [ ] **Still out of scope here**, parked in the backlog: the Unix-socket transport, the `actactl` CLI, launch-if-not-running semantics, the trust boundary and compatibility rules. Those are new surface with no testing payoff; the façade above is what makes them cheap to add later without a rewrite

**Process-based crash testing** — `kill -9` **cannot be simulated in-process**: throwing, cancelling a
task or dropping an object all run cleanup, which is exactly what `SIGKILL` does not.

- [ ] Harness executable modes, e.g. `ActaHarness record --root <temp> --scenario <file>`, `ActaHarness recover --root <temp>`, `ActaHarness run --root <temp>`
- [ ] The **recording child** must: enter through the same lifecycle command the UI uses; write to a unique temporary archive; **signal readiness only after** the manifest says `recording`, at least one **closed** segment exists per expected track, **and a later segment is open with non-zero audio data**; then stay alive until killed. Readiness goes over a pipe or an **atomically written** readiness file — ⚠️ **polling for segment files is not enough**: the parent could kill between rotations when no open tail exists, silently weakening the test
- [ ] The **parent** must: wait for readiness with a bounded timeout; verify the child is alive; `SIGKILL` the exact PID; `waitpid` and **assert termination was by `SIGKILL`**; launch recovery as a **new process** on the same archive root; assert through controller-visible state and durable outputs — **not** by calling `RecoveryManager` directly; inspect the final WAVs and manifest only after the recovery process exits successfully
- [ ] **A deterministic audio oracle.** ⚠️ A dropped buffer still yields two perfectly decodable WAVs — "it decodes" proves nothing. With deterministic synthetic input, assert exact or bounded **frame counts**, durations, discontinuities, and a simple **per-track sample fingerprint**
- [ ] **A permanent negative control, not a one-off.** "Prove the harness can fail" must not mean hand-editing production code. Add an **injectable fault** (a writer decorator that acknowledges a buffer and drops the Nth) and a **permanent test** that runs the harness against it and asserts the harness **reports failure**. The outer test passes only because it observed the expected inner failure

**Characterization contract (consumed by Task 12).** Record the *current* externally visible behaviour
before anything is refactored:

- [ ] Freeze scenarios covering: start; confirmed recording; stop → saving → done; failed start; fatal stall; recovery. Assert on **externally visible state traces**, manifest status transitions, segment and final-output artifacts, error messages or typed error categories, start/stop **idempotence**, and **recovery occurring once at launch**
- [ ] Other harness scenarios: start → segments appear → stop → both tracks assembled and valid; **child SIGKILLed mid-recording → recovery in a fresh process assembles what survived**; a stalled track → the watchdog reacts; a failing and a **hanging** `ffmpeg` → error surfaced, segments intact
- [ ] **Keep it honest.** This is *approximate* E2E: it does **not** prove ScreenCaptureKit works, TCC prompts appear, or real audio is captured. Those stay manual. Say so here and **update `CLAUDE.md`**, whose claims — that runtime audio and crash recovery are manual only, that validation only checks compilation/build/unit logic, and that `ActaKit` is the only place for testable code — all become false or misleading once `ActaRuntime` and the harness exist
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh` (E2E scenarios, characterization scenarios **and** the negative control inside it), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green

### Task 12: One serialized recording lifecycle

**Why this exists.** Several actors can already mutate a live recording — manual stop, watchdog
restart, stream error, app termination, capture-authorization loss — and every parked backlog item
adds more. Without a single owner they race.

This is not speculative: the shipped bug history is *entirely* this class — "isStopping symmetric to
isStarting", "await watchdogTask.value before stopping the recorder, otherwise the watchdog's rest()
could bring up a new SCStream after assembly", "run recovery once per launch, not on every menu
open", "the restart budget was a quota for the whole recording rather than per incident". Those were
found by review, one at a time, after the fact. The coordinator is how we stop finding them that way.

- [ ] A single serialized lifecycle in `ActaRuntime` owning every transition of a recording (one actor/queue). All mutations go through it; nothing touches the recorder/writers/manifest directly
- [ ] **Generation IDs and operation tokens.** "A stale completion must not resurrect a stopped session" is solved by a session generation + per-operation token, not ad-hoc state checks. Reject any completion whose token is no longer current — start, restart, segment closure, manifest write, assembly. The generation is persisted in the Task 13 timeline, so design the ID now
- [ ] ⚠️ **Do not force export into the recording state machine.** Export is not a transition of a live recording; forcing it in turns the coordinator into a god object. Export gets a **separate per-folder lock/token tied to the committed generation** (Task 15)
- [ ] Explicit precedence, encoded and tested: **stop beats restart**; duplicate/burst events coalesce; **capture-authorization-lost** is terminal
- [ ] Every operation **idempotent**: a second stop or a repeated event is a no-op, not a second path
- [ ] Pure state machine in `ActaKit` (events → transitions + emitted effects); the I/O and wiring live in `ActaRuntime`
- [ ] Two test layers, kept distinct: **fake effects** for exhaustive state-machine ordering (cheap, combinatorial), and the **Task 11 harness with real writers** for integration. Do not conflate them
- [ ] Race scenarios: stop racing a restart; restart completing after stop; restart completing after an error; two stops; error during assembly; termination mid-recording; authorization lost mid-recording
- [ ] ⚠️ **"No observable behaviour change" is not an acceptance contract by itself** — the existing tests mostly protect pure logic, not the orchestration being replaced. Instead: **the Task 11 characterization scenarios must stay green and unchanged** while the race scenarios are added. Existing assertions may be updated **only for API relocation** — they may **not** be deleted, broadened, skipped, or converted from exact assertions into "does not throw"
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green, characterization scenarios unchanged
- [ ] Acceptance (manual, needs a human): a live record → stop → `kill -9` → recover cycle behaves as before the refactor on real hardware

### Task 13: Archive locking and the persisted timeline

Locking first: it is a precondition for everything that scans the archive.

- [ ] **Single-instance archive locking.** Two Acta processes must not record into or recover the same archive. This must land **before** any orphan scanning (Task 16): a scan looking for segment layouts without a valid manifest would otherwise mistake **another live process's in-progress recording** for an orphan
- [ ] **Persisted timeline — this is what makes alignment crash-safe.** In-memory segment timestamps do not survive a crash, and orphan recovery cannot reconstruct alignment without them on disk. Persist, per segment: recording time origin, track, segment index, segment start/end timestamps, format and frame count, discontinuity/gap reason, and the lifecycle generation (Task 12)
- [ ] **Specify the timeline exactly** — leaving this to the implementer invites incompatible guesses. Define: which timestamp domain is persisted; how system and microphone timestamps map onto **one recording origin**; whether intervals are **half-open**; how **overlaps, duplicate buffers, backward timestamps and mid-recording format changes** are handled; when a timeline entry is considered **committed relative to WAV segment finalisation**; and how the **repaired open tail** (Task 8.1 `SegmentRepair`) gets an end time after a crash
- [ ] **Durable format: one atomic sidecar per finalised segment**, plus recording-level origin metadata. Do **not** use a single repeatedly rewritten timeline JSON (a contention and loss point). An append-only journal is acceptable only with explicit torn-tail parsing rules
- [ ] Record a `version` field in the manifest and timeline metadata — **one field, no migration code**. There is no backward compatibility to maintain (existing folders are test data); this exists so a *future* format change is detectable
- [ ] Unit tests for the pure parts (timeline computation, origin mapping, half-open interval maths, torn/duplicate/backward-timestamp handling); harness scenarios for locking (a second instance must not proceed) and for the timeline surviving a SIGKILL
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green

### Task 14: Track alignment and asymmetric capture

- [ ] **Track alignment (the dangerous one).** The two tracks are concatenated independently. Any difference in segment count or restart timing — watchdog restarts cause this today — silently drifts "me" against "them" and destroys the attribution the two-track design exists for. Policy: **preserve a shared media timeline** (Task 13); pad only the asymmetric per-track gaps needed to keep both tracks on it; **both outputs get identical timeline treatment**
- [ ] **Asymmetric capture — decided, not optional.** When one track produced **no buffers at all** (dead or OS-muted mic): produce a **zero-filled track spanning the shared recorded timeline**, mark that track **absent** in `info.md` metadata, and commit both outputs as **one generation**. Rationale: it preserves the "always two tracks" shape and the downstream/export contract, and makes the absence honest. A single-track finalisation would contradict Task 10 and complicate every consumer. A perfectly good system-only meeting must **never** become unfinalisable
- [ ] Unit tests (pure): alignment with differing segment counts; a mid-recording restart; a track absent entirely; padding computed identically for both tracks
- [ ] Harness scenarios: differing segment counts and a mid-recording restart stay aligned (verified via the deterministic audio oracle, not just "it decodes"); a silent/absent mic track yields a zero-filled aligned track marked absent
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green

### Task 15: Paired atomic commit, assembly failures and segment deletion

- [ ] **Paired atomic commit.** Renaming `system.wav.tmp` and `mic.wav.tmp` independently lets a crash between the two renames leave files from **different assembly generations**. Use **generation-tagged outputs plus a single atomic commit marker/index**. ⚠️ **Readers must resolve outputs through the marker** — if the UI and export keep opening fixed names independently, generation tagging buys nothing. Validate (header + duration > 0 + expected frame count) **before** commit
- [ ] Recovery must **detect a partial pair** and either finish or roll it back
- [ ] **Never delete segments until both final tracks are validated and committed.** `deleteSegmentsAfterAssembly` defaults to true; deleting on an unvalidated assembly destroys the only copy
- [ ] **Partial assembly.** If `system` succeeds and `mic` fails: do not destroy the successful track or the segments, do not mark `done`, leave it recoverable, and say so in the UI
- [ ] **`ffmpeg` hang/failure.** A stuck child leaves the app in "Saving…" forever. Use the `ProcessRunner` timeout (scheduler-driven), capture exit status and stderr, surface an actionable error, preserve segments on every failure path. **This is automatable through the injected runner — it is not a manual test**
- [ ] Bring **export** under this discipline: the per-folder token/lock from Task 12, tied to the committed generation, closing the provisional TOCTOU window left by Task 10
- [ ] Unit tests (pure): commit-point decisions; partial-pair detection. Harness: crash between renames → recovery finishes or rolls back, never a mixed pair; hanging `ffmpeg` → error, segments intact, not stuck in "Saving…"
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green

### Task 16: Disk and archive failures, orphan recovery, durability honesty

- [ ] **Disk space — a hard refusal threshold, separate from a warning.** Two PCM tracks cost ~1.38 GB/hour (measured). Warn below a comfort margin; **refuse to start** below a hard margin. "Warn and record anyway" contradicts the core invariant — never claim a healthy recording when writes are unsafe. During recording, fail **visibly** below the hard margin
- [ ] Handle `ENOSPC` on segment writes, manifest updates, assembly and export, tested through the injectable filesystem seam (Task 11)
- [ ] **Archive becomes unavailable mid-recording** (volume unmounted, directory deleted, path read-only). Be honest about what is possible: Acta **cannot** preserve data that lived only on a vanished volume, and must not invent a failover. Required behaviour: **stop claiming a healthy recording immediately**, preserve whatever is still accessible, and never delete or overwrite anything on reconnection
- [ ] **Capture authorization revoked mid-recording** → the terminal event from Task 11/12: visible error state, segments preserved, never keep showing "recording"
- [ ] **Orphaned segments.** Recovery keys on `session.json status=recording`; a manifest truncated by power loss orphans a whole segment directory **forever**. With locking (Task 13) in place, scan for a recognisable segment layout whose manifest is missing or corrupt, reconstruct what the persisted timeline allows, mark it `recovered`, and **never silently delete**. Pre-Task-13 layouts without timeline metadata are **out of scope** — no backward compatibility; ignore them
- [ ] **Durability honesty.** Atomic rename prevents a torn manifest but does **not** by itself survive sudden power loss without syncing the file and its parent directory. Decide what to implement, then **state plainly in `SPEC.md`** what is guaranteed against **process death** versus **sudden power loss** — do not imply both. Also fix the stale SPEC claim that a crash loses "at most the last segment": the live run showed `SegmentRepair` recovering a 9.4 s open tail, so the honest claim is "at most the unrepairable remainder of the open segment"
- [ ] Harness scenarios: `ENOSPC` at each injection point; archive vanishing mid-recording; authorization lost mid-recording; an orphan folder with a corrupt manifest recovered
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): delete `session.json` from an interrupted recording → segments still recovered on next launch. (Real TCC revocation and physically removing a volume stay manual; everything else here is automated)

## Backlog

Parked, **not** in scope: sleep/lid close, audio device changes, menu-bar timer, auto-stop on
silence, calendar metadata, mic-activity prompt, silence trimming.

They live in `docs/backlog/acta-full-plan.md`, together with the defects each still carries. Promote
one at a time, only after the core above has landed and been verified on real hardware — and re-fix
the listed defects as part of promoting it.

---

## Parked: external transport for the control API (agterm-style automation)

Requested by the user while re-planning: make Acta drivable by agents and automation, the way
`agtermctl` drives agterm.

**Most of this is already in the core**, because it turned out cheaper to build than to avoid: core
Task 11 builds the in-process `ControlAPI` — one façade, `Codable` commands and results, an
event/trace stream, typed error categories, an API version field, UI as just a client. It earns its
place there by *replacing* test scaffolding: the harness's scenario file becomes a list of commands,
and the event stream is the state trace the characterization contract needs.

**What is parked here is only the out-of-process transport** — new surface with no testing payoff:

- A **Unix domain socket** in the user's directory (mode `0600`, never a network listener), JSON
  lines; hosted by the menu-bar app. Listener lifecycle, concurrency and error handling.
- A thin CLI (`actactl`) speaking to the running app — a third client of the same façade, after the
  UI and the harness.
- **Launch semantics**: if the app is not running, does the CLI start it? What happens to a TCC
  prompt raised by a recording started with no user in front of the screen?
- **Compatibility rules** for the version field the core already records.

⚠️ **Privacy constraint to carry over:** anything able to invoke `start` can record the user. The
socket's file permissions are the entire trust boundary — there is no auth beyond them, which is why
a network listener is out. The core's invariant already applies: an API-initiated recording is never
silent and always shows visible state; there is no "quiet mode".

---

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

The only honest use for a mix is *listening back* to a meeting, where two files are awkward. That is
an on-demand need, not a reason to write a third file on every recording.

Decided (agreed with the user): **always write both tracks**; no mix in the recording pipeline;
provide an on-demand "Export mix" action. The track-selection setting disappears with it.

- [ ] `SegmentAssembler`: always assemble `system.wav` **and** `mic.wav`. Remove the mix from the pipeline and with it the special cases — building `combined` via intermediate wavs, the "mix impossible" vs "mix failed" distinction, and the mix-related guards on segment deletion
- [ ] `RecordingSettings` (ActaKit): remove `saveSystemTrack`, `saveMicTrack`, `saveCombinedTrack` and the whole `TrackSelection` type, plus the normalisation rule that forced `combined` when nothing was selected. Keep `segmentSeconds`, `archivePath`, `deleteSegmentsAfterAssembly`
- [ ] **Settings migration:** existing `UserDefaults` hold JSON with the removed keys (verified: `{"saveSystemTrack":true,"saveMicTrack":true,"saveCombinedTrack":false,...}`). Decoding must ignore unknown keys and keep the surviving ones — no crash, no reset to defaults. Cover with a unit test using that exact legacy JSON
- [ ] `MenuContent`: drop the "Save tracks" section from Settings; add a per-recording **"Export mix"** action to the recordings list (next to "Open folder")
- [ ] `ExportMix` in `Acta`: run `ffmpeg` `amix=inputs=2:duration=longest` over `system.wav`/`mic.wav` → `combined.wav` in the same folder. Reuse `FFmpeg.mixArgs` and `SegmentAssembler.locateFFmpeg()`. Write to a **temp file and rename atomically** — a failed or killed `ffmpeg` must never leave a plausible-looking `combined.wav`. Handle honestly: `ffmpeg` missing → the existing actionable error; a track file missing → clear message; an existing `combined.wav` → replaced only on success. Run off the main actor via an injectable process runner; guard against a double export of the same folder
- [ ] Recovery path: assemble both tracks the same way, no mix (`RecoveryManager` must not gain a mix branch)
- [ ] Update the generated `~/Acta/CLAUDE.md` (`MeetingStore.ensureArchiveRoot`): the archive holds `system.wav` + `mic.wav`; `combined.wav` appears only if exported on demand
- [ ] Update tests: delete `TrackSelection` tests; adapt `SegmentAssembler`/`RecordingSettings` tests; keep `FFmpeg.mixArgs` covered (it is still used by Export mix)
- [ ] Acceptance: `grep -rn "TrackSelection\|saveCombinedTrack\|saveSystemTrack\|saveMicTrack" Sources/` returns nothing; a recording produces exactly `system.wav` + `mic.wav` and no `combined.wav`; both decode fully with plausible durations; `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): record → only two files appear; press "Export mix" → a valid `combined.wav` (`ffprobe` duration > 0, non-silent); recordings that already contain `combined.wav` are untouched by recording/recovery

### Task 11: Fakeable capture seam and an approximate E2E harness

**This is the highest-leverage task in the plan.** Today every criterion that actually matters —
audio was really recorded, a crash recovered, sleep survived, a device switch handled, silence
detected — is marked `manual test (skipped - not automatable)`. So the autonomous loop cannot verify
the app's core job at all: it verifies pure functions and that the thing compiles. An external review
named exactly this as the number one risk — the orchestration that can lose recordings is precisely
what is untested, so every component can look correct in isolation while being wired together wrong.

Fix: put a seam under the capture layer so the **whole pipeline** can run against synthetic input,
against a real filesystem, inside `bash Scripts/test.sh`.

- [ ] Protocol seam under `AudioRecorder`: a `CaptureSource` yielding (track, buffer, timestamp). The real implementation is ScreenCaptureKit; **nothing above the seam may know about `SCStream`**
- [ ] `FakeCaptureSource` (test target): emits synthetic PCM **per track independently**, with control over — level (silence / tone / speech-like), **format** (interleaved and non-interleaved, integer and float, differing channel counts), **stalls** (stop emitting), **errors** (stream failure), and pacing driven by an **injected clock** rather than wall time
- [ ] Injectable seams for the rest of what the loop cannot exercise: permissions/TCC status, sleep/wake events, default-input-device changes, the mic-activity process list, calendar, the `ffmpeg` process runner, and a **monotonic clock**
- [ ] E2E harness in `ActaTestRunner`: drives the **real** pipeline (real segment writing to a temp dir, real manifest, real assembly) against the fakes. Cover at minimum: start → segments appear → stop → both tracks assembled and valid; abrupt termination mid-recording → recovery on next launch assembles what survived; a stalled track → the watchdog reacts; a failing/hanging `ffmpeg` → error surfaced, segments intact
- [ ] Use real `ffmpeg` where available; a stub-on-`PATH` variant drives the failure paths
- [ ] **Prove the harness can fail.** A test suite that cannot go red is decoration: deliberately break the pipeline (e.g. make `SegmentWriter` drop a buffer) and confirm a red run; document that check in the task
- [ ] **Keep it honest.** This is *approximate* E2E: it does **not** prove ScreenCaptureKit works, TCC prompts appear, or real audio is captured. Those stay manual. State this in the task and in `CLAUDE.md` — a green harness must never be read as "recording verified"
- [ ] **From here on, every later task adds its scenario to the harness**, not only pure tests: sleep/wake (Task 14), device change (Task 15), auto-stop silence (Task 17), mic prompt (Task 19)
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green, with the E2E scenarios running inside `Scripts/test.sh`

### Task 12: One serialized recording lifecycle

**Why this exists.** Tasks 14–17 each add a new actor that can mutate a live recording: manual stop,
watchdog restart, sleep, wake, device change, auto-stop, stream error, app termination. Without a
single owner these race.

This is not speculative — the shipped bug history is *entirely* this class: "isStopping symmetric to
isStarting", "await watchdogTask.value before stopping the recorder, otherwise the watchdog's rest()
could bring up a new SCStream after assembly", "run recovery once per launch, not on every menu
open", "the restart budget was a quota for the whole recording rather than per incident". Adding
three more event sources without a coordinator repeats it.

- [ ] A single serialized lifecycle owning every transition of a recording (one actor/queue). All mutations go through it; nothing touches `AudioRecorder`/`SegmentWriter`/the manifest directly
- [ ] Explicit precedence, encoded and tested: **stop beats restart**; sleep suppresses restart; duplicate/burst events coalesce; a **stale restart completion must never resurrect** a stopped or errored session into "recording"
- [ ] Every operation **idempotent**: a second stop, a duplicate wake, a repeated device event are no-ops, not second paths
- [ ] Pure state machine in `ActaKit` (events → transitions + emitted effects); I/O stays in `Acta`
- [ ] Tests via the Task 11 harness with fake recorder/writers: assert call **order** and final state for — stop racing a restart; restart completing after stop; restart completing after an error; two stops; error during assembly; termination mid-recording
- [ ] Refactor the existing `RecordingSession`/`SelfCheck`/`RecordingController` interactions onto the coordinator without changing observable behaviour (the existing tests must stay green)
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green; no regression in a live record → stop → recover cycle

### Task 13: Recording durability — alignment, atomic outputs, orphans, disk failures

Everything so far protects against a process dying. These are the failures that survive that: the
data is written but wrong, or unrecoverable, or the disk says no.

- [ ] **Track alignment (the most dangerous one).** The two tracks are concatenated independently. If they ever differ in segment count or in start/restart timing — which sleep, watchdog restarts and device changes all cause — "me" and "them" silently drift apart in time, destroying the very attribution the two-track design exists for. Define and implement an explicit alignment policy (a common time origin per recording; record each segment's start timestamp; pad or mark gaps rather than silently closing them). Test via the harness: differing segment counts and a mid-recording restart must stay aligned
- [ ] **Orphaned segments.** Recovery keys on `session.json status=recording`. A manifest truncated by power loss orphans a full segment directory **forever**. The filesystem is already the source of truth for segments — make it the source of truth for "a recording happened here" too: scan for a recognisable segment layout with a missing/corrupt manifest and recover it conservatively (reconstruct what is knowable, mark `recovered`, never silently delete)
- [ ] **Atomic final outputs.** Assemble to `system.wav.tmp`/`mic.wav.tmp`, validate (header + duration > 0), then rename. A crash mid-`ffmpeg` must never leave a plausible-looking final file
- [ ] **Never delete segments until both final tracks are validated.** `deleteSegmentsAfterAssembly` defaults to true; deleting on an unvalidated assembly destroys the only copy
- [ ] **Partial assembly.** If `system` succeeds and `mic` fails, define the commit point: do not destroy the successful track or the segments, do not mark `done`; leave it recoverable and say so in the UI
- [ ] **`ffmpeg` hang/failure.** A stuck child leaves the app in "Saving…" forever. Generous timeout, capture exit status and stderr, actionable error, segments preserved on every failure path
- [ ] **Disk space.** Two PCM tracks cost ~1.38 GB/hour (measured). Check free space before start and warn; during recording fail **visibly** below a safety margin. Handle `ENOSPC` on segment writes, manifest updates, assembly and export
- [ ] **Archive unavailable mid-recording** (volume unmounted, directory deleted, path read-only) → visible error, keep what is written
- [ ] **TCC revoked mid-recording** → visible terminal error, segments preserved; never keep showing "recording"
- [ ] **Single instance.** Two Acta processes must not record into or recover the same archive concurrently
- [ ] **Durability honesty.** Atomic rename prevents a torn manifest but does not by itself guarantee power-loss durability without syncing the file and its parent directory. Decide, implement and **state plainly in SPEC** what is guaranteed against process crash versus sudden power loss — do not imply both
- [ ] Unit tests for the pure parts (alignment policy, orphan detection, assembly commit points); harness tests for the failure paths (timeout, `ENOSPC`, partial assembly)
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): delete `session.json` from an interrupted recording → the segments are still recovered on next launch; put a failing/hanging `ffmpeg` stub earlier on `PATH` → clear error, segments intact, app not stuck in "Saving…"

### Task 14: Survive sleep and lid close

Verified gap: nothing in `Sources/` observes sleep (`grep` for `willSleep|didWake|NSWorkspace.*[Ss]leep`
returns nothing). Yet on a laptop this is **the most common interruption of all** — far more likely
than the `kill -9` we already defend against. `SCStream` does not survive sleep, so today the
behaviour is unknown: at best the watchdog thrashes restarts, at worst we show "recording" while
nothing is written — the exact invariant the app exists to protect.

Built on the Task 12 coordinator: sleep/wake are events into it, not another set of booleans.
See the sleep section of the `.claude/skills/crash-safe-recording` skill.

- [ ] Observe `NSWorkspace.shared.notificationCenter` `willSleepNotification` / `didWakeNotification`. `screensDidSleepNotification` is a different event (screen sleep ≠ system sleep, e.g. lid closed with an external display) — do not conflate them
- [ ] On `willSleep`: finalise the current segment as cheaply as possible. **The system will not wait**: `finishWriting` is async and may not complete. Do not attempt assembly (`ffmpeg`) from the handler. Accept truncation — `SegmentRepair` (Task 8.1) already rescues a truncated tail, so this is not data loss
- [ ] On `didWake`: the stream is dead → restart via the coordinator, advancing the segment index so a closed segment is never overwritten. If the restart fails → surface the error; **never keep showing "recording"**
- [ ] The watchdog must not fight the sleep handler: suppress stall detection between `willSleep` and `didWake`, otherwise it burns its restart budget on a sleeping machine
- [ ] Also handle ordinary **app termination and logout** with the same cheap segment closure — do not pretend async work is guaranteed; ordinary recovery covers the rest
- [ ] A sleep gap means the assembled audio is shorter than wall-clock — correct and consistent, since duration comes from the audio (Task 8.3). Do not pad the gap. Respect the Task 13 alignment policy
- [ ] Harness scenarios (Task 11) + unit tests: watchdog stalls ignored inside the sleep window and resumed after wake; **wake arriving twice**; **wake after the user stopped while asleep**; **stop racing `didWake`**; **a watchdog callback already queued before `willSleep`**; **a restart completion arriving after an error or stop**; termination during sleep → ordinary recovery at launch
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): start a recording → sleep ~1 min → wake → recording continues; the segment open at sleep is **valid or repaired and included** after assembly; new segments appear after wake; stopping assembles audio spanning both sides of the gap, both tracks still aligned

### Task 15: Handle audio device changes mid-recording

Verified gap: nothing observes the default input device (`grep` for
`kAudioHardwarePropertyDefaultInputDevice` returns nothing). Plugging in AirPods mid-call switches
the default input — routine, and currently undefined. It lands **before** auto-stop deliberately: a
device transition produces missing buffers and low levels, and auto-stop must not mistake an expected
interruption for a finished meeting.

- [ ] Observe `kAudioHardwarePropertyDefaultInputDevice` via `AudioObjectAddPropertyListener`. Mind the Swift listener-removal bug noted in the `mic-activity-detection` skill (`AudioObjectRemovePropertyListenerBlock` — use `AudioObjectPropertyListenerProc`)
- [ ] **CoreAudio emits several property events for one physical change** — define an explicit debounce/coalescing interval; one physical switch must cause exactly one restart. Handle a device ID going transiently unknown/zero
- [ ] On a device change: restart through the Task 12 coordinator, advancing the segment index and keeping every written segment
- [ ] A device change is an **expected event**: it must not consume the `SelfCheck` restart budget reserved for genuine failures, and it must reset/suspend the auto-stop silence state (Task 17)
- [ ] Harness scenarios + unit tests: a burst of events → exactly one restart; a second genuine change after the first restart completes → a second restart; a change while idle → nothing; the failure budget untouched
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): record on the built-in mic → connect AirPods mid-recording → recording continues, no segment lost or overwritten, **both tracks** inspected around the switch (the mic track must not go silent afterwards) and still aligned

### Task 16: Menu-bar timer and authoritative health

Today the elapsed time lives inside the popover — you must click to learn whether anything is being
recorded. Putting it in the menu bar makes state permanently visible, reinforcing the "never a
silent recording" invariant and stopping you forgetting to hit Stop. It also becomes the **surface
the Task 17 countdown needs**, which is why it lands first.

- [ ] `MenuBarExtra` label reflects state: idle → icon only; recording → icon + elapsed time (`MM:SS`, `H:MM:SS` past an hour); error → a clearly distinct warning icon
- [ ] **Show authoritative health, not `phase == recording`.** A ticking timer must never reinforce a false status while writes are stalled — reuse the self-diagnosis/watchdog health signal
- [ ] Monospaced digits so the menu bar does not jitter; update once per second while recording only, no timer work while idle
- [ ] Reuse the existing `RecordingController.elapsedString` rather than duplicating it
- [ ] Unit tests: formatting (seconds → `MM:SS`, crossing an hour → `H:MM:SS`, zero, a long recording); and that a stalled/error health state does not render as a healthy ticking timer
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): during a recording the menu bar shows a ticking timer without opening the popover; it disappears on stop; an error state is visible at a glance

### Task 17: Auto-stop on prolonged silence — configurable, cancellable

Problem: it is easy to forget to stop. A forgotten recording writes ~1.38 GB/hour (measured). But
stopping silently would be as bad as recording silently — hence the symmetry: **never record
silently, never stop silently**.

Trigger on **silence in all channels**, not on the app releasing the microphone — listening with a
muted mic is still a meeting.

- [ ] **The silence period is a setting, not a constant** (agreed with the user): selectable **1 / 5 / 15 minutes**, plus off. Different meetings, different tolerance — this knob decides whether the feature helps or annoys
- [ ] **Calibrate the threshold empirically — do not guess.** An earlier "−50 dB" default was derived backwards (a bit below measured *speech*), while measured **mic levels are ≈ −34…−40 dB mean, which is ambient room noise** — so a −50 dB floor may **never** trigger and the feature would silently do nothing. Measure actual silence on this hardware (mic muted, no system audio), derive the floor from that, and document the measured numbers here
- [ ] **The countdown lives in the menu bar** (Task 16 surface), not only in a notification: a delivered macOS notification does **not** tick, and notification permission may be **denied**. If there is no observable warning channel, **do not auto-stop** — an invisible stop breaks the invariant
- [ ] Notification (when authorised) is auxiliary: a fixed "recording stops in N" plus a **"Keep recording"** action. After a cancel, re-arm only on a **fresh** silence period — never re-notify immediately
- [ ] **Use monotonic time, not wall-clock `Date`** — sleep and clock corrections otherwise cause a false immediate stop
- [ ] **Suspend/reset the silence state** across sleep/wake (Task 14), stream restart and device change (Task 15) — an expected interruption is not a finished meeting
- [ ] Measure levels **streaming**, from the `CMSampleBuffer`s as they are written (cheap, per track). Do **not** shell out to `ffmpeg volumedetect`
- [ ] **Level extraction is format-sensitive** — fixture tests via the Task 11 fake source for interleaved and non-interleaved PCM, integer and float samples, differing channel counts, empty/discontinuous buffers, NaN and clipping. Assert the recorder actually calls the extractor for **both** outputs
- [ ] Keep the signals separate: **level** drives auto-stop; **buffer/write progress** drives the watchdog. Do not merge them. (Related: the existing rule "no buffers at all is only logged, since silence is indistinguishable from a dead device" deserves re-checking — buffer *absence* is not silent PCM. If ScreenCaptureKit normally emits silent buffers during quiet, absence is a flow failure and should be treated as one after a grace period. Verify empirically with the harness before changing shipped behaviour)
- [ ] Pure `SilenceWatcher`/`AutoStop` in `ActaKit`: (timestamp, systemLevel, micLevel) → `active → silent → countdown → stop`, plus `cancelled`. Thresholds are parameters; **both tracks must be quiet**; never fire in the first minute
- [ ] If not cancelled → a normal **clean stop** through the Task 12 coordinator (status `done`, assembly, the usual notification) — not a second stop path
- [ ] Tests: sustained speech → never fires; short pause → no countdown; silence ≥ threshold → countdown exactly once; cancel → no stop and no immediate re-notify; sound returns during countdown → aborts; system silent but mic active → no fire; both silent → fires; nothing in the first minute; sleep/device-change during silence → state reset, no false stop
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): with the period set to 1 minute, leave a recording in silence → the menu bar shows a countdown → "Keep recording" cancels it → left alone it stops cleanly and assembles normally; with notifications denied, the countdown is still visible in the menu bar

### Task 18: Attach calendar event data to the recording

Problem this solves: a recording is currently identified by "Slack — 2026-07-15 18:28". If the
meeting is in the calendar, the archive should carry the real thing — title, agenda, participants —
so it is searchable and worth returning to.

Read the `.claude/skills/eventkit-calendar` skill first — verified API facts and the macOS 14+
authorization trap. **Do not invent EventKit API — check the docs.**

Design:
- **Drift between the calendar and reality is the norm.** All of these must work: the call is at
  15:00 and you hit record at 15:08; you hit record at 14:50 before the start; the 15:00–15:30
  meeting actually ran 15:35–16:05 so the event has **already ended** and there is zero overlap; you
  start recording 40 minutes into a long meeting.
- 🪤 **Match on interval distance, not start-to-start.** An external review caught the earlier rule
  contradicting its own example: for an event 15:00–15:30 and a recording at 15:35, "nearest by
  start" computes 35 min and rejects it — though that case must match. Distance = **0 when the
  intervals overlap, otherwise the gap between the recording interval and the nearest event
  boundary** (15:30 → 15:35 = 5 min). The widened EventKit query and the pure matcher must use the
  **same** definition.
- **Two-phase matching.** The folder is created at start, so match provisionally then (title/folder)
  and **re-match at stop** over the full interval to finalise `info.md`. Do not rename the folder.
- **Graceful degradation is mandatory**: no permission, no calendar, or no match → record exactly as
  today. Calendar access is never a precondition for recording.
- Keep matching **pure** in `ActaKit`; EventKit I/O stays in `Acta`.
- **First cut is deliberately small** (an external review flagged the full version as oversized):
  event title, start/end, and stable occurrence identity. Notes, attendees and organizer come after
  that lands and is verified.

- [ ] `Resources/Info.plist`: add **`NSCalendarsFullAccessUsageDescription`** (English; macOS shows it verbatim). Without this key TCC refuses before EventKit is reached and no prompt ever appears
- [ ] `CalendarService.swift` (in `Acta`): `requestFullAccessToEvents()`, status `.fullAccess`; fetch via `predicateForEvents(withStart:end:calendars:)` over a window widened by the drift tolerance on both sides (the predicate returns events *overlapping* the range). Never block or fail a recording on calendar errors. Injectable behind a seam (Task 11) so matching is testable without a real calendar
- [ ] Pure `CalendarMatch` in `ActaKit`: candidates + recording interval → best match by **interval distance**, within tolerance; **exclude/de-prioritise all-day events** (otherwise every recording matches "Vacation"); de-prioritise declined events; among overlapping candidates prefer the **larger overlap**; deterministic tie-break (shortest, then earliest start, then `event_id`)
- [ ] **Mapping tests, not just matching tests**: fixtures for `EKEvent`-like → plain structs — current-user status, nil dates/URLs, recurring occurrences (`eventIdentifier` is shared across occurrences; pair it with `startDate`)
- [ ] Extend `MeetingInfo`/`info.md` front-matter: `event_title`, `event_start`, `event_end`, `event_id`, `calendar`. Keep the existing YAML escaping rules
- [ ] Title: use the matched event title only when the user left the title empty; an explicit title always wins. Feed the same value to `MeetingArchive.slug`
- [ ] **Recovery enrichment:** a crash-recovered recording has a known start and audio duration — decide and implement whether calendar enrichment runs during recovery too. Leaving it to normal stop only would give the *recovered* recordings (the ones Acta exists to save) inconsistent metadata
- [ ] Settings: master toggle (default on) + **drift tolerance in minutes** (default 15); extend `RecordingSettings` (Codable + normalisation, clamped)
- [ ] Unit tests — **the drift cases are the point**: recording inside the event → matched; starts 8 min late → matched by overlap; starts 10 min early, no overlap → matched by distance; event 15:00–15:30 vs recording 15:35–16:05 (**zero overlap, event ended**) → matched (distance 5 min); same but 2 h later → no match; covers the middle of a long meeting → matched; two overlapping → larger overlap wins, equal → deterministic; all-day beside a real one → real wins; all-day only → no match; declined de-prioritised; nothing in tolerance → no match and recording proceeds
- [ ] Acceptance: front-matter **actually parses** with a YAML parser available in the validation environment (hand-rolled escaping is easy to get subtly wrong); plus `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): with a real meeting in the calendar, record → `info.md` carries the event title and times, folder named after the event. **Drift check:** start ~10 min after the scheduled start → still matched. **Degradation check:** deny Calendar access → records normally, no calendar fields, no crash

#### 18b (after 18 lands and is verified): notes, attendees, organizer
- [ ] Add `organizer`, `attendees`, `location`, `event_url` to front-matter; the **notes/agenda go in the body** under a heading (long and multi-line — wrong for front-matter)
- [ ] Attendees: `name` from `EKParticipant`; email from the `mailto:` `url` — **verify against the SDK** whether a public `emailAddress` exists before using it. Mark the current user via `isCurrentUser`
- [ ] **Privacy is configurable, not all-or-nothing**: copying agenda, attendee emails and join URLs materially raises the archive's sensitivity. Separate toggles for notes and participants; **never log notes** (they routinely contain join links and passcodes)
- [ ] Tests: attendee `mailto:` parsing, multiline notes serialisation, front-matter still parses with a real YAML parser

### Task 19: Offer to record when another app starts using the microphone

Problem this solves: the recording is easy to forget. When a call starts, some app opens the
microphone — a decent "a meeting is probably starting" signal. Acta should notice and offer to
record **once**, with a button, without stealing focus.

Read the `.claude/skills/mic-activity-detection` skill first — verified API facts and the gotchas
(unreliable `IsRunningInput` listeners, Bluetooth mics, the Swift listener-removal bug).
**Do not invent CoreAudio API — check the docs.**

Honest limits, stated up front: microphone activity means "an app is capturing input", **not**
"a meeting started"; for browser meetings it identifies **the browser**, not the tab or the meeting.
Hence: default **off**, opt-in, until verified on this hardware.

- [ ] `MicActivityMonitor.swift` (in `Acta`): enumerate `kAudioHardwarePropertyProcessObjectList`, read `kAudioProcessPropertyPID` + `kAudioProcessPropertyIsRunningInput`, map PID → `NSRunningApplication`. Listener **plus** a light poll (1–2 s) — per the skill, `IsRunningInput` listeners are unreliable alone. Behind the Task 11 seam so it is testable without real processes
- [ ] **Exclude Acta's own PID**, otherwise recording triggers the monitor on itself
- [ ] Trigger on **any** app (an allow-list would miss new tools) with a **dwell filter ≥ 5 s** to drop Siri and short device probes. Fire **once per idle → active transition**; re-arm only after the mic goes idle; never prompt while already recording
- [ ] Pure `MicActivity` in `ActaKit`: snapshots of (pid, bundleID, isRunningInput, timestamp) → `shouldPrompt` — dwell, edge detection, one-shot, re-arm, ignore list, self-exclusion. No I/O
- [ ] Actionable notification: `UNNotificationCategory` + `UNNotificationAction` "Start Recording"; handle it in `UNUserNotificationCenterDelegate`
- [ ] **One canonical start operation.** Starting from the notification must go through exactly the same path as starting from the menu — same calendar/title/start logic (Task 18), same TCC failure handling. No "if both tasks exist" special wiring, and never claim recording before writes actually begin
- [ ] Settings: master toggle (**default off**) + ignore list by bundle identifier; extend `RecordingSettings`
- [ ] Tests: blip < 5 s → no prompt; sustained ≥ 5 s → exactly one prompt; still active → no second prompt; idle then active again → prompts again; ignored bundle → no prompt; Acta's own PID → no prompt; **multiple simultaneous processes**; one goes idle while another stays active; **PID reuse**; missing bundle ID; Acta starts recording during the dwell window. Harness scenario for the notification action starting a recording through the canonical path
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): start a Slack/Meet call → a notification with a "Start Recording" button appears naming the app, **within ~5–7 s** (dwell ≥ 5 s plus a 1–2 s poll — do not promise 5); pressing it starts a recording through the normal path; no second notification for the same call; a 1–2 s mic blip or Siri produces none; starting from the menu bar does not self-prompt

### Task 20: Optional silence trimming — one window, both tracks (future)

Idea from the user, deliberately last: optionally trim leading and trailing silence from a recording.

🪤 **The whole risk is in the coordination.** Trimming each track independently would shift "me"
relative to "them" and destroy the attribution the two-track design exists for — the same failure
mode as the Task 13 alignment issue.

Decided rule: compute **one common trim window** across both tracks — start at the **earliest** onset
of sound in *either* track, end at the **latest** offset of sound in *either* track — and apply that
identical window to both. Never trim a track by its own onset/offset.

- [ ] Pure trim-window computation in `ActaKit`: per-track (onset, offset) → one common window (min of onsets, max of offsets), with a safety pad; a fully silent track must not collapse the window
- [ ] Apply the identical window to both tracks; keep the untrimmed originals until the trimmed pair is validated
- [ ] Off by default; a setting. Never trim during recovery of an interrupted recording without an explicit action
- [ ] Unit tests: one track starts earlier → the earlier onset wins; one ends later → the later offset wins; one track fully silent → window driven by the other, no collapse; both silent → no trim; alignment preserved (identical window applied to both)
- [ ] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh` all green
- [ ] Acceptance (manual, needs a human): a recording with a quiet lead-in trims on both tracks by the same amount; playing the trimmed pair together, the two sides remain in sync
