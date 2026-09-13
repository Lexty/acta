---
name: acta-notes
description: >-
  End-to-end processing of an Acta meeting recording in ~/Acta: local
  transcription (Parakeet TDT via fluidaudiocli), offline VBx diarization,
  utterance-level merge into a verbatim transcript, anchor-based speaker naming
  that never guesses a name, quality gates with a provenance block, then a
  Russian summary.md with bullets and action points enriched from screenshots,
  calendar, Jira, Slack and local project docs. Audio never leaves the machine.
  Use whenever the task is to transcribe a meeting, summarize a recording, find
  WHEN a call about a topic happened, or enrich a meeting with outside sources.
  Trigger on: "транскрибируй встречу", "транскрибируй последнюю встречу",
  "сделай саммари по встрече", "сделай сводку по встрече", "булеты по встрече",
  "суммаризируй запись", "подтяни скриншоты к встрече", "подтяни календарь к
  встрече", "подтяни jira к встрече", "найди когда был созвон по <теме>",
  "обработай запись из ~/Acta", "transcribe the meeting", "summarize this
  recording", "как обычно" (in the context of meeting notes).
---

# acta-notes — transcribe, name speakers, summarize a meeting

Acta is a macOS menu-bar recorder that writes each meeting to `~/Acta/`. This skill is the
post-processing workflow (Acta itself only records). Instructions here are English; every heading
you **write into a file** is the exact Russian string shown in `references/summary-format.md`.

**Division of labour.** The bundled scripts do the machine chain S1–S6 and stop. Everything after
that — reviewing the speaker map, the cleaned `transcript.md`, screenshots, context, `summary.md` —
is yours (D7: no local LLM). Never re-implement a stage in Bash that a script already owns.

## Archive layout

Each meeting is a folder `~/Acta/YYYY-MM-DD_HHMM__<slug>/`:

- `system.wav` — the other participants' audio · `mic.wav` — my microphone. No mix is produced.
- `info.md` — YAML front-matter: `title`, `date` (UTC, `…Z`), `source` (Slack / Microsoft Teams / …),
  `duration` (`HH:MM:SS`), `status`.
- `session.json` — `started_at` (UTC), `segment_count`, `segment_seconds`, `status`.

Working files land in `<meeting>/.acta-notes/` (stage JSONs, 16 kHz wavs, `verify.json`,
`quality.md`). The transcripts, `summary.md` and the two artifacts later stages read —
`diarization.json` (S4) and `speakers.json` (S6) — land in the meeting folder itself.

**Timezone:** the machine runs **WEST (+0100)**; `info.md` / `session.json` are **UTC**, so local
time = UTC + 1 h. Full rules in `references/air-skill-lessons.md` §1.

## The artifact chain — three files, three producers

| file | written by | when |
|---|---|---|
| `transcript.raw.md` | `merge.py` (local ASR) **or** `teams_vtt_to_transcript.py` (Teams) | S5 — verbatim, `SPK_NN` labels, never overwritten without `--force` |
| `transcript.labeled.md` | `speakers.py apply` | S6 — same text, `SPK_NN` replaced by anchored names |
| `transcript.md` | **you, at S7** | the cleaned, readable view — `.acta-notes/quality.md` prepended verbatim |

Two machine artifacts sit beside them at the meeting root and are read, never edited by hand:
`diarization.json` (S4), `speakers.json` (S6) and `<meeting>/dicta.json` (S6.5 — see below).

No script ever writes `transcript.md`; `speakers.py apply` exits 2 if asked to. `transcript.raw.md`
has exactly two possible producers and they are **alternatives** — see the fork in Step 0.

## Step 0 — Identify the meeting, then fork

