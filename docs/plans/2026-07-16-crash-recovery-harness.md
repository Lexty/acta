# Plan: A process-based crash-recovery harness (SIGKILL a real recording, recover in a fresh process)

## Overview

Crash recovery is the one mandatory property still proven **only by hand** (the `kill -9` test, the
9.4 s repaired tail). It cannot be tested in-process — throwing, cancelling a task or dropping an object
all run cleanup, which `SIGKILL` does not. The only honest automated test is a real subprocess that
records to a temp archive, is `SIGKILL`ed mid-recording, and is then recovered by a **fresh** process,
asserting on the durable filesystem state and the assembled output — never in-memory state, which dies
with the child.

Everything to reach a real recording without hardware exists (the `CaptureSource`/permission/clock seams,
`FakeCaptureSource`, and `RecordingController(settingsStore:makeSession:)`). Two facts shape the design:

- **`FakeCaptureSource` lives in the `ActaTestRunner` executable target, which SwiftPM cannot import.**
  Instead of extracting it, `ActaTestRunner` **spawns itself**: `main.swift` (today just
  `await Testing.__swiftPMEntryPoint() as Never`) branches on arguments into harness modes **before**
  the test entry point. The child is the same binary re-invoked; the parent is an ordinary `@Test`.
- **The fake's buffers carry no deterministic content** (`makeAudioSampleBuffer` never fills the PCM
  samples). "It decodes" proves nothing — a dropped buffer still yields a decodable WAV. A deterministic,
  position-encoding generator is needed so the assembled output can be checked frame by frame.

