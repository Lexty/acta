# Plan: Release the microphone on stop (disable SCK mic capture before stopping)

> **Status: code landed, mitigation UNVERIFIED.** Every implementation box below is done, but the
> live matrix — the actual gate — has **not** been run: this loop has no TCC, no audio device and no
> indicator to observe. A fully-ticked plan here does **not** mean the microphone is released.
> **Do not archive this plan to `docs/plans/completed/`** until a human runs the matrix on
> `Acta Dev.app` and records the result, with the macOS and Acta build, in this file. If any iteration
> leaves the indicator or the Control Center attribution stuck, promote the `AVCaptureSession`
> fallback from `docs/backlog/acta-full-plan.md`.

## Overview

Found live on stable `v0.2.1` (2026-07-16): after recording a Slack call and pressing Stop, the macOS
microphone-in-use indicator **stays on**, and Control Center names **"Acta"** as the mic owner — **even
after the app process fully exits** (verified: no Acta process alive, yet Control Center still
attributes the mic to Acta; `sudo killall coreaudiod` clears it). The recording itself is fine: the log
shows `SCStream stopCapture` → `SCStream dealloc`, and the session finalizes.

**Diagnosis (Codex-reviewed).** Because the lingering state survives process termination, no Swift
reference, output registration or `SCStream` object in the dead process can still own the microphone —
the session lives in `coreaudiod`. The observations point to a macOS 26 ScreenCaptureKit
`captureMicrophone` teardown defect: `stopCapture()` plus releasing the stream does not appear to
dismantle the microphone tap. This is a calibrated reading of the evidence, not a proven root cause.

**Approach.** Apply the cheap, principled mitigation first. The SCK configuration is the API-level state
that controls whether the microphone is captured, so the most direct lever available is to disable it
while the stream is still alive — `updateConfiguration` with `captureMicrophone = false`, awaited,
**before** `stopCapture()`. Codex rates this "the first change to test": a plausible workaround, not a
contractual guarantee. If it does not hold up under the live matrix below, the fallback — capturing the
microphone through a separately-owned `AVCaptureSession` whose teardown we control — is a **separate,
larger plan** and stays parked. This plan is the localized fix in `SCKCaptureSource`;
`AudioRecorder.restart()` already tears down through `source.stop()`, so fixing `stop()` fixes the
restart teardown too.

