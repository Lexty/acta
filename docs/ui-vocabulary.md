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
