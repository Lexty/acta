# Plan: The owner-bound stop offer — ask when the application that started it lets the microphone go

## Overview

Today a recording is stopped by the user, or offered for stopping when the *audio* has been quiet for
minutes. Neither answers the ordinary case: a Slack huddle ends and the recording keeps running until
somebody remembers it.

This plan adds a second, independent reason to offer a stop: **the application whose microphone
activity the recording belongs to has let the input go.** A recording is bound to that application at
start, the binding lives as long as the recording, and a qualified release raises a prompt with a
countdown — Cancel keeps recording, Stop now ends it at once, and doing nothing ends it when the
countdown completes.

**What this is not.** No per-application memory, no automatic *start*, no cancel-and-delete, no
enrolment interface. Those are the rest of `docs/backlog/per-application-autonomy-modes.md` and they
sit on top of the ownership model this plan builds — deliberately, so the model is proven before
anything automatic is keyed to it.

⚠️ **This increment reverses a rule the reminders were built on.** `AGENTS.md` states that nothing acts
on its own: *a timer may withdraw a prompt, it may never answer one.* A countdown that stops a
recording is a timer answering a prompt. The user decided this explicitly. Task 11 rewrites that rule
as a **narrow exception** in the same change — the rule is not deleted, and it keeps applying to
everything else.

## Context (from discovery)

**Files involved**

- `Sources/ActaKit/MicrophoneActivityRule.swift` — the existing prompt-qualifying rule. **Not modified
  by this plan** beyond what Task 9 requires.
- `Sources/ActaKit/RecordingSettings.swift` — where the third preference goes; deliberately absent from
  `WireSettings`.
- `Sources/ActaRuntime/ReminderCoordinator.swift` — the tick, the prompts, the admission checks.
- `Sources/ActaRuntime/AudioProcessReader.swift` — `AudioProcessSnapshot`, `AudioProcessObservation`.
- `Sources/ActaRuntime/RecordingController.swift`, `RecordingController+Types.swift` — `Phase` is
  `idle / recording / saving / error`.
- `Sources/ActaRuntime/ControlState.swift` — `Operation` is `idle / starting / recording / saving`;
  `canStart` is `operation == .idle`; `hasWorkInFlight` is `operation != .idle`.
- `Sources/Acta/ReminderPanel.swift` — the floating panel, prompt rendering and lifetimes.
- `Sources/Acta/SettingsWindow.swift` — the Reminders tab.
- `Sources/ActaTestRunner/` — all tests; `bash Scripts/test.sh`; **854 passing** at `e051167`.

**Patterns this plan follows**

- **Pure rule in `ActaKit`, thin coordinator in `ActaRuntime`.** `MicrophoneActivityRule` and
  `AudioActivityRule` are both pure and clock-injected; the coordinator owns no timing logic of its
  own. The new rule is built the same way.
- **A projection, never a ternary in the view.** User-facing sentences are resolved in `ControlAPI` /
  the coordinator and tested, because the view is the one layer nothing checks.
- **Negative controls.** Every rule gets a test whose failure is *caused* by deleting that rule. On
  2026-09-12 this caught three tests that passed with their rule removed.
- **Unknown is never idle.** An unreadable observation is not evidence that anything stopped.

**Dependencies**

- One HAL read per tick, shared by both rules. `reader.readSnapshot()` is currently called inside
  `if settings.offersRecordingWhenMicrophoneBusy`, which must change: the release rule needs
  observations even when the *start* reminder is off.

## Measured facts this plan is built on

Every number is from `docs/backlog/per-application-autonomy-modes.md`, measured on this machine
(macOS 26.6.2 build 25G83, Slack 4.52.155) on 2026-09-12. Re-measure before contradicting one.

- **A Slack huddle is held by `com.tinyspeck.slackmacgap.helper`**, with its own bundle identifier,
  distinct from the app's `com.tinyspeck.slackmacgap`. `display` is `<none>`, `process` is
  `Slack Helper`. **The bundle identifier is present where the display name is absent** — 29 of 32
  process objects carried one, including processes `NSRunningApplication` cannot resolve.
- **Holding separates the call from the idle app**: positive in every sample across a 90 s huddle,
  negative in every sample across 180 s of a running, idle Slack.
- **Holding is not smooth.** Observed gaps *inside* a call: **266, 273, 279, 539, 551, 824, 834 ms**.
  The longest is 834 ms. They are intervals between observed states, not physical durations — the
  sampling interval bounds them from below. ⚠️ **Do not tune a threshold to these numbers.**