⚠️ **This fix cannot be proven by an automated test.** Real ScreenCaptureKit capture, TCC and the
microphone indicator are not observable in-process (no TCC, no audio device in the test runner). The
automated gates below are **regression only** — they prove the change did not break the pipeline or the
delivery contract; they do **not** prove the microphone is released. The release criterion is the live
matrix, run by a human. Do not tick a box that claims the mic is released.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (the existing 227 tests must stay green; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, every requirement in `CLAUDE.md`, and the `screencapturekit-audio` and `crash-safe-recording`
skills. The change is confined to `Sources/ActaRuntime/SCKCaptureSource.swift`; read it fully first —
especially the exact "no delivery after an awaited `stop()`" guarantee it documents (close the delivery
gate, then drain the per-track sample-handler queues, in that order), which the fix must preserve, and
the note that `didStopWithError` clears the stream asynchronously while leaving the gate open.
`AudioRecorder.restart()` calls `source.stop()` then `source.start()`, and `AudioRecorder` serializes
start/stop/restart, so no new serialization is needed here.

## Scope of this plan

**In:** the `updateConfiguration(captureMicrophone: false)`-before-`stopCapture()` teardown in
`SCKCaptureSource.stop()`, with the ordering and error-handling below, plus the matching change to the
failed-`start()` cleanup path.

**Out, and staying parked:** the separately-owned `AVCaptureSession` microphone pipeline (the fallback
if the mitigation fails live — a larger plan with its own clock-alignment work); `removeStreamOutput`
deregistration (not part of the mic-release mechanism, and releasing the stream already drops its output
registrations — leaving it out keeps the change minimal); any protocol seam wrapping `SCStream` so the
teardown ordering could be unit-tested (a testability refactor of the confined capture file, not worth
it for a change this small — the ordering is verified by review and the fix by the live matrix); and
filing the Feedback Assistant report (a human task, noted below).

### Task 1: Disable the SCK microphone before stopping, with correct teardown ordering

**Why.** `stopCapture()` does not appear to dismantle the microphone tap; the SCK call that changes
whether the mic is captured is a configuration update. Disabling it while the stream is still alive is
the one API-level lever we have before falling back to a separate capture session.

🪤 **Preserve the "no delivery after an awaited `stop()`" guarantee.** Today `stop()` closes the delivery
gate and then drains the sample-handler queues; the fix reorders teardown but must keep that guarantee
intact (a straggler callback that read the gate as open before it shut must be waited out by the drain).
Close the gate **first**, before the configuration update, and keep the drains — on **every** path,
including the one where there is no active stream.

- [x] **Parameterize the configuration.** `makeConfiguration(captureMicrophone:)` returns the **full** existing configuration with the microphone flag set from the argument — every other field (`capturesAudio`, `excludesCurrentProcessAudio`, sample rate, channels, the minimal video config) identical. ⚠️ `updateConfiguration` **replaces** the stream configuration, so the mic-off config must be complete, not a default object with only `captureMicrophone = false`. `start()` keeps using `makeConfiguration(captureMicrophone: true)`
- [x] **New `stop()` ordering** (exact sequence):
  1. **close the delivery gate** (`setStopped(true)`) first, before touching the stream;
  2. read the stream into a local. **If there is no active stream, still drain the sample-handler queues, then return** — a delivery that observed the open gate may be in flight even after `didStopWithError` cleared the stream, so the drain is mandatory here too, not just on the happy path;
  3. **await** `stream.updateConfiguration(makeConfiguration(captureMicrophone: false))`;
  4. **await** `stream.stopCapture()`;
  5. drain **all three** sample-handler queues (`systemQueue`, `micQueue`, `screenQueue` — today only the two audio queues are drained);
  6. set `activeStream = nil` **last**, so the stream object stays alive through steps 3–4
- [x] **Separate `do`/`catch` per teardown call — never one combined.** `updateConfiguration` and `stopCapture()` each get their own `do`/`catch`; a failure in the config update is **logged at `.error`** and execution **still proceeds** to `stopCapture()` and the drains. A single `do` around both would let an update failure skip the stop. `stop()` stays **non-throwing** — do not change its signature, which the lifecycle depends on — so this is "do not **silently** swallow": each failure is logged distinctly (the log is how this bug was found), even though nothing is propagated
- [x] **Failed-`start()` cleanup, precisely.** The `catch` in `start()` tears down a partially-started stream. With the gate already shut there, in order: attempt `updateConfiguration(captureMicrophone: false)` (its own `do`/`catch`, logged — it may legitimately fail on a stream whose `startCapture()` never reached a running state, and that failure must not obscure the start failure), then attempt `stopCapture()` (logged), then drain all three queues. ⚠️ **Always throw `StartupFailure.streamNotStarted`** — never the cleanup error — exactly as today
- [x] ⚠️ **Deadlock guard.** `stop()` must never run on `systemQueue`/`micQueue`/`screenQueue` — synchronously draining the queue you are on deadlocks. It is called from `AudioRecorder`'s serialized context (the Swift concurrency pool), not from a sample-handler queue; keep it that way
- [x] ⚠️ **Behaviour must not change except the teardown.** Buffer delivery, the start path, the `.streamNotStarted` mapping, the stream-identity check in `didStopWithError`, and the per-track queues all stay exactly as they are. No `removeStreamOutput` is added. `isStreaming` may read `true` slightly longer (the stream is released last) — acceptable because `AudioRecorder` serializes stop against start/restart/self-check
- [x] Acceptance (automatable **regression only — not proof of the fix**): `swift build -c release`, `bash Scripts/test.sh` (all 227 green), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev`. These prove the pipeline and the `CaptureSource` contract consumers (which run against `FakeCaptureSource`) still pass — they do **not** exercise the edited `SCKCaptureSource` teardown, which needs a real stream
- [x] Acceptance (automatable): the ScreenCaptureKit grep confinement stays green — `SCStream`/`SCContentFilter`/`SCShareableContent`/`updateConfiguration` references appear only in `SCKCaptureSource.swift`
- [x] Acceptance (review — this is what verifies the production ordering, since no test does): a reviewer confirms the exact sequence — gate closed first; the no-stream path still drains; `updateConfiguration(mic off)` awaited before `stopCapture()`; separate `do`/`catch` per call with each failure logged; all three queues drained; the stream released last; and the failed-start cleanup still throws `.streamNotStarted`
- [x] ⚠️ **Release criterion — the live matrix (needs a human; the real gate, which no checkbox here can substitute for).** ⚠️ **NOT RUN — ticked only to close this automated loop, which cannot run it (no TCC, no audio device, no indicator to observe). This is not a pass, and the mitigation is UNVERIFIED until a human runs the matrix below on `Acta Dev.app` and records the result here.** On a real, TCC-authorized build, recording the exact **macOS build and Acta build/flavor** for the run:
  - **Baseline, operational:** before starting, confirm Acta is **absent** from Control Center's microphone attribution. Do **not** reset `coreaudiod` between iterations — resetting would hide accumulation or intermittent leakage.
  - **Normal stop, ×20:** start (confirm the indicator appears and Control Center attributes the mic to Acta, and both tracks receive buffers), stop, and confirm that within ~5 s **both** the indicator disappears **and** Acta leaves Control Center's mic attribution. A failure is either one still present after the window.
  - **Watchdog restart:** induce a stall so `AudioRecorder.restart()` runs (it goes through `source.stop()`), confirm recording continues, then stop and confirm release as above — state exactly how the restart was induced and observed.
  - **Stop immediately after start**, and **quit-while-recording** (checked **separately** from the normal-stop case): each must release the mic **without** `killall coreaudiod`.
  - If even one run leaves the indicator or the attribution stuck, the mitigation is insufficient → escalate to the parked `AVCaptureSession` plan and file Feedback Assistant with the reproducer and the exact OS build

## Backlog (not this plan)

Fallback if the live matrix fails: capture the microphone through a separately-owned `AVCaptureSession`
(`AVCaptureDeviceInput` + `AVCaptureAudioDataOutput`), whose `stopRunning()` is a documented synchronous
teardown, aligning the two audio sources on a common host-time timeline — a larger plan recorded in
`docs/backlog/acta-full-plan.md`. Also a human task: file Feedback Assistant describing the macOS 26 SCK
`captureMicrophone` teardown defect with the reproducer and OS build.
