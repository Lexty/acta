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

## Is it viable — assessment, 2026-09-12, corrected the same day

**Yes, as explicitly enrolled per-application automation — not as a call detector.** That distinction is
Codex's and it is the right frame: what can be observed is an application using microphone input, which
is not the same claim as "a meeting is happening".

⚠️ **Four claims in the first version of this assessment were wrong. They are corrected here rather
than deleted, because each was believed and acted on.**

1. **"No application name means the holder was a helper" — false.** `resolveNames` returns nil in three
   distinct cases: `NSRunningApplication(processIdentifier:)` does not resolve the pid and nothing is
   cached, `localizedName` is nil, or `activationPolicy != .regular`. Only the third is "a helper".
2. **The prompt that had no name was not evidence about huddles at all.** The user identified what was
   holding the input at that moment: **the System Settings microphone pane**, whose level meter opens
   the input. So the one observation the original assessment reasoned from was not a Slack huddle, and
   says nothing about how a huddle is attributed. It does, however, surface a false-positive class the
   proposal never mentioned — see below.
3. **"A shared identifier is nothing to hang on" — false, and it answered the wrong question.** The
   proposal asks for behaviour *per application*. An identifier shared across all of Slack's audio use
   supports exactly that: "always record when Slack takes the microphone". It does not support "Slack
   huddles only", which is a different and narrower claim. A stable bundle id, a recognisable product,
   and a particular call are three separate things and the assessment ran them together. What genuinely
   has nothing durable to remember is a **PID-keyed** holder.
4. **"The countdown must be at least as long as the re-arm" — does not follow.** Thirty seconds was
   chosen to stop repeated offers; it was never measured as a bound on device handoffs or on call
   endings. Release qualification, the time a person needs to cancel, and the re-arm before the next
   offer are three independent policies that may share a number deliberately, but no finite grace
   proves a call ended.

**And one structural correction that matters more than the other four.** The original assessment said
the release signal already exists and nothing new has to be observed. That is wrong at the level of the
public contract:

- `acceptStart` calls `offerResolved`, which clears `standingOffer`; the withdraw path requires
  `standingOffer`. **So once a start is accepted, that episode never produces a release event again.**
- `tick` only calls `reader.readSnapshot()` inside `if settings.offersRecordingWhenMicrophoneBusy`, so
  with the start reminder off there are no observations at all — yet release-stop could reasonably be
  wanted with auto-start off.
- Re-arm expiry deletes the episode and a wake resets the whole rule.

The rule is a **prompt qualifier**, not a session-owner observer. Owner tracking has to be separated
from prompt qualification, with its own held / released / unknown evidence and its own freshness. In
particular: ⚠️ **do not infer "released" from `!isEpisodeActionable`.** At `b95ebdd` that predicate also
carries policy and history distinctions, and deliberately tolerates an unreadable reading after a spent
one — appropriate for admitting a human click, wrong for arming an automatic action.

**`source` in `info.md` is not attribution, and this is now demonstrated rather than argued.**
`SourceDetector` collects the names of every running `.regular` application and `MeetingSource.detect`
returns the first match in a fixed priority list (zoom, teams, webex, slack, discord, skype, facetime,
telegram, whatsapp, meet). Nothing consults the microphone. The proof is in the archive: the recordings
made on 2026-09-12 carry `source: "Telegram"` while the application actually holding the input was the
System Settings microphone pane. With Zoom merely open in the background, a Telegram call would be
titled "Zoom". Binding means introducing real attribution; this field cannot be reused as if it were
one, and Codex is right that it should stay the separate heuristic it is.

**A false-positive class the statement did not cover.** The System Settings microphone pane raised a
"record this call?" offer. So do, presumably, an application's own microphone-test screen, dictation,
and recording a voice message. Manual prompts tolerate this — the user simply declines. **Automatic
start does not**: enrolled auto-record would start a recording every time the user opened a settings
pane. Any enrolment flow has to answer this before it ships.

## Contracts to settle before implementation

From Codex's review of 2026-09-12, kept because each is a decision someone must make rather than
discover:

