---
worth: yes
where: Sources/ActaRuntime/ReminderCoordinator.swift:176
added: 2026-09-12
---
# a long-running instance stopped noticing huddles, and a fresh one notices immediately

## What was observed

On 2026-09-12 the microphone-activity reminder did not fire for **two real Slack huddles** — one at
13:22 and one at 13:38:59–13:40:34, the second lasting 95 seconds. The preference was on
(`offersRecordingWhenMicrophoneBusy = true`, verified by decoding the stored settings blob), nothing
was excluded, and the running build contained the episode-mint logging. Nothing was logged.

That instance had been running since **09:57:57**.

A fresh instance launched at 13:53 was then given the same test at 15:22 and behaved perfectly:

```
15:22:19.794  observed 35 processes, complete=true, holding=[com.tinyspeck.slackmacgap.helper]
15:22:21.943  observed 35 processes, complete=true, holding=[]
15:22:23.043  observed 35 processes, complete=true, holding=[com.tinyspeck.slackmacgap.helper]
15:22:26.357  episode 1 minted — bundle=com.tinyspeck.slackmacgap.helper display=<none> process=Slack Helper
15:23:08.070  observed 35 processes, complete=true, holding=[]
```

The prompt appeared on screen. Same code, different outcome — so this is **state, not logic**.

⚠️ **It is `episode 1`.** The fresh instance had minted nothing in the ninety minutes before the test,
which is expected on an idle machine. But it also means the older instance's silence cannot be
attributed to an exhausted or wedged episode counter that we can see: nothing about that instance's
internal state was captured before it was killed, and it is gone.

## What is NOT established

⚠️ **My first diagnosis — "the feature is broken" — was wrong, and the check behind it was invalid.**
I confirmed the running build had the mint logging by running `strings` on the on-disk binary. By then
the binary had been rebuilt several times; I was inspecting a different build from the one that had
been running. The silence was real, the conclusion drawn from it was not.

Candidate causes, none of them measured:

- **The poll task stopped.** `ReminderCoordinator.start()` drives `tick()` from a `Task` looping on
  `try? await Task.sleep(for: pollInterval)`. If that task ends or is starved, everything downstream is
  silent and indistinguishable from "nothing happened" — the diagnostic logs only on *change*, so an
  absent tick and an idle machine look identical.
- **App Nap.** The app is `LSUIElement` with no window open for hours at a time, which is the shape
  macOS throttles. This is a hypothesis from the app's configuration, not an observation.
- **A wedged rule.** If `standingOffer` were left set on an episode that stayed actionable,
  `offerIfQualified` would never be reached — `observe` returns early on the withdrawal check. No
  mechanism for that was found by reading, and the mint log would have recorded the offer that set it.

## What would settle it

A **heartbeat**: log every N ticks regardless of change, at debug level. Then "the tick is not running"
and "nothing is holding the microphone" stop looking the same, which is the single thing that made this
undiagnosable. Add it before the next long-uptime session rather than after.

## Why it matters more than an ordinary intermittent

The whole feature exists for the moment when the user is *not* interacting with Acta — a huddle starts
while they are doing something else. An instance that works for the first hours and goes quiet
afterwards is failing in exactly its own use case, and it fails **silently**: nothing is shown, so
there is nothing to report except "it didn't happen".