- "last meeting" → newest folder in `~/Acta` by name/mtime.
- "the call about `<topic>`" → search the calendar, then match the event window to a folder
  (folder local start ≈ event UTC + 1 h, within a few minutes). **Calendar subjects contain typos** —
  a real case: the a client review was titled "*a client* review", so an exact search missed it. Search by
  a short root, by attendees and by time window. Details in `references/air-skill-lessons.md` §2.

  Read the calendar with the **`mac-pim`** CLI (`/mac-pim` skill), not a cloud connector — it reads
  this Mac's own store, which is the copy that is actually current for an Exchange/M365 account:

  ```bash
  mac-pim cal events --from -14d --to now --query "a-client" --no-notes
  mac-pim cal events --from "2026-07-29 00:00" --to "2026-07-30 00:00" --no-notes   # by window
  ```

  Because subjects are unreliable, prefer the time window and fall back to `--query` with a short
  root. `attendee_count` feeds `--num-speakers` and `attendees[].name` feeds `--attendees` below;
  attendees whose `status` is `declined` were invited but did not attend, so drop them from the
  count. If `mac-pim` is missing or unpermitted it says so via `mac-pim doctor` — it needs a
  one-time `mac-pim setup` that raises two macOS dialogs, so never run it mid-task unannounced.
- Confirm with `info.md` (source + duration) before spending compute.
- **For a Slack meeting, take the roster from the huddle itself, not only the calendar.** The
  huddle's own participant list is the authoritative attendance — who was actually there, not who was
  invited (a real case today: 18 invited on the calendar, 14 in the huddle) — and for an **ad-hoc
  huddle with no calendar event it is the only source of participants at all**. Find the huddle
  message by the recording's start time (`session.json.started_at`, UTC → epoch) and read
  `room.participants`:

  ```bash
  # a one-to-one huddle lives in the DM; a group huddle in a channel
  slack-cli conversation open <user-id>            # → DM channel id for a 1:1
  slack-cli channel history <chan> --oldest <epoch-120> --latest <epoch+300> --all --ndjson \
    | jq -c 'select(.room.participants) | {ts, participants: .room.participants}'
  slack-cli user info <id>                          # resolve each id → real name (Cyrillic)
  ```

  Filter on the presence of `room.participants`, **not** on `subtype` — a 1:1 huddle arrives as
  `huddle_thread` but a group huddle as `thread_broadcast`. The channel is one of the candidates from
  `slack-cli channel list`. The roster feeds `--num-speakers` (its size minus your own mic track) and
  `--attendees` — take the Cyrillic names from the Slack profiles, do not transliterate the calendar's
  Latin ones (the mapping is not guessable, and a wrong form makes an anchor silently miss;
  see `references/air-skill-lessons.md` and the memory on Cyrillic attendees).
  ⚠️ **A two-person roster (you + one other) is itself a D8 anchor**: every non-mic voice is
  unambiguously that one person, no vocative needed — name them even though diarization split the
  single voice into several `SPK_NN`. A larger roster only *narrows* the candidate set; a per-speaker
  name still needs a vocative / self-introduction in the text (D8), so a crowded huddle can legitimately
  leave an `SPK_NN` sitting between two named candidates rather than resolved.

Then decide **which of the two paths produces `transcript.raw.md`**. They are mutually exclusive:

| | condition | what runs |
|---|---|---|
| **A — local ASR** | no official transcript (Slack huddle, Meet, Teams without one) | `pipeline.py` from the top |
| **B — Teams VTT** | an official Teams transcript exists | `teams_vtt_to_transcript.py`, then `pipeline.py --from-stage speakers` |

Path B is **strictly better** where it applies (real speaker names, no ASR errors) and it replaces
stages S1–S5 wholesale: on that path no audio is preprocessed, gated, transcribed or diarized. The
converter is **not** a stage inside `pipeline.py` and `pipeline.py` never invokes it.

To fetch the official transcript: find the event, read its `meetingTranscriptUrl`
(`meeting-transcript:///events/<b64>`), read that resource — a large result is auto-saved to a file —
and hand that file to the converter.

## Path A — the machine pipeline

One invocation runs `doctor` → `prep_audio` → `gate` → `transcribe` → `diarize run --track system`
→ `merge` → `speakers build` → `speakers apply` → `dicta_overlay` → `verify`:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/pipeline.py" \
  ~/Acta/2026-01-15_1000__weekly-review \
  --num-speakers 4 \
  --attendees "Дмитрий Иванов,Любовь Петрова,Анна Смирнова" \
  --json
