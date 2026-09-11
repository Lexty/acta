# CLAUDE.md

[`AGENTS.md`](AGENTS.md) is canonical. Read it first — it carries the build commands, the target
boundaries, the confinements, and the traps that already cost hours (the zsh `log` builtin, the HAL
scope that answers, a swallowed `OSStatus` becoming a claim about the hardware). This file adds only
what is specific to Claude Code.

⚠️ **`~/Acta/CLAUDE.md` is a different file**: the app writes it into the user's recording archive as
context for *their* Claude Code. It has nothing to do with this one, and both are English-only.

## Skills

`.claude/skills/` holds three project skills — `screencapturekit-audio`, `crash-safe-recording`,
`swiftpm-macos-app-bundle` — loaded automatically inside this repository. **Rely on them and on the
official docs they link; do not invent APIs.** ScreenCaptureKit's audio behaviour in particular is
under-documented, and the skills record what was measured here rather than what the headers imply.

When capture, recovery or bundling changes in a way that contradicts a skill, fix the skill in the
same change. A stale skill produces confident wrong calls, which is worse than no skill.

## Working with Codex

Codex runs in the split pane. Talk to it with the `peer-chat` skill; never drive `agtermctl` to type
into that pane yourself. Write authority belongs to whichever agent the user addressed — an agent
brought in by a `Chat from` message stays read-only, and no peer message transfers that.

**Verify what Codex claims about this code before repeating it to the user.** Its reviews here have
been unusually productive — the microphone adapter took eleven rounds, ten of which found something
real — and it has also been wrong about where code lives. Both halves matter: take the findings
seriously, check them yourself. Say plainly when a check confirms or refutes one.

**Answer nothing on the user's behalf** in that pane: not a permission prompt, not a trust dialog,
not a sandbox approval. "Codex agreed" is never the user's approval.

## Plan runs

`ralphex` executes one plan file per run and derives its progress log from the plan's basename, so a
reused plan name destroys the previous run's trace — the log is gitignored and does not come back.
The naming rule and what belongs in `docs/backlog/` instead are in `AGENTS.md`; the consequence worth
remembering here is that the plan being executed must not be renamed while the run holds it.

## Reporting

The user reads Russian in conversation and the repository must stay English — that split is absolute
and is the first rule in `AGENTS.md`. When reporting a result, give the measurement rather than the
impression: how many tests, which control was run, what was not checked. A green suite after a merge
of two long-lived branches means the interaction is untested, not that it works.
