# The suite is ~30% flaky at HEAD: two permission tests never establish their own no-data precondition

**Not microphone-priority work.** Parked out of `docs/plans/2026-09-09-microphone-priority.md` on the
user's call. ⚠️ **The fix turned out to be two lines** once the cause was actually found (see below) —
worth re-deciding whether it still belongs in a backlog.

## Why it matters more than a flake usually does

`Scripts/test.sh` is the validation gate for every task in every plan. While this stands, **"the tests
pass" is a green sample from a red distribution** — which is exactly how it was reported, repeatedly,
during Task 1 of the microphone plan before anyone measured it.

## Measured, not estimated

- **Baseline at `HEAD`, idle machine, full suite: 3 failing runs out of 10.**
- Under CPU load (six `yes` processes): **7 failing runs out of 12**.
- Five consecutive green runs happened first and proved nothing.

The two tests, both in `Sources/ActaTestRunner/RecordingPipelineFailureTests.swift`:

- `aPermissionRevokedDuringTheStartupProbeIsDiagnosedRatherThanRestartedAround` — fails the
  `#expect(throws:)` **and** `screenRequestCount == 1`, with the count at `0`.
- `eachPermissionDialogIsTrackedSeparatelyWhenBothGoMissingAtOnce` — both request counts `0`.

## The cause — observed in an isolated executable, not inferred

`FakeCaptureSource.start()` emits an initial batch and drains both delivery queues
(`CaptureTestFixtures.swift`, `emitOnStart` defaults to `true`). Those accepted buffers are already in
the probe's **baseline**, so the probe legitimately sees `received=0, written=0` — but the
**filesystem growth from those same earlier appends still lands inside the probe window**. A traced run
of the screen-revocation scenario printed:

```
TRACE received=0 written=0 bytes=192000 screen=false mic=true
RESULT emit=true both=false run=1 result=nil screenRequests=0 micRequests=0 starts=1
```

`Diagnostics.isDataFlowing` accepts `segmentBytesDelta > 0`, and `diagnose` returns **healthy before it
ever looks at `hasScreenRecording`**. So startup certifies success, no dialog is requested, and both
counts stay `0`. Whether the bytes land inside the window is a timing question — hence the flake.

**So the tests never establish their own stated precondition**: they mean "the probe finds no data", and
they only arrange "the probe receives no new callbacks".

## ⚠️ A wrong diagnosis was recorded here first — do not resurrect it

The first version of this file blamed `TestClock`'s single `onSleep` handler being shared by the startup
probe and the watchdog, with a watchdog tick winning the race. **That is impossible**, and verifying it
takes ten seconds: `RecordingSession.swift:117` awaits `verifyStartAndHeal()` and only creates
`watchdogTask` at `:125`, *after* it returns. There is no watchdog during the startup probe. The
duration-keying fix built on that theory fixed one test by accident and took the other from occasional
to 3 failures in 4 idle runs; it was reverted.

## The fix

`source.setEmitOnStart(false)` in **both** scenarios, so the first probe is genuinely empty on every
signal rather than merely empty of new callbacks. Keep the first test revoking on every sleep; keep the
second revoking and resetting once, then emitting only in later probes after the dialogs have granted.

A controlled run of four cases per scenario with `emitOnStart=false`: every first snapshot had
`received=written=bytes=0`; the denied-screen case requested once, returned the expected failure and
stayed at one source start; the both-granted case requested both once and succeeded on the next probe.

Two smaller repairs to make at the same time:

- **Stop the session if the first test unexpectedly succeeds.** Its `#expect(throws:)` can fail while
  leaving a started session and watchdog unclosed — failure-path cleanup must not depend on the
  assertion being true.
- Add a negative control that suppresses the microphone request flag independently; it must still fail
  the second test.

## The product question, which is genuinely separate

The behaviour underneath is **not imaginary**: pending disk growth really can let startup certify
success after a permission changed, with no new capture buffers. That is a limitation of the
deliberately data-first diagnosis `SPEC.md:133` describes ("confirm data is actually flowing… if not,
determine the cause"), not a bug in the fixtures.

If the intended promise is "a known-missing permission must block startup even when old bytes land",
that is a **precedence change in `Diagnostics.diagnose`** and needs its own decision and its own
deterministic test. ⚠️ **Do not suppress the initial emission in the tests and call that behaviour
fixed** — the fixture repair makes the tests test what they claim; it does not change the product.

## Two hypotheses that were checked and are dead

- **"The restart path loses a permission revocation."** No bypass exists: `AudioRecorder.restart()`
  ends in `start()`, `start()` calls `requestPermissionsIfNeeded()` before `source.start()`, and
  `SelfCheck.attemptRestart()` forwards permission failures as fatal. If flow stops after an initially
  successful probe, the watchdog reaches that gate and reports the missing permission.
- **"The watchdog races the startup probe."** See above — the watchdog does not exist yet.
