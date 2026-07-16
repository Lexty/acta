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
crash-safety approach), and honour every requirement in `CLAUDE.md` — including the skills it already
mandates. Task-specific on top of that: **`.claude/skills/screencapturekit-audio`** is the API Task A
moves behind a protocol, and **`.claude/skills/crash-safe-recording`** covers the segmentation and
recovery semantics around it. ⚠️ Neither skill documents the callback-queue and drain semantics —
those live only in Task A below, which is exactly why that task spells them out.

**Language: English only** across UI, code, docs and git — see `CLAUDE.md`.

Environment: Apple M3, macOS 26.2, Swift 6.3.3, CLT only (no full Xcode), SwiftPM. `ffmpeg` present.

**Already shipped and verified live (`v0.1.0`) — context, not a goal:** start/stop from the menu bar;
two separate streaming tracks; `kill -9`/restart leaves the written segments recoverable and they are
finalised on the next launch; a failed start is diagnosed and reported; the display is held awake for
the duration of a recording; the mix is out of the pipeline. **Do not re-implement any of it.**

## Validation Commands
- `swift build -c release`
- `swift test` (under CLT-only this ONLY COMPILES the tests — there is no `xctest` host utility)
- `bash Scripts/test.sh` (real unit-test run via the executable runner; fails on error)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor is explicit here; it defaults to `dev` when omitted, and `stable` refuses a dirty or untagged tree by design)

## Scope of this plan

**Two open tasks: A then B.** Everything before them is done and verified live — tagged `v0.1.0`
(`kill -9` → 7/7 segments recovered incl. a repaired 9.4 s tail; a 9:26 recording that survived the
display-sleep timeout; the mix dropped from the pipeline). That history lives in
`docs/plans/completed/acta.md`.

**Why these two.** The project already has real automated coverage — 193 tests, including the pure
diagnosis, recovery and layout logic. What stays unreachable is narrow and precise: **a successful,
capture-backed recording and the watchdog/restart paths behind it**, because `RecordingSession.start()`
checks real TCC, creates a real `SCStream` and waits for real buffers. A façade + characterization task was pulled from an overnight run for exactly that reason —
it needed a *successful* recording to be reachable, and it is not. These two tasks make it reachable
in-process, and nothing else.

This plan converged over six rounds of external review; each round found exactly one real defect, and
the last said "Ready". **The ⚠️ markers are where a reasonable implementation goes wrong** — they are
findings, not decoration.

Breaking things is cheap: a protected stable build exists (`Acta.app`, `dev.personal.acta`, built from
the `v0.1.0` tag), and the dev build is a separate app with its own identity and its own archive.

### Task A: Extract `CaptureSource` (mechanical, with concurrency preserved)

**Why.** `AudioRecorder` **is** the ScreenCaptureKit integration: declared
`NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable`, owning `currentStream: SCStream?`
and building the content filter and configuration itself. Nothing can be injected, so `start()`
cannot be reached without real TCC, a real display and real buffers — which is why **a successful,
capture-backed recording and the watchdog/restart paths behind it** are the one area still stuck at
`manual test (skipped - not automatable)`, while the pure logic around them is well covered. This task
moves the capture behind a protocol and nothing else.

🪤 **Mechanical — but "mechanical" here means *behaviour-preserving*, not textual.** Extracting the
conformances forces a few ownership decisions (below); make exactly those and no others. The fake,
the permission seam, the clock and the tests belong to Task B. Task 11 showed this works: extract
first, design second.

