# Plan: Microphone priority — pin Acta's capture, and hold the Mac's default input

## Overview

Two related features, separated deliberately because only one of them fits today's `SPEC.md`.

**(A) Acta pins its own capture microphone.** `SCKCaptureSource.makeConfiguration` sets
`captureMicrophone = true` and never sets `microphoneCaptureDeviceID`, and `SCStream.h` is explicit
that an unspecified device means "System Default Microphone". So Acta records whatever macOS most
recently decided the default input is — today a Bluetooth headset silently becomes that on connect.
This is a **defect against an existing rule** ("never show recording when the right data is not being
written"), not a new feature, and it needs no scope change.

**(B) Acta holds the Mac's default input on a user-ordered priority list.** A CoreAudio HAL
reconciler that keeps `kAudioHardwarePropertyDefaultInputDevice` on the highest-priority available
device. This **does** change scope: the promise is "while Acta is running, the Mac's default
microphone stays on my list", which holds while Acta is idle. `SPEC.md` currently says Acta only
records; this plan amends it explicitly rather than smuggling the change past it.

**What (B) does not promise, and the UI must not imply:** an app with its own explicitly selected
input device (Slack, Teams, Meet all have one) need not follow the system default. (B) fixes the
system default; per-app pickers stay the user's job, once.

## Measured facts this plan is built on

Every number below was measured on this machine (macOS 26, MacBook Pro, AirPods Pro) with throwaway
probes, not taken from documentation. Tasks depend on them; re-measure before contradicting one.

- **The HAL identity and the ScreenCaptureKit identity are the same string.** `AVCaptureDevice.uniqueID`
  and `kAudioDevicePropertyDeviceUID` returned byte-identical values for every device produced:
  `BuiltInMicrophoneDevice`, `BlackHole2ch_UID`, `MSLoopbackDriverDevice_UID`, `~:AMS2_Aggregate:0`,
  the Continuity mic `333CDAA6-…`, **and the Bluetooth headset** `00-00-5E-00-53-01:input`.
  `AVCaptureDevice.default(for: .audio)` agreed with `kAudioHardwarePropertyDefaultInputDevice`.
  ⚠️ This is **measured, not a documented contract** — the SDK documents each identity's persistence
  separately and never states they are one identity. Task 9 pins it with a live probe.
- **The UID survives disconnect/reconnect; the integer does not.** Across a headset reconnect the
  `AudioObjectID` went `140 → 181` while the UID was unchanged. Key the priority list on the UID.
- **There is no A2DP/HFP identity split to design around.** Opening the mic set
  `kAudioDevicePropertyDeviceIsRunningSomewhere` to 1 and back to 0 without replacing the device,
  without changing the `AudioObjectID`, and without changing the nominal sample rate (24000 both idle
  and running). Do **not** write code that expects a second device to appear for the call profile.
- **The flip is not observably ordered after the device arrives.** At 0.4 s resolution the
  `DEFAULT INPUT` change and the device's appearance landed in the same sample, both times. A
  reconciler must therefore be **order-independent** and must not infer intent from ordering.
- ⚠️ **`kAudioDevicePropertyDeviceCanBeDefaultDevice` is scope-sensitive and fails silently.** Queried
  in `kAudioObjectPropertyScopeGlobal` it returns `kAudioHardwareUnknownPropertyError` (2003332927)
  for **every** device; a helper that ignores the `OSStatus` then reports `0` for everything, and a
  filter built on it rejects the entire machine. Query it in `kAudioObjectPropertyScopeInput`. In that
  scope it is meaningful: the Teams loopback driver reports `0`, while BlackHole and the aggregate
  report `1` — so it prunes some virtual devices and not others.
- **Bluetooth has two transport constants.** `AudioHardwareBase.h:616-617` defines
  `kAudioDeviceTransportTypeBluetooth` (`'blue'`) and `kAudioDeviceTransportTypeBluetoothLE` (`'blea'`)
  separately. Any transport test that checks only `'blue'` has a hole.
- **Hidden devices are out of reach and stay out of scope.** `kAudioDevicePropertyIsHidden`
  (`AudioHardwareBase.h:717`) documents that hidden devices are not in the normal device list and
  cannot become the default. Do not add hidden-device discovery.

## Decisions taken before the plan was written

Reached in a design exchange with Codex; each is a decision, not an option to revisit mid-run.

1. **The chooser lives in Acta's menu, not in System Settings.** That is what lets strict enforcement
   fight only macOS and never a human. It does **not** eliminate competing controls (troubleshooting
   docs, other audio utilities, a forgotten Acta), so Pause stays reachable and the menu always states
   that Acta is managing the input.
2. **Two distinct chooser actions.** *Use now* is a temporary override, cleared on that device's
   disconnect or on "resume automatic selection", and may select the headset. *Change priority* edits
   the persistent list. A plain click must never silently rewrite the permanent list — borrowing a
   headset for one call is not a preference change.
3. **Enforcement is continuous while enabled, not windowed.** Reconcile on **both** device-list and
   default-input notifications. An unchanged winner does not mean there is nothing to do: the built-in
   mic can remain the winner throughout a headset connection while the actual default moves.
4. **No "never auto-select Bluetooth" policy.** Rejected: it still needs persisted identity to
   survive a relaunch, "non-Bluetooth" wrongly includes BlackHole/loopback/aggregate/Continuity
   devices, observing a non-Bluetooth default does not establish the user chose it, and `'blea'`
   makes the transport test itself leaky. Instead **seed** the list on enable (see Task 7).
5. **Wire protocol goes to v2, with no compatibility machinery.** `Package.swift` declares five
   targets, none of them a CLI, and `actactl` appears nowhere under `Sources/`: every client today is
   in-process and ships in the same binary as the server. There is no deployed v1 peer to preserve.
   Set `current = 2`, `supported = [2]`, make the new field required, and write the four-case
   compatibility matrix the day `actactl` ships — not now.
6. **Three states are displayed separately**: the preferred device, the actual system default, and the
   device Acta is recording from. System Settings showing the right default does not prove Acta's
   capture followed.

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (existing tests **plus** the new policy, reconciler, directory, confinement and
  wire tests; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev`
- `grep -rn '^import\|^@[a-zA-Z]* import' Sources/ActaControlProtocol/` — still Foundation only
- ⚠️ Validation reaches nothing above the seams: no real ScreenCaptureKit capture, no TCC, no UI, and
  **no real default-input write**. See "Not verified automatically".

## Read before working

`SPEC.md`, `CLAUDE.md`, and: `SCKCaptureSource.swift` (the confinement and `makeConfiguration`),
`RecordingDependencies.swift` (and **why** its members are per-recording factories),
`RecordingSession.swift` (the composition root), `ControlDispatcher.swift` (`settingsSet` replaces
whole settings), `Envelope.swift` (`ProtocolVersion` and its forward-compat rules),
`RecordingSettings.swift`, `ControlProtocolTests.swift:362` (the one confinement that is actually a
test).

⚠️ **Facts the tasks depend on — verify before relying on them:** `RecordingDependencies` holds
`@Sendable` factories called once per `RecordingSession`; `AVCaptureDevice` currently appears in
`SystemPermissions.swift` and nowhere else; the ScreenCaptureKit and TCC confinements are enforced by
**no test at all** (only `controlProtocolSourcesImportOnlyFoundation` exists); `SCKCaptureSource.swift:5`
is `@preconcurrency import ScreenCaptureKit`.

## Scope of this plan

**In:** the CoreAudio device directory seam and its adapter; the pure selection policy; the
reconciler and its state machine; app-lifetime ownership of the reconciler; pinning
`microphoneCaptureDeviceID` for Acta's own capture and the failure policy around it; protocol v2 and
the settings field; the menu chooser; the CoreAudio confinement test; the live divergence probe; the
`SPEC.md` amendment.

**Out, and staying parked:** output-device management (this plan touches input only); hidden-device
discovery; per-app input routing; converting the ScreenCaptureKit and TCC confinements into tests
(Task 8 notes the gap without widening into it); the four-case wire compatibility matrix (decision 5).

---

### Task 1: The device directory seam and its CoreAudio adapter

**Why.** Everything else needs a list of input devices and a way to read and write the system
default. Building the seam first is what lets the policy and the reconciler be tested without a
sound card, and what keeps the HAL in one file.

- [ ] `AudioInputDevice` in **ActaKit** — a pure value: `uid`, `name`, `transport`, `inputChannels`,
      `canBeSystemDefault`, `isAlive`, `isRunningSomewhere`. No HAL types and no `AudioObjectID`: the
      ephemeral integer must not escape the adapter (it changed `140 → 181` across one reconnect)
- [ ] ⚠️ **Presence plus input channels is not availability.** Carry `kAudioDevicePropertyDeviceIsAlive`
      and decide, in this task, **how a readiness or capability change refreshes the snapshot when the
      device list itself is unchanged** — a device can stop being usable without leaving the list, and
      a directory that only watches the list will never notice
- [ ] `AudioDeviceDirectory` protocol in **ActaRuntime**: enumerate input devices, read the current
      default input, write it, and observe changes. Every operation returns an **explicit outcome**,
      never a bare value
- [ ] ⚠️ **An enumeration failure is not an empty device list, and a failed eligibility query is not
      `false`.** This is the shape of the bug measured above (a swallowed `OSStatus` reporting `0` for
      every device). Model both explicitly; a regression test must distinguish them
- [ ] ⚠️ **Listener registration can fail, and that is a third outcome** — not "registered" and not
      "no changes". A directory that silently registered nothing looks exactly like a quiet machine
- [ ] ⚠️ **Observation is broadcast, not a single stream.** Two consumers subscribe (the reconciler and
      the recording-side observer); they must not compete for events from one stream, and one
      consumer's lifetime must not end the other's subscription
- [ ] ⚠️ Query `kAudioDevicePropertyDeviceCanBeDefaultDevice` in **`kAudioObjectPropertyScopeInput`**.
      Global scope returns `kAudioHardwareUnknownPropertyError` for every device
- [ ] ⚠️ **Do not drop a device from the directory because `canBeSystemDefault` is false.** That
      property answers system-default eligibility, not whether ScreenCaptureKit can capture it. Carry
      it as a field and apply it only when choosing a system-default candidate
- [ ] `CoreAudioDeviceDirectory` — the **only** file naming a HAL symbol. Property listeners on
      `kAudioHardwarePropertyDevices` **and** `kAudioHardwarePropertyDefaultInputDevice`; names from
      `kAudioObjectPropertyName`; identity from `kAudioDevicePropertyDeviceUID`
- [ ] `FakeAudioDeviceDirectory` in the test target: scriptable device sets, scriptable read/write
      outcomes, scriptable listener-registration failure, and scriptable notification delivery **in
      either order**, duplicated, and coalesced

### Task 2: The selection policy, pure and total, in ActaKit

**Why.** The decision is the part worth freezing in tests; separating it from reconciliation is what
makes the hard cases (a temporary override expiring, no eligible device) reachable from literals.

- [ ] `MicrophonePriority` in **ActaKit**: an ordered list of UIDs plus an optional temporary override
- [ ] A **total** function from (device snapshot, preferences) to a selection outcome. The outcomes are
      distinct values, not an optional: a chosen device, **no preferred device available**, and **no
      eligible device at all**
- [ ] ⚠️ "No preferred device available" must be its own outcome, distinct from Pause and distinct from
      an error. It means *leave the system default untouched and keep watching*
- [ ] Selection for the **system default** filters on `canBeSystemDefault`; selection for **Acta's
      capture** does not use that filter. Two call sites, one function, an explicit parameter
- [ ] ⚠️ **An `.unknown`-eligibility candidate that the OS then refuses must not become a dead end.**
      Task 1 decided that an unanswered eligibility query counts as eligible, so the policy will happily
      pick such a device — but a rejected write is **not** the same as a reversal by a competitor, and
      re-selecting the same uncertain top candidate forever would prevent ever trying a known-good
      device below it. Selection must therefore be able to exclude a candidate the *write* refused, for
      this reconciliation pass, and fall through to the next one. Test it: an uncertain first candidate
      whose write is refused, and a known-good second candidate that is then selected
- [ ] Tests from literals: order respected; an absent device skipped; a present-but-not-alive device
      skipped; the override winning; the override's device gone; an empty list; a list whose every
      entry is absent; a device present but not default-eligible; an incomplete snapshot (some devices
      uninspectable) not being treated as proof that the missing device disconnected

### Task 3: The reconciler and its state machine

**Why.** This is where the fight-back problem lives. The public HAL callback carries no originator and
no "manual change" flag, so intent cannot be classified — only a policy can be chosen, and it has to
be one that cannot loop.

- [x] A reconciler in **ActaRuntime** over `AudioDeviceDirectory` + the Task 2 policy, with time from
      an **injected clock** (reuse `SelfCheckClock`'s shape)
- [x] **Serialize** reconciliation; **coalesce** bursts of notifications; **re-read the actual default
      immediately before writing**; **write only on a mismatch**; **verify after the write**. A
      notification caused by Acta's own successful write must then be a no-op
- [x] ⚠️ **Triggers include two with no HAL notification behind them at all**: a priority-list edit and
      *Use now*. Both must reconcile. The full trigger list is: enable, wake, device-list change,
      default-input change, readiness change, override expiry, **preference edit**, **Use now**
- [x] ⚠️ **Do not diff winners.** The winner can stay unchanged while the actual default moves; the
      comparison is always against the freshly read actual default
- [x] ⚠️ **A fallback selection is not evidence that the previous device left.** `MicrophonePolicy.select`
      takes no snapshot-completeness input by design, so on a partial snapshot it will happily return a
      lower-priority candidate. That must never be read as proof the override's or the current device
      disappeared: expiry and failover go through `MicrophonePolicy.presence`, whose `.unknown` exists
      for exactly this, and a pin is retired only on `.absent`. Pin the sequence here **and** at the
      capture consumer in Task 5 — a helper only protects the caller that consults it
- [x] ⚠️ **A refused candidate must not reset the error or retry history.** `select` reports
      `.allPreferredCandidatesRefused` rather than disguising a rejected write as ordinary waiting or as
      missing hardware; the reconciler must carry that through to a visible operational status, not
      fold it into "waiting for a preferred microphone". Pin both sequences: a rejected *last* preferred
      candidate must not become success, must not become ordinary waiting, and must not become
      no-hardware
- [x] ⚠️ **Coalescing must not eat the fact that a device left.** The sequence that breaks a naive
      coalescer: *override on X → X disappears → X reconnects with the same UID → coalescing delivers
      only the final snapshot, which contains X.* The override should have expired on the
      disappearance, and a snapshot-only reconciler will instead keep it alive. Preserve observed
      removals across coalescing. If **both** transitions land before any observation, say so in the
      code as a stated detection limit rather than pretending it is handled
- [x] ⚠️ **Choose the constants here, not at implementation time.** "Bound the conflict budget" is a
      wish without numbers. Fix and pin with the fake clock: the **conflict count** that trips
      suspension, the **rolling window** it is counted over, the **verification deadline** after a
      write, and the **reset rule**. Starting proposal, to be adjusted only with a stated reason: 3
      reversals within 60 s trips suspension; a write is verified within 2 s; the budget resets on
      explicit Resume, on enable, and after 5 minutes with no conflict
      — ⚠️ **adjusted during execution, with the reason, as this bullet requires.** Counting reversals
      alone does not bound enforcement: a competitor that restores its choice *before* the first
      verification read means Acta's write never visibly wins, so no reversal is ever provable, while
      each write provokes the notification that starts the next pass. A peer review reproduced nine
      writes and no suspension. A **second** setback kind was therefore added —
      `EnforcementSetback.convergenceFailure`, charged once per pass in which **any** write failed to
      verify — against the same threshold and window, and the status names which of the two suspended
      it, because sampling can prove a reversal and cannot prove intent. ⚠️ **"Any write that failed to
      verify", not "the pass ended in refusal"**: a second review found two escapes from the narrower
      rule. A preferred device whose write never converges, with a working fallback below it, ends the
      pass *settled* on the fallback; and a failed verification *read* ends it *degraded*. Both are
      correct presentations and neither may erase the fact that the write was unsuccessful — a seeded
      list normally has a fallback, so the first is the ordinary shape rather than a corner. A stale
      completion (Pause, disable, a preference edit) is the one attempt that is **not** charged: the
      user's own action must not count against them.
- [x] ⚠️ **The uncertainty hold is a question about each candidate, not about the pass.** A snapshot
      that cannot account for the device Acta is holding still permits attempting a device the user
      ranks *above* it — but if that attempt is refused, or its write never converges, the candidate
      loop must not walk past the unaccounted-for device and write something ranked *below* it. A
      refused write proves nothing about a departure and authorises nothing about the fallbacks under
      it. Both converse behaviours stay: a higher-ranked candidate is still written, and a **proved**
      departure still permits the fallback. ⚠️ And **every** terminal outcome consults the unknown held
      device, not only the ones about to write: "this Mac has no usable input" and "nothing you prefer
      is here" are claims about the hardware, and a directory that could not describe the microphone
      currently in use has earned neither. The converse is pinned too — a held device the snapshot
      *does* describe as unusable yields the real verdict, because "present and unusable" is a proved
      fact and must not be laundered into "I could not see it". The reversal is
      also consumed when charged: one displacement is one setback, however many passes can still see
      its aftermath
- [x] ⚠️ **Bounded verification must tell delayed convergence from repeated conflict.** A successful
      write followed by a briefly stale read is not a fight, and must not spend the budget
- [x] ⚠️ **"A stale result must not be applied" was imprecise, and is corrected here**: ignoring a late
      completion cannot undo an OS write already issued. The requirements are that a stale completion
      produces **no follow-up action** and **no false success published to the UI**; that after a
      preference change the *actual* result is reconciled against the *new* preference; and that after
      Pause **no compensating write is issued** to undo what was already written
- [x] The temporary override expires on its device's disconnect or on explicit resume — never on a
      timer, and never silently into the persistent list
- [x] Tests through `FakeAudioDeviceDirectory`, at minimum: both notification orders; duplicate and
      coalesced notifications; **unchanged winner with a changed actual default**; the override
      disappear/reconnect sequence above; a preference edit and a *Use now* with no HAL notification;
      a **subscription startup race** (a change between the initial enumeration and observer
      installation); the device disappearing between selection and write; a write that fails;
      **observation or enumeration failure followed by recovery** (preferences and override must
      **not** be cleared as though devices had disconnected); a write completing after Pause or after
      a new preference arrived; **Pause or disable during an in-flight write** (no subsequent writes,
      actual state stays observable); conflict-budget exhaustion and its visible suspension;
      suspension followed by explicit Resume; enforcement while idle; repeated recording start/stop
      with the reconciler running throughout
      — ⚠️ **the last two are deferred to Task 4, deliberately.** `MicrophoneReconciler` names no
      recording type and holds no controller, so "it still enforces while nothing is recording" would
      assert that a type it cannot reach did not affect it. The real question is *ownership* — one
      reconciler for the app's lifetime, surviving stop/restart — which is Task 4's acceptance, and
      `MicrophoneReconcilerTests`' suite comment says so where an executor will read it

### Task 4: App-lifetime ownership

**Why.** `CLAUDE.md` says new seams go into `RecordingDependencies` and never into a default argument.
That rule is written for **per-recording** seams — `RecordingDependencies`' members are factories, and
its own doc says a source "belongs to exactly one recording, so `.live` must mint a fresh one per
session". The reconciler must run while idle and survive stop/restart. Getting this wrong creates one
global enforcer **per recording session**.

- [x] ⚠️ **Amend the rule; do not claim it already excluded this.** The rule says "new seams", with no
      lifetime qualifier. The honest move is to add the app-lifetime exclusion to `CLAUDE.md` with the
      lifecycle evidence, not to argue the current wording anticipated it
- [x] One owner, created once for the app's lifetime, with explicit injectable wiring (a `.live`-style
      value a test can assert against — the reason `RecordingDependencies` exists as a value at all)
- [x] Name the **composition root** explicitly, the way `RecordingSession` is named as the root for
      permissions
- [x] A recording receives **shared read access** to the directory; it never constructs a reconciler
- [x] The menu reaches the manager through the **existing `ControlAPI`/`ControlState` path** — the
      transient commands (*Use now*, Pause, Resume) and the microphone status are assigned to that
      path in this task, so the executor does not have to invent a route
- [x] Record the decision and its rationale in `CLAUDE.md`, next to the existing seam rule
- [x] ⚠️ **Acceptance is behavioural, not a constructor count**: monitoring starts without the menu
      being opened and without a recording; opening and closing the menu neither stops nor duplicates
      monitoring; **both** consumers receive the relevant changes; a recording stop/restart does not
      remove the manager's subscription; shutdown unregisters the listeners

### Task 5: Pin Acta's own capture, and keep it pinned

**Why.** Feature (A). Setting the device at start is one line; the work is every transition after it.

- [x] `SCKCaptureSource` sets `microphoneCaptureDeviceID` from the resolved UID
- [x] ⚠️ **Never pass `nil` as a fallback.** `SCStream.h` makes `nil` mean "system default", which is
      exactly the silent inheritance this feature exists to end. Before recording, require either an
      available choice or an explicit **"Use system default"** action
- [x] ⚠️ **Define "Use system default" as resolve-then-pin**: read the current default, resolve it to a
      concrete UID, and pin *that*. Anything else contradicts the no-`nil` rule one line above
- [x] ⚠️ **The mid-recording rule, stated once and precisely: capture resolves its device when it
      starts or restarts, and a healthy capture is never preempted except by an explicit *Use now*.**
      So of the four transitions that could move it — a higher-priority device arriving, a *Use now*, a
      priority-list edit, and a watchdog restart — only *Use now* and the restart change a healthy
      capture in progress. This is a decision, not an omission, and it is the answer to "a checklist
      that only covers disappearance can be satisfied by an implementation that keeps the original mic
      forever"
- [x] ⚠️ **"Takes effect at the next recording" describes Acta's capture ONLY — never the preference
      change as a whole.** With feature (B) enabled, connecting that USB mic or editing the list
      reconciles the **system default immediately**, while Acta keeps its pinned recording device.
      Conflating the two would make the menu lie about (B)
- [x] ⚠️ **"Next recording" is not strictly true either, and the plan must not claim it is.** A
      watchdog restart re-resolves, so a priority change made mid-recording **can** take effect during
      that same recording once recovery happens to fire. That is acceptable — a restart is already
      paying the cost — but it must be **reported**, not silent: the user has to be able to tell why
      the device changed
- [x] ⚠️ **The rationale is about capture teardown, not about segment boundaries.** A segment boundary
      is routine here and sacrifices no crash safety; invoking "crash safety beats speed" for it would
      be wrong. The real cost of preempting a healthy capture is tearing one down and rebuilding it:
      it can leave an audio gap, it can fail outright, and it can come back with a different source
      format. That is what makes automatic preemption a bad trade, and it is the reason to write in
      the code
- [x] ⚠️ **Every device switch and every recovery goes through `AudioRecorder.restart()`
      (`AudioRecorder.swift:187`) — never a second restart owner.** It already owns
      `stop() → finishAndAdvance() → start()`, and its doc comment says the order "is the whole point
      and must not be rearranged": an awaited `stop()` delivers nothing further, so no callback can
      append while the writers advance. This binds **all** of it — a *Use now* switch, a fallback after
      loss, and the restoration after a failed *Use now* — not just one of them. A competing restart
      path would race the watchdog and Stop. One serialized capture lifecycle, shared with watchdog
      recovery and Stop
- [x] **Decided, as this task requires**: the capture pin does **not** outlive the recording it was
      issued during — it is resolved per start, and per restart. What outlives it is the *override
      itself*, which lives in `MicrophonePriority` until the reconciler expires it on that device's
      disconnect or on an explicit resume; so the next recording uses it too, which is the same
      "temporary until the device goes" promise the system default gets. A recording **ending** does
      nothing to the system-default override: ending a recording is not a statement about which
      microphone the Mac should prefer.
- [x] ⚠️ ***Use now* is ONE user action with TWO effects, and the plan says so rather than leaving the
      executor to guess.** It is (i) a temporary override of the **system-default** priority, held by
      `MicrophonePriority` and expired by the reconciler on that device's disconnect (Tasks 2-3), and
      (ii) an immediate switch of the **live capture** device, if a recording is running (this task).
      They differ in eligibility — capture does not filter on `canBeSystemDefault`, the system default
      does — so **one click can legitimately land on only one of the two**, which Task 7 already
      requires the menu to show. Decide and state here: whether the capture pin outlives the recording
      it was issued during, and what a recording ending does to the system-default override. Neither
      is derivable from the rest of the plan
- [x] ⚠️ **An explicit *Use now* that fails while the old microphone is still usable needs a defined
      outcome.** Attempt to restore the previous device through the **same serialized recovery path**,
      report that the requested switch failed, and **never show the requested device as active before
      capture actually succeeds**. Bound the attempts
- [x] During a recording, losing the pinned microphone is a **recording failure surfaced immediately**
      through the existing failure policy — not a quiet menu note. Try the configured alternatives
      first; if none work, report loss. ⚠️ **The watchdog is not this**, and assuming it was is why the
      recording-owned observation was missing at first: `TrackWatchdog` reads a track's count not
      increasing as ordinary source silence, and the system track keeps advancing when only the
      microphone goes, so a lost headset produced no stall at all
- [x] Any new message the controller writes into `errorMessage` goes into **`ControllerMessage`**, not
      hand-typed (the reverse lookup in `ControlState+Mapping` reads it)
- [x] ⚠️ The `CaptureSource` contract test must state what the fake does **not** prove here: the fake
      accepts any UID, and `SCKCaptureSource`'s acceptance of one is unverified in-process. Skip
      visibly with `.enabled(if:)` where the real source needs a live `SCStream` — never a bare `return`
- [x] Tests through the scripted pipeline: a mic switch **racing** a watchdog restart, and one racing a
      user Stop; the first candidate enumerating but **failing to start** while the next succeeds; **no
      candidate succeeding**, with recovery terminating within a defined bound
- [x] A switch between devices of **different source formats** leaving every segment valid and
      consistently formatted. ⚠️ **My earlier note here was false and is corrected rather than
      softened**: I wrote that this needed a fixture the task had not built, when
      `FakeCaptureSource.setFormat` and `FixtureAudioFormat(sampleRate:channels:)` both already existed
      — I did not look before writing the reason down. A peer review built it, saw a failure, and then
      traced that failure to **its own sandbox** rather than to Acta, so the code was right and only my
      excuse was wrong. The test now exists and passes. It is **skipped by default, visibly**, because
      the one case costs ~59 s and starves a timing-sensitive pipeline test into failing about half the
      time: `ACTA_SLOW_TESTS=1 bash Scripts/test.sh`. That cost is a separate finding, in
      `docs/backlog/slow-non-48k-segment-writing.md`, and it matters — the AirPods measured 24 kHz,
      which is exactly the format that is slow

### Task 6: Protocol v2 and the settings fields

**Why.** Decision 5. The work is the version bump and the tests that keep the exact-version rule
honest — not compatibility adapters.

- [x] `RecordingSettings` gains **both** new fields — the priority list **and** the enable flag — with
      `Field` cases and `merging(_:)` coverage, matching the existing anti-clobber pattern
- [x] ⚠️ **A third field was added, and this is the stated reason.** `captureMicrophoneChoice` is not on
      this checklist because it did not exist when the plan was written: Task 5 turned "use the system
      default" into an explicit resolve-then-pin *choice*, and a choice that resets at every relaunch is
      not a setting. Adding it in Task 7 instead would have meant a second required wire field and so a
      second protocol bump, for a field that could ride this one
- [x] `WireSettings` gains **both** fields as **required**; `ProtocolVersion.current = 2`,
      `supported = [2]`, and a test asserts exactly that
- [x] ⚠️ **Update the fixtures that use `2` as the deliberately unsupported version** — and know that
      they do **not** all fail loudly. Verified: `aVersionMismatchIsReportedWithItsIDPreserved`
      (`ControlProtocolTests.swift:291`) and the **response** half of
      `aNonCurrentVersionIsRejectedOnBothResponseAndEvent` (line 354) start **failing**, so they cannot
      be missed. The **event** half (line 355) is quiet: its payload `{"event":{}}` still throws after
      the bump — for being an undecodable `WatchEvent`, not for its version — so it keeps passing while
      testing nothing it was written to test
- [x] ⚠️ **Two more tests go quiet, and they guard the sharper bug.**
      `aResponseCarryingNeitherAResultNorAnErrorIsRejected` (line 330) and
      `aResponseCarryingBothAResultAndAnErrorIsRejectedRatherThanReadAsSuccess` (line 342) both pin
      `"version":1` and assert only that decoding throws. After the bump both throw at the **version
      check**, before envelope exclusivity is ever evaluated — and the second one is the test whose own
      comment calls it "the one that actually bites", because reading `result` first renders a server's
      error as `ok`. **Move every payload-validation fixture to v2**; only the version-rejection tests
      keep a non-current version
- [x] ⚠️ **Version-rejection tests must use otherwise-valid payloads.** Flipping `{"event":{}}` to
      another version leaves the test weak: delete the version check entirely and it still throws
- [x] ⚠️ **Test a v2 settings payload with a required microphone field missing** — that is what
      "required" is supposed to mean, and nothing else asserts it
- [x] ⚠️ **`RecordingID`'s `"v1:"` prefix stays untouched** (`RecordingID.swift:17`). It is an
      independent frozen encoding version, not the protocol version; renaming it would invalidate every
      stored id for no reason
- [x] ⚠️ **Phrase acceptance around the boundary that exists.** The codec returns `.versionMismatch`;
      no production caller constructs its wire reply today. Do not write acceptance that assumes
      response routing unless this plan deliberately adds it — it does not
- [x] ⚠️ **Persisted on-disk settings migration is separate from the wire version.** An old config
      decodes with the new fields defaulted; the wire fields stay required
- [x] `ControlDispatcher.settingsSet` still replaces whole settings — no new semantics
- [x] ⚠️ Adding a **case** to any response-direction enum is still a version bump, not an additive
      change. This task adds fields, not cases; keep it that way

### Task 7: The menu chooser and the states it must not blur

- [ ] The input chooser in Acta's menu, with **Use now** and **Change priority** as distinct actions
      (decision 2)
- [ ] Display the three states separately (decision 6): preferred, actual system default, Acta's
      recording device. Never collapse them when they differ
- [ ] ⚠️ **The recording-only user must have a defined startup flow.** The list defaults empty, seeding
      happens only when feature (B) is enabled, and capture refuses an unresolved microphone — so
      someone who never enables (B) otherwise falls into an unspecified state. Add acceptance for a
      **fresh install** and for **migrated settings**, both with (B) disabled: the user can select or
      accept a recording microphone without enabling system management
- [ ] **Seed, do not invent.** On enabling (B), propose the current suitable physical microphone, with
      the built-in as fallback; if the current input is Bluetooth, propose the built-in
- [ ] ⚠️ **Define "suitable physical microphone" in this task**, in terms of the Task 1 fields
      (transport, alive, input channels, default-eligibility) — not as prose. And define what happens
      when **no built-in microphone exists**
- [ ] ⚠️ **Seeding must never overwrite an existing list**, and an existing list must survive a
      disable/re-enable cycle
- [ ] **"Managing Mac input"** stated in the menu whenever (B) is on, with **Pause** always reachable
- [ ] ⚠️ **Pause suspends global enforcement only.** Acta's own capture selection stays fully
      operational while paused — they are different promises and must not share a switch
- [ ] ⚠️ **A *Use now* selection that is capture-eligible but not default-eligible needs an explicit
      result while (B) is on.** Decide it here: Acta's capture follows, the system default does not,
      and the menu says so. ⚠️ **Name no examples without measuring them first** — an earlier draft
      cited BlackHole and the aggregate here, which the measured-facts section of this very file
      refutes: both returned `1` for input-scope `canBeDefaultDevice`. The one device measured at `0`
      was the Teams loopback driver, and whether ScreenCaptureKit will capture *that* is unverified,
      so it is not an example either
- [ ] **"Waiting for a preferred microphone"** shown distinctly from **Paused** and from an error
- [ ] With (B) disabled, the chooser must read unambiguously as **Acta's recording input only**
- [ ] (B) is **opt-in, off by default** — it changes state other applications depend on
- [ ] `ControlViewModel` keeps the existing optimistic-write-plus-reconcile shape; assert only through
      the public surface

### Task 8: The CoreAudio confinement, as a real test

**Why.** `CLAUDE.md` calls three confinements "grep-enforceable", but only
`controlProtocolSourcesImportOnlyFoundation` is a test; the ScreenCaptureKit and TCC rules are held by
a human remembering to run `grep`. The new rule gets a test rather than joining the honour system.

- [ ] A test asserting CoreAudio HAL symbols appear only in `CoreAudioDeviceDirectory.swift`
- [ ] ⚠️ **Do not copy the existing parser unchanged.** It matches `trimmed.hasPrefix("import ")`, so
      `@preconcurrency import CoreAudio` is invisible to it — and `SCKCaptureSource.swift:5` proves that
      form is in use here. Fix the same hole in the existing
      `controlProtocolSourcesImportOnlyFoundation` while here: today a `@preconcurrency import AppKit`
      under `ActaControlProtocol/` would **pass** it
- [ ] **Parser fixtures**, so the guard's own correctness is tested rather than assumed: an attributed
      import is caught, and an import named in a comment is ignored
- [ ] Guard **HAL symbol use**, not only imports — a transitive framework import can expose the API with
      no `import CoreAudio` line at all
- [ ] Define precisely: which directories are production, which single file is the allowed adapter, and
      which HAL API families are guarded. Do **not** forbid unrelated audio buffer types
      (`CMSampleBuffer`, `AudioBufferList` in the writer) merely for belonging to audio frameworks
- [ ] Match type references, not prose — doc comments legitimately name these APIs. Move the comment
      rather than contorting the code
- [ ] Converting the ScreenCaptureKit and TCC rules into tests stays **out of scope**; note the gap in
      `CLAUDE.md` so the wording stops overstating what is enforced

### Task 9: The live divergence probe

**Why.** The whole design rests on one measured equality that Apple documents nowhere as a single
identity. If a future macOS diverges, everything still compiles and the wrong microphone is recorded —
or capture fails outright, since a UID `SCStream` rejects is as broken as one it misroutes.

- [ ] A probe that enumerates **both** APIs live and compares the devices present
- [ ] ⚠️ **Deriving both sides from the HAL proves nothing**, and a fake or a recorded fixture cannot
      detect future divergence. It must be two independent live observations
- [ ] ⚠️ **Distinguish the two negative results, and never merge them.** A device that was enumerated
      and expected but whose identity does **not** correspond across the APIs is a **failure**. Test
      hardware that is simply absent (no Bluetooth device connected) is **incomplete coverage**,
      reported visibly through `.enabled(if:)`. Classifying a genuine discrepancy as "missing — skip"
      is the one outcome that would defeat the probe's purpose
- [ ] **Specify the matching procedure, the command that runs it, and the result categories** — the
      probe is only useful if a human can run it deliberately and read its verdict
- [ ] It lives outside production sources, with its scope explicitly excluded from the Task 8
      confinement (it must import `AVFoundation` by design)
- [ ] ⚠️ State the claim honestly in the test's own doc comment: "detects divergence on the devices
      exercised", **not** "guarantees compatibility with future macOS". UID equality also does not
      prove ScreenCaptureKit captured the intended microphone — that stays in manual acceptance

### Task 10: Documentation

- [ ] **`SPEC.md`: amend the "only records" scope explicitly**, stating feature (B), its promise
      ("while Acta is running, the Mac's default input stays on your list"), that it is opt-in, and what
      it does not promise (per-app input pickers)
- [ ] `CLAUDE.md`: the app-lifetime seam **amendment** (Task 4); the corrected confinement wording
      (Task 8); the measured-identity dependency and the probe that guards it (Task 9); the
      `canBeDefaultDevice` scope trap and the swallowed-`OSStatus` failure mode
- [ ] English only — `grep -rP '[\x{0400}-\x{04FF}]' --exclude-dir=.git --exclude-dir=.build .`

## Not verified automatically (needs a human)

The seams end below all of this; the suite proves the decision logic and none of the OS behaviour.

- **A real default-input write.** No test writes `kAudioHardwarePropertyDefaultInputDevice` on the real
  machine: System Settings must be seen to follow, and to keep following across a headset
  connect/disconnect cycle and across sleep/wake.
- **That ScreenCaptureKit honours `microphoneCaptureDeviceID`.** The fake accepts any string. Only a
  TCC-authorized build recording from a deliberately non-default microphone, and the resulting audio
  being listened to, proves the pin took effect.
- **Live microphone failover during a real recording** — the pinned device pulled out mid-recording, and
  the next candidate actually producing audio rather than silence.
- ***Use now* during a real recording** — that the switch happens, that the segments on both sides of it
  are valid, and that the assembled file is not broken by a format change.
- **That a real sleep/wake reconciles.** `MicrophoneManager` installs `NSWorkspace.didWakeNotification`
  as the app-lifetime wake source — until Task 4 the reconciler's `wake` trigger had **no production
  caller at all** and existed only as an endpoint. ⚠️ An earlier draft of this bullet claimed the
  handler could not be tested without sleeping a Mac. **That was wrong**: a synthetic post into an
  injected notification centre exercises the installed handler, and the suite now does exactly that
  (`aWakeReconcilesWhatSleepHid`), which is how it was discovered that replacing the handler's body
  with a no-op had passed every test. What genuinely needs a human is the OS behaviour around it: that
  macOS posts the notification, and that the device world after a real sleep is what the reconciler
  then finds.
- **That the production HAL listeners actually fire.** The observation tests drive the *fake*; they
  establish the contract's shape, not that `CoreAudioDeviceDirectory`'s registrations deliver. Only
  plugging a device in and out on a real Mac shows that — and it is the same gap as
  `SCKCaptureSource`'s: the seam is what makes everything above testable, and the seam's own floor is
  not.
- **That the fight-back policy is livable.** Whether enforcement feels correct or hostile when the user
  reaches for System Settings anyway — and whether the conflict budget suspends at the right point.
- **Microphone release on stop, again.** Task 5 changes the stream configuration; Gotcha 4 in the
  `screencapturekit-audio` skill applies unchanged, and a regression there is silent.