```

- **`--num-speakers`** — the attendee count from the calendar. Pass it whenever you know it; it is
  the primary diarization control. Omitted, the run falls back to a 0.75 threshold (the CLI's 0.6
  default is never used — measured, it collapses everything into two speakers).
- **`--attendees`** — the calendar attendee list, forwarded to `speakers build`. Once supplied it is
  authoritative: an anchor it does not recognise names nobody. Absent, the build still runs
  anchor-only.
- Long meetings take minutes — run it with `run_in_background: true` and wait for the notification.
- Reruns: `--from-stage <stage>` or `--only <stage>`; fresh outputs are skipped, `--force` redoes
  them. `--force` is deliberately **not** forwarded to `merge.py`, so if merge would have to
  overwrite an existing `transcript.raw.md` the whole run **refuses up front** (exit 2, nothing
  executed) rather than burning an ASR pass to die at S5. The check is predictive: it also fires
  when an upstream stage is merely *about to* re-run — re-recorded audio, a changed `--chain`,
  wavs removed by `--cleanup-wavs` — since that stage would make the transcript stale mid-run. Two
  ways past it, both yours to choose: replace the transcript deliberately by re-running the same
  command with `--replace-transcript` (which is the only thing that forwards `--force` to
  `merge.py`), or keep it and resume with `--from-stage speakers`. Running `merge.py --force` by
  hand first does *not* clear the refusal — the upstream stage is still stale, so the next
  `pipeline.py` refuses again for the same reason.
  A Teams-converted folder is the same case: run it with `--from-stage speakers`, never plain.
- A cache hit matches on **parameters**, not just mtimes. Changing `--chain`, `--language`,
  `--custom-vocab`, `--num-speakers` or `--attendees` re-runs the stage that owns the flag instead
  of silently reusing an artifact built with the old one. The check lives in the driver *and* in
  each stage script, so it holds whether you run `pipeline.py` or the script directly. *Dropping* a
  flag is not changing it: an omitted flag means "re-use what is there", so a bare re-run after a
  flagged one is a cache hit, not a rebuild with the stage's default. And when the stage has to
  re-run anyway — a re-recorded track, `--replace-transcript`, wavs removed by `--cleanup-wavs` —
  it re-runs with the value recorded on disk, not with the stage default: all five flags are read
  back from the stage JSONs, so a `--num-speakers 3 --language ru` folder stays that way without
  you repeating the flags. Going back to a default is
  `--force` (deliberate), never an omission (accidental) — which is what keeps the bare
  `--from-stage speakers` rerun below from rebuilding a corrected `speakers.json`. A flag whose
  owning stage is *not* in the selection is refused up front (exit 2) rather than dropped, so
  `--from-stage speakers --num-speakers 5` cannot exit green having ignored the count.
- **`--language` / `--custom-vocab`** — the two D6 ASR opt-ins, both off by default and both
  forwarded to `transcribe.py`. Parakeet auto-LIDs (pinning `ru` did not move WER) and hotwords
  carry a false-substitution risk (`при` → `IREE`), so reach for them only with a reason.
- `--cleanup-wavs` deletes the 16 kHz intermediates after a green run (~230 MB/h of meeting). It is
  suppressed when a hard gate trips, so a failure stays diagnosable — and equally when the run
  never reached `verify` at all (`--only prep_audio`), since nothing has confirmed the transcript
  those wavs produced.
- A mic track that is effectively silent is not transcribed, and the run records why. `diarize` is
  never run on the mic track — the mic is `Я` by construction (D5).
- **A track that is merely quiet is not silent, and the run fixes it itself.** The silence gate is
  an absolute RMS threshold calibrated for a normally-levelled capture, so a track recorded far
  below level used to clear no span at all, get called `effectively_silent`, be dropped from the ASR
  pass — and the run would finish **green with one side of the conversation missing** (measured
  2026-08-03: mic ~30 dB under `system`, 110 words lost). S2 now re-gates such a track at its own
  level and reports `under_levelled` instead; `pipeline.py` re-runs S1 for that track alone with
  `--chain loudnorm`, re-gates, and carries on. You will see `re-levelled (was too quiet for the RMS
  gate…)` in the run output and a per-track chain in the provenance line
  (`предобработка: mic=loudnorm, system=denoise`). Nothing to do by hand. If loudnorm cannot rescue
  it the run says `⚠ still under-levelled` rather than quietly calling it silent — that one is worth
  listening to before trusting the transcript.

## Path B — the Teams converter, then resume

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/teams_vtt_to_transcript.py" \
  ~/Acta/2026-01-15_1000__weekly-review \
  ~/Downloads/meeting-transcript.json

python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/pipeline.py" \
  ~/Acta/2026-01-15_1000__weekly-review --from-stage speakers
```

