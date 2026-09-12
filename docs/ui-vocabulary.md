# The menu-bar vocabulary shared by acta and dicta

**This file is a COPY**, and its twin lives at `docs/ui-vocabulary.md` in the `dicta` repository.
The two projects are separate repositories with no shared package, so nothing mechanical keeps them
in step — that is precisely why the vocabulary is written down instead of being left implicit in
each app's SwiftUI. The check is a human reading both copies; the cost of not having it is two menus
in one menu bar that differ by twenty points and read as a mistake rather than as a choice.

**It was written by dicta and checked against acta, not the other way round.** Every row below was
read off `Sources/Acta/ActaApp.swift` and `Sources/ActaRuntime/ControlViewModel.swift` on
`socket-transport` on 2026-08-24 (the view model has since moved out of the executable target — see
the amendment at the end) — so where this file describes acta it describes what acta actually
does, and where it names something acta does not do, that is marked as a divergence rather than as a
thing to go and implement. Nothing here asks acta to change.

In acta these decisions live in `ActaApp.swift` as three parallel switches (`statusIcon`,
`statusColor`, `statusText`). Collapsing them into one pure presentation value would make the header
assertable in tests — it is proposed in dicta's `docs/ui-proposal.md` §7, it is **optional**, and it
belongs to acta to schedule. In dicta the same decisions are already one value, in
`Sources/DictaCore/Presentation.swift` and `MenuModel.swift`. **When this file and either app's code
disagree, the code is what ships and this is what is wrong** — correct the document.

---

## The elements

| element | rule |
|---|---|
| container | `MenuBarExtra`, `.menuBarExtraStyle(.window)`, `LSUIElement`, no dock icon |
| panel | `.frame(width: 300)`, `.padding(12)`, `VStack(spacing: 10)`, `Divider()` between sections |
| header | tinted SF Symbol + app name `.headline` + one-line status `.caption`/`.secondary`, trailing monospaced timer while active |
| banner | icon + `.caption` text on `tint.opacity(0.12)` in a `RoundedRectangle(cornerRadius: 6)`, with an optional trailing `xmark` that dismisses it |
| colours | red = broken now, or the microphone is open; amber = landed but degraded, or working; green = it worked; faint = nothing there |
| primary action | `.borderedProminent`, `.controlSize(.large)`, full-width, tinted red when it is a stop |
| list | `.caption`/`.secondary` section title, at most five rows, each a 7 pt status `Circle` + a one-line primary + `.caption2`/`.secondary` secondary + a trailing borderless icon button; an empty list says so in `.caption`/`.tertiary` |
| footer | `HStack` at `.caption`: a verb on the left, `Spacer`, an exit verb on the right |
| first frame | the view model seeds its state **synchronously** in `init`, so the panel never opens blank. A `Task` started there has not run when SwiftUI first renders |
| lazy content | **`MenuBarExtra` builds its content view only when the item is clicked.** Anything that must run at launch cannot hang off the panel. Both apps hit this and solved it differently — acta with an `NSApplicationDelegateAdaptor` (`applicationDidFinishLaunching`), dicta by putting the subscription on the menu-bar **label**, which is the one view that always exists |

Two rows are **not adopted by dicta and are not divergences to fix**: the `settings`
`DisclosureGroup` (`Label("Settings", systemImage: "gearshape").font(.caption)` — acta has archive
path, segment length and a checkbox in it) is Tier 2 and waits for the external filter, since a
settings panel with one row in it is worse than none; and the `DEV` tag beside the glyph, with the
revision under the app name in `.caption2`/`.tertiary`, belongs to an app launched by hand, while
dicta's menu is a LaunchAgent with exactly one installed copy.

**Every row above was checked against `Sources/Acta/ActaApp.swift` and `ControlViewModel.swift` on
`socket-transport` on 2026-08-24, not copied from `docs/ui-proposal.md`.** That check paid for
itself immediately: dicta had shipped its primary action without `.controlSize(.large)`, which is
precisely the drift this file exists to catch and which a proposal written before either app could
not have caught.

