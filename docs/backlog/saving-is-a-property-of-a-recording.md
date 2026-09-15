---
worth: later
where: Sources/ActaRuntime/ControlState.swift:239
added: 2026-09-12
---
# `.saving` blocks the next start: saving should belong to a recording, not to the app

The user's requirement, from `per-application-autonomy-modes.md`: after stopping a multi-hour recording,
the next one must be startable **at once** — leave a three-hour call, stop, join the next one.

**It is not satisfied today.** `ControlState.canStart` is `operation == .idle`, and `.saving` is an
operation, so a start is refused for as long as the previous recording's segments are being assembled.

⚠️ **How long that is has not been measured.** A 90-second recording assembled in about 570 ms; assembly
is concatenation, so a three-hour recording suggests something like a minute. That is arithmetic on one
data point. **Record a long session and time the stop before designing anything** — if the number is a
few seconds, this item is not worth its concurrency.

## Cut from the owner-bound stop offer, and why

It was in the first draft of `docs/plans/completed/2026-09-12-owner-bound-stop-offer.md`. Both reviewers
(the planning plugin's `plan-review` agent and Codex), independently, said it does not belong there —
"a concurrency refactor wearing a prerequisite's clothes". Their four boundaries are what a plan for it
has to answer:

1. **The state cannot express it.** `canStart` and `hasWorkInFlight` (`ControlState.swift:233`, `:239`)
   derive from **the same** `Operation` enum, so "a start is allowed **and** work is in flight" needs new
   state. The draft's two warning bullets — start must be allowed while saving, quit must still wait for
   saving — were mutually unsatisfiable on the current type.
2. **It is a wire change.** `can_start` and `operation.kind` are on the wire, and `AGENTS.md` says adding a
   case to `Operation.Kind` or `RecordingSummary.Status` within v1 is a version bump, not an additive
   change. It needs its own protocol review.
3. **The controller holds one of everything.** `RecordingController` has one `session`, one
   `currentDirectory`, one `isStopping`. Concurrency means several, and the hazard is concrete: recording
   A finishing while B records, with A's teardown erasing B's state or writing B's metadata into A's
   folder.
4. **Nothing else waits on it.** The release offer works while saving still blocks the next capture. The
   one ordering argument the first draft gave — that unblocking `.saving` would let Acta's own
   `com.apple.replayd` capture mint an offer — was false: the start rule spends every qualified key before
   its `isBusy` guard, so replayd is `.spent` about three seconds into every recording. Corrected in
   `b4dfe4a`.

Constraints any design keeps: the archive listing must not show a half-assembled recording as done;
quitting still waits for every piece of work in flight; recovery must attribute an interrupted assembly to
its own folder, not to the recording that started after it.

The plan, when there is one: `docs/plans/YYYY-MM-DD-saving-is-a-property-of-a-recording.md`, with the
long-recording measurement as its first task.