This is **approximate** E2E: it does not prove ScreenCaptureKit works, that TCC prompts appear, or that
real audio is captured — those stay manual. It proves the crash-safety machinery
(segmentation → `SIGKILL` → fresh-process recovery → repair → assembly) end to end, automatically. The
work is three ordered tasks, each with its own acceptance.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (existing 238 tests **plus** the new oracle unit tests, the crash scenario, and its negative control; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, every requirement in `CLAUDE.md`, and the `crash-safe-recording` skill. Reuse:
`FakeCaptureSource`, `makeAudioSampleBuffer`, the construction seam in `ControllerTestSupport` /
`CaptureTestFixtures` / `AudioBufferFixtures`; `RecordingController(settingsStore:makeSession:)`,
`onLaunch`, `RecoveryManager`, `SegmentRepair`, `SegmentAssembler`, `SegmentLayout`. ⚠️ **Verified facts
the tasks depend on** — check them yourself before relying on them: recovery writes status **`.recovered`**
(not `.done`); `SessionManifest.segmentCount` is `max(system, mic)`, so it does **not** prove one segment
per track; `onLaunch()` starts a private async recovery task and returns immediately; `onLaunch()` also
calls `Notifier.requestAuthorization()`. The whole pipeline is shipped and verified live; these tasks
test it, they do not change its recording behaviour.

## Scope of this plan

**In:** a deterministic position-encoding audio generator and a frame-level WAV oracle (Task 1); the
self-spawn subprocess protocol and supervision (Task 2); the SIGKILL crash-recovery scenario wired to
the oracle, plus a permanent negative control (Task 3).

**Out, and staying parked:** a filesystem/`ENOSPC` fault seam (`SIGKILL` *is* the fault here); the full
virtual scheduler with `advance(by:)`/drain (the injected clock suffices); typed assembly failures; the
failing/hanging-`ffmpeg` assembly scenarios; a separate `ActaHarness` executable and a test-support
library extraction (self-spawn avoids both); the `ControlAPI` boundary and the socket transport.

### Task 1: Deterministic position-encoding audio, and a frame-level WAV oracle

**Why.** The oracle is what makes every later assertion honest: without deterministic content, a lost or
duplicated frame is invisible. Building and unit-testing it **first**, against hand-made files, means the
crash scenario in Task 3 inherits a proven checker rather than an unproven claim.

- [x] **A position-encoding generator, as a new mode/overload — not a global change to `makeAudioSampleBuffer`.** ⚠️ Filling the existing generic buffer would change fixtures that rely on zeroed samples (e.g. format-layout tests). Add a distinct generator that fills each frame from its **absolute per-track frame index** with a **fully specified** function: state the integer sample format and endianness, the channel layout, the exact `sample(track, frameIndex, channel)` formula, and its overflow/wrap behaviour, so the value at any output position is predictable and the two tracks are distinguishable from each other
  - Done: `makePositionEncodedSampleBuffer` in `AudioBufferFixtures.swift`, additive — `makeAudioSampleBuffer` keeps producing silence (asserted by `theSilenceGeneratorStillProducesSilence`); the two share a body that fills only when asked. Formula, format and wrap are specified in `PositionEncodedAudio`'s doc comment: signed 16-bit LE PCM, `frameIndex * stride(track) + channel * 7 + salt(track)`, truncating to the low 16 bits.
  - ⚠️ **Tracks are separated by distinct strides (3/5), not by the salt alone.** A salt-only separation makes both tracks linear with the same slope, so the mic track is *exactly* the system track shifted by 22299 frames — the oracle would then report mic audio in the system track as a clean `discontinuity` with every value confirming. Distinct strides make one track unreachable from the other by any shift.
- [x] **The oracle: a pure function over a finished WAV**, taking the expected track and a frame range, returning a **structured result** (`ok`, or a typed failure naming the first bad position — e.g. `discontinuity(at:)`, `wrongValue(at:)`, `shorterThan(expected:)`). It reads PCM by parsing the WAV data chunk directly (define how chunk offset and any padding are handled) or decodes via `AVAudioFile` — pick one and state it. It must assert **every** decoded frame equals `sample(track, position, channel)`, with no gap, repeat or corruption
  - Done: `PositionEncodedAudio.verify(wav:track:frames:)` → `.ok` / `.unreadable` / `.unexpectedFormat` / `.shorterThan` / `.longerThan` / `.discontinuity(frame:skipped:)` / `.repeated(frame:by:)` / `.wrongValue(frame:channel:expected:actual:)`. **Parses the data chunk directly** through `WAV.layout` (the parser recovery already trusts), so it stays a pure function of bytes and a test can hand it literal bytes; chunk offset, the declared-vs-actual size rule, padding and the partial-trailing-frame rule are stated in its doc comment.
  - `.repeated` was added beyond the plan's list: under the wrap a repeat of 1 frame and a skip of 65535 are the same value delta, so reporting a duplication as a `discontinuity` would be arithmetically arbitrary. Both tracks live in `ActaTestRunner`, not `ActaKit` — nothing shipped needs them, and the harness child is this same binary.
- [x] **Unit tests for the oracle against hand-made files** (no subprocess yet): a correct file passes; a file with one frame dropped mid-stream fails with the position; a truncated-by-whole-frames tail is accepted only when the plan's tail rule says so; a corrupted sample fails. ⚠️ This is what proves the oracle can fail — Task 3's negative control then proves it fails *in the harness*
  - Done: `PositionEncodedAudioTests.swift`, 22 tests. Every failure case is provoked on a file built to provoke it, including the ones that keep the classification honest: corruption that *mimics* a shift is still `.wrongValue` (the confirmation window), a duplicate is `.repeated`, mic-read-as-system is `.wrongValue` at frame 0. Plus generator↔oracle loop closure (real `CMSampleBuffer` bytes pass the oracle; both `AudioBufferList` layouts fill identically; `startFrame` is absolute).
- [x] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh` (existing 238 **plus** the oracle unit tests), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green; no existing assertion changed beyond imports/constructor arguments (the generator is additive)
  - All four green. ⚠️ **The plan's "238 existing tests" was stale**: the baseline measured on this branch is **227** (verified by stashing the change and re-running), and the suite now reports **249** = 227 + 22. Later tasks should count from 249, not 238. No existing assertion was touched; the only edits to existing files are an `import ActaKit` and the extraction of the shared `CMSampleBuffer` body.

### Task 2: The self-spawn subprocess protocol and supervision

**Why.** A real `SIGKILL` needs a real child process and honest process control. This task builds the
plumbing — child record mode, disk-backed readiness, fresh-process recover mode, and a parent that kills
and reaps correctly — with a **non-crash** end-to-end pass (spawn → readiness → graceful stop → recover
is a no-op) proving the plumbing before Task 3 introduces the kill.

- [ ] **`--harness-child --root <dir>` mode, branched in `main.swift` before `Testing.__swiftPMEntryPoint()`.** If a harness argument is present, run the mode and `exit()` — never fall through to the test runner; a child must never spawn a child. The child constructs `RecordingController(settingsStore:makeSession:)` against `<dir>` with the fake source, injected permissions and injected clock, calls `start()`, and drives the **position-encoding** generator (Task 1)
- [ ] ⚠️ **Emission is frozen before readiness, and the emitted-frame count is published with it.** The self-check needs data during its probe to confirm, but the watchdog clock keeps invoking emission afterwards, so the upper bound on frames is not deterministic unless the child **stops emitting** once it has produced the required disk state and records the **exact per-track emitted-frame count**, published atomically together with readiness. The child drives emission explicitly for this reason; it does not leave emission wired to the clock
- [ ] ⚠️ **Readiness is a disk predicate proven with the production recovery scan — not a filename poll, and not the controller's coarse state.** `RecordingController` does not expose per-track progress, and `segmentCount == max(system, mic)` cannot prove one segment per track. The child inspects `<dir>` with the **read-only recovery planning** the production pass uses — `Recovery.recoveryPlan` / `Recovery.action` and `SegmentLayout` — and signals readiness only when, **per track**, that planning sees a **finalised valid** lower-index segment **and** a higher-index open segment with demonstrably usable audio, and the manifest is still `recording`. ⚠️ It must **not** call `SegmentRepair.apply` (or any mutating repair): that truncates/rewrites the open segment, and it must never run while the recording process is still writing it — readiness is a read-only observation. Signal by an **atomically renamed** readiness file (or a pipe with a defined readiness byte and careful fd inheritance so EOF is not read as ready). ⚠️ The prohibition is that the **parent must not decide to kill from filenames/sizes alone** — disk inspection by the child, through the production scan, is exactly the point
- [ ] **`--harness-recover --root <dir>` mode — a fresh process.** Constructs `RecordingController` against `<dir>` and runs recovery to a **distinguishable outcome** — this **requires a narrow completion seam** (an acknowledged, minimal production API change), because manifest polling **cannot** work: a recovery that is still running and one that finished but *failed* both leave the manifest at `.recording`, so a timeout only bounds the ambiguity, it does not resolve it. Add a seam that awaits the recovery task and returns a typed outcome — **recovered** / **nothing to recover** / **failed** — and have recover mode exit `0` on **recovered or nothing-to-recover**, non-zero on **failed** or timeout. ⚠️ `onLaunch()` also calls `Notifier.requestAuthorization()`: inject a no-op notifier if it prompts, otherwise record that it is a non-blocking notification request
- [ ] ⚠️ **Process control, done one way.** Locate the binary with `Bundle.main.executableURL` (canonicalised), **not** `CommandLine.arguments[0]`. Do **not** mix Foundation `Process` with a direct `waitpid` on the same child — either use `posix_spawn` + `waitpid` throughout (so `WIFSIGNALED` is literal) **or** `Process` + `waitUntilExit()` and assert `terminationReason == .uncaughtSignal` with the signal. Pick one and use it consistently
- [ ] **A non-crash end-to-end `@Test`** proving the plumbing: parent spawns the child, waits readiness under a bounded timeout (fails, does not hang, if it never signals), then asks the child to stop gracefully and exit, leaving a `.done` session; a `--harness-recover` run on that archive returns the seam's **nothing-to-recover** outcome and exits `0` (a `.done` session has no interrupted marker to act on) — so the supervision, readiness and recover paths are all exercised before a kill is introduced. ⚠️ This is why recover success must include **nothing-to-recover**, not only `.recovered`
- [ ] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green; the plumbing test runs with **no TCC prompt, no audio device**, under the injected clock, within a **stated wall-clock bound** (asserted)

### Task 3: The SIGKILL crash-recovery scenario, and a permanent negative control

**Why.** This is the payoff — and the negative control is what keeps it honest, proving the oracle would
catch a real loss rather than rubber-stamping.

- [ ] **The crash scenario (`@Test`):** spawn the child (Task 2); wait readiness and read the published per-track emitted-frame count; confirm the child is alive; `SIGKILL` the **exact** pid; reap it and ⚠️ **assert it was terminated by `SIGKILL`** (`WIFSIGNALED`/`.uncaughtSignal` + signal) — an ordinary exit means the kill raced the recording and the test proved nothing; then run `--harness-recover` and require it to exit `0` **before** inspecting anything
- [ ] **Assert on durable outputs only, through the oracle** (after recover exits `0`): the manifest is **`.recovered`**; both tracks assemble to valid audio (`AVAsset` with an audio track and positive duration, larger than a bare header); and the oracle confirms, **per track**, that every recovered frame equals `sample(track, position, channel)` with no gap/repeat/corruption. ⚠️ Length is **bounded, not exact**: at least the frames from the **closed** segments (a guaranteed prefix), at most the emitted-frame count published at readiness; the repaired open tail is a whole-frame prefix of what was emitted. "It decodes" / "a file exists" is **not** acceptance
- [ ] **A permanent negative control — prove the oracle fails in the harness.** Add a fake-source **drop mode** that acknowledges a buffer but silently drops the Nth, ⚠️ **positioned so the dropped frame lands in a segment guaranteed to be closed** (in the survivable prefix, not the truncated crash tail) and **after** indices have advanced, creating a detectable hole. A permanent `@Test` runs the whole harness against the faulted child and asserts the oracle returns its **specific** failure (`discontinuity`/`wrongValue` at the expected position) — **not** any failure, timeout, `ffmpeg` error or child crash — while the same run otherwise produces both tracks. ⚠️ The outer test must read the oracle's **structured result**; it must **not** try to "expect a `#expect` to fail" (an inner assertion failure is not a catchable value)
- [ ] **Update `CLAUDE.md`.** Its claims that crash recovery is manual-only and that validation only checks compilation/build/unit logic become false — correct them: crash recovery is now covered by an automated process-based harness, while real ScreenCaptureKit capture and TCC stay manual
- [ ] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh` (all existing tests **plus** the crash scenario **and** the negative control), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green, within a **stated wall-clock bound**; the existing 238 tests unchanged except imports/constructor arguments
- [ ] Acceptance (review, not grep): a reviewer confirms the child reaches recording through `RecordingController.start()` (not by fabricating segments), recovery runs in a genuinely separate process through `onLaunch()`, the kill is asserted to be `SIGKILL`, and the negative control demonstrates the oracle failing on a dropped frame in a survivable segment
- [ ] Morning check (needs a human, **not** a blocking checkbox): the app still records, stops and recovers a real `kill -9` exactly as before — the harness approximates this, it does not replace the one real-hardware check

## Backlog (not this plan)

Still parked: a filesystem/`SegmentSink` fault seam for `ENOSPC`-during-write; the failing/hanging-`ffmpeg`
assembly scenarios; the `ControlAPI` boundary (typed state + typed errors + state stream + UI migration),
which comes just before the socket/CLI transport for agents. All in `docs/backlog/acta-full-plan.md`.