---

## The two conventions

Neither is code. Both are rules about what may exist at all, and both were learned from something
already built.

**A control that cannot do what it says must not exist.** This is why the footers differ. acta has
`Quit`, because quitting acta quits it. dicta has no `Quit`: the daemon's LaunchAgent has `KeepAlive`
and launchd would restart it within ten seconds, so the button would be a lie told once per click.
dicta's right-hand footer verb is `Restart` (`launchctl kickstart -k`), which is honest and is also
the thing you want immediately after `--fetch-models`.

The same rule is what makes dicta's Stop and Abort **absent** when idle rather than greyed out. A
disabled `Stop` invites the question "why is the Start next to it disabled too", and the answer is
that there is no Start and cannot be one — a click carries no session to aim at (D30).

**Every app in the family owns one glyph and keeps it.** acta keeps `waveform`; dicta takes the
`mic` family. Two items in one menu bar must be distinguishable **by shape, not by position**,
because position is whatever the user's other menu items make it. Observed together on 2026-08-23
and they are distinguishable at a glance, which is the only test this rule has.

---

## Deliberate divergences

Written down so they are not later "fixed" into inconsistency.

| | acta | dicta | why |
|---|---|---|---|
| glyph | `waveform` | `mic` family | two items in one menu bar must be distinguishable by shape |
| menu-bar item | glyph alone | glyph **plus a running clock** while the microphone is open | measured: a glyph that changes only its fill is not legible without being looked at, and macOS's own microphone indicator says "some app", not "dicta" (SPEC.md F9). The clock changes the item's width, which is the change peripheral vision reads |
| primary action | symmetric Start/Stop | **Stop and Abort only** | a click has no session to aim at (D4, D22, D30) |
| footer right | `Quit` | `Restart` | launchd `KeepAlive` makes a Quit button a lie |
| degraded screen | `UnsupportedContent` at 240 pt for macOS 14 | none | dicta needs no capture-era availability gate |
| history rows | open in Finder | copy to clipboard | dicta's artefact is text, and the UI never injects (D28) |
| a row with nothing delivered | — | shows what was HEARD, in italic, and has **no copy button at all** | D28's structural half: the clipboard is loaded from `final` and never from `recognised`, so a row that produced no `final` has nothing for a button to carry |
| row primary line | `.caption` (a folder name) | `.callout` (a sentence of dictated speech) | the row's content is what has to be read, not merely recognised — a dictation you are trying to find again is prose, and a folder name is a label |
| dismissible banners | yes — the recovery notice carries an `xmark`, and two banners can be up at once | none, and only ever one | every banner dicta can raise is a CURRENT condition — no daemon, no models, no microphone — so dismissing one would hide something still true and it would come straight back. acta's recovery notice is about something that already happened, which is dismissible in a way a live fault is not |
| a control that is busy | present and **disabled** — `Starting…`, `Saving…` | absent | not a contradiction of the convention below: acta's disabled button is a *state display* occupying the place its control will return to, while dicta has no idle-state control to grey out in the first place |
| where the state comes from | the app **is** the daemon | a `watch` stream from a separate daemon | dicta's UI is a second client of the control socket and the daemon holds no reference to it (D27); acta's menu has no equivalent of "the daemon is not running" because for acta that state is "the app is not running" |

---

## The one rule that is not about pixels (dicta's, and acta has no equivalent)

**The daemon cannot tell whether a UI is running, and nothing about a dictation depends on it**
(D27). The menu app links `DictaCore`, `DictaIPC` and `DictaRecord` plus SwiftUI — the same budget
`dictactl` has, one target wider — and it opens no microphone and loads no model. With it absent,
quit or crashed, every dictation behaves identically. That is what makes the strip a *display* of
dicta rather than a *part* of it, and it is asserted by `Scripts/linkage.sh` rather than by any test,
because it is a property of what the binary is linked against (SPEC.md §8, invariants 8 and 11).

---

## Amendment, 2026-09-11: what the microphone merge changed under this file