The resume runs `speakers build` → `speakers apply` → `verify` against a folder that holds only
`transcript.raw.md`; the missing ASR/diarization stage JSONs are expected, and their provenance
fields read `n/a`. The converter refuses to replace an existing `transcript.raw.md` in exactly the
same words `merge.py` uses — neither producer can clobber the other.

If the folder had already been through a local-ASR run, `--force` replaces its `transcript.raw.md`
and the converter moves that run's S1–S5 stage JSONs (`prep_audio.json`, `gate.json`,
`transcribe.json`, `merge.json`, `diarization.json`) into `.acta-notes/superseded/` — archived, not
deleted, and reported in the run's output. Their **absence** is what `verify.py` reads as "official
Teams transcript"; left in place they would make `quality.md` claim local ASR, score the previous
run's per-word confidence against the Teams text and put its diarization coverage through a hard
gate. `speakers.json` and `transcript.labeled.md` are deliberately left alone: the resume rewrites
them, precisely because they are now older than the transcript. The two halves land together or not
at all — if a stage JSON cannot be archived the conversion **fails with the folder untouched**
(non-zero, no new transcript), because a Teams transcript sitting beside a readable
`transcribe.json` is exactly the mis-provenance this avoids. Move the named file out of
`.acta-notes/` by hand and re-run.

## When doctor is red

