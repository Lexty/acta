# Plan: The owner-bound stop offer — ask when the application that started it lets the microphone go

## Overview

A recording is stopped by the user, or offered for stopping when the *audio* has been quiet for
minutes. Neither answers the ordinary case: a Slack huddle ends and the recording keeps running.

This plan adds a second, independent reason to offer a stop: **the application whose microphone
activity the recording belongs to has let the input go.** A recording is bound to that application at
the moment the start is admitted, the binding travels with the session, and a qualified release raises
a prompt with a countdown — Cancel keeps recording, Stop now ends it at once, and doing nothing ends it
when the countdown completes.

**Not in this plan.** Per-application memory or modes, automatic *start*, cancel-and-delete, enrolment
UI — the rest of `docs/backlog/per-application-autonomy-modes.md`. Also **not** here: making `.saving`
stop blocking a new start. It was in the first draft of this plan and both reviews said to cut it; see
*Cut from this plan* below.

⚠️ **This increment reverses a rule the reminders were built on.** `AGENTS.md` states that nothing acts
on its own: *a timer may withdraw a prompt, it may never answer one.* A countdown that stops a
recording is a timer answering a prompt. The user decided this explicitly. Task 9 writes it into
`AGENTS.md` as a **narrow exception** in the same change that makes it true.

## This plan has been reviewed twice, and rewritten

Reviewed by the planning plugin's `plan-review` agent and by Codex, independently, before any code was
written. Both found the same five blockers. Everything below is the second version.

**What was wrong in the first draft, recorded because it was believed:**

1. ⚠️ **The stated reason for one task ordering did not exist.** The draft claimed that unblocking
   `.saving` would let `isBusy` go false while `com.apple.replayd` was still holding, minting an offer
   from Acta's own capture. It cannot: `offerIfQualified` **spends every qualified key before** the
   `isBusy` guard is reached, so replayd is `.spent` about three seconds into every recording and mints
   nothing afterwards. Codex compiled an isolated reproduction against the unchanged rule — held while
   busy at t=1 and t=4, still held with busy false at t=100 — and all four outcomes were `.none`. The
   backlog carried the same false claim and was corrected in `b4dfe4a`.
2. **Binding was specified at the wrong instant.** `performStart` awaits `recoveryTask` and then
   `session.start(...)` — roughly two seconds by its own comment — and only then assigns
   `currentDirectory` and `phase = .recording`. Sampling the world there is sampling it after the
   holder may have changed and after Acta's own capture has appeared.
3. **Owner selection was wrong twice.** The first draft's "exactly one foreign holder" counts
   `com.apple.CoreSpeech`, which holds the input persistently here, alongside the Slack helper — every
   recording would have bound to nothing, silently, forever. The second draft's recency heuristic was
   worse: it could bind the *wrong* application and stop a live recording. Both are gone; see
   Decision 2.
4. **"No visible prompt means no stop" was not expressible.** The coordinator cannot observe a screen;
   a non-nil `prompt` property is not proof of presentation.
5. **Task 9 (`.saving`) was a concurrency refactor wearing a prerequisite's clothes.**

Smaller corrections, all verified: `AudioProcessSnapshot` and `AudioProcessObservation` are declared in
`ActaKit/MicrophoneActivityRule.swift`, not in `ActaRuntime/AudioProcessReader.swift`; the existing
stop prompt's lifetime is **30 s** in both switches, so 20 s "matches" nothing — it is the *start*
prompt's number, and the new countdown keeps 20 s as a judgement; `ReminderCoordinator` **already owns**
timing logic (prompt deadlines, the tick, rebaselining), so the plan describes a boundary it intends to
draw rather than one that exists; and the 25 s total is **nominal**, since sampling, scheduling and
presentation add latency.

## Cut from this plan

**`.saving` becoming a property of a recording** — the user's "stop a multi-hour recording and start
the next at once" requirement. Both reviewers, independently, said it does not belong here:

- `canStart` and `hasWorkInFlight` derive from **the same** `Operation` enum, so "a start is allowed
  **and** work is in flight" is not expressible without new state; the draft's two warning bullets were
  mutually unsatisfiable.
- `can_start` and `operation.kind` are **on the wire**, and `AGENTS.md` says adding a case to
  `Operation.Kind` or `RecordingSummary.Status` within v1 is a version bump, not an additive change.
- `RecordingController` holds one `session`, one `currentDirectory`, one `isStopping`. Concurrency
  means several, with an A-completes-while-B-records hazard where A's teardown erases B's state or
  writes B's metadata into A.
- The release offer works perfectly well while saving still blocks the next capture.

It gets its own plan, with its own protocol review:
`docs/plans/YYYY-MM-DD-saving-is-a-property-of-a-recording.md`. ➕ **Task 11 files it back to the
backlog so it is not lost.**

## Context (from discovery)

- `Sources/ActaKit/MicrophoneActivityRule.swift` — the existing prompt-qualifying rule, **and the home
  of `AudioProcessSnapshot` / `AudioProcessObservation`**. Task 3 extracts a shared reduction from it;
  nothing else here modifies it.
- `Sources/ActaKit/RecordingSettings.swift` — the third preference; deliberately absent from
  `WireSettings`.
- `Sources/ActaRuntime/ReminderCoordinator.swift` — the tick, prompts, admission checks, and the
  `ProcessInfo.processInfo.processIdentifier` that is the only pid it supplies today.
- `Sources/ActaRuntime/RecordingController.swift` — `performStart` and its two awaits before
  `.recording`; `Phase` is `idle / recording / saving / error`.
- `Sources/ActaRuntime/ControlState.swift` — `Operation`; `canStart` is `operation == .idle`;
  `hasWorkInFlight` is `operation != .idle`.
- `Sources/Acta/ReminderPanel.swift` — ⚠️ `present()` rebuilds the hosting view, **repositions the
  panel from the pointer**, re-arms the dismissal timer and re-installs the click monitor **on every
  call**. Task 8 depends on this.
- `Sources/ActaTestRunner/` — all tests; `bash Scripts/test.sh`; **854 passing** at `b4dfe4a`.
- ⚠️ **Branch: `dev`.** `AGENTS.md` forbids committing to `main`.

## Measured facts this plan is built on

From `docs/backlog/per-application-autonomy-modes.md`, measured 2026-09-12 on this machine
(macOS 26.6.2 build 25G83, Slack 4.52.155). Re-measure before contradicting one.

- A Slack huddle is held by **`com.tinyspeck.slackmacgap.helper`**, which has a bundle identifier while
  its display name is absent. 29 of 32 process objects carried a bundle id.
- Holding separated the huddle from the idle app: positive in every sample across 90 s, negative in
  every sample across 180 s of a running idle Slack.
- **`com.apple.CoreSpeech` holds the input persistently** — observed holding at two points seven
  minutes apart, and again through a later huddle. This is what breaks naive uniqueness.
- Gaps observed *inside* a call: **266, 273, 279, 539, 551, 824, 834 ms**. ⚠️ They are intervals
  between observed states. Polling bounds neither edge — either can fall between samples — so they are
  **not** lower bounds on physical durations. **Do not tune a threshold to them.**
- The first gap is Slack's **pre-join dialog** ending, not a device event; first holds of 1.90, 1.37,
  6.21, 2.22 s are how long a person looked at a dialog.
- Muting caused **no observed release** in the interval tested.
- The helper was not restarted between two calls; recurrence across a Slack **restart** is unmeasured.
- Acta's own capture is reported as **`com.apple.replayd`**, matching its log to the millisecond.

## Decisions taken before the plan was written

1. **A separate ownership state machine**, because the existing phases encode prompt consumption,
   baseline and re-arm history — not continuous evidence authorising a timer. ⚠️ **Never infer release
   from `!isEpisodeActionable`.** But *logical* separation is what matters: Task 3 extracts the shared
   **observation reduction** so the two rules cannot drift on how a snapshot is read.