`socket-transport` and the microphone-priority line were merged on this date, and the rows above were
read off the menu **before** the microphone work existed. By this file's own rule — the code ships and
the document is what is wrong — the following are corrections, not proposals, and **none of them asks
dicta to change anything**.

- **`ControlViewModel` moved** from `Sources/Acta/` to `Sources/ActaRuntime/`. It is not a view; it is
  the `ControlAPI` adapter, and while it lived in the executable target no test could reach it. Four
  defects were found in it the day it became importable. The `first frame` row above still describes
  what it does — only its path changed.
- **A second `DisclosureGroup`.** The panel now carries a collapsed **Microphone** section beside the
  `settings` one. Its label is a two-line `VStack`: `Text("Microphone").font(.headline)` over a
  `.caption`/`.secondary` line stating which microphone a recording would use. ⚠️ The label is a
  **projection**, not a ternary in the view: the sentence is resolved in `ControlAPI.MicrophoneStatus`
  and tested, because a user-facing string that states a fact is the one layer nothing checks.
- **The `list` row's "at most five rows" no longer holds for this section.** The microphone chooser is
  a self-sizing `ScrollView` bounded at 320 pt (`MenuContent.chooserMaxHeight`), because the device
  count is the machine's to decide and a menu that runs off the bottom of the screen cannot be clicked.
  ⚠️ A `ScrollView` is greedy along its scroll axis, so the section is measured with a `PreferenceKey`
  and the measurement is turned into a frame by `ActaKit.BoundedSectionLayout` — a **collapsed**
  disclosure reports zero, and a zero stored as a height is a latch that makes the section open empty
  and stay empty. That shipped once. If dicta ever grows a bounded self-sizing section, this is the
  trap.
- **The rows above were not otherwise re-derived.** Everything not listed here dates from the
  2026-08-24 reading and should be treated as that old.

---

## Amendment, 2026-09-12: acta's panel diverges on five rows, deliberately

The acta panel was redesigned after a measured reading of what it actually looked like on screen.
Three mock-ups were put to the user and variant A — "quiet", the idiom of Apple's own menu extras —
was chosen. **None of this asks dicta to change anything**, and every row below is a divergence acta
now owns rather than a correction to the shared vocabulary.

What the reading measured, since the divergences follow from it: on macOS `.caption` and `.caption2`
are **the same 10 pt**, differing only in colour, so a hierarchy the code expressed in four styles had
three levels on screen; `.headline` is 13 pt bold, which made the app's own name and a subsection
heading the same rank; and the panel carried **five `Divider()`s at an identical 10 pt step**, which
is the same as having no grouping at all.

- **`panel`: no `VStack(spacing: 10)`, and one `Divider()` rather than five.** Grouping is by
  distance — 6 pt inside a group, 16 pt between — which is what Apple's own menu extras (Wi-Fi, Sound,
  Now Playing) do; they carry no rules at all. The one surviving rule sits above the utility line,
  where what follows is not another group but a different kind of thing. ⚠️ **The cost is real**: a
  wrong `spacing:` destroys the grouping silently and no test can see it. Rules are cheaper to keep
  right, which is the argument for dicta keeping them.
- **`header`: one line, and no status text.** "Ready to record" sat directly above a button reading
  "Start Recording" — the same sentence twice, in the place the eye lands first. The glyph became a
  22 pt tinted tile, the name lost the flavour suffix in favour of a `DEV` capsule beside it, and the
  timer still sits at the trailing edge while recording. The status sentence survives as the tile's
  **accessibility label**, because a reader that cannot see a red tile and a running timer needs it.
- **`list`: no status `Circle`.** The dot marked the *ordinary* — every saved recording had one — so
  the eye learned to ignore it, and a recovered or unfinished recording sat in the same field of dots
  with only a hue to distinguish it. Now the ordinary is silent and the exceptions carry **a symbol
  and a word**, which also survives a user who cannot tell the hues apart. The `colours` row still
  holds for what remains: red for unfinished, amber for recovered.
