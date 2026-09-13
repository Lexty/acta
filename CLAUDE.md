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

## Companion plugins (`tools/`)

⚠️ **Here rather than in `AGENTS.md`, and the distinction is the file's own rule.** What ships under
`tools/` is Claude Code plugins — skills, a marketplace manifest, an install command — so it is
specific to Claude Code in the way this file is for. The half that is *not* — that Russian is allowed
there and nowhere else — stays in the language convention in `AGENTS.md`, where every contributor
reads it.

The app only records. What happens to a recording afterwards ships beside it, as a Claude Code
plugin, so that handing someone this repository hands them the whole product rather than half of it.
`.claude-plugin/marketplace.json` at the root makes the repo a marketplace; a recipient runs
`/plugin marketplace add Lexty/acta` and then `/plugin install acta-notes@acta`.

- `tools/acta-notes/` — the post-processing pipeline: local transcription, diarization, speaker
  naming, quality gates, summary. `plugin/` is what gets installed, `tests/` is its suite,
  `PLAN.md` and `FINDINGS-*.md` are its design record.

**Two audiences, two directories, never mixed.** `.claude/skills/` holds skills for *developing*
Acta (`screencapturekit-audio`, `crash-safe-recording`, …); they load automatically when working in
this repo and are useless to someone who just wants to process a recording. `tools/*/plugin/` holds
skills for *using* Acta, installed deliberately. A dev skill must never move under `tools/`, and a
companion skill must never be dropped into `.claude/skills/` — that would install
`swiftpm-macos-app-bundle` onto the machine of someone who only wanted meeting notes.

Rules for anything under `tools/`:

- **Russian is allowed here, and only here.** These skills emit Russian by design — the `summary.md`
  format is Russian, and the trigger phrases a user types are Russian. That is why the language
  convention in `AGENTS.md` excludes `tools/` **by name**, and excludes nothing else. It does not
  license Russian anywhere else.
- **Python, stdlib only** — no pip, no virtualenv, nothing to install. External binaries (`ffmpeg`,
  `fluidaudiocli`) are located at runtime and reported by the plugin's own `doctor.py`.
- Tests run with `make test-skills` from the repo root. They are plain `unittest`, discovered under
  each plugin's `tests/`. **One test module per script**, and every test module's first import is
  `_ctx` — `tests/_ctx.py` is the single place that bridges the suite to the scripts under
  `plugin/skills/*/scripts/`, loading them by file path so stems like `gate`, `merge` and `verify`
  cannot collide with installed modules.
- A plugin's suite asserts things about *this* repo — that `marketplace.json` registers it, that the
  `SKILL_PLUGINS` list in the `Makefile` names it, that this file documents these conventions. Those
  tests are the reason the section you are reading exists; do not delete it to make them pass.
