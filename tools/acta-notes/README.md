# acta-notes

The post-processing half of [Acta](../../README.md): takes a meeting folder in `~/Acta` and
produces a verbatim transcript, a speaker-named transcript, and a summary. Packaged as a Claude
Code plugin — skills plus Python scripts, nothing compiled.

Audio, transcription and diarization run entirely on this machine. Summarisation runs in Claude,
so the transcript *text* is sent out; the skill says so, and says it again if you ask.

## Install

```
/plugin marketplace add Lexty/acta
/plugin install acta-notes@acta
```

Then, once:

```sh
brew install ffmpeg
bash "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/bootstrap.sh"
```

`bootstrap.sh` clones FluidAudio at a pinned tag and builds `fluidaudiocli`. It is idempotent — a
second run is a no-op — and it writes a stamp that `doctor.py` reads rather than re-deriving the
tag from git. The speech models download themselves on first use.

Check the result:

```sh
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/doctor.py" --json
```

`doctor.py` is the diagnostic for everything below: binaries, models, disk. Three of the models it
lists are optional and never block a run.

## Use

Ask Claude in plain language — "транскрибируй последнюю встречу", "сделай саммари по встрече",
"найди когда был созвон по <теме>" — or invoke `/acta-notes` directly. The skill decides between
the local-ASR path and the shortcut for meetings that already have an official Teams transcript.

Everything the skill knows about the pipeline, its stages, its failure modes and the discipline it
follows when naming speakers is in
[`plugin/skills/acta-notes/SKILL.md`](plugin/skills/acta-notes/SKILL.md). Start there.

## Archive upkeep

Two scripts maintain `~/Acta` itself rather than any one meeting, and neither is part of the
processing chain:

```sh
S="$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts"
python3 "$S/archive_index.py"                    # regenerate ~/Acta/INDEX.md
python3 "$S/archive_retention.py"                # dry run: what would be compressed
python3 "$S/archive_retention.py" --apply        # compress it
```

Retention matters more than it sounds: Acta records 48 kHz stereo PCM on both tracks, ~1.7 GB per
hour, while the pipeline only ever consumes 16 kHz mono. Opus at 32 kbps per track is ~29 MB/hour
and stays good enough to re-listen and to re-run ASR; `--codec flac` writes 16 kHz mono instead,
lossless against what the recogniser actually sees.

Nothing is deleted on trust. Before a source `.wav` is removed, the encoded copy is fully decoded
and its duration compared against the original — a truncated encode fails the check and the
original survives. A meeting is eligible only once it has a summary and a speaker-marked
transcript, and only if no quality gate went **red**. `--restore <meeting> --apply` decodes the
tracks back to wav so the pipeline can run over them again.

## Development

```sh
make test-skills            # from the repository root
```

887 tests, plain `unittest`, no dependencies. Conventions — one test module per script, `_ctx` as
every module's first import, stdlib only — are documented in the repository's
[`CLAUDE.md`](../../CLAUDE.md), and the suite asserts that they stay documented.

`PLAN.md` is the original design document; `FINDINGS.md` records what
processing 44 real meetings turned up.
