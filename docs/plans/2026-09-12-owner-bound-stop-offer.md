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
4. **Default outcome is stop.** Cancel keeps recording; Stop now ends it; the owner returning cancels
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
not measured is out of scope. Stated in the code and in the settings copy.

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

- [ ] read the snapshot once per tick, above both preference checks; feed each rule per its own
      preference
- [ ] when neither feature is enabled, read nothing
- [ ] write a test: with the start reminder off and release-stop on, observation happens from idle
- [ ] write a test: with both off, `readSnapshot` is never called (counted on the scripted reader)
      — ⚠️ **"both" means the start and release reminders**, the two that consume process observations;
      the quiet one measures audio and never gated this read. The matrix to land here:
      start=false/release=false → zero reads for **either** quiet value; start=false/release=true → one
      read from idle. `ScriptedReader` already counts (Task 1), and
      `noReminderEnabledBeatsNotObserved` already pins the zero-read half.
- [ ] **negative control**: move the read back inside the start branch → the first test fails
- [ ] run `bash Scripts/test.sh`

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

- [ ] put an **injected, synchronous binding resolver** at the common runtime start boundary, or route
      all three paths through one admission service. ⚠️ The controller must never call the HAL; the
      coordinator supplies the resolver's observation state
- [ ] ⚠️ **resolve after the last pre-admission `await`**, and attach in the **same actor turn** that
      successfully latches `isStarting`
- [ ] ⚠️ **a `nil` binding starts the recording unbound — it never refuses the start.** Codex, on
      Task 4: `guard let binding else { return }` recreates the dead-button defect and would also break
      pid-only prompt starts. Record *why* the binding was withheld, for diagnosis; do not attach an
      owner later when the input returns, which would move the frozen admission boundary
- [ ] for a prompt: preserve the original episode identity across the barrier, but **re-check** its
      observation epoch, key and current evidence afterwards — never replace it with a newer candidate
- [ ] freeze the accepted binding across the `recoveryTask` and `session.start` suspensions; an owner
      change during them does not rebind. Release evidence later decides whether to offer a stop
- [ ] ⚠️ a failed start discards **only that attempt's** binding, and a rejected second start must not
      overwrite a first start's pending one. Do **not** copy `ControlAPI.title`'s setter, which mutates
      before the controller's busy guard
- [ ] keep raw owner selection **off** the socket payload
- [ ] the controller stores the binding as opaque session metadata and projects it into
      `ControllerSnapshot` / `ControlState`
- [ ] write a test: **a parked microphone barrier during which the candidate changes** — the admitted
      binding is the re-checked one, not a newer holder
- [ ] write a test: **a parked `session.start`** preserves the admitted binding
- [ ] write a test: a rejected second start cannot alter a first start's pending binding
- [ ] write a test: manual and socket starts share the admission mechanics and **deliberately produce
      no binding** — ⚠️ the draft's "all three routes bind identically" contradicted Decision 2
- [ ] **negative control**: resolve before the barrier instead of after → the parked-barrier test fails
- [ ] run `bash Scripts/test.sh`

### Task 8: The presenter contract

⚠️ **`prompt != nil` is not proof of presentation.** And `ReminderPanel.present()` today rebuilds the
view, **repositions the panel from the pointer**, re-arms the dismissal timer and re-installs the click
monitor on every call — so publishing `secondsRemaining` each second through that path would walk the
panel across the screen and reset its timer forever.

**Files:** Modify `Sources/Acta/ReminderPanel.swift`, `Sources/ActaRuntime/ReminderCoordinator.swift`,
Create `Sources/ActaTestRunner/ReminderPresenterTests.swift`

- [ ] introduce a presenter protocol the coordinator talks to, with **acknowledgement**: the countdown
      starts from acknowledged presentation, bound to a stable presentation identity
- [ ] separate **initial presentation** from **updating an existing countdown** in the panel: an update
      must not reposition, re-arm the dismissal timer or reinstall the monitor
- [ ] the authoritative deadline lives in the coordinator and is never re-derived from a rendering
      update
- [ ] revoke on: dismissal, replacement by another prompt, the preference being turned off, quit, and
      loss of presentation eligibility
