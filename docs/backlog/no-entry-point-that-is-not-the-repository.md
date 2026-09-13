---
worth: later
added: 2026-09-13
---
# nothing describes Acta to someone who is not already reading its source

The only thing that explains what Acta is, is `README.md` — a file addressed to someone who has already
found the repository and is comfortable there. It opens with two audio tracks and a build command.
Someone deciding whether they want a meeting recorder at all has nowhere to land.

## The dependency I asserted does not exist

⚠️ The first version of this item said the page was blocked on there being something to download, and
made [[installing-acta-means-building-it]] its precondition. That is wrong, and Codex took it apart:
**only the Download call-to-action depends on a binary.** A page that explains the product, its
requirements and its data flows, and then offers the installation route that actually exists today, is
a complete and honest deliverable on its own.

The hosting premise was wrong too. GitHub Pages is free from **public** repositories on GitHub Free —
but that does not mean this repository must be published: **a separate public repository containing
only the static site works while Acta itself stays private**, on a `github.io` address with no domain
to buy. So publishing Acta is not a prerequisite either.

What a public *binary download* does need is an anonymously reachable artefact location; release assets
of a private repository are not that.

## So why is this still `later`

Because the remaining question is one of value, not of blockers: **is a page whose only call to action
is "clone it and build it" worth writing before there is a binary?** It competes with a README that
already says that, better. The condition that settles it is a decision rather than a discovery —
publish a source-install entry point now, or schedule the page with the binary launch. Either is
defensible; nobody has chosen.

## The constraint to write down now, because it is easy to lose later

This is copy that persuades, for a tool that records other people talking. **The failure mode is
already in this repository's own history**: the README said recordings never leave the machine on its
fourth line and qualified it eighty lines down, where the companion plugin's summary step sends the
transcript, the screenshots on the Desktop inside the meeting window, the calendar event with its
attendees, matching mail, Jira issues and local project documents to a model. The claim was not false;
it was narrower than the behaviour, which in a privacy statement is the same mistake.

A page makes that likelier, not less: it is shorter, it is written to persuade, and every qualification
competes with the pitch for space. So whoever writes it inherits one rule — **the qualification travels
in the same breath as the promise, or the promise does not appear.** Keep recorder-only claims distinct
from the optional plugin's enrichment; "audio capture does not store screenshots" must never be allowed
to grow into "nothing in the workflow reads screenshots".

The same applies to the retention pass: it is destructive and has two open defects
([[retention-restore-can-leave-a-truncated-wav]], [[retention-gate-and-its-documentation-disagree]]), so
it must not be advertised as safe unattended maintenance until those are closed.

## What a first page has to carry

What the thing is, with a screenshot built from synthetic data. The macOS version that *records* (15,
not the 14 the build needs) and the architectures actually tested. Both permissions, with the reason
Screen Recording is one of them — system audio on macOS goes through ScreenCaptureKit — and without
implying that Developer ID makes that prompt go away. Where the menu-bar icon appears on first launch,
because `LSUIElement` means there is no Dock icon to look for. And the `ffmpeg` requirement, next to
the install step rather than below it.

No backend, no analytics, no custom domain, no branding project.