- **`list`: the row shows the meeting's real title.** It showed `directory.lastPathComponent` — a slug
  that repeats the date already in the folder name, truncated through the middle. The title has been
  in `info.md` since the first version and the listing simply never read it back
  (`MeetingInfo.parse`). The second line is `Today 20:07 · 41:12`, and **the duration appears only for
  a finished recording that measured one**: `info.md` is written at start with `duration: "00:00:00"`,
  and rendering that placeholder beside real durations would state that a recording lasted no time.
- **`footer`: replaced by a utility line.** "Open Archive" and "Quit" were two bordered buttons of
  equal weight — a frequent, harmless action and a rare, destructive one. "Open Archive" moved to the
  header of the list it is about; "Quit" is a quiet verb paired with the build revision, which also
  moved here out of the header.
- **The `settings` `DisclosureGroup` is gone from acta.** Configuration lives in a real Settings
  window (⌘,) reached by one row; the note above about that disclosure being Tier 2 for dicta still
  stands on its own terms.

---

## Amendment, 2026-09-12: the reminder panel, and the one prompt in it that acts

acta now raises prompts in a floating panel of its own (`Sources/Acta/ReminderPanel.swift`), outside the
menu. dicta has no equivalent, so **nothing here asks dicta to change anything**; it is written down
because the panel reuses this vocabulary and the rows it bends are easy to "fix" back.

**What the panel shares with the menu.** `.frame(width: 300)`, `.padding(12)`, on `.regularMaterial` in a
12 pt `RoundedRectangle`. Each prompt is a 24 pt tinted tile beside a `.headline` over a
`.caption`/`.secondary` line; a detail block indented 32 pt to align under the text; the `primary action`
row as written (`.borderedProminent`, `.controlSize(.large)`, full-width, red when it is a stop); and a
`.caption` `HStack` of plain-button verbs underneath, in the `footer`'s shape. It is **not** a
notification — measured: a `UNUserNotificationCenter` banner hides its buttons until hover — and no copy
may claim it respects Focus.

**The prompts.** Offer to record ("Microphone activity in Slack" — Start Recording / Not now / Never for
Slack); offer to stop when quiet ("Little audio activity" — Stop & Save / Keep Recording / Remind me in 30
min); and, new in this amendment, **the owner-release stop offer**:

| part | what it is |
|---|---|
| tile | `mic.slash`, secondary tint |
| headline | "Slack released the microphone"; with no name, "The microphone was released" |
| second line | "Acta saw Slack stop using the microphone input. The recording will stop and save unless you keep it." — not line-limited |
| detail block | the recording's title, then "Stopping and saving in 17 s" in `.caption`/`.tertiary`, `monospacedDigit()`; the line reads the full 20 s from the first frame and starts counting only once the panel has acknowledged the prompt as on screen |
| primary action | **Stop Now**, `stop.fill`, tinted red |
| footer | **Keep Recording** alone, on the left |

Four decisions in that row set, each deliberate:

- ⚠️ **It is the only prompt that acts without a click.** When the countdown completes, the recording
  stops and saves. `AGENTS.md` ("The reminders") carries that exception and its conditions; the other
  prompts' expiry still acts on nothing.
- ⚠️ **"Keep Recording", never "Cancel".** On a prompt about stopping, "Cancel" reads as cancelling the
  recording, which is a different and unbuilt action (stop and delete). The button says what it keeps.
- ⚠️ **No click-outside dismissal on this prompt.** On the other prompts a click elsewhere dismisses an
  offer that acts on nothing. Here a dismissal is a decline, and the person this is for clicks in another
  app within twenty seconds as a matter of course — so the two buttons are the only answers.
- **The copy names an observation, not an ending.** Acta saw an application let the input go; it never
  says the call, meeting or huddle ended, and a test forbids those words. Every sentence is a projection
  in `ActaKit.OwnerReleaseOfferText`, not text in the view.

⚠️ **Not verified on screen**: the countdown's layout, the unbounded second line, and the panel staying in
place while the number updates once a second are human acceptance, not tests.