2. **Only a prompt-started recording is bound.** The prompt carries a *known* triggering identity;
   every other route would have to infer one, and inference here is not cheap to get wrong.
   ⚠️ **This reverses an earlier product decision, on a counterexample.** The user first chose that
   manual starts should bind too, and the plan's second draft inferred an owner from "the holder that
   most recently acquired the input". Codex killed it: Slack has held the input for four minutes and
   the meeting is live; a microphone test or dictation service acquires briefly just before the user
   presses Record; that service is the only recent acquirer, so the rule binds **it**; it releases, and
   Acta runs a countdown and **stops the still-running Slack recording**. A false binding is worse
   than a missing one. A second failure needs no third party: two holders both acquire, the rule
   correctly answers "ambiguous" — then the older acquisition **ages out** while that application is
   still holding, and the identical situation becomes "unambiguous" because a timestamp expired.
   A manual or socket start therefore stays **unbound**: the recording works, and no stop is offered
   for it. The user accepted this after seeing the counterexample.
   ⚠️ **The start-prompt exclusion list is not reused.** The second draft decided an excluded holder
   would not count toward uniqueness. Codex disagreed with the decision rather than its wording, and
   the trace is convincing: "do not offer to record Slack" can mean "I record Slack myself", which is
   not consent to disregard Slack while assigning *another* application authority to stop a recording.
   New copy and a new test do not retroactively change what an already-saved preference meant. The
   list stays scoped to start offers. With only prompt-bound starts, the CoreSpeech uniqueness problem
   does not arise at all.
