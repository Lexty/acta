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
- **Ownership survives an unqualified release** — added after the flap was measured, and it is the
  contract the flap forces. Track `held → release-candidate → qualified-release` **separately** from
  the prompt rule's spent/re-arm phases. While a release is unqualified: keep capturing, and show no
  stop prompt. Any positive input from the **same owner** cancels the candidate and the countdown and
  keeps the *same* session — never stop and restart to compensate for a flap, which would fragment a
  recording for no reason. Unknown evidence, or an observation gap, **revokes** qualification: no
  countdown may commit on stale evidence. After a cancellation, a fresh full release interval is
  required before another stop attempt. Release qualification and the countdown are two different
  durations and the user-visible total is the sum — say what it is.
- **"Continuously released" needs a definition that polling can actually satisfy.** A sufficiently
  fresh *sequence* of released observations spanning N on the monotonic clock, with a maximum
  permitted gap between samples. One false sample followed by a late callback does not qualify.
  ⚠️ Polling cannot prove the absence of sub-sample holds — and the production observer runs at 1 Hz
  while the trace that found the flaps ran at 250 ms, so they see different worlds. Test the rule by
  replaying these recorded events at several 1 Hz sampling offsets, and cover the **two-flap** sequence
  actually observed, not a single clean release and re-acquire.
- **Qualifier clocks and owner identity live outside the prompt slot.** Dismissing or consuming a toast
  must not delete the binding, and a brief re-acquisition must not create a second recording. The final
  stop admission still re-checks recording identity, ownership, settings, quit state and a *fresh*
  qualified release after every await.
- ⚠️ **"Another app still holds the input, so demote the auto-stop" was wrong, and the measurement is
  what killed it.** `com.apple.CoreSpeech` holds the input persistently on this machine — so that rule
  would let a system speech service veto every automatic stop, forever. A competing owner has to be
  defined narrowly: another *enrolled* meeting scope observed active during this recording, not any
  system process holding input. How unknown competing activity is treated is a policy choice that still
  has to be made. The binding stays with the original owner and is never transferred.
- **Lifecycle defaults**: startup and wake must not auto-start because an application already holds the
  input, nor auto-stop because observation was lost. After a crash, recover the audio but do not resume
  an armed countdown or infer permission for a new recording from an old one. Revalidate every pending
  action against current settings, owner, recording identity, quit state and policy after each await.

## What the research and the first measurements established, 2026-09-12

Asked for by the user. Two independent efforts: a direct HAL probe on this machine
(`Scripts/probe-audio-process-objects.swift`, committed so it can be re-run) and a web search by
Codex. **The headline is that the durable key exists far more often than the original assessment
assumed** — but nothing here settles Slack or Teams, which is the case the proposal is actually about.

### Documented by Apple, verified in the installed SDK headers

- The whole per-process interface is five selectors, and that is all there is:
  `kAudioProcessPropertyPID 'ppid'`, `BundleID 'pbid'`, `Devices 'pdv#'`, `IsRunning 'pir?'`,
  `IsRunningInput 'piri'`, `IsRunningOutput 'piro'`
  (`MacOSX.sdk/.../CoreAudio.framework/Headers/AudioHardware.h:1977-1983`). ⚠️ **`'ppid'` is the
  process's own pid, not a parent pid** — the four-character code invites exactly that misreading.
  There is **no** durable per-process UID, no responsible-application id, no audio-client name and no
  parent relation.