- **The first gap is Slack's pre-join dialog ending**, not a device event. First holds measured 1.90,
  1.37, 6.21 and 2.22 s — that is how long a person looked at a dialog.
- **Muting caused no observed release** in the interval tested.
- **The helper is not restarted between calls** (same pid and process-object id across two huddles).
  Recurrence across a Slack *restart* is **unmeasured**.
- **Every release observed was "object present, input now false"**, never a disappearance — in that
  trace. Quitting and crashing still exist, so unknown/disappearance stays in the contract.
- **Acta's own capture is reported as `com.apple.replayd`**, matching its log to the millisecond.
- **A device-loss restart took 210 ms** with no buffers dropped.
- **Assembly of a 90 s recording took ~570 ms** (13:40:47.992 "Capture stopped" → 13:40:48.561
  "stopped and saved"). ⚠️ The three-hour extrapolation from this **has not been measured**.

## Decisions taken before the plan was written

1. **A new pure type, `MicrophoneOwnershipRule`, beside `MicrophoneActivityRule` — never inside it.**
   The existing rule's phases carry policy and history (spent, re-arm, exclusions, baseline) and
   deliberately tolerate an unreadable reading after a spent one. That is right for admitting a human
   click and wrong for arming an automatic action. ⚠️ **Never infer release from
   `!isEpisodeActionable`.**
2. **Binding at start, by any route** — prompt, panel or socket. Exactly one foreign holder becomes the
   owner; two or none leaves the recording **unbound for its whole life**.
3. **Release qualification N = 5 s**, a judgement and not a measurement. Countdown 20 s. **Total
   user-visible delay from leaving a call to the recording stopping: 25 s.**
4. **Default outcome is stop.** Cancel keeps recording; Stop now ends it immediately; the owner
   returning to `held` cancels the countdown with no user action.
5. ⚠️ **No visible prompt means no stop.** The countdown is legitimate only as the completion of a
   prompt the user could see and cancel.
6. **A third settings toggle**, independent of the two existing ones. The two stop reasons do not share
   authority: enabling release-stop must not make the quiet rule act, and vice versa.
7. **`.saving` stops blocking a start** (Task 9), which forces Task 8 — see the coupling there.

## Development Approach

- **Testing approach: regular (code, then tests in the same task).** This repo's standard is stronger
  than "tests exist": every rule also gets a **negative control** — delete the rule, watch the *named*
  test fail. A control that fails nothing, or fails a different test, means the test was guarding
  something else.
- Complete each task fully before the next. All 854+ tests pass before moving on.
- Small, focused changes. ⚠️ **Update this plan when scope changes** — add `➕` for new tasks and `⚠️`
  for blockers.
- English-only in the repository; the conversation about it is Russian.

## Testing Strategy

- **Unit tests** in `Sources/ActaTestRunner/`, run by `bash Scripts/test.sh`. Required in every task.
- **The replay fixture (Task 3) is the centre of this plan's testing.** The real traces become data,
  and the rule is driven by them at **several 1 Hz sampling offsets** — production samples at 1 Hz
  while the traces were captured at 250 ms, so a 539 ms gap is visible at one offset and invisible at
  another. A rule that only works on one phase is not a rule.
- **Negative control per rule**, named in the task.
- **No e2e framework in this project.** What cannot be tested is listed under Post-Completion and stays
  manual.

## Progress Tracking

- `[x]` immediately on completion, never batched.
- `➕` for newly discovered tasks, `⚠️` for blockers.
- Keep the plan in sync with the work actually done.

## Solution Overview

```
                       one HAL snapshot per tick
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
   MicrophoneActivityRule                  MicrophoneOwnershipRule   ← new, pure, ActaKit
   (which app took the mic:                (did THIS recording's owner
    qualify a start prompt)                 let the input go?)
              │                                       │
              │ .offer / .withdraw                    │ .releaseQualified / .ownerReturned
              ▼                                       ▼
                        ReminderCoordinator (@MainActor)
                                  │
                                  ▼
                    ReminderPanel: countdown prompt
                    [Cancel] [Stop now] — default: stop
```

The ownership rule knows nothing about prompts, exclusions or episodes. It knows one owner key and
whether the evidence for it is positive, negative, or missing — and how long that has been true.

## Technical Details

**`MicrophoneOwnershipRule`** (`Sources/ActaKit/MicrophoneOwnershipRule.swift`), pure and
clock-injected like its siblings:

```
enum OwnerKey: Hashable, Sendable { case bundle(String), process(Int32) }

enum OwnerPhase: Equatable, Sendable {
    case held(since: Date)
    case releaseCandidate(since: Date)     // seen released, N not yet satisfied
    case releasedQualified                 // released continuously for N
    case unknown(since: Date)              // unreadable, or an observation gap
}

enum Outcome: Equatable, Sendable {
    case none
    case releaseQualified                  // raise the prompt
    case ownerReturned                     // cancel a candidate or a countdown
    case evidenceLost                      // unknown: revoke, do not act
}

mutating func observe(_ snapshot: AudioProcessSnapshot, at: Date, context: Context) -> Outcome
mutating func bind(at: Date) -> OwnerKey?  // exactly one foreign holder, else nil
mutating func unbind()
```

**Qualification, stated so it cannot be misread.** `releasedQualified` requires a *sequence* of
released observations spanning `N` on the monotonic clock with **no gap between consecutive
observations larger than `maxSampleGap`**. One sample reading false is not a release. `unknown`
revokes what was accumulated. A positive same-owner observation returns to `held` and requires a
**full new interval** afterwards — never the remainder.

**Constants**, all named in one place with the reasoning beside them:

| name | value | why |
|---|---|---|
| `releaseQualification` | 5 s | absorbs the 834 ms longest observed gap with margin at a 1 Hz poll |
| `maxSampleGap` | 2.5 s | a poll that skipped is not a continuous sequence |
| `countdown` | 20 s | matches the existing stop prompt's lifetime |
| total | 25 s | ⚠️ the number the user actually experiences — state it in the UI copy review |

**Binding.** `ControlState` gains `recordingOwner: OwnerKey?` alongside the existing
`activeRecordingDirectory`, **absent from `WireSettings` and from `RecordingSummary`** — it is a menu
concern, not an agent one.

## What Goes Where

- **Implementation Steps** — everything achievable in this repository.
- **Post-Completion** — the rendered panel over a full-screen huddle, real timings, the long-uptime
  silence, and a Slack restart for key recurrence. These need a human and a real call.

## Implementation Steps

### Task 1: A heartbeat in the reminder tick

⚠️ **First, because without it the next bug is as undiagnosable as the last one.** On 2026-09-12 the
reminder produced nothing for two real huddles on an instance up since 09:57, while a fresh instance
fired correctly. The existing diagnostic logs only when the holder set *changes*, so "the tick is not
running" and "nothing holds the microphone" look identical. This task does not fix that defect — it
makes it observable.

