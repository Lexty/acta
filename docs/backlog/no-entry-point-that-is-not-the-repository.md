---
worth: later
added: 2026-09-13
---
# nothing describes Acta to someone who is not already reading its source

The only thing that explains what Acta is, is `README.md` — a file addressed to someone who has already
found the repository and is comfortable there. It opens with two audio tracks and a build command.
Someone deciding whether they want a meeting recorder at all has nowhere to land.

A page, hosted free, is the obvious answer. **GitHub Pages from this repository is the candidate with
no new account and no new place to keep credentials**, and it can serve from `docs/` or a branch.

⚠️ **The unknown that settles whether this is worth doing: whether there is anything to download.**
Until [[installing-acta-means-building-it]] is resolved, the only honest call to action a page can
carry is "clone it and build it", which is what the README already says better. A landing page whose
download button leads to a build procedure is worse than no landing page, because it spends a
stranger's goodwill before the first sentence of the product is read. That is the condition, and it is
the reason this is `later` rather than `yes`.

Secondary and cheaper to check: GitHub Pages for a **private** repository is a paid feature, so
publishing the repository is a prerequisite for the free route. That orders the work and is worth
confirming rather than assuming.

## The constraint to write down now, because it is easy to lose later

This is marketing copy for a tool that records other people talking. **The failure mode is already
documented in this repository's own history**: the README said recordings never leave the machine on
its fourth line and qualified it eighty lines down, where the companion plugin's summary step sends
the transcript, the screenshots on the Desktop inside the meeting window, the calendar event with its
attendees, matching mail, Jira issues and local project documents to a model. The claim was not false;
it was narrower than the behaviour, which in a privacy statement is the same mistake.

A landing page makes that mistake **more** likely, not less: it is shorter, it is written to persuade,
and every qualification competes with the pitch for space. So whoever writes it inherits one rule —
the qualification travels in the same breath as the promise, or the promise does not appear. The same
goes for the retention pass: it is destructive and it has two open defects
([[retention-restore-can-leave-a-truncated-wav]], [[retention-gate-and-its-documentation-disagree]]),
so it must not be advertised as safe unattended maintenance until those are closed.

Other things a stranger needs that the README currently buries: that recording needs macOS 15, that two
TCC grants are required and why Screen Recording is one of them, and that `ffmpeg` must be present or
the meeting ends on an error screen.