- [ ] ⚠️ **sleep/lock/wake**: no catch-up stop after a wake in which the user never had the promised
      cancellation interval — withdraw, and require fresh release evidence and a newly presented full
      countdown
- [ ] write tests through an **injected presenter**, including a **parked acknowledgement**
- [ ] write a test: a stalled or unavailable presenter never authorises a stop
- [ ] **negative control**: start the countdown on publication instead of acknowledgement → the parked
      test fails
- [ ] run `bash Scripts/test.sh`

### Task 9: The stop offer, its UI, and the narrow exception — one increment

⚠️ Kept together on Codex's point: the countdown must not become live several green commits before its
cancellation UI exists or before `AGENTS.md` says a timer may act.

**Files:** Modify `Sources/ActaRuntime/ReminderCoordinator.swift`, `Sources/Acta/ReminderPanel.swift`,
`AGENTS.md`, `docs/ui-vocabulary.md`, `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [ ] add `ReminderPrompt.offerToStopOnRelease(...)`, and its case to **both** exhaustive
      `lifetime(of:)` switches; ⚠️ its `promptDeadline` must outlast the countdown, or `isWithinDeadline`
      refuses the Cancel click before the countdown completes
- [ ] resolve the sentence as a **projection**, not in the view — ⚠️ naming the application is a fact,
      and `AGENTS.md` says a user-facing string that states a fact is a projection
- [ ] copy must not claim the call ended: Acta saw an application release the input
- [ ] Cancel keeps recording and suppresses further release offers **until the owner returns to `held`**
- [ ] Stop now stops; countdown completion stops; `ownerReturned` cancels silently
- [ ] arbitrate against the quiet prompt: neither inherits the other's authority, and the quiet
      prompt's non-acting expiry stays intact
- [ ] decide and state whether the release offer defers to `isMenuOpen` as the quiet one does
- [ ] rewrite the `AGENTS.md` rule as a narrow exception: the release countdown may act, **only** after
      an acknowledged prompt ran its full duration; automatic start, automatic deletion and any timer
      answering the quiet prompt stay forbidden
- [ ] write tests for all four outcomes, plus displacement by another prompt, plus a countdown whose
      recording identity changed under it
- [ ] **negative control**: remove the displacement revocation → the displacement test fails
- [ ] run `bash Scripts/test.sh`

### Task 10: Verify acceptance criteria

- [ ] Slack + CoreSpeech binds to Slack; the huddle ending raises the prompt; no flap in any trace does
- [ ] all four outcomes behave; displacement, wake and a failed start revoke correctly
- [ ] the two stop preferences are independent in both directions
- [ ] no offer is minted from Acta's own capture
- [ ] run `bash Scripts/test.sh` — ⚠️ and **repeat it where a failure was observed**, rather than a
      blanket ten runs: both reviewers called the blanket campaign waste
- [ ] re-run the named negative controls once together

### Task 11: [Final] Documentation and the backlog

- [ ] ⚠️ **annotate** the implemented parts of `docs/backlog/per-application-autonomy-modes.md` with
      links — do **not** delete the user's verbatim proposal or the measurement record this plan cites
- [ ] ➕ file `.saving` as its own backlog item with the reviewers' four boundaries
- [ ] update `.claude/skills/mic-activity-detection/` if the ownership rule changes what it claims
- [ ] record the new prompt in `docs/ui-vocabulary.md`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Needs a human, a real call, and a real machine.*

- The prompt **visible and clickable over a full-screen huddle**, on a second display, after unlock.
- Whether 25 s nominal feels right on a live call; the number is a judgement and may change on evidence.
- **The long-uptime silence**: hours of uptime with Task 1's heartbeat, then a huddle. The plan
  deliberately does not pre-empt this diagnosis; if the tick has stopped, the heartbeat says so and the
  fix is a new task.
- **A Slack restart**, for whether `com.tinyspeck.slackmacgap.helper` recurs. Nothing here depends on
  the answer; the next increment does.
- Still unmeasured and out of scope: Microsoft Teams entirely; two enrolled applications at once;
  whether `.saving` blocking is a real problem at three hours.