**Files:**
- Modify: `Sources/ActaRuntime/ReminderCoordinator.swift`
- Modify: `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [ ] add a tick counter and a monotonic start instant to the coordinator
- [ ] log at `.info` every `heartbeatTicks` (60) regardless of change: tick count, uptime, whether the
      snapshot was complete, and the current holder count — one line, low noise
- [ ] make the existing holders diagnostic and the heartbeat share one snapshot read
- [ ] write a test that the heartbeat fires on the expected tick and not between
- [ ] write a test that a run of identical snapshots still produces heartbeats (the regression that
      would reintroduce the blind spot)
- [ ] run `bash Scripts/test.sh` — must pass before Task 2

### Task 2: `MicrophoneOwnershipRule` — the pure type

**Files:**
- Create: `Sources/ActaKit/MicrophoneOwnershipRule.swift`
- Create: `Sources/ActaTestRunner/MicrophoneOwnershipRuleTests.swift`

- [ ] define `OwnerKey`, `OwnerPhase`, `Outcome` and `Context` (own bundle ids and pids to drop, as
      `MicrophoneActivityRule.Context` does)
- [ ] implement `bind(at:)`: exactly one foreign holder in the last observation becomes the owner;
      two or none returns nil. ⚠️ Document that a `.process`-keyed binding does not survive a restart
      of that process, and that this is accepted rather than hidden
- [ ] implement `observe`: held / releaseCandidate / releasedQualified / unknown, with
      `releaseQualification` and `maxSampleGap`
- [ ] implement `ownerReturned`: a positive same-owner observation cancels a candidate and requires a
      full new interval afterwards
- [ ] write tests: binding with one, two and zero holders
- [ ] write tests: qualification needs a continuous sequence — a single false sample does not qualify
- [ ] write tests: `unknown` revokes accumulated qualification and does not advance it
- [ ] write tests: a return after 4.9 s of candidacy requires a **full** new 5 s, not 0.1 s
- [ ] write tests: another application holding or releasing never affects the owner
- [ ] **negative control**: delete the `maxSampleGap` check → the "a skipped poll is not continuous"
      test must fail, and nothing else
- [ ] run `bash Scripts/test.sh` — must pass before Task 3

### Task 3: The replay fixture, from the real traces

⚠️ **The traces are data, not anecdotes.** Everything in this plan's timing was measured once, on one
machine; encoding those exact events as a fixture is what stops the next change from quietly breaking
against them.

**Files:**
- Create: `Sources/ActaTestRunner/MicrophoneOwnershipFixtures.swift`
- Modify: `Sources/ActaTestRunner/MicrophoneOwnershipRuleTests.swift`

- [ ] encode the recorded traces as `(offsetMilliseconds, holders)` event lists: the two-flap join
      sequence, the gaps of 266/273/279/539/551/824/834 ms, the pre-join→huddle transition, the
      device-loss restart, and the final release
- [ ] write a replayer that samples an event list at a given period and **phase offset**, producing the
      snapshots a 1 Hz observer would actually have seen
- [ ] drive the rule over every trace at **at least four offsets** spanning one second
- [ ] assert the invariant that matters: **no flap in any trace at any offset produces
      `releaseQualified`**, and the genuine final release does at every offset
- [ ] write a test that the replayer itself is honest — a known 539 ms flap is visible at one offset and
      invisible at another, which is the whole reason for the exercise
- [ ] run `bash Scripts/test.sh` — must pass before Task 4

### Task 4: Bind a recording to its owner

**Files:**
- Modify: `Sources/ActaRuntime/ControlState.swift`
- Modify: `Sources/ActaRuntime/ControlAPI.swift`
- Modify: `Sources/ActaRuntime/ReminderCoordinator.swift`
- Modify: `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [ ] add `recordingOwner: OwnerKey?` to `ControllerSnapshot` and `ControlState`, ⚠️ **not** to
      `WireSettings` or `RecordingSummary`
- [ ] bind on the transition into a recording, by any route — prompt, panel or socket — using the
      coordinator's most recent snapshot
- [ ] clear the binding when the recording ends; a new recording binds afresh
- [ ] ⚠️ never rebind a live recording to a newer holder: the owner is who *triggered* it
- [ ] write a test: a recording started while one foreign app holds input is bound to it
- [ ] write a test: started with two holders, or none, the recording is unbound and stays unbound even
      when one of them later releases
- [ ] write a test: a second recording started after the first binds independently
- [ ] **negative control**: remove the "exactly one" condition → the two-holders test must fail
- [ ] run `bash Scripts/test.sh` — must pass before Task 5

### Task 5: One snapshot, two rules

⚠️ **The release rule needs observations even when the start reminder is off.** Today
`reader.readSnapshot()` sits inside `if settings.offersRecordingWhenMicrophoneBusy`, so turning off the
start prompt would silently disable release-stop too — exactly the "two features sharing one
authority" mistake the design forbids.