- [ ] **`CaptureSource` protocol** in `ActaRuntime`, owning **only capture lifecycle and buffer production**: `start()`, `stop()`, an `isStreaming` flag, buffer delivery as `(track, CMSampleBuffer)`. ⚠️ **There is deliberately no `restart()` on the protocol.** Restart is `AudioRecorder`'s composition, spelled out below — putting it on the source creates an unresolvable ordering contradiction (finalise before restarting and old queued callbacks append after finalisation; restart first and the replacement delivers before the writers advance)
- [ ] ⚠️ **`AudioRecorder.restart()` keeps today's exact order, and this is the whole point**: `await source.stop()` (which, by contract, has drained — no callback can still arrive) → `finishAndAdvance()` on **both** writers → `try await self.start()`. Note it calls **`self.start()`**, not `source.start()`, because today `restart()` ends in `start()` and therefore **re-checks permissions**; composing it any other way silently drops that. The source knows nothing about writers or segments
- [ ] ⚠️ **Permissions do NOT move.** `AudioRecorder.start()` calls `requestPermissionsIfNeeded()` before `startStream()` (verified in source). That check stays **in `AudioRecorder`**, unchanged — it goes neither into the protocol nor into `SCKCaptureSource`. Otherwise the fake would bypass different logic than the real path runs, which is exactly the divergence a fake must not have. Task B injects the permission dependency; Task A does not touch it. Note today's behaviour, to be preserved: **every restart re-checks permissions**, because `restart()` ends in `try await start()`
- [ ] ⚠️ **`CMSampleBuffer` is the boundary and must stay so.** `SegmentWriter` feeds `AVAssetWriterInput`, so an abstract "audio chunk" would move the seam to the wrong place and leave format propagation, timestamps, rotation and real WAV creation untested
- [ ] **The ownership decisions this extraction must make** — these are the design content of an otherwise mechanical task:
  - `SCKCaptureSource` owns the `SCStream` delegate/output entry points and the ScreenCaptureKit callback queues;
  - its callback forwards `(track, buffer)` **synchronously on the corresponding per-track queue**;
  - `AudioRecorder` appends on that callback, **without an extra asynchronous hop**;
  - `stop()` and `restart()` **drain both audio callback queues before returning**.