`pipeline.py` refuses to start rather than dying mid-meeting. Run the check on its own to see why:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/doctor.py" --json
```

- **missing/stale bootstrap stamp** → build the binary:
  `bash "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/bootstrap.sh"` (clones FluidAudio at the
  pinned tag and builds `fluidaudiocli`; a second run is a no-op).
- **a required model absent** — only `parakeet-tdt-0.6b-v3` and `speaker-diarization` are required;
  FluidAudio downloads them on first use.
- **optional models `absent`** — `sortformer`, `ls-eend`, `parakeet-ctc-110m-coreml` are
  **informational and never block a run**. v1 never invokes the streaming diarizers, and the CTC
  model is loaded only by an opt-in `--custom-vocab`. Do not "fix" these lines.
- **disk** — red under 2 GB, warn under 5 GB. Under 2 GB, free space before starting.

## When a hard gate trips

`verify` exits 1 and `pipeline.py` propagates it, prints `quality.md` to stderr and keeps every
artifact (including the wavs — `--cleanup-wavs` is suppressed). Only three checks can do this:

- **`transcript`** — the file holds no `**[HH:MM:SS] LABEL:**` lines. Something upstream produced
  nothing; read `.acta-notes/pipeline.json` for the stage that failed.
- **`repeated_phrase_loop`** — a real ASR decoder loop: the *same speaker* repeating a phrase of
  three words or more. Re-run `transcribe.py <meeting> --track <track> --force`, then
  `merge.py <meeting> --force`, then `pipeline.py <meeting> --from-stage speakers` — the same
  three-command shape as the bullet below, and for the same reason: a plain `pipeline.py` re-run
  refuses with exit 2 rather than overwrite `transcript.raw.md`. If the loop recurs, the audio
  segment is the problem, not the model. (Cross-speaker "да / да / да" is conversation and is not
  flagged.)
- **`diarization_coverage`** below 80 % — the clustering disagrees with the word timings. Re-run
  `diarize.py run <meeting> --track system --num-speakers N --force` with the true attendee count,
  then `merge.py <meeting> --force`, then `pipeline.py <meeting> --from-stage speakers`. Or, in one
  command, `pipeline.py <meeting> --num-speakers N --replace-transcript` — the changed count alone
  restales `diarize`, so prep_audio and the ASR pass stay cached. Not `--force` here: that would
  also send `--chain` back to its default and re-prep the audio.

Do not paper over a tripped gate by continuing to S7: `quality.md` is prepended to `transcript.md`
verbatim, so the ⚠ block is what tells the reader the transcript is suspect.

## S6 — review `speakers.json`

`speakers build` has already written `<meeting>/speakers.json` and `apply` has already
substituted every **anchored** speaker into `transcript.labeled.md`. Your job is to read the result,
not to redo it:

- Read the entries in evidence order. Each carries `name`, `evidence[]` (the matched span),
  `anchor_type`, `confidence`, `anchored|inferred`.
- An `inferred` speaker keeps its `SPK_NN` label — that is correct behaviour, not a bug. **Ask the
  user** ("кто такой SPK_03, говорит про…, вот реплика") rather than guessing from the attendee list.
- A `name_conflict` field means two diarized speakers claimed the same name; the weaker claim (or
  both, on a tie) was demoted to `inferred` rather than render one person as two voices. Ask the
  user which `SPK_NN` is that person — do not resolve it yourself.
- An `uncorroborated` field means a single address was seen with no attendee list to check it
  against ("Отлично, поехали" and a real short name look identical to a regex), so the name was
  withheld. The surface is in `evidence[]`. Re-run `speakers build --attendees …` if the user
  confirms it is a person.
- If the user names a speaker, re-run `speakers build` with a corrected `--attendees` list and then
  `speakers apply`; do not hand-edit `transcript.labeled.md`. That route is the documented one
  because it keeps `evidence[]` honest about where the name came from. A `speakers.json` that
  changed after `apply` ran is still not lost, though: `pipeline.py --from-stage speakers` sees the
  map is newer than `transcript.labeled.md` and re-runs **`apply` alone**, so it relabels the
  transcript instead of either skipping it or rebuilding the map over the edit.

## S6.5 — the dictation that leaked in (`dicta.json`)

`dicta` is the sibling voice-dictation app: press a chord, speak, the text lands in the terminal.
It opens **the same microphone Acta is recording**, so a prompt dictated to an agent during a call
is captured into `mic.wav` and reads in the transcript as something the user said *to the meeting*.
Muting yourself in Slack or Teams does not prevent it — that mutes what the others hear, not what
Acta captures.

`dicta_overlay.py` correlates the two and writes `<meeting>/dicta.json`. It runs automatically, is
cheap (no model, no audio), and **writes no transcript**. Nothing else in the chain changes.

How it decides, and why you can lean on it: both programs run the *same* recogniser (Parakeet TDT
0.6B v3, 16 kHz), so one utterance decoded twice comes out near-identical, and the match is on
**text**, not on time. Time only narrows the search — the transcript's clock is an offset into the
assembled wav while dicta's is wall clock, and the drift between them (startup probe, watchdog
restarts, recovered segments) is real and unknown in advance. Two confident matches calibrate that
offset; the measured value lands in the provenance line, and it is the only place it is ever visible.

Three verdicts, and they are **not** interchangeable:

| verdict | what it means | what you do |
|---|---|---|
| `matched` | the dictation's text was found in the mic track | mark it at S7; apply the summary rule below |
| `suspected` | dicta had a speech window here but no text that could place it — none produced, or too few words to align on | placed by the window alone: **check it by ear or by reading the line**, never exclude on this evidence |

| `unmatched` | dicta recorded a dictation during the meeting whose text is *not* in the transcript | the loud one — a dictation is probably in there unmarked. Say so to the user rather than ignoring it |

A `suspected` span carries `uncertainty_seconds` and `lines_within_uncertainty`, and both are the
point of it. Its position comes from arithmetic on two clocks, so it is only as good as whatever
measured the difference between them — with no text match anywhere in the meeting the clocks were
never compared at all, `placement` reads `uncalibrated`, and the uncertainty is the full ±90 s drift
budget. Read the timecode as "somewhere in here", never as a location, and check
`lines_within_uncertainty` before touching anything: when it is much larger than the lines the
nominal window names, the nominal window is a guess and marking those lines would be wrong.

Each `matched` span names the `merge.json` utterance indices it covers, and flags a line it only
**clips** (`partial: true`). Mark the clipped part, not the whole turn: over-marking real meeting
speech is the harmful error here, and failing to mark a dictation merely leaves things as they were.

**The verdict keys on text, never on `outcome`.** If a span carries text, it is placed by that text
and treated as a dictation whatever became of the attempt — including an `aborted` one, whose
`final` is empty because it never reached a terminal. It went into the microphone Acta was recording
either way, and it was addressed to a terminal either way; the summary treats it identically.

Today dicta writes no text for the discarded classes, so in practice those arrive as `suspected`.
Recognising a cancelled buffer for the journal — which would place such spans to the word, and let
them anchor the clock — is decided and built in that project but **not yet merged**, so nothing here
depends on it. When it lands it will cover `aborted` and `capped` only: a `capture-fault` has its
samples dropped in the capture layer itself, because the boundary is in doubt, so that class stays
evidence-free and `suspected` is its permanent answer. This stage needs no change either way, which
is the point of keying on text rather than on outcome.

`dicta.json` also carries `target` — the agterm session and pane the text was aimed at. That is the
record's own statement that this speech was addressed to a terminal rather than to the people in
the call, and it is worth reading before deciding what a span was about.

The stage **skips**, green and without comment, when there is no dicta record (`dicta` not installed
or never used) and on the Teams path, where there are no local word timings and the official
transcript runs on its own clock. It never fails a run.

## S7 — write `transcript.md`

Build it from **`transcript.labeled.md`**, with `.acta-notes/quality.md` prepended **verbatim** (it
is the ⚠ block plus the provenance line — transcript source, engine and FluidAudio tag, denoise
chain, diarization settings, gate threshold, which names are anchored vs inferred).

Two constraints, both paid for by `lab/007` (`references/lab-verdicts.md` §4):

1. **Preserve speaker markers.** Minutes without speaker attribution are not minutes; a cleanup pass
   drops them silently if you let it.
2. **Never invent content.** Cleanup canonicalizes terms and formats; it does not repair meaning. An
   audio-blind rewrite turns a garbled-but-recoverable error into a *fluent wrong* term. Leave a
   low-confidence span marked rather than smoothing it over.
3. **Mark every `matched` span from `<meeting>/dicta.json`.** The line keeps its text verbatim; only
   its label changes, to `**[HH:MM:SS] Я ⟨диктовка⟩:**`. A `partial` span marks the clipped part
   inline (`⟨диктовка: …⟩`) rather than the whole turn. Nothing is deleted — the reader has to be
   able to see what was said and why it is set apart.

`transcript.raw.md` stays untouched — cleanup is a **reversible view** over it.

## S8 — screenshots and context

**Screenshots.** macOS saves them to `~/Desktop` as `Screenshot YYYY-MM-DD at HH.MM.SS.png` (local
capture time). Compute the meeting window (local start = `session.json.started_at` + 1 h, end =
start + `duration`), copy only the shots inside it into `<meeting>/screenshots/` with `cp -p`, Read
each PNG for its slide content, and align: **a shot lands 30–60 s after the slide appeared**, so the
discussion slightly precedes it — quote the window `[offset − 95 s, offset + 20 s]`. Write
`screenshots.md`: time, filename, slide content, and the verbatim excerpt being said.
`teams_vtt_to_transcript.py --shots` prints those windows for a Teams transcript.

**Context.** Calendar via `mac-pim cal events` (subject, organizer, attendees + response status,
follow-ups) and, when a thread is cited, mail via `mac-pim mail search --since …` — bound it by date
and check its `coverage` field before saying an email does not exist. Then Jira by topic
(extract with `jq`, never dump full descriptions, mark keys **approximate** — ASR has no bare keys),
local project docs under `~/dev/<project>/<client-or-topic>/` mapped to concrete requirement IDs, Slack only
when relevant. Record the metadata in `context.md` and fold the substance into `summary.md`.

**⚠ Secrets hygiene:** if a source doc contains a credential (a real `an auth token` once sat in a
`notes.md`), never copy it into a summary — flag it to the user. Full discipline in
`references/air-skill-lessons.md` §§3–4.

## S9 — `summary.md`

Follow `references/summary-format.md` exactly — it is the predecessor's structure verbatim, which is
what makes "как обычно" keep producing the same document. Russian, owner-attributed bullets, every
claim tied to a timestamp, a requirement ID, a ticket or a source doc.

## The rules that outrank convenience

- **`transcript.raw.md` is the source of truth.** Every later transcript is a view over it; cleanup
  never changes content and never drops speaker markers.
- **A decision or an action item is never attributed to a person on diarization alone** (D8).
  Diarization labels are advisory — a name comes from an anchor (self-introduction, vocative,
  calendar corroboration) or the speaker stays `SPK_NN`. A confidently wrong attribution is worse
  than an unnamed one.
- **A dictation span is not a meeting utterance.** A `matched` span in `dicta.json` was speech aimed
  at a terminal, and the summary treats it under the rule in `references/summary-format.md`: never a
  quoted position, never an action point on its own, and used as context only with the qualifier.
  A `suspected` span carries no such licence — it is a question for the user, not a verdict.
- **Transcripts leave the machine** (D7). Audio, ASR and diarization are entirely local, but cleanup
  and summarization run in Claude, so the transcript text is sent out. Say so if the user asks, and
  do not paste a transcript anywhere else without being asked.

## Archive upkeep — the index and audio retention

Two scripts maintain the archive itself rather than any one meeting. Neither is part of the
S1–S9 chain and `pipeline.py` never calls them.

**Why retention is not optional.** Acta records 48 kHz stereo PCM on both tracks — ~1.7 GB per
hour of meeting — while the pipeline downmixes to 16 kHz mono before ASR sees any of it. At a
normal meeting load that fills a disk in weeks. The transcripts and summaries, meanwhile, are a
few megabytes for an entire archive. So the audio is the only thing that needs a policy:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/archive_retention.py"          # dry run
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/archive_retention.py" --apply
```