**Files:**
- Modify: `Sources/ActaRuntime/ReminderCoordinator.swift`
- Modify: `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [ ] read the snapshot once per tick, above both preference checks
- [ ] feed `MicrophoneActivityRule` only when the start preference is on, exactly as now
- [ ] feed `MicrophoneOwnershipRule` whenever a bound recording exists and the release preference is on
- [ ] ⚠️ when neither feature is enabled, read nothing — a property walk per second for nobody
- [ ] write a test: with the start reminder off and release-stop on, a bound recording still observes
      its owner
- [ ] write a test: with both off, `readSnapshot` is not called (count it on the scripted reader)
- [ ] **negative control**: move the read back inside the start-preference branch → the first test must
      fail
- [ ] run `bash Scripts/test.sh` — must pass before Task 6

### Task 6: The stop prompt with a countdown

**Files:**
- Modify: `Sources/ActaRuntime/ReminderCoordinator.swift`
- Modify: `Sources/Acta/ReminderPanel.swift`
- Modify: `Sources/ActaTestRunner/ReminderCoordinatorTests.swift`

- [ ] add `ReminderPrompt.offerToStopOnRelease(recordingID:title:application:secondsRemaining:)`
- [ ] raise it on `releaseQualified`; the countdown is owned by the coordinator, not the view, and is
      re-checked at admission like every other prompt
- [ ] **Cancel** keeps the recording and suppresses further release offers for this session **until the
      owner returns to `held`**, then re-arms
- [ ] **Stop now** stops immediately
- [ ] the countdown completing stops the recording — ⚠️ **and only if the prompt is currently on
      screen.** No visible prompt, no stop
- [ ] `ownerReturned` cancels the countdown and withdraws the prompt with no user action
- [ ] ⚠️ re-check after every `await`: recording identity, owner, preference, quit state, and a *fresh*
      qualified release
- [ ] write tests for each of the four outcomes (Cancel, Stop now, countdown, owner returned)
- [ ] write a test: Cancel then a second release raises nothing until the owner returns
- [ ] write a test: the countdown does not stop a recording whose identity changed under it
- [ ] **negative control**: delete the on-screen requirement → the no-visible-prompt test must fail
- [ ] run `bash Scripts/test.sh` — must pass before Task 7

### Task 7: The third preference

**Files:**
- Modify: `Sources/ActaKit/RecordingSettings.swift`
- Modify: `Sources/ActaRuntime/ControlDispatcher.swift`
- Modify: `Sources/Acta/SettingsWindow.swift`
- Modify: `Sources/ActaTestRunner/MicrophoneSettingsTests.swift`
- Modify: `Sources/ActaTestRunner/SourceConfinementTests.swift`

- [ ] add `offersStopWhenOwnerReleases: Bool` (default **on**), decoded with the same
      `decodeIfPresent`-and-default treatment as its siblings
- [ ] confine it in `ControlDispatcher.appliedSettings` like the other reminder fields, and keep it out
      of `WireSettings`
- [ ] add the toggle to the Reminders tab, with copy that says what it does and what it does not: it
      asks, the recording is stopped only by an answer or by a visible countdown, and it is independent
      of the quiet-audio rule
- [ ] add its label to the persistent-controls list in `SourceConfinementTests`
- [ ] write a test: the two stop preferences are independent switches in both directions
- [ ] write a test: a socket `settings_set` cannot change it
- [ ] run `bash Scripts/test.sh` — must pass before Task 8

### Task 8: Identify Acta's own capture properly

⚠️ **This must land before Task 9, not after.** Acta captures through ScreenCaptureKit, so the HAL
reports `com.apple.replayd` — a system daemon that is **not** in `ownBundleIDs`. Today nothing goes
wrong only because `context.isBusy` is true for the whole of `.saving`. Task 9 makes `isBusy` false
earlier, and replayd's `.holding(since:)` was set when the recording began, so the 3 s threshold is
long past: an offer would be minted immediately, caused by Acta's own just-finished capture. A 570 ms
gap between "Capture stopped" and `.idle` is all that hides it now.

⚠️ **Do not add `replayd` to `ownBundleIDs`.** The daemon is shared by every ScreenCaptureKit client;
silencing it blinds the rule to other applications' captures.

**Files:**
- Modify: `Sources/ActaRuntime/ReminderCoordinator.swift`
- Modify: `Sources/ActaKit/MicrophoneActivityRule.swift`
- Modify: `Sources/ActaTestRunner/MicrophoneActivityRuleTests.swift`

- [ ] extend `Context` with the pid Acta's own capture runs under, supplied by the coordinator from the
      recording it started — correlation with a known recording, not a name match
- [ ] drop that process from the readings exactly as own-pids are dropped today
- [ ] write a test: with a recording in flight, the capture daemon's process produces no episode
- [ ] write a test: **the same daemon holding input for another client still does** — the fix must not
      become a blanket silence
- [ ] write a test reproducing the Task 9 hazard directly: `isBusy` goes false while the daemon is
      still observed holding, and no offer is minted
- [ ] **negative control**: remove the correlation → the first and third tests must fail, the second
      must still pass
- [ ] run `bash Scripts/test.sh` — must pass before Task 9

### Task 9: `.saving` becomes a property of a recording

The user's requirement: after stopping a multi-hour recording, the next must start **at once**. Today
`canStart` is `operation == .idle` and `.saving` is an operation, so it is refused.

⚠️ **Measure first.** The only figure is ~570 ms for a 90-second recording; the three-hour
extrapolation has never been measured. Record a long session, time the stop, and write the number into
this task before changing the phase machine. If it turns out to be a second, say so and close the task.

**Files:**
- Modify: `Sources/ActaRuntime/RecordingController.swift`
- Modify: `Sources/ActaRuntime/RecordingController+Types.swift`
- Modify: `Sources/ActaRuntime/ControlState.swift`
- Modify: `Sources/ActaTestRunner/RecordingControllerGuardTests.swift`

- [ ] measure assembly against recording length and record the numbers here
- [ ] move assembly ownership to the finished recording: a new capture may begin while a previous
      archive completes
- [ ] `canStart` no longer excludes an assembling predecessor
- [ ] ⚠️ `hasWorkInFlight` must still be true while any assembly runs — quitting waits for all of them
- [ ] ⚠️ the archive listing must not present a half-assembled recording as done
- [ ] ⚠️ launch recovery must not mistake an interrupted assembly for a crashed recording
- [ ] write a test: a second recording starts while the first assembles, and both archives are complete
- [ ] write a test: quit waits for an assembly that belongs to no current recording
- [ ] write a test: the listing shows the assembling recording as not-yet-done
- [ ] **negative control**: make `hasWorkInFlight` ignore assemblies → the quit test must fail
- [ ] run `bash Scripts/test.sh` — must pass before Task 10

### Task 10: The panel, and the words on it

**Files:**
- Modify: `Sources/Acta/ReminderPanel.swift`
- Modify: `docs/ui-vocabulary.md`

- [ ] render the countdown prompt: what is stopping, which application let the microphone go, seconds
      remaining, `Cancel` and `Stop now`
- [ ] ⚠️ the copy must not claim the call ended — Acta saw an application release the input, which is
      not the same fact
- [ ] name the application only when the system gave a usable name; otherwise say nothing about it
- [ ] no default key equivalent, consistent with the existing panel
- [ ] record the new prompt in `docs/ui-vocabulary.md` as acta's own divergence
- [ ] run `bash Scripts/test.sh` — must pass before Task 11

### Task 11: The rule reversal, written down

⚠️ **The point of this task is that the reversal is deliberate and narrow.** `AGENTS.md` says nothing
acts on its own and a timer may never answer a prompt. After this plan, one timer can — and only one.

**Files:**
- Modify: `AGENTS.md`

- [ ] rewrite the rule as: nothing acts on its own **except** the release countdown, which stops a
      recording only after a prompt the user could see and cancel has been on screen for its full
      duration
- [ ] state the two invariants that keep the exception narrow: no visible prompt means no stop, and the
      owner returning cancels without user action
- [ ] state what is still forbidden: automatic *start*, automatic deletion, and any timer answering the
      quiet-audio prompt
- [ ] cross-reference `docs/backlog/per-application-autonomy-modes.md` for the measurements behind it

### Task 12: Verify acceptance criteria

- [ ] a recording bound to Slack raises the prompt when the huddle ends, and not when a flap happens
- [ ] Cancel, Stop now, countdown and owner-returned all behave as specified
- [ ] the two stop preferences are independent in both directions
- [ ] a start is accepted while a previous recording assembles
- [ ] no offer is minted from Acta's own capture, before or after Task 9
- [ ] run the full suite: `bash Scripts/test.sh`
- [ ] run it **ten times** — this repo has a documented history of intermittent failures, and a single
      green run has twice been a green sample from a red distribution
- [ ] run every negative control listed above once more, together, and confirm each fails its own test

### Task 13: [Final] Documentation

- [ ] update `AGENTS.md` where the reminder rules are described
- [ ] update `.claude/skills/mic-activity-detection/` if the ownership rule changes what that skill
      claims
- [ ] delete the parts of `docs/backlog/per-application-autonomy-modes.md` this plan implemented, and
      leave the rest
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*No checkboxes — these need a human, a real call, and a real machine.*

**Manual verification**

- The prompt is visible and clickable **over a full-screen Slack huddle**, on a second display, and
  after unlock. Source review and a green suite say nothing about this.
- The real 25-second delay feels right on a live call — and if it does not, the number is a judgement
  and may be changed on evidence.
- **The long-uptime silence.** Leave the app running for hours with the heartbeat from Task 1, then
  join a huddle. This is the diagnosis the plan deliberately does not pre-empt; if the tick has stopped,
  the heartbeat says so and the real fix is a new task.
- **A Slack restart**, to see whether `com.tinyspeck.slackmacgap.helper` recurs. It decides whether a
  bundle key is durable in practice, and nothing in this plan depends on the answer — but the next
  increment does.

**Still unmeasured, and out of scope here**

- Microsoft Teams, entirely.
- Two enrolled applications holding the input at once.
- Whether `.saving` blocking is a real problem at three hours (Task 9 measures it first).