- **Two independent modes per application**, not one ladder: start (Manual / Ask / Automatic) and
  release-stop (Manual / Ask / Automatic). The proposal's two separate "always" buttons already fit
  this. Define whether pressing "always" also answers *this* offer or only changes future episodes —
  the statement says "next time" for auto-stop, so enrolment must not stop the current recording as a
  side effect.
- **The AGENTS.md rule is not a veto, but the exception must be narrow.** Explicitly enrolled auto
  modes supersede "timers never act"; the rule stays in force for the default Ask mode and for every
  application not enrolled. The document is updated in the same change, describing the exception.
- **Bind provenance at successful start admission**: session identity, origin (manual / prompt /
  automatic), the durable application key when there is one, and the triggering episode. ⚠️ "Bound"
  means *who triggered control*, never *whose audio is captured* — Acta still records system audio and
  the microphone, including other applications. A Slack-only control policy must not read as Slack-only
  capture.
- **One recorder, overlapping applications**: keep the original owner, never rebind to the newest
  process. When the owner releases while another application is still using the input, the conservative
  default is to demote that stop to an offer rather than silently end someone else's conversation. A
  manually started recording stays unbound unless the user binds it. A manual Stop, or a
  cancel-and-delete, must consume that application's current episode so auto-start does not immediately
  undo the user's decision.
- **The two stop reasons do not share authority.** Enrolling "stop when Slack releases the input" must
  not make the heuristic quiet rule stop anything automatically. Re-acquisition cancels a release
  countdown even while quiet; audio activity cancels a quiet offer even though the owner released. One
  presentation arbiter, distinct trigger identities and permissions. "Keep recording" needs a
  session-level suppression, or the same released state re-offers on every tick.
- **Cancellation means two different things.** During a stop countdown, "Keep recording" prevents a
  stop. After an automatic start, the user's "Cancel" means stop **and delete** — so it must be labelled
  for what it does ("Stop & delete"), never as an ordinary save. A late click must never delete the next
  session, a manually started one, or one whose ownership changed. Teardown, writer draining, assembly
  and recovery need one coordinated terminal disposition, and a crash mid-deletion must not resurrect
  the cancelled recording or apply its deletion intent to another folder. "Cancel at any moment" cannot
  literally undo a finalisation, so the window has to be defined — and the way to reach the action needs
  to outlive a three-second toast.
- **Enrolment through prompts must not be the only way in or out.** Once Ask becomes Automatic the
  enrolment prompt may never appear again, so there must be a way to inspect and revoke a mode without
  starting a call, plus an immediate pause-all-automation control. Disabling automation cancels pending
  actions without stopping or deleting audio already captured. Define precedence against "Never for this
  app" and the two existing switches. Keep every mode **off `WireSettings`** and preserve it across
  every wire round-trip, as `reminderExcludedBundleIDs` already is.
- **Lifecycle defaults**: startup and wake must not auto-start because an application already holds the
  input, nor auto-stop because observation was lost. After a crash, recover the audio but do not resume
  an armed countdown or infer permission for a new recording from an old one. Revalidate every pending
  action against current settings, owner, recording identity, quit state and policy after each await.

## The measurement that comes first

⚠️ **Mint-time logging alone is not enough** — that was the original plan and Codex is right that it
under-specifies the question. What is needed is a bounded transition trace across: acquisition,
mute/unmute, output-only listening, a device switch, a helper restart, the call ending, two applications
overlapping, and the application's own microphone test or settings screen. Record read failures and
input-device evidence too, and record the key kind (bundle vs pid) separately from the bundle read
outcome, the process-object lifetime, the process name and the activation policy — the first version of
this item collapsed all of those into "was there a display name".

A first step landed on 2026-09-12: the coordinator now logs `bundle=`, `display=` and `process=` when an
episode is minted, and logs the withdrawal. That answers the narrow question "is there a durable key for
Slack and for Teams" and nothing more.

Observations from Slack and Teams establish behaviour for **those versions and those scenarios**, not
for all calls and not for browsers. The scope question can be designed now; the measurement decides
which applications can honestly be enrolled.

## Not to be confused with

The existing quiet-audio stop rule, which is about measured silence and stays useful when the holder
never releases — a call left open. These are two independent triggers for the same prompt, and per the
contract above they do not share authority.
