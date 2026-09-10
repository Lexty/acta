# The suite is ~30% flaky at HEAD: two permission tests race the watchdog on a shared clock

**Not microphone-priority work.** Parked out of `docs/plans/2026-09-09-microphone-priority.md` on the
user's call, because it is not small and it is not that plan's subject. Promote it on its own.

## Why it matters more than a flake usually does

`Scripts/test.sh` is the validation gate for every task in every plan. While this stands, **"the tests
pass" is a green sample from a red distribution** — which is exactly how it was reported, repeatedly,
during Task 1 of the microphone plan before anyone measured it.

## Measured, not estimated

- **Baseline at `HEAD` (f5590c6..c90f357 era), idle machine, full suite: 3 failing runs out of 10.**
- Under CPU load (six `yes` processes on this Mac): **7 failing runs out of 12**.
- Five consecutive green runs happened first and proved nothing. External review reported the failures
  twice before they were reproduced here.

The two tests, both in `Sources/ActaTestRunner/RecordingPipelineFailureTests.swift`:

- `aPermissionRevokedDuringTheStartupProbeIsDiagnosedRatherThanRestartedAround` — fails the
  `#expect(throws:)` **and** `screenRequestCount == 1`, with the count at `0`.
- `eachPermissionDialogIsTrackedSeparatelyWhenBothGoMissingAtOnce` — both request counts `0` instead
  of `1`.

## Mechanism, as far as it was traced

`TestClock` carries **one** `onSleep` handler, and the startup probe and the watchdog **both sleep on
that clock**. A test keying its effect on "the first sleep" is really keying on whichever of the two
the scheduler reached first — the probe on an idle machine, often the watchdog's 1 s tick under load.

In `eachPermissionDialog…` the non-first branch calls `source.emitBatch()`, so a watchdog tick landing
**inside the probe window** feeds the probe. `SelfDiagnosis` clears a snapshot whose data is flowing
*before* it looks at permissions — a live recording is fine whatever TCC now says — so neither dialog
is ever shown and both counts stay `0`.

## The attempted fix, and why it was reverted

`startupProbeSeconds` is `2.0` and `watchdogTickSeconds` is `1.0`, so the probe's sleep **is**
distinguishable by duration; a `TestClock.onStartupProbeSleep` helper was added and both tests keyed to
it. Result: `eachPermissionDialog…` was fixed (0 failures in 12 loaded runs), and
`aPermissionRevoked…` **got worse** — from occasional to 3 failures in 4 idle runs.

⚠️ **Revoking on every sleep is load-bearing in that test.** `SelfCheck` evaluates `missingPermission`
at the top of its loop, *before* `probeDataFlow`; revoking only inside the probe window changes which
branch diagnoses the failure and whether the dialog is requested at all. The whole attempt was reverted
rather than left as a half-fix.

## The open question that decides the shape of the fix

**Is the residue only a test defect?** Tracing stopped short of proving it. If `SelfCheck`'s *restart*
path can genuinely lose a permission revocation — re-entering `AudioRecorder.start()`, which rejects a
start whose permissions are already missing, and surfacing a different failure with no dialog — then
this is a **product bug wearing a flake's clothes**, and the tests are reporting it correctly and
intermittently. Answer that first; the fix is a different piece of work in each case.

## Where to start

- Give `TestClock` a way to name the event a test means, rather than requiring it to guess by position
  — the duration key works, it just is not sufficient on its own.
- Then decide per test what it actually intends: "revoked at some point during startup" and "revoked
  precisely inside the probe window" are different scenarios, and the two tests want different ones.
- Re-measure over **at least 10 full-suite runs**, idle and loaded. A single green run means nothing
  here; that mistake is the reason this file exists.