- [ ] ⚠️ **The drain is the crux, and it is where a careless move breaks everything.** "No delivery after an awaited `stop()`" is *not* provided by `SCStream.stopCapture()`. Today it comes from `AudioRecorder` doing `systemQueue.sync { … }` / `micQueue.sync { … }` *after* `stopCapture()` — and `systemQueue`/`micQueue` **are the ScreenCaptureKit sample-handler queues** (`addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)`, verified in source). So today a single `systemQueue.sync { systemWriter.finishAndAdvance() }` does **two things atomically**: it drains the callback queue *and* advances the writer, with no delivery possible in between. Moving queue ownership into the source breaks that atomicity unless `stop()` carries the drain guarantee. **`CaptureSource.stop()` must not return until every already-enqueued callback has run**, and preserving this is the single most important review criterion of this task
- [ ] ⚠️ **Preserve the stream identity check.** `clearStream(ifIdentical:)` compares under one lock so a delayed `didStopWithError` from an old stream cannot clear a replacement created by `restart()`. Keep that guarantee wherever the delegate ends up living
- [ ] **The contract, written down** and honoured by every implementation — this is what makes a fake meaningful rather than decorative: the buffer callback is installed **before** `start()`; **no delivery after an awaited `stop()`**; per-track **ordered** delivery; `isStreaming` reflects the source's **actual state**, including asynchronous failure — not merely whether `start()` returned
- [ ] **Failure semantics, stated exactly** (today's, not a new one): raw ScreenCaptureKit failures inside stream creation are mapped to `StartupFailure.streamNotStarted` so `SelfCheck` can spend its restart attempts; permission failures arise **outside** stream creation (`requestPermissionsIfNeeded`) and propagate untouched
- [ ] **`SCKCaptureSource`**: the existing ScreenCaptureKit code moved behind the protocol, behaviour unchanged. `AudioRecorder` keeps what it already does — routing buffers into the two `SegmentWriter`s, `receivedBufferCounts`/`writtenBufferCounts`/`segmentBytesOnDisk`, `setSegmentCountObserver`, `finalizedSegmentCount` — and stops knowing about `SCStream`
- [ ] ⚠️ **The per-track queues move with the source, and only there.** They are the SCK sample-handler queues, so they cannot belong to both sides: `SCKCaptureSource` owns them, forwards `(track, buffer)` synchronously on them, and `AudioRecorder` appends on that callback with no hop of its own. **`AudioRecorder` therefore does not keep its own per-track queues** — the per-track serialization it relies on is the one the source provides, and that is exactly why `stop()` must drain before returning. A fake source owes the same guarantee: distinct serial queues per track, drained by `stop()`
- [ ] `AudioRecorder.init` takes a `CaptureSource` with the real one as the default, so no production call site changes
- [ ] ⚠️ **Behaviour must not change.** Existing tests stay green **unchanged** except for `import`s and constructor arguments. No assertion may be deleted, broadened, skipped, or turned into "does not throw"
- [ ] Acceptance (automatable): `grep -rnE "^import ScreenCaptureKit|: *SCStream|SCStream[A-Za-z]* *[),:]|SCContentFilter|SCShareableContent" Sources/ActaRuntime --include=*.swift` matches **only** `SCKCaptureSource.swift`. ⚠️ Match **imports and type references, not prose**: `AudioRecorder`'s doc comments legitimately mention `SCStream` today (lines ~6/9), and a correct implementation must not fail acceptance over documentation. Move a comment if it belongs with the code; never contort code to satisfy a grep
- [ ] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green
- [ ] Acceptance (review, not grep): diff the moved code against the original. Grep confinement cannot prove the stream configuration, the output registration, or the **queue/drain ordering** survived intact — that is what a reviewer must check
- [ ] Morning check (needs a human, **not** a blocking checkbox): `Acta Dev.app` still records, stops and recovers exactly as before

### Task B: Inject permissions and time, and drive the pipeline with a fake

**Why.** With `CaptureSource` extracted, this makes a **successful recording reachable in-process** —
no TCC prompt, no display, no audio device. It is what the parked façade + characterization task
waits on.

**Still parked, do not build:** the process-based crash harness (`SIGKILL` a child, recover in a fresh
process), the deterministic audio oracle (frame counts, fingerprints), filesystem fault injection /
`SegmentSink`, `ProcessRunner`, and a full virtual scheduler with `advance(by:)` + drain-to-quiescence.

- [ ] **`PermissionChecking` protocol** over the four static calls (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `AVCaptureDevice.authorizationStatus(for: .audio)`, `AVCaptureDevice.requestAccess(for: .audio)`). The real implementation keeps today's bodies; the fake answers granted/denied per permission with no system dialog
- [ ] ⚠️ **Inject it where the check actually lives**: into **`AudioRecorder`** (which owns `requestPermissionsIfNeeded`) and into **`SelfCheck`** (which diagnoses a missing permission). `RecordingSession` is the **composition root** — it passes the same dependency to both — but it is **not** itself a permission consumer. Preserve today's behaviour that every restart re-checks, since `restart()` ends in `start()`
- [ ] **`SelfCheckClock` protocol with BOTH `sleep(for:)` and `now`.** ⚠️ A sleeper alone is the trap: `SelfCheck` sleeps, but stall detection separately reads `Self.monotonicSeconds()` (lines ~208/308). An instant sleeper leaves `now` unchanged, the stall threshold **never elapses**, and the entire restart path silently becomes untestable while the tests still pass. The test clock advances `now` when it sleeps. This is **not** the parked virtual scheduler — no `advance(by:)`, no queues, no drain-to-quiescence. `startedAt` and metadata keep wall time exactly as today
- [ ] **A scripted fake source** — deliberately dumb, so it cannot drift into being a scheduler: emit N buffers for either or both tracks on `start()`/`restart()`; emit another batch on a clock tick or an explicit test action; stop emitting one track; fail selected `start()`/`restart()` calls. ⚠️ No tone generation, no arbitrary cadence — parked-oracle territory, and not needed to reach a confirmed recording
- [ ] ⚠️ **The fake must deliver the two tracks from distinct serial queues.** The likeliest fake/real divergence is **callback concurrency, not buffer contents**: a fake calling back serially from the test thread will never expose simultaneous system/mic delivery, `stop()` racing an already-enqueued callback, an old stream's delayed failure arriving after `restart()`, or accidental double-queueing
- [ ] **A reusable `CaptureSource` contract suite**, run **in full against the fake**: per-track ordering, no delivery after an awaited `stop()`, `stop()` racing a queued delivery, `stop()` draining before it returns, `isStreaming` transitions including asynchronous failure, and an old stream's delayed failure not clearing a replacement
- [ ] ⚠️ **Against the real `SCKCaptureSource`, run only the named subset that needs neither TCC nor a successful start**: `isStreaming` is false before `start()`; a `start()` that cannot reach a display maps to `StartupFailure.streamNotStarted` and leaves `isStreaming` false; `stop()` before any `start()` is safe. Nothing more. **The two-stream identity case is fake-only by design** — it needs two successfully created `SCStream`s plus an injected delayed delegate failure, i.e. TCC and a display, so demanding it against the real source would force the agent to fake the test, omit it, or reopen Task A. The real source's identity guarantee is covered by Task A's review criterion instead, not by a test that cannot run
- [ ] The fake synthesises **real `CMSampleBuffer`s**: a PCM `AudioStreamBasicDescription` → `CMAudioFormatDescription` → monotonically timed buffers backed by a `CMBlockBuffer` (or `CMSampleBufferCreateReadyWithAudioBufferList`); mind the backing memory's lifetime. Use **48 kHz stereo** — ⚠️ but treat this as *a supported realistic format*, **not** "matching production": `SCStreamConfiguration` requests sample rate and channel count, it does **not** guarantee a PCM layout. **Include one non-interleaved buffer case** — CoreMedia format variation is exactly where fake-only confidence fails
- [ ] **Wiring**: dependencies default to the real implementations, so shipped behaviour is identical and no production call site changes
- [ ] Tests — **the deliverable is the tests, not the protocols**:
  - fake delivers buffers → `start()` reaches a confirmed recording → segments appear → `stop()` assembles;
  - ⚠️ the success test uses timestamps **crossing a segment boundary**, proving rotation and finalisation rather than "a file exists";
  - assert **both tracks accepted buffers**;
  - Screen Recording denied → today's `StartupFailure`, and **no wake lock left held**;
  - source never delivers → self-diagnosis restarts, then gives up, exactly as today;
  - a track stalls mid-recording → the watchdog restarts it;
  - **exact call counts on the source**: `start()` once for a clean run; for the give-up path exactly `maxRestartAttempts` **stop/start pairs** (there is no `restart()` on the protocol); `stop()` on failure; permission requests only when expected.
- [ ] ⚠️ **Define "valid segment" or the criterion is worthless**: an agent will satisfy "non-empty" with `fileSize > 0`. Require, in-process: `AVAsset` exposes an audio track **and** a positive duration, and the file exceeds header-only size
- [ ] ⚠️ **"No phantom session" belongs to the controller, not the session.** `RecordingSession.start()` writes `session.json` (line ~89) **before** `recorder.start()` (line ~98), so a permission denial **does** leave a marker — cleanup is `RecordingController`'s job (`FailedStartCleanup.removeIfEmpty`, lines ~234/240). Test it **through `RecordingController`** and assert the **existing** cleanup. Do **not** "fix" `RecordingSession`: that is a behaviour change this task forbids
- [ ] ⚠️ **The wiring test must not breed test-only introspection.** "Assert `RecordingSession` uses the real implementations" is not cleanly satisfiable against private fields, and merely constructing one proves nothing. Test the **default factory/composition function** directly, or add an explicit internal dependency-description hook — do not reach into privates
- [ ] ⚠️ **Behaviour must not change.** Existing tests stay green unchanged except for `import`s and constructor arguments; no assertion deleted, broadened, skipped, or turned into "does not throw"
- [ ] Acceptance (automatable): `grep -rn "CGPreflightScreenCaptureAccess\|CGRequestScreenCaptureAccess\|AVCaptureDevice" Sources/ActaRuntime` matches only the real `PermissionChecking` implementation
- [ ] Acceptance (automatable): the new tests run **in-process, with no TCC prompt and no audio device**, and the watchdog tests finish **under a stated wall-clock bound** (assert it — not "the run stays fast"). If a start scenario takes ~2 s of real time, the clock is not wired
- [ ] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green
- [ ] Morning check (needs a human, **not** a blocking checkbox): `Acta Dev.app` still records, stops and recovers exactly as before — the seam is a refactor, and live behaviour is the only thing that proves it

## Backlog

`docs/backlog/acta-full-plan.md` holds everything else, with the review findings each item still needs
fixed before promotion. Nearest, in order: the **`ControlAPI` façade + characterization contract**
(unblocked by Task B — its parked entry lists what must be fixed first), **Export mix** (needs a
`ProcessRunner` + scheduler; `FFmpeg.mixArgs` was correctly deleted as dead code — restore it from git
history when promoting), then the **serialized lifecycle**, the **process-based harness**, and
durability. A **self-signed signing certificate** needs the user present and its TCC benefit is
unverified — never attempt it unattended.