- The header says only "A CFString that contains the bundle ID of the process" (line 1956). It does not
  say when it is absent. Apple's Swift surface goes one step further and no further: `var bundleID:
  String? { get throws }` — optionality is documented, the absence matrix is not.
  <https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/bundleid>
- `AudioHardwareObject.owner` is **audio-object** ownership, not the responsible application, and the
  generic object `name` carries no persistence guarantee. So "nothing like an owner exists" would be
  wrong; "nothing documented as the durable application identity this needs" is right.
- `AVCaptureDevice.isInUseByAnotherApplication` answers *whether*, never *who*.

### Measured here, 2026-09-12, macOS 15

32 process objects. **29 carried a bundle identifier** — including several that
`NSRunningApplication` could not resolve at all (`com.apple.CoreSpeech`, `com.apple.audiomxd`,
`com.apple.cmio.ContinuityCaptureAgent`). So the bundle id is a **more** available identifier than the
display name, which inverts the assumption the first assessment was built on, and a missing name must
never be allowed to discard a valid HAL key.

Chrome appeared as three objects: `com.google.Chrome` (regular) and two helpers, both reporting
`com.google.Chrome.helper`, one resolving to "Google Chrome Helper" (accessory) and one not resolving
at all. `com.apple.WebKit.GPU` was present as "Safari Graphics and Media".

⚠️ **What this snapshot does and does not show.** It shows those objects exist with those identifiers.
It does **not** show that the Chrome helper is what holds input during a Chrome call — no Chrome call
was running, and `IsRunningInput` was true only for `com.apple.CoreSpeech`. That the helper is the
capture holder comes from an implementer's report, not from this measurement
(<https://macnotetaker.com/blog/which-app-is-using-mic-coreaudio-process-objects>, 2026-07-23, which
also reports `com.apple.WebKit.GPU` for WebKit capture and notes bare binaries with empty bundle ids).
A single snapshot also says nothing about **stability across process restarts**, which is the property
an enrolment actually depends on.

`com.apple.CoreSpeech` (pid 1136) was holding the input at two observations about seven minutes apart,
same pid. A system speech service, not a meeting — a live instance of the false-positive class, and
evidence that holding can be *long*, not only brief.

### Slack, measured on a live huddle — the question this item existed to answer

⚠️ **This is the result that decides the item, and it is positive.** Measured 2026-09-12 on this
machine, Slack running, with `Scripts/probe-audio-process-objects.swift` and a transition watcher:

| state | holder of `IsRunningInput` | what was observed |
|---|---|---|
| in a huddle | `com.tinyspeck.slackmacgap.helper` (pid 81379) | positive in **every** sample across 90 s |
| Slack running, no huddle | *(nothing from Slack)* | negative in **every** sample across 180 s |

⚠️ **"Every sample", not "continuously".** The watcher polled at 400 ms. A release and re-acquisition
inside one interval is invisible to it, so what is established is the state at each sample, not the
absence of transitions between them.

Three things follow.

- **A candidate durable key exists for Slack**, pending one more measurement: recurrence across a
  restart. The holder is a helper, and it carries its own bundle
  identifier — `com.tinyspeck.slackmacgap.helper`, distinct from the app's
  `com.tinyspeck.slackmacgap`, with a third object (pid 81380, "Slack Helper", accessory) present but
  not holding. So the original worry, that a huddle would be held by something keyed only by pid, is
  **wrong here**. A mode can be remembered against that string.
- **Holding separated *this* huddle from *this* idle window** — which is what the proposal's
  auto-start and auto-stop need to be true, and is a stronger result than "an identifier exists". ⚠️ It
  is **not** yet the claim that holding discriminates calls from every other Slack use of the input: a
  microphone-test screen, a settings pane, a voice clip or a device check are all untested, and any of
  them holding the input would put a false positive on exactly this signal.
- **The unverified claim was not observed — which is not the same as refuted, and the first version of
  this section said "refuted".** The secondary source's "Slack opens brief audio sessions outside
  huddles, for the mute button and device availability" produced nothing in a 180-second idle window.
  That window cannot rule the claim out: the trigger may be an interaction nobody performed, or an
  event shorter than the 400 ms poll. **The claim stays unsupported**, and this result says only "not
  observed while Slack sat idle for 180 s".

⚠️ **The release edge itself was not captured.** The watcher's first sample already found the helper
released, so what exists is two observed *states*, not a recorded transition. Auto-stop fires on the
edge, so it is worth seeing once directly — along with what happens to the pid, since a helper that
restarts between calls would break a pid-keyed design and leave a bundle-keyed one intact.

Still unmeasured for Slack: mute/unmute, a device handoff mid-huddle, the microphone-test screen, and
whether a second huddle reuses pid 81379 or spawns a new helper.

### The full trace: join, mute, leave, re-join — and the flap that breaks a naive auto-stop

Captured 2026-09-12 in one uninterrupted run. **macOS 26.6.2 (25G83), Slack 4.52.155**, sampling every
250 ms, releases reported only from a *complete* enumeration (there were no incomplete ones).

```
13:19:10.732  baseline: com.apple.CoreSpeech#1136 only
13:22:35.565  + com.tinyspeck.slackmacgap.helper pid=81379 object=182   join #1
13:22:37.468  −   (held 1.9 s)   object present, input now false
13:22:37.741  +   (gap 273 ms)
13:22:38.009  −   (held 268 ms)  object present, input now false
13:22:38.275  +   (gap 266 ms)
13:22:56.051  −   (held 17.8 s)  object present, input now false        leave #1
13:23:12.846  +   (gap 16.8 s)                                          join #2
13:23:14.217  −   (held 1.4 s)   object present, input now false
13:23:14.768  +   (gap 551 ms)
13:23:24.347  −   (held 9.6 s)   object present, input now false        leave #2
13:24:10.813  end: com.apple.CoreSpeech#1136 only  (46 s, nothing from Slack)
```

⚠️ **The finding that changes the design: holding is not smooth.** Every join was followed within
1.4–2.4 s by a release and re-acquisition. Three flaps were observed, of **273 ms, 266 ms and 551 ms**
— the last on the second join. ⚠️ The first version of this paragraph said "~270 ms" and "266–273 ms",
**omitting the longest gap, which is twice the others**; the raw trace above had it all along. Anyone
tempted to pick a threshold from these numbers should not: they are intervals between *observed
states*, not physical release durations, and the sampling interval bounds them from below.

**An auto-stop firing on the first observed release would stop a running recording two seconds into
the call.** A debounce is not a precaution here, it is a measured requirement. ⚠️ That statement is
about a recording that is **already running** — started by hand, or by an earlier automatic start. It
is *not* demonstrated for the current qualified-*start* rule, whose hold is
`RecordingSettings.microphoneActivityHold` = 3 s: both initial holds in this trace (1.9 s, 1.4 s) are
shorter than that, so today's rule would not have offered until after a stable re-acquisition anyway.

And because the flaps are the same order as the 250 ms sampling interval, **shorter ones may exist
unseen**. Any release qualification must therefore be expressed as "released continuously for N",
never as "a sample said false".

**Mute caused no observed release in the interval tested.** The user muted and unmuted shortly before
leaving huddle #1 — roughly 13:22:45–56 — and there is no transition in that range. Huddle #2, where
nothing was muted and the join flap happened anyway, shows that muting is **not necessary** for a
join-associated flap. ⚠️ That is not a proof of mechanism: it says muting did not release the input
*here*, not that Slack never releases on mute. It is still enough to reject the naive reading of
"released the microphone means the call ended", which would have stopped a recording the moment its
owner muted.

**The helper is not restarted between calls.** `pid=81379 object=182` in every transition, across both
huddles. A pid-keyed mode would have survived *this* sequence. ⚠️ That does **not** weaken the case
against pid-keyed persistent preferences: restart, crash and relaunch are part of an application's
ordinary lifetime, not hypothetical exceptions, and a preference that silently stops applying after a
relaunch is worse than one that was never offered. Recurrence of the *bundle* key across a Slack
restart is still unmeasured, and that is the measurement that settles it.

**Every release in this trace was "object present, input now false", never a disappearance.** ⚠️ That
describes this five-minute sequence and nothing more: quitting or crashing Slack still exists, so
disappearance and unknown must stay in the owner contract rather than being designed out on the
strength of one trace in which nobody quit anything.

### Two calls back to back — and why the debounce cannot tell them from a flap

Raised by the user on 2026-09-12: a three-hour huddle can end and a new one begin **in the same
second**, and the same is true of every comparable application.

⚠️ **On this signal the two are indistinguishable, and that is a property of the evidence rather than
of any rule we might write.** A release followed by a re-acquisition looks the same whether it is a
device handoff inside one call or the boundary between two. The measured flaps were 266 ms, 273 ms,
279 ms, 551 ms, 824 ms and 834 ms; a genuine call boundary can be shorter than all of them. No
debounce can separate the two cases, because there is nothing in the HAL that says "new call" — only
"input held" and "input not held".

**This already bites the shipped rule, not just the proposal.** A re-acquisition inside the re-arm
window returns `.releasing` to `.spent` — the *same* episode — and `offerIfQualified` mints only from
`.holding`. So today, when one call ends and another begins within the re-arm (**thirty seconds**, not
one), **the second call raises no offer at all**. The window that exists to stop one call producing
two prompts also stops two calls producing two prompts.

The choices, none of them free:

- **A short debounce** (say something above the longest observed flap) separates back-to-back calls
  that are further apart than it, and absorbs the flaps we have seen. It does not help the user's
  sub-second case, and it splits a call whenever an unobserved flap is longer than the threshold.
- **A faster poll.** Production samples at 1 Hz while the trace that found the flaps ran at 250 ms — at
  1 Hz a 550 ms flap may be missed entirely or may look like a 1-second release. Raising the rate
  narrows the ambiguous band and costs a cheap HAL read; it cannot remove the band.
- **Accept the merge.** Two consecutive calls become one recording. Defensible for a file-per-sitting
  model, wrong for a file-per-meeting one, and it must be a stated choice rather than an accident.
- **Separate the two windows.** The re-arm that suppresses a *second prompt for one call* need not be
  the same duration as the debounce that qualifies a *release*. Today they are entangled; the proposal
  needs them independent, and the second-call case is the argument for it.

⚠️ Whatever is chosen, the sub-second case the user named is **unreachable at a 1 Hz poll** and stays a
known limitation. Say so in the interface rather than pretending the boundary was detected.

**And a third case, which settles the argument: reconnecting to the *same* call.** The user also drops
out and rejoins the same huddle. On this signal that is identical to the other two — same application,
same helper, same identifier — and only the length of the gap differs, unreliably.

So three situations produce one indistinguishable signal:

| what happened | what the design should do | which way it pulls the threshold |
|---|---|---|
| device handoff inside a call | keep one recording | longer |
| two different calls back to back | two recordings | **shorter** |
| dropping out and rejoining the same call | keep one recording | **longer** |

Two of them pull in opposite directions and no threshold satisfies both. ⚠️ **The conclusion is that
the input-holding signal cannot decide recording boundaries on its own**, and a design that pretends
otherwise will be wrong some of the time by construction. What it can do is choose *which* error to
make, and there the answer is not symmetric:

- **Merging is recoverable.** Two calls in one file can be split afterwards; the audio is all there.
- **Splitting is not.** Two files lose the moment of transition, and the restart itself can drop audio
  — the measured device-loss restart took 210 ms, during which nothing was captured.

So the bias should be toward **keeping one recording**: a long release qualification, a reconnection
that cancels any countdown, and a *manual* way to start a second recording when the user knows the
meeting changed. Getting two calls in one file is an inconvenience; getting a torn recording of one
meeting is a loss.



### The user's resolution: the boundary is a human decision, not a detected fact

Decided by the user on 2026-09-12, after the three-indistinguishable-situations finding above, and it
is the right shape: **since the signal cannot tell the cases apart, Acta must not decide — it asks, and
it never does the irreversible thing without an answer.**

- Leaving a call raises a prompt saying the recording **is about to be stopped**.
- **Cancel** keeps it running — this is the reconnect case, and it is the *default* outcome if nothing
  is pressed, because keeping one recording is the recoverable error.
- **Stop now** ends it immediately — this is the "I am going straight into another call" case, and it
  removes the wait the countdown would otherwise impose.
- A third button, "stop and start a new one", was considered and **rejected by the user as overloading
  the prompt**. Recorded so nobody adds it back without a reason.

⚠️ **This also disposes of the countdown-length argument.** The debate about whether the release
qualification should be long (for reconnects) or short (for back-to-back calls) does not have to be
settled by a number, because both answers are on the prompt. The countdown only needs to be long enough
to be *readable and cancellable*; it is not trying to be right about what happened.

### Responsiveness after a long recording — a constraint with numbers

The user's requirement: after stopping a multi-hour recording, the next one must be startable **at
once**.

⚠️ **It is not satisfied today.** `ControlState.canStart` is `operation == .idle`, and `.saving` is an
operation — so while the segments are being assembled, a start is refused. The user would leave a
three-hour call, stop, want to join the next one, and be told no.

How long that lasts is **extrapolated, not measured**: a 90-second recording assembled in ~570 ms
(13:40:47.99 capture stopped → 13:40:48.56 session stopped, from today's log). Assembly is
concatenation, so the cost is roughly linear in bytes; a three-hour recording is 120× longer, which
suggests something like a minute of refusing to start. ⚠️ That is arithmetic on one data point and
**must be measured before it is believed** — record a long session and time the stop.

If it holds, the fix is not a faster assembler. It is that **assembly must stop being part of the
operation that blocks a start**: the next recording writes to its own folder and has nothing to do with
the previous one's segments. The phase machine would need `.saving` to be a property of *a recording*
rather than of *the app*, so a new capture can begin while the previous archive finishes in the
background — with the obvious constraints that the archive listing must not show a half-assembled
recording as done, and that quitting must still wait for work in flight.

### Acta's own reader, compared against the probe on the same huddle

Both views of the same 15:22 huddle, Acta sampling at 1 Hz and the probe at 250 ms:

```
truth (250 ms)                        Acta (1 Hz)
15:22:19.676  + slack.helper          15:22:19.794  [slack.helper]      +118 ms
15:22:19.951  + CoreSpeech                  —                           not seen
15:22:21.900  − slack.helper          15:22:21.943  []                   +43 ms
15:22:22.439  + slack.helper          15:22:23.043  [slack.helper]      +604 ms
15:22:53.280  − CoreSpeech                  —
15:23:07.915  − slack.helper          15:23:08.070  []                  +155 ms
```

- **The flap was 539 ms and Acta caught it — by luck.** At 1 Hz a sub-second flap can fall entirely
  between samples. This is the concrete argument for never expressing release qualification as "a
  sample said false".
- **The rule then behaved exactly right**: it saw the re-acquisition at :23.043 and minted at :26.357,
  which is the 3 s hold measured from the *re-acquisition*, not from the first acquisition. The flap
  restarted the qualification, which is what the review predicted and is why today's start rule is not
  vulnerable to these flaps.
- ⚠️ **Acta's reader does not report `com.apple.CoreSpeech` as holding** while the probe does — it held
  from :19.951 to :53.280 and Acta's list is empty at :21.943 and :23.043. The likely explanation is
  that Acta reads its input flag as `nil` (unreadable) where the probe reads `true`, and the diagnostic
  filters on `== true`. Not necessarily a defect — unknown must stay unknown — but **a systematically
  unreadable process behaves differently from an idle one**, and which one this is has not been
  established.
- The bundle identifier is present and the display name absent (`display=<none>`, `process=Slack
  Helper`), now confirmed by **Acta's own reader** rather than only by the probe.

### What the flap actually is: the pre-join screen

Explained by the user on 2026-09-12, and it reinterprets every trace above. **The first hold is Slack's
pre-join dialog** — the screen offering microphone and camera settings before you create or join — and
the microphone is already requested there. The gap is the transition, and the second hold is the live
huddle.

That immediately explains the one number that had looked erratic. The first hold measured 1.90 s,
1.37 s, 6.21 s and 2.22 s across four huddles: **those are how long a person spent looking at a
dialog**, not a device behaviour. Nothing needed explaining about the variance.

⚠️ **In one of the four, the pre-join screen alone exceeded the 3 s offer threshold** — 6.21 s at
13:38. So on a healthy instance Acta would have offered to record a call that had not started, and
might never have. That is the "microphone-test screen" false positive, no longer hypothetical.

**And it is largely fine, which is the correction to how this was first written up.** For the manual
prompt it is arguably an improvement: the offer arrives while the user is still in the dialog, so
pressing Start catches the *beginning* of the meeting rather than its third second. If they abandon the
dialog, the cost is one dismissed toast, or twenty seconds until it expires.

For automatic start the cost is a stray short recording, and the proposal already answers it: the
"recording has started" notice carries Cancel, which stops and deletes. Even ignored, the dialog
closing releases the input and the release-stop path ends it.

The case genuinely worth handling is **someone who opens the dialog often without joining** — each time
costs a recording — and even that is bounded by the re-arm. So this is a cost to be aware of when
choosing the enrolment defaults, not a blocker, and the first version of this section overstated it as
something that "has to be answered before it ships".

⚠️ It does sharpen the central finding, though: the boundary between the pre-join screen and the live
call, and the boundary caused by a device switch, are **the same event on the wire** — 539 ms in one
trace, 824 ms in another. The meaning is in the context, and the context is not observable.

### Scope ambiguity, which the key does not solve

A durable key answers "remember a decision for this scope". It does not answer "is this scope's current
audio use a call". `com.google.Chrome.helper` is shared across all Chrome media use and says nothing
about the site; **`com.apple.WebKit.GPU` is worse**, being shared by every WebKit-hosting application.

### Alternatives, and what they cost

- **EndpointSecurity** has genuine attribution metadata — `es_process_t.responsible_audit_token`,
  `parent_audit_token`, `signing_id`, `team_id` — but there is **no documented microphone
  acquisition/release event**, and `ES_EVENT_TYPE_NOTIFY_TCC_MODIFY` is a *permission change*, not a
  use. Already-granted access starts repeatedly with no TCC event. It also needs the ES entitlement and
  Full Disk Access, which is a large deployment change from what Acta is today.
- **OverSight** achieves attribution through device-state listeners plus `com.apple.coremedia` system
  log messages, read with **private LoggingSupport APIs** (Wardle, *The Art of Mac Malware* vol. 2 ch.
  12, pp. 288-292, which warns Apple changes those messages). Its own product page admits attribution
  sometimes fails. Evidence that a route exists; not a supported one.
- No public API returning Control Center's own attribution list was found. The orange indicator proves
  the **system** can attribute; it does not give third parties that bookkeeping.

### Unverified, and to be treated as such

A secondary source claims **Slack opens a brief audio session outside huddles** — for the mute button
and device-availability checks. If true, an enrolled "always record for Slack" would fire outside
calls. Neither of us found primary evidence. It is also not automatically fatal: whether a brief
session clears the qualification hold depends on its duration, which nobody has measured. **Test it
rather than inherit it.**

### The decision this supports

Per-application enrolment stays viable — for identity scopes that have been *measured* and are
*understandable*. Unknown or shared identities stay manual: keep the offer, omit the "always" controls.
One application failing to be identifiable does not sink the feature.

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
