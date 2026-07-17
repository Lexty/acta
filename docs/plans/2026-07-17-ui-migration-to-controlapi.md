# Plan: Migrate the SwiftUI menu to consume `ControlAPI` (the UI stops touching the pipeline)

## Overview

`ControlAPI` (landed) is a typed, observable façade over the unchanged `RecordingController`, with
`ControlAPI.shared` wrapping `RecordingController.shared` — the menu's instance. This plan makes the
SwiftUI menu a **client of that façade**: it stops reading `RecordingController` directly and instead
renders a `ControlState` delivered by `ControlAPI.shared.states()` and issues commands through the
façade. That proves the façade is sufficient for a real client, and it is the last step before the
socket/CLI transport — which becomes a *second* client of the same boundary.

**Behaviour must not change.** The menu must start, stop, show state, tick the timer, list recordings,
edit the title and settings, open the archive, and quit exactly as it does today. The façade already
wraps the same `RecordingController.shared`, and `RecordingController` is **not** touched by this plan —
so the frozen characterization/guard tests and the `ControlState` mapping tests keep protecting the
behaviour underneath. What changes is only which object the views read and call.

⚠️ **This is a UI change, and the UI has no automated test.** The regression gates below prove the
pipeline and the façade still pass; they do **not** prove the menu renders correctly. The real
acceptance is a **review** that every view reads `ControlState`/calls `ControlAPI` (never the pipeline)
and a **human morning check** that the menu behaves exactly as before — the same honest situation as any
SwiftUI change here.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (the existing 314 tests stay green; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, every requirement in `CLAUDE.md`, and the current `Sources/Acta/ActaApp.swift` (the menu and
`AppDelegate`) plus `ControlAPI` / `ControlState`. ⚠️ **Facts the migration depends on** — verify them:
`ControlAPI.shared` exists and wraps `RecordingController.shared`; `ControlAPI` exposes a settable
`title` and `settings`, `saveSettings()`, `recordings`, `suggestedTitle`, `state`, `states()`, and the
commands `start(title:)`, `stop()`, `stopAndWait()`, `recover()`, `refresh()`, `openArchive()`,
`openInFinder(_:)`, `dismissRecoveryNotice()`. Today the menu holds `@ObservedObject controller =
RecordingController.shared` and binds `$controller.title` and `$controller.settings.<field>`, saves on
`.onChange(of: controller.settings)`, and `AppDelegate` calls `RecordingController.shared.onLaunch()` and,
on quit, `controller.hasWorkInFlight` + `stopAndWait()`. The elapsed timer ticks because
`RecordingController.elapsedSeconds` is `@Published`, so each tick flows through `states()`.

## Scope of this plan

**In:** a UI-owned adapter that subscribes to `ControlAPI.shared.states()`, and the migration of the
menu views and `AppDelegate` to read `ControlState` and call `ControlAPI` — preserving every current
behaviour, including the two-way title/settings bindings and the ticking timer.

**Out, and staying parked:** the socket/CLI transport (`Codable` envelope, Unix socket, `actactl`,
wire-format `RecordingSummary`); any change to `ControlAPI`, `RecordingController` or the pipeline (if
the migration seems to need one, the façade is missing something — surface it, do not reach around it);
a health signal.

### Task 1: Route the menu and `AppDelegate` through `ControlAPI`, via a UI-owned adapter

**Why.** A single boundary is only real when the app's own UI goes through it; and a real client is the
honest proof the façade is sufficient before a socket becomes the next client.

🪤 **Render `ControlState`, do not reconstruct pipeline state.** The views derive everything from
`ControlState` and call `ControlAPI` for every action. No view may reference `RecordingController`,
`RecordingSession`, `SelfCheck`, `SegmentAssembler` or `AudioRecorder`.

- [x] **A UI-owned adapter** (e.g. `ControlViewModel`) in `Sources/Acta`, `@MainActor`, `ObservableObject`, **owned by `MenuContent` as `@StateObject`** (the view creates it; it must not be `@ObservedObject`). ⚠️ It initialises its `@Published private(set) var state` **synchronously from `ControlAPI.shared.state` in `init`** — replay-current does **not** prevent a blank first frame, because a `Task` started in `init` has not run yet when SwiftUI first renders
- [x] ⚠️ **A cycle-free, cancelling subscription.** The naïve `task = Task { for await s in api.states() { self.state = s } }` with `deinit { task.cancel() }` **leaks**: the running task retains `self`, so `deinit` never runs and never cancels. Drive the subscription from the view's **`.task {}` modifier** (auto-cancelled on disappear) or capture **`[weak self]`** and stop when `self` is gone — and cancellation must end the `for await` so `AsyncStream.onTermination` unregisters the continuation. This matters because the `.window` menu rebuilds its content, so repeated opens must not accumulate subscriptions
- [x] **Settings bindings write to the *authoritative* value, not the snapshot.** The three settings controls are two-way. ⚠️ A setter that reads `state.settings` (a **lagging** UI snapshot) and writes it back can **clobber** a recent sibling-field edit not yet delivered by the stream. Each setter merges its field into the **latest `ControlAPI.shared.settings`** (the authoritative current value), then assigns and calls `saveSettings()` — reproducing today's save-on-change including any normalisation `saveSettings()` applies. Put the pure "merge one field into a `RecordingSettings`" step in `ActaKit`/`ActaRuntime` as a tested function so the clobber logic is not review-only
- [x] **Title editing uses an optimistic local value.** ⚠️ A `TextField` whose getter reads only the asynchronously-refreshed `state.title` while the setter writes `ControlAPI.shared.title` can visibly **revert characters / jump the cursor** when an unrelated stream snapshot arrives mid-typing. The adapter keeps a local title it updates **synchronously** on edit and writes through the façade. ⚠️ Reconciliation must not let a **stale buffered snapshot** overwrite that optimistic value: while a local title write is unacknowledged, the adapter **ignores the `title` field of incoming snapshots** (the local value stands), and resumes reconciling `title` only once a snapshot arrives whose title **equals the pending write** (the write is now reflected) or is a demonstrably newer authoritative change. Every **other** field of each snapshot still applies normally throughout
- [x] **Migrate `MenuContent`**: derive the controls from `state.operation` — `.starting` → disabled "Starting…", `.saving` → disabled "Saving…", `.recording` → red "Stop", `.idle` → "Start Recording", matching today's flags exactly; the busy/disable condition for the title and settings is `state.operation != .idle` (today's `isBusy`); the timer from `state`'s `recording(elapsedSeconds:)` formatted with `MeetingInfo.formatDuration` (it keeps ticking because `elapsedSeconds` is `@Published` and each tick is a distinct `ControlState` the stream emits); the recordings list, the suggested-title placeholder, and the banners from `state.recoveryNotice` (dismiss via `dismissRecoveryNotice()`) and `state.lifecycleFailure`/`state.notice` (`displayMessage`). Every action calls a `ControlAPI` command
- [x] **Migrate `AppDelegate` with the exact quit protocol** (not a looser paraphrase): launch recovery via `ControlAPI.shared.recover()`; and `applicationShouldTerminate` stays `guard ControlAPI.shared.state.hasWorkInFlight else { return .terminateNow }` → `Task { await ControlAPI.shared.stopAndWait(); NSApp.reply(toApplicationShouldTerminate: true) }` → `return .terminateLater`. ⚠️ Unconditionally returning `.terminateLater`/awaiting on an idle quit would change today's behaviour
- [x] ⚠️ **Privacy invariant, now load-bearing for the UI.** `ControlAPI.shared` wraps the same `RecordingController.shared` the menu now observes via `states()`, so a recording started through the façade shows in the menu — what keeps "never a silent recording" true once a socket is a second client. Do not break the shared-instance wiring
- [x] ⚠️ **Behaviour must not change, and this is UI-only.** `RecordingController`, `ControlAPI` and the pipeline are untouched; the existing 314 tests stay green **unchanged** (a UI-only migration needs **zero** test edits — if an existing test needs changing, something non-UI changed and that is out of scope). The button-state, timer, banner, title and settings behaviour must match today's exactly
- [x] Acceptance (automatable): `grep -nE "RecordingController|RecordingSession|SelfCheck|SegmentAssembler|AudioRecorder" Sources/Acta/*.swift` returns **nothing** (a heuristic, not proof — pair it with the review below), and `ControlAPI`/`ControlState` **are** referenced. Match type references, not prose. Plus the settings-merge function has unit tests
- [x] Acceptance (automatable): `swift build -c release`, `bash Scripts/test.sh` (314, unchanged), `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` all green
- [x] Acceptance (review — verifies what no test can): [human review — not automatable; code satisfies each item] a reviewer confirms `@StateObject` ownership, a cycle-free cancelling subscription, synchronous initial state, settings setters merging into the authoritative `ControlAPI.shared.settings` (not the snapshot), the optimistic-local title, the exact quit protocol, and that every view reads `ControlState`/calls `ControlAPI`
- [x] ⚠️ **Morning check (needs a human — the real gate) [manual — not automatable, deferred to human], exercising the hazards above**, on `Acta Dev.app`: Start → the timer ticks up; Stop → "Saving…" then idle with the recording listed; **type into the title while a recording is in flight and confirm no character reversion/cursor jump**; **change the archive path AND the segment length AND the delete-toggle, then reopen the menu and confirm all three persisted** (catches a clobber); **open and close the menu several times during a recording and confirm the timer still ticks and nothing misbehaves** (catches a leaked/duplicated subscription); Open Archive works; a permission-denied start shows the same error; quitting during a recording still finishes and assembles it. Anything that differs from today is a regression this plan must fix

## Backlog (not this plan)

Next and last for the agent interface: the **socket/CLI transport** — a `Codable` command envelope, a
Unix domain socket (mode `0600`, no network listener), an `actactl` CLI as a second client of
`ControlAPI`, launch-if-not-running semantics, and wire-format `RecordingSummary` value types. The
privacy invariant carries over: an API-initiated recording is never silent. Recorded in
`docs/backlog/acta-full-plan.md`.