3. **Release qualification N = 5 s; countdown 20 s.** Nominal total **25 s**, not exact.
4. **Default outcome is stop.** Cancel (shipped as **Keep Recording**, Task 9) keeps recording; Stop now ends it; the owner returning cancels
   with no user action. *(User's decision; not open.)*
5. ⚠️ **No acknowledged presentation, no stop** — expressed as a **presenter contract** (Task 8), not
   as `prompt != nil`.
6. **A third preference**, independent of both existing ones, preserved for **both** confinements.
   *(User's decision; not open.)*

## Development Approach

- **Testing approach: regular** (code, then tests in the same task). The repo's standard is stronger
  than "tests exist": every rule gets a **negative control** — delete the rule, watch the *named* test
  fail. On 2026-09-12 this caught three tests that passed with their rule deleted.
- ⚠️ **A green suite is not the contract.** Both reviewers warned that this plan's risk is a green
  implementation being mistaken for the contracts having been implemented. The contracts are the
  binding instant, the presenter acknowledgement and the revocation cases.
- Work lands on `dev`. English-only in the repository.
- Update this plan when scope changes: `➕` new tasks, `⚠️` blockers.

## Testing Strategy

- Unit tests in `Sources/ActaTestRunner/`, `bash Scripts/test.sh`. Required in every task.
- **The realistic multi-holder fixture is the most valuable test in this plan** — Slack + CoreSpeech,
  plus a shared capture service. A one-holder fake would let the acceptance case pass while the
  measured machine fails.
- **The replay fixture** (Task 5) drives the rule from the recorded traces at several 1 Hz phase
  offsets. ⚠️ Label the assumption: this resamples *a reconstruction of what was observed*, not proof
  of what another physical observer would have seen.
- ⚠️ "No e2e framework" does **not** mean runtime integration is untestable — the repo has crash and
  recovery harness infrastructure. Only *rendered* visibility is human acceptance.
- Negative controls per rule, named in the task.

## Solution Overview

```
                    one HAL snapshot per tick
                              │
                 ┌────────────┴────────────┐
                 │   shared reduction      │  ← Task 3, extracted, one copy
                 │  (keys, held-wins,      │
                 │   complete vs partial)  │
                 └────────────┬────────────┘
              ┌───────────────┴───────────────┐
              ▼                               ▼
   MicrophoneActivityRule           MicrophoneOwnershipRule   ← new, pure
   (qualify a start prompt)         (did THIS recording's owner let go?)
                                              │
                                              ▼
                              ReminderCoordinator ──► Presenter contract
                                                       (acknowledged, revocable)
```

## Technical Details

**Ownership rule** (`Sources/ActaKit/MicrophoneOwnershipRule.swift`), pure and clock-injected:

```
enum OwnerKey: Hashable, Sendable { case bundle(String), process(Int32) }

enum OwnerPhase: Equatable, Sendable {
    case held(since: Date)
    case releaseCandidate(since: Date)
    case releasedQualified
    case unknown(since: Date)
}

enum Outcome: Equatable, Sendable { case none, releaseQualified, ownerReturned, evidenceLost }
```

⚠️ **`OwnerKey.process` and pid reuse.** A pid can be reused *within one recording*. "Not persisted
across launches" does not solve that. **This increment leaves pid-only holders unbound** — a bare pid
cannot promise the identity a bundle key can, and inventing an incarnation fence from evidence we have
not measured is out of scope. Stated in the code and in the settings copy (the copy added in review).

**Qualification.** `releasedQualified` requires a *sequence* of released observations spanning `N` with
no gap between consecutive observations larger than `maxSampleGap` (2.5 s). One false sample is not a
release. `unknown` **revokes** what was accumulated. A positive same-owner observation returns to
`held` and requires a **full new interval**.

**Binding travels with the session.** ⚠️ The two reviews disagreed here and this is the synthesis,
which Codex then accepted as "the right boundary": the **coordinator resolves the binding** — it holds
the observation state, so audio-process knowledge stays out of the recorder — and it is passed **into
the start call**, where the **controller carries it as opaque session metadata** and projects it back
out. `ControlState` stays a pure projection. Discarded if that attempt fails.

⚠️ **Admission time is a software boundary, not proof of the physical holder at that instant.** Even a
fresh 1 Hz sample carries observation latency, which is why the binding records its `observedAt` and
observation epoch and why the prompt's identity is **re-checked** after the barrier rather than trusted
from when the click arrived.

## Implementation Steps

### Task 1: A heartbeat in the reminder tick

⚠️ Independent of everything else, and first, because without it the next silence is as undiagnosable
as the last one. It does **not** fix the silent-instance defect — it makes it observable.

**Files:** Modify `Sources/ActaRuntime/ReminderCoordinator.swift`,
`Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [x] add an observable tick counter and monotonic start instant on the coordinator — ⚠️ **observable,
      because the `Logger` is a private `let` and there is no log-capture seam in the test runner**
- [x] emit the heartbeat every `heartbeatTicks`, carrying tick count, uptime, and whether a snapshot was
      taken at all
- [x] ⚠️ when **both** preferences are off, report "not observed" — do **not** introduce a HAL read for
      diagnostics that the design deliberately avoids
- [x] choose the log level deliberately: `.info`/`.debug` are not persisted by `os_log`, and the defect
      appears after *hours*, so the buffer may have wrapped — record the choice and why
      → **`.notice`**, reasoned in `emitHeartbeatIfDue`. The existing holder diagnostic stays `.info`:
      it is read while reproducing, not hours later.
- [x] write a test that the heartbeat fires on the expected tick and not between
- [x] write a test that a run of identical snapshots still produces heartbeats
- [x] **negative control**: make the heartbeat fire only on change → the identical-snapshots test fails
- [x] run `bash Scripts/test.sh`


**Done.** 857 tests pass (854 before). The beat is a property (`tickCount`, `heartbeatCount`,
`lastHeartbeat`) *and* a `.notice` line, because `log` is a private `let` with no capture seam.
⚠️ The negative control failed **two** tests, not one: `anUnchangingPictureStillBeats` as the plan
required, and `theHeartbeatFiresOnSchedule` as well — both assert the schedule, so a change-gate breaks
both. The named one bites; the control is not uniquely scoped to it.

**Codex reviewed it read-only and found two real things, both now fixed:**

1. ⚠️ **A false claim inside the diagnostic itself.** My comment said a tick count far below the elapsed
   seconds is a starved loop. `ContinuousClock` keeps counting while the Mac is asleep — which is the
   very reason `lastTick` rebaselines on a gap, seventy lines above — so an overnight sleep produces
   the same ratio with nothing wrong. The comment now calls it an observation gap to be explained. The
   same correction applies to *no beats*: sleep, a quit, a tick wedged in a synchronous read and the
   store's retention limit all produce it as readily as a dead poll task.
2. ⚠️ **The both-off test proved nothing about the HAL.** It asserted the *payload* said `notObserved`;
   `ScriptedReader` had no counter, so an illicit `readSnapshot()` would have left it green. The reader
   now counts, and the test asserts zero reads.

⚠️ **And my reason for declining his second suggestion was wrong, in a way that condemned my own test.**
I refused to pin start-off/quiet-on because Task 6 changes it — then kept a test that left
`offersStopWhenOwnerReleases` at its new default `true`, which Task 6 changes in exactly the same way.
The quiet reminder never governed the read: it measures audio, not processes. The durable matrix is
**start=false and release=false → zero reads for either quiet value; release=true → one read even from
idle**. The test now sets all three explicitly and is named for that.

Also on his review: `defer` now closes over `let settings` read *before* it is registered, so an early
return inserted later cannot make the beat report both reminders off — a fabricated fact in the one line
whose job is to be believed hours later. And one test now drives a non-empty, **incomplete** snapshot
with `isRunningInput` true, false and `nil`, because every other beat carried an empty complete one and
a hard-coded payload would have passed them all.

⚠️ **What the beat does not answer**, stated because the backlog item invites the opposite reading:
CoreSpeech alone and Slack alone both show `holding=1`. This settles *whether ticks completed and
sampling was on*; it does not settle why a particular huddle raised no offer.

### Task 2: The third preference, before anything consumes it

⚠️ Moved ahead of its consumers: both reviewers found Tasks that referenced a preference introduced
later.

**Files:** Modify `Sources/ActaKit/RecordingSettings.swift`,
`Sources/ActaRuntime/ControlDispatcher.swift`, `Sources/Acta/SettingsWindow.swift`,
`Sources/ActaTestRunner/RecordingSettingsTests.swift`,
`Sources/ActaTestRunner/SourceConfinementTests.swift`,
`Sources/ActaRuntime/ControlViewModel.swift`,
`Sources/ActaTestRunner/ControlDispatcherConfinementTests.swift`
⚠️ **The plan named the wrong test file.** The reminder settings tests live in
`RecordingSettingsTests.swift`; `MicrophoneSettingsTests.swift` is about devices. Two files the plan
did not list were needed: the binding (`ControlViewModel`) and the confinement tests that actually
assert the substitution.

- [x] add `offersStopWhenOwnerReleases: Bool` (default on) with the `decodeIfPresent`-and-default
      pattern its siblings use
- [x] preserve it in `appliedSettings` for **both** confinements — ⚠️ the wire never supplied it in
      either case, so a trusted-dispatcher regression is as real as a socket one
- [x] add the toggle to the Reminders tab; copy states what it does, that it only *asks*, and that it is
      independent of the quiet rule
- [x] add its label to `persistentControls` in `SourceConfinementTests`
- [x] write tests: the two stop preferences are independent in both directions
- [x] write tests: neither a socket **nor** a trusted `settings_set` can change it
- [x] **negative control**: drop it from `appliedSettings` → the trusted-dispatcher test fails
- [x] run `bash Scripts/test.sh`


**Done.** 860 tests pass (857 after Task 1). The toggle reads *"Offer to stop when the app that started
the recording releases the microphone"*, and its caption says three things the decisions require: it
covers only recordings Acta offered to start, it is the one place Acta acts without a click, and it is
separate from the quiet reminder.

⚠️ **The heartbeat's payload gained the third preference in this task**, not in Task 1. A beat that
reported `start=` and `quiet=` while a third reminder existed would be a diagnostic that lies by
omission — the exact failure mode Task 1 exists to prevent.

**Negative control:** deleting the `appliedSettings` line failed
`aTrustedSettingsSetCannotChangeTheReminderPreferencesEither` as the plan required, and the socket one
alongside it. Both fail for the same reason: `RecordingSettings(wire)` fabricates `true`, and without
the substitution an unrelated `settings_set` switches a user's preference back on.

### Task 3: One shared reduction of process observations

⚠️ **This is where drift would actually live.** Both reviewers flagged it: a second copy of key
derivation, own-process dropping, "held wins over released" and "a partial list cannot say anything
stopped" is what will diverge. Extract it once; neither rule reimplements it.

**Files:** Create `Sources/ActaKit/AudioProcessReadings.swift`, Modify
`Sources/ActaKit/MicrophoneActivityRule.swift`, Create
`Sources/ActaTestRunner/AudioProcessReadingsTests.swift`

- [x] extract the fold into a pure helper: one `ProcessKey`, own-pid/own-bundle dropping, held-wins,
      and the partial-enumeration rule that turns `released` into `unreadable`
- [x] have `MicrophoneActivityRule` consume it with **no behaviour change**
- [x] write tests: held wins over an unreadable sibling of the same key; a partial list with a visible
      idle sibling yields unreadable, never released; confirmed absence in a *complete* list is release
- [x] **negative control**: delete the partial-list rule → the visible-idle-sibling test fails
- [x] run `bash Scripts/test.sh` — ⚠️ all 854 must still pass: this task changes no behaviour


**Done.** 871 tests pass (860 before; 11 new). `MicrophoneActivityRule` changed no behaviour — its
`Key` and `Reading` are now `typealias`es onto the shared `AudioProcessKey` and `MicrophoneInputReading`,
and its `readings(from:context:)` is three lines translating a `Context` into the set of processes the
fold must pretend it never saw.

⚠️ **The plan's name for the reading type was already taken.** `AudioProcessReading` is the *reader
protocol* in `ActaRuntime` — the thing `ScriptedReader` conforms to. The fold's per-key verdict is
`MicrophoneInputReading`; the file keeps the plan's name, `AudioProcessReadings.swift`.

**Codex reviewed it read-only**, compared the removed loop, the precedence helper and the
incomplete-list pass against the new implementation line by line, and found no functional regression —
which is the evidence for "no behaviour change"; a green suite alone would not be. He also declined my
worry about the old rule losing its own guard: one invariant, in the shared fold, with consumer
regressions rather than a duplicate. Four precision corrections applied:

1. ⚠️ **My own-process test did not demonstrate what its comment claimed.** The rationale said an idle
   own process could contradict a foreign sibling — impossible under held > unreadable > released — and
   the fixture excluded the *whole bundle*, so both processes were Acta's and there was no foreign
   sibling at all. The case that actually needs filtering **before** aggregation is the opposite one:
   Acta's own process holding, a foreign process of the same bundle idle, only the pid excluded.
   Two new fixtures; deleting the pid drop makes them read `held` and `unreadable` instead of
   `released`, which is precisely the folding-first outcome.
2. ⚠️ **"Confirmed absence in a complete list is a release" supplied a *present idle* process.** An
   absent key gets no reading at all, and an empty complete list and an empty incomplete one reduce to
   the same empty dictionary — so a consumer writing `readings[owner] ?? .released` would read a failed
   enumeration as a call ending. Renamed, and both empties are now asserted. **Completeness must be
   carried by every consumer**; the ownership rule inherits that obligation in Task 5.
3. The two-order rationale blamed dictionary ordering. The fold iterates `snapshot.processes`, an
   array, so a fixed fixture is deterministic; what is not promised is the HAL's enumeration order.
4. `stronger` is now private: `reduce` is its only consumer.

**Negative control:** deleting the incomplete-enumeration rule failed **three** tests, not one — the
named `a partial list with a visible idle sibling is unreadable, never released`, its sibling
`a partial list may still say that something is holding`, and the *pre-existing*
`a partial list whose visible sibling is idle does not release the application` in
`MicrophoneActivityRuleTests`. The third is the useful one: it proves the extraction really does feed
the old rule rather than sitting beside it.

### Task 4: Owner selection from the triggering prompt

⚠️ **Small on purpose.** The second draft had a recency heuristic here; it is gone, with its window
constant and its exclusion policy. What remains is the case where the identity is *known*.

**Files:** Create `Sources/ActaKit/OwnerBinding.swift`, Create
`Sources/ActaTestRunner/OwnerBindingTests.swift`

- [x] define `OwnerBinding` — an immutable value carrying the owner key, the observation epoch and the
      `observedAt` of the evidence it came from
- [x] build it from a triggering episode's key; there is no other constructor in this increment
- [x] ⚠️ pid-only holders yield no binding (pid reuse within one recording; see Technical Details)
- [x] coalesce several processes of one key into one holder
- [x] write tests: a prompt episode yields a binding carrying its epoch and `observedAt`
- [x] write tests: **prompt(A) keeps A even when B acquired more recently** — the guard against the
      heuristic ever coming back
- [x] write tests: a pid-only episode yields no binding
- [x] **negative control**: let the constructor take any current holder → the prompt(A)-with-B test
      fails
- [x] run `bash Scripts/test.sh`


**Done.** 877 tests pass (871 before; 6 new). `OwnerBinding.bind(episode:holding:epoch:observedAt:)` is
the only entry point; the memberwise initialiser is private.

⚠️ **One thing the plan did not specify, decided here: the readings are a parameter.** They are never
used to *choose* the key — that is the whole rule — but a binding is refused when the evidence does not
show that application holding. Handing stop authority to an application we cannot see would be a guess,
and this is also the shape Task 7 re-checks after the barrier. `unreadable` is not `held`, so an
incomplete enumeration mints no binding.

⚠️ **The negative control had to be constructible.** The rule here is an *absence* — there is no
inference to delete — so the control adds one: pick the holder the world offers instead of the prompt's.
Codex accepted constructed controls as legitimate mutation tests and declined my offer of a source-level
guard.

**Codex reviewed it and corrected two things, both verified:**

1. ⚠️ **"An incomplete enumeration mints no binding" was false, and the code never did it.** A
   positively held owner in a partial list reduces to `.held` and binds — held wins. What refuses a
   binding is the absence of positive evidence *for that key*. Prose corrected everywhere, and two
   fixtures added: a partial list showing the owner holding **binds**, and an unreadable property
   (`nil`) in a **complete** list does not. The old "unreadable" fixture only covered a `false` that
   incompleteness had turned unreadable — a different case.
2. ⚠️ **My fixture's ordering claim was wrong.** I said both orderings a world-picking rule could use
   land on the second application; but the snapshot's array order is erased by the fold, so only the
   identifier order survives, and a selector sorting the other way would have passed. His replacement is
   stronger and is what is now in the file: bind the **same two-holder readings twice**, once with each
   episode, and expect the matching owner each time. No deterministic episode-ignoring selector can
   answer both. Run in both sort directions, the control fails two tests each time.

⚠️ **Carried into Task 7 on his point 3:** a `nil` binding must never become a refused *start*. An
unbindable episode — pid-only, or an owner not positively held at that instant — still starts a
recording; it starts **unbound**, and only the owner-release stop is unavailable. `guard let binding
else { return }` would recreate the dead-button defect `checkingStart` exists to prevent. Record why the
binding was withheld; do **not** attach an owner later when the input returns, which would move the
frozen admission boundary.

### Task 5: `MicrophoneOwnershipRule` and the replay fixture

**Files:** Create `Sources/ActaKit/MicrophoneOwnershipRule.swift`, Create
`Sources/ActaTestRunner/MicrophoneOwnershipRuleTests.swift`, Create
`Sources/ActaTestRunner/MicrophoneOwnershipFixtures.swift`

- [x] implement the four phases and `observe`, consuming Task 3's reduction
- [x] implement `ownerReturned`: a positive same-owner observation cancels and requires a full new
      interval
- [x] encode the recorded traces as event lists and a replayer that samples at a period **and phase
      offset** — ⚠️ with the assumption labelled in the file
- [x] write tests: a single false sample does not qualify; `unknown` revokes; a return at 4.9 s requires
      a full new 5 s; other applications never affect the owner
- [x] write ownership fixtures Codex asked for: partial enumeration with a visible idle sibling;
      same-key positive sibling; **disappearance**; unresolved identity; an observation gap **during a
      visible countdown**
- [x] replay every trace at several offsets: no flap qualifies, the genuine release does
- [x] **negative control**: delete `maxSampleGap` → the skipped-poll test fails, and nothing else
- [x] run `bash Scripts/test.sh`


**Done.** 895 tests pass (877 before; 18 new). The rule consumes `AudioProcessReadings.Evidence`, not a
snapshot, so completeness and own-process dropping stay in the shared fold and the coordinator can fold
once per tick for both rules (Task 6). It starts `held` at the binding's `observedAt`, because a binding
is only minted from positive evidence for that key.

Decided here, because the plan did not specify it: `ownerReturned` is emitted when a held observation
follows a release candidate or a qualified release, and **not** when leaving `unknown`, since nothing is
left to cancel there. `evidenceLost` is emitted only when a *qualified* release is revoked; an unqualified
candidate is revoked silently, because nothing could have been shown for it. A timestamp that runs
backwards counts as a gap.

⚠️ **An unresolved identity needed no pid tracking in the rule.** `AudioProcessProjection` already turns
a bundle-identifier read that fails for a pid it never identified into an incomplete snapshot with no
input evidence, which the fold reads as `unreadable`. The fixture encodes exactly that. The dependency is
written in the rule's doc: a reader that reported such a process under a pid key in a *complete* list
would make the owner look absent, which is a release.

**The traces** are the 13:22 two-huddle run and the 15:22 probe-against-Acta huddle, transcribed with
timestamps, plus the seven reported gaps placed after the four reported pre-join holds. That placement is
invented and labelled so in the file. Each trace is replayed at 1 Hz and at 250 ms, 16 phase offsets each
(sixteenths of a period, so every timestamp is exact in binary). The machine in every replay is the
Slack helper plus CoreSpeech holding. The oracle works from the trace, in both directions: no
qualification without the full interval of truth-released behind it; every release that lasted
interval + period qualifies exactly once, within a period of the earliest instant it could; a return is
reported at the first sample that sees it. A precondition check rejects any release whose qualification
would depend on phase.

**Negative controls, run:**
- Deleting `maxSampleGap` (keeping only the backwards-clock half) failed **two** tests, not one: the named
  `a skipped poll is not a continuous release`, and `an observation gap during a visible countdown`.
  That second fixture is the same rule by construction, so "and nothing else" cannot hold for it.
  ⚠️ A first version of the backwards-clock test used a 5 s forward step and failed this control as well.
  It was rewritten to use only 1 s steps, and it now fails only under its own control, which deletes the
  `interval < 0` half.
- Letting an unknown observation keep an accumulating candidate failed the unknown-revokes test, the
  partial-list fixture and the unresolved-identity fixture.
- Letting a return keep a release candidate failed the replay at every offset (245 issues), plus the
  single-false-sample test and the 4.9 s return test.
- ⚠️ **The replay does not pin the 5 s.** With the interval set to 1 s it stayed green, because its oracle
  reads the configured interval and every recorded flap is under a second. Thirteen unit tests pinned the
  number instead. `the recorded traces would have stopped the call under a naive rule` proves that the
  fixture can fail at all.

⚠️ **Not checked:** `bash Scripts/lint.sh` could not run, because `swiftlint` is not installed on this
machine. Line lengths were checked by hand against the 140-column warning.

### Task 6: One snapshot per tick, feeding both rules

⚠️ The release rule must observe **from idle**, not only once a bound recording exists — otherwise the
binding depends on the *start* preference, which is the shared-authority mistake Decision 6 forbids,
and Codex notes it would also be circular.

**Files:** Modify `Sources/ActaRuntime/ReminderCoordinator.swift`,
`Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [x] read the snapshot once per tick, above both preference checks; feed each rule per its own
      preference
- [x] when neither feature is enabled, read nothing
- [x] write a test: with the start reminder off and release-stop on, observation happens from idle
- [x] write a test: with both off, `readSnapshot` is never called (counted on the scripted reader)
      — ⚠️ **"both" means the start and release reminders**, the two that consume process observations;
      the quiet one measures audio and never gated this read. The matrix to land here:
      start=false/release=false → zero reads for **either** quiet value; start=false/release=true → one
      read from idle. `ScriptedReader` already counts (Task 1), and
      `noReminderEnabledBeatsNotObserved` already pins the zero-read half.
- [x] **negative control**: move the read back inside the start branch → the first test fails
- [x] run `bash Scripts/test.sh`


**Done.** 899 tests pass (895 before; 4 new). The read sits above both preference checks and is gated
on `start || release`; the start rule is fed under its own switch, and the release side folds the same
snapshot through `AudioProcessReadings.evidence` into `ReminderCoordinator.releaseEvidence` — the
evidence, the coordinator's `observedAt`, and the observation epoch.

⚠️ **Decided here: this task feeds no `MicrophoneOwnershipRule`, because none can exist yet.** A rule
needs an `OwnerBinding`, and bindings are admitted in Task 7. What lands is the per-tick evidence that
rule and Task 7's re-check will consume. It is `nil` whenever the release preference is off, so a later
consumer can never read a picture nobody was allowed to keep gathering.

⚠️ **Carried into Task 7:** the epoch in `releaseEvidence` is the start rule's, and it advances on
*every* tick while the start reminder is off, because `applyPreferenceChanges` replaces the activity rule
each time. It is harmless now only because no prompt, and so no binding, exists then.

The release fold drops Acta's own bundles and pid and **nothing else** — the start reminder's exclusion
list is not applied, per Decision 2, and a test pins it with the Slack helper excluded.

**Negative controls, run:**
- Moving the read back inside the start branch (the plan's control) failed the named
  `with the start reminder off and the release one on, the process list is observed from idle`, and the
  matrix test alongside it, which contains the same configuration.
- A second `readSnapshot()` for the release fold failed the matrix, the from-idle test, the
  switch-off test and the pre-existing `the beat reports what was actually in the snapshot`.
- Keeping stale evidence when the release preference is off failed the matrix and the switch-off test.
- Applying the exclusion list to the release fold failed only the exclusion test.
- ⚠️ **Feeding the start rule regardless of its preference stayed green.** While that preference is off
  the rule is replaced every tick and its context is disabled, so "the start rule was not fed" is not
  observable. The from-idle test's `prompt == nil` assertion pins the outcome only, and now says so.

⚠️ **Not checked:** `bash Scripts/lint.sh` — `swiftlint` is not installed. The three lines over 140
columns in the coordinator are pre-existing log lines; one moved into `observeActivity` and got shorter.

### Task 7: One admission seam, and the binding frozen across the start

⚠️ **Naming the seam is the task.** Today `ControlViewModel.start` calls `api.start`, `ControlDispatcher`
calls `service.start` after its microphone barrier, and `ReminderCoordinator.acceptStart` calls
`service.start` after its own — **neither the menu nor the dispatcher passes through the coordinator**.
Adding `owner: OwnerBinding? = nil` would compile and silently leave two routes out, which is exactly
the kind of green implementation both reviews warned about.

**Files:** Modify `Sources/ActaRuntime/RecordingController.swift`,
`Sources/ActaRuntime/ControlAPI.swift`, `Sources/ActaRuntime/ControlState.swift`,
`Sources/ActaRuntime/ReminderCoordinator.swift`,
`Sources/ActaTestRunner/RecordingControllerGuardTests.swift`

- [x] put an **injected, synchronous binding resolver** at the common runtime start boundary, or route
      all three paths through one admission service. ⚠️ The controller must never call the HAL; the
      coordinator supplies the resolver's observation state
- [x] ⚠️ **resolve after the last pre-admission `await`**, and attach in the **same actor turn** that
      successfully latches `isStarting`
- [x] ⚠️ **a `nil` binding starts the recording unbound — it never refuses the start.** Codex, on
      Task 4: `guard let binding else { return }` recreates the dead-button defect and would also break
      pid-only prompt starts. Record *why* the binding was withheld, for diagnosis; do not attach an
      owner later when the input returns, which would move the frozen admission boundary
- [x] for a prompt: preserve the original episode identity across the barrier, but **re-check** its
      observation epoch, key and current evidence afterwards — never replace it with a newer candidate
- [x] freeze the accepted binding across the `recoveryTask` and `session.start` suspensions; an owner
      change during them does not rebind. Release evidence later decides whether to offer a stop
- [x] ⚠️ a failed start discards **only that attempt's** binding, and a rejected second start must not
      overwrite a first start's pending one. Do **not** copy `ControlAPI.title`'s setter, which mutates
      before the controller's busy guard
- [x] keep raw owner selection **off** the socket payload
- [x] the controller stores the binding as opaque session metadata and projects it into
      `ControllerSnapshot` / `ControlState`
- [x] write a test: **a parked microphone barrier during which the candidate changes** — the admitted
      binding is the re-checked one, not a newer holder
- [x] write a test: **a parked `session.start`** preserves the admitted binding
- [x] write a test: a rejected second start cannot alter a first start's pending binding
- [x] write a test: manual and socket starts share the admission mechanics and **deliberately produce
      no binding** — ⚠️ the draft's "all three routes bind identically" contradicted Decision 2
- [x] **negative control**: resolve before the barrier instead of after → the parked-barrier test fails
- [x] run `bash Scripts/test.sh`


**Done.** 907 tests pass (899 before; 8 new). The seam is `RecordingController.start(resolvingOwner:)`: a
**non-escaping, synchronous** resolver the controller calls only after its busy guard, in the turn that
latches `isStarting`. `start()` is that same call with `{ .unbound(.notStartedFromPrompt) }`, so the menu
(`ControlViewModel` → `ControlAPI.start(title:)`) and the socket (`ControlDispatcher` → `ControlServing.start`)
converge on it. The prompt route is `ControlAPI.start(title:resolvingOwner:)`, which is **not** on
`ControlServing` — the transport has no way to name an owner. The coordinator's resolver reads
`releaseEvidence` (no HAL read), keeps the key from the prompt's episode, and re-checks epoch, reading and
time against the evidence held after the barrier.

⚠️ **Decided here: `OwnerAdmission` in ActaKit, not `OwnerBinding?`.** `.bound(binding)` or
`.unbound(reason)`, with the reasons `notStartedFromPrompt`, `noBundleIdentifier`, `ownerNotHeld`,
`releaseNotObserved` and `evidenceFromAnotherEpoch`. That is "record why it was withheld"; the coordinator
also logs it at `.notice`. The controller stores it next to `currentDirectory` and projects it through
`ControllerSnapshot` into `ControlState.ownerAdmission`; `WireProjection` does not read it.

⚠️ **Carried into Tasks 8 and 9:**
- The admission is cleared together with `currentDirectory`, when the stop's assembly *returns* — so
  `.saving` still carries it (corrected in review: an earlier note said a stop's beginning cleared it). A
  countdown must hold its recording identity itself, not re-read the owner mid-stop.
- With the release preference off at admission, the recording is `.unbound(.releaseNotObserved)`, and
  switching the preference on later does **not** bind it.
- ⚠️ **Corrected in review (Codex): "re-checks time" was not true of the code.** `releaseEvidence` is only
  as current as the last tick — the tick clears it when the preference goes off and moves the epoch after a
  gap — so an acceptance resuming before that tick bound from a picture the tick was about to discard. The
  resolver now reads the preference itself (off → `.releaseNotObserved`) and refuses evidence older than
  `rebaselineThreshold` with a sixth reason, `.evidenceStale`. Tests: `staleEvidenceAtAdmissionStartsUnbound`
  and `releasePreferenceIsRecheckedAtAdmission`; both failed against the unfixed resolver (admitted bound).
- `ControlAPI.start(title:resolvingOwner:)` writes the title before the controller's guard, as
  `start(title:)` always has. The owner does not follow it: it is resolved after the guard.

**Tests:** in `RecordingControllerGuardTests` — a parked `session.start` (parked by blocking the startup
probe's sleep on a pool thread, `StartupProbePark`) while the resolver's world changes; a rejected second
start, bound and unbound, while the first is parked; a failed start; menu and `.socket` dispatcher starts
over a real `ControlAPI`. In `ReminderCoordinatorTests` — a parked barrier during which a second holder
acquires and time moves (the admitted binding is Slack with the post-barrier `observedAt` and epoch); an owner
unreadable after the barrier (episode still actionable, the recording **starts** `.unbound(.ownerNotHeld)`);
the release preference off. One pure test in `OwnerBindingTests` for the reasons.

**Negative controls, run:**
- Resolving before the barrier (the plan's control) failed **two** tests: the named parked-barrier test
  (`observedAt` from the click, not the re-check) and the unreadable-owner test (bound instead of unbound).
- Resolving a second time and adopting it at `.recording` failed only the parked-`session.start` test, and
  ⚠️ **only on the resolution count**: the second call ran in the same turn and returned the same owner.
  A re-resolution *after* `session.start` is not constructible — the resolver is non-escaping — so the type,
  not the test, holds that half.
- Resolving before the busy guard failed only the rejected-second-start test.
- Keeping the binding on a failed start failed only the failed-start test.
- Treating an unbound admission as a refused start failed the unreadable-owner and release-off tests.
- Not clearing the admission on stop failed the parked-`session.start` and menu/socket tests.

⚠️ **Not checked:** `bash Scripts/lint.sh` — `swiftlint` is not installed. No added line exceeds 140 columns.

### Task 8: The presenter contract

⚠️ **`prompt != nil` is not proof of presentation.** And `ReminderPanel.present()` today rebuilds the
view, **repositions the panel from the pointer**, re-arms the dismissal timer and re-installs the click
monitor on every call — so publishing `secondsRemaining` each second through that path would walk the
panel across the screen and reset its timer forever.

**Files:** Modify `Sources/Acta/ReminderPanel.swift`, `Sources/ActaRuntime/ReminderCoordinator.swift`,
Create `Sources/ActaTestRunner/ReminderPresenterTests.swift`

- [x] introduce a presenter protocol the coordinator talks to, with **acknowledgement**: the countdown
      starts from acknowledged presentation, bound to a stable presentation identity
- [x] separate **initial presentation** from **updating an existing countdown** in the panel: an update
      must not reposition, re-arm the dismissal timer or reinstall the monitor
- [x] the authoritative deadline lives in the coordinator and is never re-derived from a rendering
      update
- [x] revoke on: dismissal, replacement by another prompt, the preference being turned off, quit, and
      loss of presentation eligibility
- [x] ⚠️ **sleep/lock/wake**: no catch-up stop after a wake in which the user never had the promised
      cancellation interval — withdraw, and require fresh release evidence and a newly presented full
      countdown
- [x] write tests through an **injected presenter**, including a **parked acknowledgement**
- [x] write a test: a stalled or unavailable presenter never authorises a stop
- [x] **negative control**: start the countdown on publication instead of acknowledgement → the parked
      test fails
- [x] run `bash Scripts/test.sh`

**Done.** 924 tests pass (907 before; 17 new, in `ReminderPresenterTests`). The contract has three parts:

- `AcknowledgedCountdown` (ActaKit, pure, clock-injected): `awaitingAcknowledgement → running(deadline) →
  completed | revoked(reason)`. Only `acknowledge(presentation:at:)` with the matching id starts it; a
  second acknowledgement is refused, so nothing can move the deadline. An evaluation gap over 2.5 s — or a
  backwards clock — revokes, checked **before** the deadline, so a wake past the deadline never completes.
- `ReminderPresenting` (ActaRuntime): `show` / `updateCountdown` / `withdraw`, each carrying a
  `ReminderPresentation` with a stable `id` (the coordinator's `presentation` counter). The presenter calls
  back `acknowledgePresentation(_:)` and `presentationLost(_:)`. The coordinator holds it weakly; `nil`
  shows nothing and so authorises nothing.
- `ReminderCoordinator` owns the countdown. `presentCountdown(_:configuration:)` is **internal** and has no
  production caller — Task 9 adds one. The tick evaluates it **last**, so evidence gathered in the same tick
  reaches it first; `.remaining` is sent through `updateCountdown` only when the whole second changes.

⚠️ **Decided here: what a completed countdown does before Task 9.** It records `authorisedCountdown` (the
presentation id) and takes its prompt down. Nothing acts on it. Task 9 replaces that with the stop.

⚠️ **Decided here: the panel is the presenter, not a `$prompt` subscriber.** `ActaApp` sets
`coordinator.presenter = panel`; the Combine sink (and `import Combine` there) is gone. The panel acknowledges
when `isVisible && occlusionState.contains(.visible)` — right after `orderFrontRegardless`, or on the next
`didChangeOcclusionStateNotification`. It reports lost on occlusion becoming not-visible, `willSleep`,
`screensDidSleep`, `sessionDidResignActive` and `com.apple.screenIsLocked`, and — added in the second review
pass — holds each of those as a suppression until its own counterpart (`didWake`, `screensDidWake`,
`sessionDidBecomeActive`, `com.apple.screenIsUnlocked`), acknowledging nothing meanwhile: the release stays
qualified behind a lock, so a fresh offer is raised onto the still-locked screen, and whether occlusion
calls that panel visible is unmeasured. The lock pair is registered with `.deliverImmediately`: the default
suspension behaviour coalesces while the app is inactive and flushes the two names in no fixed order, which
could hold the lock suppression for good (third review pass). The coordinator ignores a loss
for a presentation that carries no countdown, so existing prompts behave as before.

Revocation points: `dismiss()` (`.dismissed`), `present` of anything (`.replaced` — and the new prompt's
countdown **overwrites** the old one, so nothing is inherited), release preference off (`.preferenceOff`),
`beginClosing` (`.closing`), `presentationLost` (`.presentationLost`), the rebaseline and the countdown's own
gap (`.observationLapsed`). A `didSet` on `prompt` revokes with `.withdrawn` on any other route to `nil` and
tells the presenter to withdraw.

⚠️ **Carried into Task 9:**
- The countdown prompt needs its own `lifetime(of:)` in **both** switches; the panel's dismissal timer
  otherwise dismisses it at whatever that case returns, which revokes it (`.dismissed`).
- **No acknowledgement timeout.** A late acknowledgement still starts a *full* countdown, which keeps the
  user's interval intact. It does not keep the release evidence fresh: Task 9 must revoke on
  `ownerReturned` / `evidenceLost` whether the countdown is awaiting or running.
- "Fresh release evidence" after a wake is not enforced here. The ownership rule's own gap revocation
  provides it, and Task 9 must feed that rule, not a cached qualification.
- A main thread stalled for more than 2.5 s between ticks revokes the countdown. That is the conservative
  direction, and it is a judgement, not a measurement.

**Negative controls, run** (each restored after, against the presenter suite):
- Starting the countdown at publication (the plan's control) failed the named parked-acknowledgement test,
  plus the stalled-presenter and no-presenter tests.
- Removing the gap check failed the four gap and wake tests. Removing the rebaseline revocation failed only
  the rebaseline test. Removing the preference revocation failed only the preference test, and removing the
  lost-presentation revocation failed only the lost-presentation test.
- Letting a prompt without a countdown keep the old one failed only the replacement test.
- Sending updates through `show` failed only the in-place update test.
- Letting a second acknowledgement reset the deadline failed the update test and the pure acknowledgement
  test. Ignoring the id failed the stalled-presenter test and the pure acknowledgement test.
- Removing the dismissal revocation, or the closing revocation, failed only its own test, each on the
  reason alone, because the `didSet` then revokes with `.withdrawn`.
- ⚠️ **Removing only the `didSet` revocation stayed green.** Every route that can take a countdown prompt
  down today names its own reason, so the `didSet` has no route of its own to catch. It is there for routes
  Task 9 adds; its presenter `withdraw` half *is* pinned, by the dismissal, lost-presentation and completion
  tests.

⚠️ **Not checked:** the panel. Acknowledging on visibility, reporting loss on lock and sleep, and an update
that leaves the panel in place all live in the executable and need a human (see Post-Completion). Also not
checked: `bash Scripts/lint.sh`, because `swiftlint` is not installed. No added line is over 140 columns;
the one existing over-long log line in `present` moved and was not lengthened.

### Task 9: The stop offer, its UI, and the narrow exception — one increment

⚠️ Kept together on Codex's point: the countdown must not become live several green commits before its
cancellation UI exists or before `AGENTS.md` says a timer may act.

**Files:** Modify `Sources/ActaRuntime/ReminderCoordinator.swift`, `Sources/Acta/ReminderPanel.swift`,
`AGENTS.md`, `docs/ui-vocabulary.md`, `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [x] add `ReminderPrompt.offerToStopOnRelease(...)`, and its case to **both** exhaustive
      `lifetime(of:)` switches; ⚠️ its `promptDeadline` must outlast the countdown, or `isWithinDeadline`
      refuses the Cancel click before the countdown completes
- [x] resolve the sentence as a **projection**, not in the view — ⚠️ naming the application is a fact,
      and `AGENTS.md` says a user-facing string that states a fact is a projection
- [x] copy must not claim the call ended: Acta saw an application release the input
- [x] Cancel keeps recording and suppresses further release offers **until the owner returns to `held`**
- [x] Stop now stops; countdown completion stops; `ownerReturned` cancels silently
- [x] arbitrate against the quiet prompt: neither inherits the other's authority, and the quiet
      prompt's non-acting expiry stays intact
- [x] decide and state whether the release offer defers to `isMenuOpen` as the quiet one does
      → **it defers raising, and spends nothing**; a countdown already running is not revoked by opening
      the menu (a menu that hides the panel is a lost presentation, which is)
- [x] rewrite the `AGENTS.md` rule as a narrow exception: the release countdown may act, **only** after
      an acknowledged prompt ran its full duration; automatic start, automatic deletion and any timer
      answering the quiet prompt stay forbidden
- [x] write tests for all four outcomes, plus displacement by another prompt, plus a countdown whose
      recording identity changed under it
- [x] **negative control**: remove the displacement revocation → the displacement test fails
- [x] run `bash Scripts/test.sh`

**Done.** 942 tests pass (924 before; 18 new — 11 through the coordinator over real recordings, 7 pure),
in four consecutive full runs of 28–29 s.

- `ReminderPrompt.offerToStopOnRelease(recordingID:title:text:)`, 30 s in **both** `lifetime(of:)` switches.
  ⚠️ **Decided here: an acknowledgement extends `promptDeadline` to the countdown's own deadline**, once.
  Task 8 left acknowledgement unbounded, so a lifetime counted from publication could not outlast every
  countdown; `a late acknowledgement … still leaves Stop Now answerable to the end` acknowledges 15 s late
  and presses Stop Now 34 s after publication. ⚠️ **Review found the panel's own 30 s timer undid this**:
  it dismissed the prompt mid-countdown as a decline, and dismissed an offer raised onto a locked screen
  the same way. Its expiry now goes through `ReminderCoordinator.expire(_:)`, keyed by presentation id,
  which leaves a running countdown alone and ends an unacknowledged one as `.presentationLost`.
- The sentence is `OwnerReleaseOfferText` in ActaKit: "Slack released the microphone" / "Acta saw Slack stop
  using the microphone input." Unnamed: "The microphone was released". A word-list test forbids "ended",
  "call", "meeting", "huddle" and similar. ⚠️ **The secondary button is "Keep Recording", not "Cancel"**:
  on a stop prompt "Cancel" reads as cancelling the recording, which is the unbuilt cancel-and-delete.
  The name comes from the start offer (already attribution-filtered), remembered against the binding.
- `ReminderCoordinator.ownerWatch` holds a `MicrophoneOwnershipRule` per admitted binding, rebuilt when the
  recorder's admission changes and discarded when there is none. It is fed `releaseEvidence` every tick,
  after the quiet evaluation and before the countdown. `ownerReturned` and `evidenceLost` withdraw the offer
  whether the countdown is running or awaiting acknowledgement.
- Outcomes: Keep Recording (and any dismissal) declines until the rule is next `held`; Stop Now stops;
  completion stops only if the recording id, the folder and the binding still match and the release is still
  qualified; the owner returning withdraws silently.
- ⚠️ **Arbitration, decided here:** the release offer is raised **only onto an empty panel**; a quiet offer
  **may** displace a running countdown, which is revoked — displacement only moves toward the prompt that
  keeps recording. A displaced offer returns on the next empty panel with a **new** presentation and a full
  countdown. A lost presentation or a lapse calls `MicrophoneOwnershipRule.discardAccumulatedRelease()`
  (new), so the next offer needs a freshly observed interval — the lock-without-sleep case the rule's own gap
  check cannot see.
- ⚠️ **Decided here: the panel installs no click-outside monitor for a countdown prompt.** A click elsewhere
  is a decline, and the user this is for clicks in another app within twenty seconds as a matter of course.
- `AGENTS.md` "The reminders" now states the exception and its four conditions, and what stays forbidden.
- ⚠️ **`docs/ui-vocabulary.md` was listed in this task's files and is not touched here**: Task 11 has the
  checkbox for it, and the file has no reminder-panel section to amend yet.
- Tests are `Sources/ActaTestRunner/OwnerReleaseOfferTests.swift`, the coordinator suite **nested inside
  `ReminderCoordinatorTests`**; the fixture is Slack + CoreSpeech, plus `com.apple.replayd` once recording.

**Negative controls, run** (each reverted; the plan's and the whole-body one re-run on the final tests):
- Removing the displacement revocation (the plan's control) failed **only** the named displacement test, at
  "the release was not offered again". ⚠️ It bites through bookkeeping, not through the stop: `present`
  overwrites the countdown anyway, so nothing stops. What the revocation carries is the watch learning the
  offer ended; without it the offer is never re-raised — the direction that keeps recording.
- Deleting the body of `observeOwnerRelease` failed 10 of 11 coordinator tests; the eleventh asserts that an
  unbound recording is never offered, which an absent feature satisfies.
- Completion not stopping: the completion and displacement tests. Dismissal not declining, or `held` not
  clearing the decline: the Keep Recording test. No deadline extension: the late-acknowledgement test. No
  discard on a lost presentation: its test. No withdrawal on `ownerReturned` / `evidenceLost`: their tests.
  No menu deferral: the menu test. Letting the offer displace any prompt: the displacement test.
- ⚠️ **Three guards stayed green alone**, each redundant with another: the folder check and the binding check
  in `stopForOwnerRelease` (a menu-started successor differs in both), and the qualification re-check at
  completion (the owner returning already withdrew the offer). **Removed in pairs**, folder + binding failed
  the replaced-recording test at both Stop Now and the countdown; qualification + the `ownerReturned`
  withdrawal failed the owner-return test, including the recording stopping.

⚠️ **The suite broke the full gate, and the fix is outside this task's files.** Alone it passed; in the full
run it failed every time with 16–17 issues, socket suites timing out at 62 s. `sample` showed all 13
cooperative threads blocked in `SegmentWriter.finish`'s 30-second wait. Controls: no recordings → green;
freezing the clock and nesting the suite → still red; an 8-second delay before each start → green. What
restored it was marking **"Activity meter in the pipeline" and "Activity meter gate" `.serialized`** — the
last two suites stopping recordings in parallel. Written up as a third reproducer in
`docs/backlog/segment-finalisation-waits-under-parallel-tests.md`; the production wait is untouched.

⚠️ **Not checked:** the panel — the countdown's layout, the missing click-outside dismissal, the button
labels on screen — is human acceptance. `bash Scripts/lint.sh` did not run: `swiftlint` is not installed.
No added line exceeds 140 columns.

### Task 10: Verify acceptance criteria

- [x] Slack + CoreSpeech binds to Slack; the huddle ending raises the prompt; no flap in any trace does
- [x] all four outcomes behave; displacement, wake and a failed start revoke correctly
- [x] the two stop preferences are independent in both directions
- [x] no offer is minted from Acta's own capture
- [x] run `bash Scripts/test.sh` — ⚠️ and **repeat it where a failure was observed**, rather than a
      blanket ten runs: both reviewers called the blanket campaign waste
- [x] re-run the named negative controls once together

**Done.** 946 tests pass (942 before; 4 new), in three consecutive full runs of about 30 s — the full gate
being where Task 9 saw its failure. The four new tests are acceptance tests through the wired coordinator,
in `OwnerReleaseOfferTests`; the other criteria were already pinned by named tests, and the controls below
are the evidence that they still bite.

- `the recorded traces, replayed through the coordinator, offer on the real release and on no flap` — the
  rule's replay repeated end to end on Slack + CoreSpeech + replayd, at 1 Hz and four phase offsets, up to
  each trace's final leave. The oracle reads the trace: an offer needs 5 s of truth-released behind it, a
  release still running 6 s in must have been offered, and the one genuine release (16.8 s between the two
  huddles) must be offered at every offset and withdrawn by the re-join without stopping anything. A
  precondition rejects releases whose offer would depend on phase.
- `a wake during the countdown withdraws it, and only a freshly observed release offers again` — the
  coordinator's rebaseline, with the injected clock advancing steadily so the rule itself sees no gap.
- `the two stop reminders act independently in both directions` — behaviour, on one bound recording;
  `RecordingSettingsTests` already pinned storage.
- `Acta's own capture mints no offer of either kind, while recording or after the stop` — replayd holding
  from the start, lingering into idle, then letting go, with Slack holding throughout.
- A failed start: `a failed start discards the binding it was admitted with` (Task 7). All four outcomes and
  displacement: Task 9's tests.

**Negative controls, re-run together** (15, one after another, each restored; the runner compares the
source tree to git afterwards and it was clean). All bit:
- Tasks 1–6, 8 and 9: each failed its named test, with the same companions their tasks recorded (the
  filters ran only the named suite, so Task 3's cross-suite failure was not re-observed, and Task 6's narrower
  filter ran the from-idle test without the matrix test that also failed in Task 6).
- ⚠️ **Task 7's control as first written stayed green, and the control was the defect.** It resolved before
  the barrier into a variable nobody used, and still handed the late resolver to `start`. Rebuilt so the
  early result is what `start` receives, it failed the named parked-barrier test and the unreadable-owner
  test, which is the pair Task 7 recorded.
- The new tests' own controls: never raising the offer, and qualifying after 1 s, each fail the replay (the
  oracle fails in both directions); a lapse that does not discard the release fails only the wake test;
  the release switch invalidating the quiet rule fails only the independence test; `isBusy: false` fails the
  own-capture test.
- ⚠️ The quiet switch gating the release offer failed the independence test and **12 others**: the fixture
  runs with the quiet reminder off, so that control removes the whole feature from the suite. It shows the
  test can fail, not that it alone can. The first attempt at this control did not compile and was rebuilt.

⚠️ **Not checked:** `bash Scripts/lint.sh` — `swiftlint` is not installed. No added line exceeds 140
columns. Human acceptance stays in Post-Completion.

### Task 11: [Final] Documentation and the backlog

- [x] ⚠️ **annotate** the implemented parts of `docs/backlog/per-application-autonomy-modes.md` with
      links — do **not** delete the user's verbatim proposal or the measurement record this plan cites
- [x] ➕ file `.saving` as its own backlog item with the reviewers' four boundaries
- [x] update `.claude/skills/mic-activity-detection/` if the ownership rule changes what it claims
- [x] record the new prompt in `docs/ui-vocabulary.md`
- [x] move this plan to `docs/plans/completed/` (not done by hand: ralphex archives the finished plan to
      `docs/plans/completed/<same-basename>.md` itself, and `AGENTS.md` forbids renaming a plan while the
      run holds its path)

**Done.** Documentation only; no source file changed. `bash Scripts/test.sh`: 946 tests pass, as after
Task 10.

- `per-application-autonomy-modes.md` gained one section, *What has landed*, above the assessment, linking
  `OwnerBinding`, `MicrophoneOwnershipRule`, `AudioProcessReadings`, `AcknowledgedCountdown`,
  `OwnerReleaseOfferText`, the `AGENTS.md` exception and this plan's archive path. Nothing below it was
  edited. ⚠️ **It flags a contradiction the item carried**: *The user's resolution* says doing nothing keeps
  the recording, while this plan's Decision 4 made the default stop. The section is kept as written and
  the reversal is stated above it. It also lists what of the proposal is **not** built.
- `docs/backlog/saving-is-a-property-of-a-recording.md`, `worth: later`: the unknown that settles its value
  is the unmeasured assembly time of a long recording, extrapolated today from one 90-second data point.
- The skill **did** claim things the work contradicts, so it changed: its gotcha "exclude Acta by its own
  pid" is wrong here, since Acta's capture is `com.apple.replayd`; its "≥ 5 s dwell" was not the 3 s the
  start rule uses; and it had the display name as the key, where the HAL bundle id is the more available
  one. Added CoreSpeech's persistent hold, unknown-is-never-released, and a release section.
- `docs/ui-vocabulary.md` gained an amendment for the reminder panel and the owner-release prompt, with
  the deliberate choices a later reader might "fix": Keep Recording rather than Cancel, no click-outside
  dismissal, and the only prompt whose timer acts. ⚠️ Checked against `ReminderPanel.swift`: the first
  draft said the countdown line appears only after acknowledgement; the view renders the full 20 s from the
  first frame and the coordinator starts counting at acknowledgement. Corrected before commit.

⚠️ **Not checked:** the dicta copy of `ui-vocabulary.md` is not updated (a separate repository); the
settings copy did not mention that pid-only holders stay unbound, which *Technical Details* says it does
— left as found, since that is a source change outside this task; the review added it.

## Post-Completion

*Needs a human, a real call, and a real machine.*

- The prompt **visible and clickable over a full-screen huddle**, on a second display, after unlock.
- **The panel's half of the presenter contract** (Task 8): that a countdown is acknowledged only once the
  panel is on screen, that locking the screen or sleeping the displays withdraws it, and that the
  once-a-second update leaves the panel where it is and does not reset its dismissal.
- Whether 25 s nominal feels right on a live call; the number is a judgement and may change on evidence.
- **The long-uptime silence**: hours of uptime with Task 1's heartbeat, then a huddle. The plan
  deliberately does not pre-empt this diagnosis; if the tick has stopped, the heartbeat says so and the
  fix is a new task.
- **A Slack restart**, for whether `com.tinyspeck.slackmacgap.helper` recurs. Nothing here depends on
  the answer; the next increment does.
- Still unmeasured and out of scope: Microsoft Teams entirely; two enrolled applications at once;
  whether `.saving` blocking is a real problem at three hours.

## After archiving: a review of the finished increment

The plan was archived at `5213c3f`; the user then asked for a check of the whole increment, and Codex
reviewed it read-only. Two findings, both verified in the code before acting on them, both fixed here.

- **The release offer was associated with its watch *after* `presenter.show` returned.** `show` may call
  back synchronously — the acknowledgement already does — so a presenter reporting the presentation lost
  from inside it reached `releaseOfferEnded` while `ownerWatch.offer` was still `nil`. The guard returned:
  the accumulated release was never discarded, and the assignment after `show` then installed a
  presentation that was already dead. `offer == nil` is a precondition of every later offer, so that one
  orphan silenced the feature for the rest of the recording. Fixed by making the association part of
  `present`, before any external call. ⚠️ **Not reached by the shipped panel**: `ReminderPanel.show` calls
  `acknowledgeIfVisible`, never `presentationLost`. This is a contract defect, found by reading, not an
  observed screen failure.
- **`aReplacedRecordingIsNotStopped` claimed a route it never ran.** `acceptReleaseStop` calls `dismiss()`
  before it checks identity, so the countdown is revoked and the ticks that follow cannot reach the
  completion path its comment described. Split: the old test keeps the click half under a title that says
  so, and `aReplacementWithdrawsTheCountdownBeforeItCanComplete` covers the case nobody clicks.

Three tests added, one `FakePresenter` flag (`losesNextPresentationOnShow`). **957 tests pass.**

**Negative controls** (eleven, each restored, each verified against `git diff` afterwards):

- association made after `show` again → fails **only** `a presentation lost from inside show leaves no
  orphan`. The fix is load-bearing and uniquely pinned.
- a lost presentation discards nothing → fails four, the new test among them.
- ⚠️ **The replacement test as first written never put B under the live countdown.** Codex caught it on a
  second read: the tick sat between A's stop and B's start, so it arranged A ending and *then* B beginning.
  Rearranged — B recording before the first tick, A's countdown asserted still running immediately before
  it — the test now reaches `trackRecordingIdentity` by the changed recording directory, which is a
  different branch from the one the first draft reached.
- ⚠️ **Every fence here is one of a redundant pair, and no single one has a test.** Measured, after the
  rearrangement: deleting `trackRecordingIdentity`'s clear on the *new-recording* branch fails nothing;
  deleting `observeOwnerRelease`'s teardown of a watch whose recording is gone fails nothing; deleting both
  fails the replacement test. The same holds for the *recording-ended* branch and the same teardown, against
  the new `aRecordingEndingTakesItsOfferDown`. Written into both tests, because a green run there is not
  evidence that any one line is load-bearing.
- ⚠️ **`trackRecordingIdentity`'s release-offer clear on the recording-ended branch had no test at all** —
  deleting it failed nothing in any of the 956 tests. That is what `aRecordingEndingTakesItsOfferDown` was
  added for: a recording that simply ends under a standing offer, with no successor. 957 tests now.

⚠️ **A control of mine corrupted the tree and I did not notice for two runs.** The harness saved its
"original" per edit rather than per file, so a control with two edits to one file restored the file to its
half-mutated state. Three later controls ran against that, and their results were meaningless; the full
suite then failed six tests and the first thing I suspected was the design. The controls above are the
re-run on a clean tree, and the harness now proves each restore with `git diff`.
