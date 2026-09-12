---
worth: yes
where: Sources/ActaKit/MicrophoneActivityRule.swift:518
added: 2026-09-12
---
# per-application autonomy: bind a recording to the app that triggered it, and let the prompts teach Acta what to do next time

## The proposal, as put

Proposed by the user on 2026-09-12, in full and without condensing:

- Acta can already see a **specific application releasing** the microphone. Use that as the trigger for
  the stop prompt, not only the quiet-audio rule.
- For that to work, a recording started from a prompt must be **bound to the application** that caused
  the prompt.
- When that application releases the input, show a stop prompt — with a second button, **"always stop
  automatically for this app"**.
- Once that is on, the next time becomes a prompt carrying a **countdown to the automatic stop**, which
  can be cancelled.
- This is a mode **per application**, remembered for that application.
- The intended shape, in the user's scenario: a Slack huddle starts → the start prompt appears → press
  Start → the recording is bound to Slack → Slack releases the microphone → the stop prompt appears,
  carrying "always stop automatically for this app".
- The same for **starting**: the start prompt carries "always start automatically for this app". After
  that, the next time Slack takes the microphone the prompt is no longer a question — it says a
  recording **has started**, and carries **Cancel**, where cancel means stop *and delete what was
  already recorded*.
- The end state for an application in full auto: any microphone acquisition starts a recording and any
  release ends it, with nothing for the user to do — and **the prompt can always cancel the action at
  any moment**.
- Same for Teams and anything else: each application's behaviour is configured **from the prompts
  themselves**, not from a settings screen.

## Is it viable — assessment, 2026-09-12

**The signal exists.** `MicrophoneActivityRule` already tracks a phase per key, and `.releasing` is
exactly "this application dropped the input". The withdrawal path added in `b95ebdd` is driven by it.
Nothing new has to be observed for the *stop* half.

**The load-bearing unknown is attribution, and it is measurable.** The whole design says "remember this
for *this application*", which needs a stable identifier. Two facts bear on it, and they are not
encouraging:

- In the user's own test that day the prompt read **"Microphone activity detected"** with no
  application name. By the rule's own contract that means `displayName` was nil — the holder was not a
  *regular* application, i.e. a helper process. Whether it carried a `bundleID` is **unknown**: nothing
  logs it.
- `AudioProcessObservation` already distinguishes bundle-keyed from PID-keyed processes
  (`Key.bundle` vs `Key.process`). A PID-keyed holder has nothing durable to remember: a mode keyed on
  a PID is worthless the moment the helper restarts.

⚠️ **Settle this first, by measurement, before designing anything.** Log the key (`bundle:` vs `pid:`)
and the bundle identifier of the holder at the moment an episode is minted, then start a Slack huddle
and a Teams call and read it back. If huddles are held by a helper with no bundle identifier — or with
one shared across every Slack feature — the per-application memory has nothing to hang on and the whole
proposal needs a different anchor.

**`source` in `info.md` is not attribution today.** `MeetingSource.detect(fromRunningApps:)` guesses
from the list of *running* applications, not from who holds the microphone. "Telegram" appears in
recordings because Telegram was running. Binding a recording to an application means introducing real
attribution, not reusing this field as if it already were one.

**Release is not the end of a call.** A device handoff — AirPods connecting, a headset switching —
releases and re-acquires within seconds. That is precisely why the episode survives a release for the
re-arm window. An automatic stop that fires on the first release would cut a meeting into pieces, so
the countdown must be at least as long as the re-arm and must be **cancelled by re-acquisition**, not
only by the user.

**This reverses a rule the feature was built on, and that must be an explicit decision.** `AGENTS.md`
states that nothing acts on its own — every start and stop begins with a click, and a timer may
withdraw a prompt but never answer one. Full auto for an application is the opposite. The proposal's
own mitigation (a countdown that can always be cancelled) is the right shape, but whoever picks this up
must change that rule deliberately and in the same commit, rather than leaving the document contradicted
by the code.

**Cancel-and-delete is a destructive path and needs its own care.** Segments are written continuously
for crash safety; a cancel must not race the assembler, and "delete what was recorded" must not be
reachable for a recording the user started by hand.

**Open questions not answered by the statement:**

- Two applications hold the microphone at once — which owns the recording, and what happens when only
  one of them releases? The rule offers one episode at a time (`standingOffer` is single).
- A recording bound to an application, where the user then stops it by hand, or where the app releases
  while the user is still talking to someone in the room.
- Where per-application modes live. `reminderExcludedBundleIDs` is the precedent: a per-app list in
  `RecordingSettings`, deliberately **absent** from `WireSettings`. A mode map should follow it, so a
  socket client cannot arm auto-recording on someone's machine.
- Whether the "always" buttons on a prompt are discoverable enough to also be *un*-settable there, or
  whether the Settings window needs a Reminders list of per-app modes to undo them.

## Not to be confused with

The existing quiet-audio stop rule, which is about measured silence and stays useful when the holder
never releases (a call left open). These are two independent triggers for the same prompt.
