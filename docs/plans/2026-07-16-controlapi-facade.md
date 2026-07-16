# Plan: The `ControlAPI` façade — a typed, observable boundary over the pipeline (no UI migration)

## Overview

Toward an interface agents can drive, the in-process core is a single typed boundary: `ControlAPI`. It
wraps the **unchanged** `RecordingController` (the object the UI already calls, whose behaviour is
frozen by `RecordingControllerLifecycleTests`/`RecordingControllerGuardTests`) and exposes the
operations the app performs plus a typed, observable `ControlState`.

**Wrap, do not replace.** `ControlAPI` is a new `@MainActor` façade around `RecordingController`; that
type does not change, so its frozen tests keep exercising the exact object the UI calls. **Production
`ControlAPI` must wrap `RecordingController.shared`** — the same instance the menu uses — or the privacy
invariant (a recording is always visible in the UI) would not hold while the UI still reads the
controller directly.

**This plan builds and tests the façade only — it does not migrate the SwiftUI menu** (a separate later
plan, before the socket transport). No `Codable` envelope, no socket, no CLI here.

**The honest core is a pure mapping function.** `RecordingController` publishes an untyped bag
(`phase`, `isStarting`, private `isStopping`, one `errorMessage`, `recoveredBanner`, …). The façade's
value is turning that into a typed `ControlState`. That translation is a **pure function** over a plain
snapshot of the controller's observable fields — so it can be unit-tested exhaustively, including states
that **cannot be induced** through the real pipeline (an archive-open failure, an assembly failure, a
retry-after-failed-start). The façade then *observes* the real controller, builds that snapshot, and
maps it. Separating the two is what keeps every acceptance honest.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (existing 286 tests **plus** the mapping unit tests and the façade integration tests; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, every requirement in `CLAUDE.md`, and — because the façade must mirror it — the current
`RecordingController` and the frozen contract in `RecordingControllerLifecycleTests` /
`RecordingControllerGuardTests` / `ControllerTestSupport` (note especially how that helper samples state
around `objectWillChange` — pre-change plus a next-main-actor-turn sample — because it is **sampling,
not a lossless stream**, and the façade inherits that limit). ⚠️ **Facts the mapping depends on** —
verify them: `start()` is allowed after a failed start with `phase == .error`; it sets `isStarting =
true` and clears `errorMessage` but does **not** reset `phase`. A fatal stall parks `phase == .error`
while `isStopping` stays true through the background assembly. `openArchive()` sets `errorMessage`
without changing `phase`, **overwriting** whatever error was there. The controller has **one** untyped
`errorMessage` and a **separate** `recoveredBanner`. It exposes `start()` (using its mutable `title`),
not `start(title:)`.

## Scope of this plan

**In:** a pure `ControllerSnapshot` + `ControlState` model with a pure mapping function (exhaustively
unit-tested); the `ControlAPI` `@MainActor` façade wrapping `RecordingController.shared` in production;
a replay-current state stream with a sampling-honest guarantee; and integration tests driving the real
pipeline for the inducible cases.

**Out, and staying parked:** migrating the SwiftUI menu (next plan); the `Codable` envelope / socket /
CLI (transport plan); a health signal (needs `SelfCheck` plumbing); typed error *provenance* from the
pipeline (this plan classifies the single `errorMessage` by context — a lossy reverse mapping, admitted
as such — rather than pulling typed failures out of `RecordingSession`/`SegmentAssembler`); wire-format
`RecordingSummary` types (introduced with the socket).

### Task 1: A pure `ControlState` and its mapping function, unit-tested exhaustively

**Why.** Everything the façade promises rests on this translation being correct. As a pure function over
a plain snapshot, it can be tested for **every** combination — including the ones no in-process test can
induce — which is the only honest way to cover the archive-open and assembly-failure mappings.

- [ ] **`ControllerSnapshot`**: a plain value capturing exactly the controller's observable fields the mapping needs — `phase`, `isStarting`, whether a stop is in flight (the public `isSaving`/`isBusy` already fold in the private `isStopping`; use those, do not read the private field), `errorMessage`, `recoveredBanner`, `title`, `suggestedTitle`, `settings`, `recordings`, and the elapsed seconds. No SwiftUI/AppKit types
- [ ] **`ControlState`, an orthogonal struct** — `operation: Operation` (`idle` / `starting` / `recording(elapsedSeconds: Int)` / `saving`) plus `lifecycleFailure: ControlFailure?`, `notice: Notice?`, `recoveryNotice: RecoveryNotice?`, and `title`/`suggestedTitle`/`settings`/`recordings`. ⚠️ `.error` is **not** an `Operation` case. Elapsed **seconds only**. **Omit health.** `hasWorkInFlight`/`canStart`/`canStop` are computed from `operation`
- [ ] **The mapping, with explicit precedence** (`ControlState(from: ControllerSnapshot)`):
  - `operation`: **`isStarting` → `.starting` first, regardless of `phase`** (so a retry after a failed start, which leaves `phase == .error`, is `.starting`, not `.idle`/unmappable); else a stop-in-flight/`saving` → `.saving`; else the settled phase: `.recording` → `.recording(elapsedSeconds:)`, `.idle` → `.idle`, and a settled **`.error` → `.idle`** (error is carried in `lifecycleFailure`, not `operation`);
  - so a **fatal stall** reads `.saving` **with** a `lifecycleFailure` while the assembly is in flight, and once it settles becomes **`.idle`** (it leaves `.saving`) **still carrying the same `lifecycleFailure`** (the message and `phase == .error` remain) — leaving `.saving` is not clearing the failure
- [ ] **Typed errors that preserve today's display strings — provenance is admitted as lossy.** `ControlFailure` carries a `category` **and** a `displayMessage` byte-identical to today. ⚠️ The controller exposes only **one** untyped `errorMessage`, so the category is inferred from `phase`/context and, where needed, a **reverse lookup** over known `StartupFailure.userMessage` strings — a best-effort classification, **not** truthful typed provenance; say so. `recoveryNotice` maps from the **separate** `recoveredBanner` and is genuinely independent. ⚠️ **`lifecycleFailure` and `notice` are two views of the same single `errorMessage`, discriminated by the message itself — a snapshot-local rule, since the pure function has no previous state.** The archive-open failure is recognised by its **message prefix** (`"Could not open the archive: "`) and classified as a `notice` **before** any phase-based classification; any other non-empty `errorMessage` is a `lifecycleFailure` (category via the reverse lookup below). This makes them **last-write / lossy**: when `openArchive()` overwrites a prior lifecycle failure — including one set while `phase == .error` — the snapshot holds only the archive string, so the façade shows the `notice` and the earlier failure is gone, exactly as the controller lost it. Do **not** claim both can be reconstructed, and do **not** classify by `phase` alone (the archive message can sit on `phase == .error`)
- [ ] **Exhaustive mapping unit tests over synthetic `ControllerSnapshot`s** — this is where the un-inducible cases are covered: the startup window (`isStarting` with `phase` `.idle` **and** with `.error`); `.recording`; normal `.saving`; fatal stall (`.saving`+failure, then settled `.idle`+failure); failed start (`.idle`+failure, `displayMessage == StartupFailure.<denied>.userMessage`); the generic start-error string; the assembly-failure string (both ffmpeg-missing and ffmpeg-failed branches, as strings); the archive-open **notice** (recognised by message prefix, `operation` unchanged); the recovery notice independent of a failure; and ⚠️ **`openArchive` overwriting a failure that was set while `phase == .error`** — the snapshot then holds the archive prefix on `phase == .error`, and the mapping must yield a `notice` with **no** `lifecycleFailure` (prefix wins over phase), proving the last-write/lossy rule. Assert byte-identical `displayMessage`s
- [ ] Acceptance (automatable): `swift build`, `bash Scripts/test.sh` (existing 286 **plus** the mapping tests), `bash Scripts/lint.sh` green; the mapping function is **pure** (no I/O, no `RecordingController`), so these tests need no pipeline, no clock and no subprocess

### Task 2: The `ControlAPI` façade — observe, expose the operations, stream the state

**Why.** With the mapping proven, the façade is the thin, honest layer that observes the real controller
and forwards commands — the surface the UI migration and the socket will build on.

- [ ] **`ControlAPI`, `@MainActor`, wrapping a `RecordingController`.** A production entry point wraps **`RecordingController.shared`** (the menu's instance — required for the privacy invariant); an injecting initializer takes a controller so tests wrap one built with the fake seams. Never construct a second `shared`
- [ ] **The full operation set — commands and title editing, none dropped.** Commands: `start(title:)`, `stop()`, `stopAndWait()`, `recover()` (today's `onLaunch`, recovery-once), `refresh()` (today's `onAppear`), get/set `settings`, `saveSettings()`, `openArchive()`, `openInFinder(_:)`, `dismissRecoveryNotice()`. ⚠️ `start(title:)` sets the controller's `title` then calls `start()` — an observable intermediate title mutation; specify that a title set while busy follows the controller's existing guard (the start is a no-op, the title still mutates) rather than inventing new rejection. Title editing the UI does today (`controller.title`) is exposed as a settable `title` on the façade — otherwise "every operation" is false. `stop()` stays fire-and-forget, `stopAndWait()` stays awaited (it tears down capture live during `.starting`)
- [ ] **A replay-current state stream — with a sampling-honest guarantee, not an overclaim.** `states() -> AsyncStream<ControlState>` created on the main actor: **register the continuation and yield the current snapshot atomically** (no fetch-then-subscribe gap), then yield a fresh mapped snapshot **when observation detects a distinct settled `ControlState`**, in order. Also a synchronous `var state: ControlState` equal to the replayed first element (one source of truth). ⚠️ Because `RecordingController` is unchanged and `objectWillChange` fires *before* values settle and names neither the property nor its value, the guarantee is **what sampling can prove**: atomic registration + current replay; ordered distinct snapshots; and visibility of the **known dangerous transitions including a normal `.saving`** (observable because `phase = .saving` is set before an `await`). It does **not** promise a snapshot for literally every synchronous mutation; do not claim losslessness that the observation cannot deliver. Removing `.bufferingNewest(1)` only stops the façade's own buffer from dropping — use unbounded/default buffering, but do not claim it recovers states never sampled
- [ ] ⚠️ **Privacy invariant.** A `ControlAPI`-initiated recording obeys the same rule as a UI one — visible state, never silent. Wrapping `.shared` in production is what makes the menu reflect an API-started recording; state this as the reason
- [ ] **Integration tests — drive the real pipeline through `ControlAPI`** (wrapping a controller built with the fake source / injected permissions / injected clock, as the characterization tests do; never `.shared`) for the **inducible** cases and the stream: success (`operation` `idle → starting → recording → saving → idle`, both tracks assembled); the startup window shows `.starting`; failed start → `.idle`+`lifecycleFailure` with the right `displayMessage`, no wake lock held, no phantom session; recovery once across repeated `recover()`; `refresh()` does not recover; stop idempotence (a second `stop()` → no observable change); the dangerous windows (stop during starting; a second start does not begin a second capture). **Replay/ordering**: a new subscriber gets the current state first, then ordered transitions, and a normal `.saving` is observed. ⚠️ The archive-open-notice and assembly-failure mappings are **not** re-tested here (they cannot be induced without a seam) — they are covered by Task 1's pure tests; note that here
- [ ] ⚠️ **Behaviour must not change.** `RecordingController` is untouched; the existing 286 tests (including the frozen contract) stay green **unchanged** except imports/constructor arguments. The façade is additive
- [ ] Acceptance (automatable): the integration tests run in-process, no TCC prompt, no audio device, under the injected clock (assert the wait count, not wall-clock), within a stated bound; `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green
- [ ] Acceptance (review, not grep): a reviewer confirms production `ControlAPI` wraps `RecordingController.shared`, `ControlState` keeps error as orthogonal fields with the lossy-provenance limits documented, and the stream replays the current state atomically
- [ ] Morning check (needs a human, **not** blocking): none — the UI is unchanged this plan; the menu behaves exactly as before because `RecordingController` is untouched

## Backlog (not this plan)

Next: **migrate the SwiftUI menu to consume `ControlAPI`** (a small UI-owned `@Observable` adapter
subscribes to `states()`; the UI stops reading `RecordingController` directly), proving the façade
sufficient for a real client. Then the **socket/CLI transport** (`Codable` envelope, Unix socket,
`actactl`, wire-format `RecordingSummary`). All in `docs/backlog/acta-full-plan.md`.