- Default is a **dry run**; `--apply` is what writes and deletes.
- A meeting is eligible only when a non-empty `summary.md` exists, a transcript with speaker
  markers exists, it is older than `--older-than` days (default 7), and — if `verify.json` is
  present — **every check in it is green**. A meeting whose gate tripped keeps its audio, because
  that is exactly the audio someone will want to hear.
- Before any source wav is deleted the encoded copy is **fully decoded** and its duration compared
  against the wav read with the stdlib `wave` module. A truncated encode fails the gate and the
  original survives; that check is the whole point of the script.
- Default `--codec opus` at 32 kbps mono per track is ~29 MB/hour and stays fine for re-listening
  and for a later ASR pass. `--codec flac` writes 16 kHz mono instead — lossless against what
  Parakeet actually consumes, ~4× larger.
- Tracks are encoded **separately and in mono**: `mic` = me and `system` = them is load-bearing for
  diarization, so the two must never be mixed into one file.
- `--prune-work` additionally drops `.acta-notes/*.wav`, the 16 kHz intermediates the pipeline
  regenerates on demand. Safe at any age.
- To re-run the pipeline over an archived meeting, put its wavs back first:
  `archive_retention.py --restore <meeting> --apply`.

**The index** turns the flat archive into something readable without opening folders. The flat
layout is deliberate — folder names sort chronologically and "newest folder in `~/Acta`" depends
on it, so do not nest by year or month:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/scripts/archive_index.py"
```

It writes `INDEX.md` at the archive root from what each meeting already contains: time and duration
from `info.md`, the topic from the `summary.md` heading, the participants line, which artifacts
exist, and the state of the audio. The file is derived — safe to delete and regenerate, and it
flags any meeting still missing `summary.md`.

## Reference docs

- `references/summary-format.md` — the exact Russian `summary.md` skeleton and how to fill it.
- `references/air-skill-lessons.md` — timezone arithmetic, meeting identification, the screenshot
  lag, context-gathering discipline, secrets hygiene.
- `references/lab-verdicts.md` — what was measured: preprocessing levers, engine complementarity,
  the two-track decision, the cleanup constraints.

## Gotchas

- Large tool results are auto-saved to a file (path is in the message) — slice them with `jq` or
  Python, do not read them line by line.
- Foreground `sleep` is blocked; run the pipeline with `run_in_background: true`.
- Calendar/M365 sessions expire mid-task; retry once, then fall back to what is on disk.
- Every script is Python 3 stdlib only and takes its binaries from `ACTA_FLUIDAUDIO_BIN` /
  `ACTA_FFMPEG_BIN` when set. Nothing here installs anything globally.
