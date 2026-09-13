# `acta-notes` — plan for the Pro-grade meeting-notes skill

**Goal.** A successor to `~/air-rescue/claude/skills/acta-meeting-notes` for this machine
(MacBook Pro, **M3 Pro, 18 GPU cores, 36 GB**), with two capabilities the Air skill does not have:

1. **Better transcription** — Parakeet TDT 0.6B v3 on CoreML/ANE instead of `mlx_whisper`
   large-v3-turbo, per-track, with word-level timestamps and confidence.
2. **Real diarization** — speaker turns on the *system* track (who of the others is speaking),
   not just the two-track `Я` / `Собеседники` split.

Everything else the Air skill does well (source gathering, screenshots, the Russian `summary.md`
format) is **ported, not redesigned**.

> **Evidence base.** Two independent sources, both re-verified today:
> - The June-2026 `wsp`/Acta lab program (10 experiments, written verdicts, run on **this**
>   machine on **these** meetings) — cited inline as `lab/NNN`.
>   Archive: `~/dev/_archive-2026-07-28/personal/wsp/lab/`.
> - **A live spike run on 2026-07-29** — FluidAudio v0.15.5 built from source and run end-to-end
>   on `~/Acta/2026-01-15_0901__slack-2026-01-15-09-01` (57:03, ~6 speakers). Every number
>   marked **[measured 07-29]** below comes from that run, not from documentation.
>
> The spike **falsified three assumptions** in the first draft of this plan. They are called out
> as ⚠ **CORRECTED** where they appear.

---

## 0. Environment (verified 2026-07-29)

| thing | state |
|---|---|
| `~/Acta/` | 34 meetings; `system.wav` + `mic.wav`, **48 kHz stereo pcm_s16le** (~657 MB/track for 57 min) |
| toolchain | `ffmpeg`, `python3`, **Swift 6.3.2 (Command Line Tools only — no full Xcode; SwiftPM builds fine)** |
| **missing** | `mlx_whisper`, `ollama`, `lms`, `uv`, `sox` |
| FluidAudio models on disk | `parakeet-tdt-0.6b-v3` (461 MB, from June), `speaker-diarization` (21 MB, **auto-downloaded during the spike**), plus `ls-eend` / `sortformer` / `parakeet-ctc-110m` |
| lab harness | `lab/010/bench/compute/.build/release/diar-bench` built; `merge_diar.py`, `summit_ref.py`, `annotate.html` |
| `~/.local/bin/acta` | Rust CLI, 2026-06-25 — `diarize` is a **stub** in the default build. Not a dependency. |
| **free disk** | **19 GB of 460 GB (96 % full)** — a real constraint, see §6 |

**Consequence:** the Air skill's transcription path (`mlx_whisper`) does not run here at all. The
transcription stage is replaced outright, not tuned.

---

## 1. Design decisions

### D1 — ASR engine: **Parakeet TDT 0.6B v3 via `fluidaudiocli transcribe`**
- `tech-currency` re-check **2026-07-29** (`ml-asr__asr-best-quality`, previously 2026-06-24):
  verdict **unchanged**. Parakeet v3 is the on-device consensus — 25 European languages incl. RU
  with auto-LID, throughput leader. The tier above is cloud/large only (Canary-Qwen 2.5B ~5.63 %
  mean WER, leaderboard #1) → rejected on privacy.
- **[measured 07-29]** on the full 57-min system track: **9.4 s processing / 9.96 s wall**,
  **RTF 0.0027 ≈ 365× realtime**, 5371 words, mean confidence **0.959**. Russian output is
  coherent and punctuated; errors are the expected ones — proper nouns and jargon
  (a given name gaining a leading consonant, `best shot`→`бэшот/бесшот`, an acronym read as a word, `podium`→`подиум`).
- **Do not expect a large WER win over whisper.** `lab/003`/`lab/004`: all engines cluster at
  ~0.18–0.21 WER on this exact audio; the apparent "whisper 7 %" was a reference-seed artifact.
  The real wins are: **no hallucination loops**, **no `--language` footgun**, **365× realtime**,
  **native RU+EN+PT in one model**, and **word-level timings + per-word confidence**.

### D2 — Diarization: **FluidAudio Offline VBx**, but it does **not** work at defaults ⚠ **CORRECTED**
`fluidaudiocli process <wav> --mode offline` → `OfflineDiarizerManager` (segmentation → WeSpeaker
embeddings → **VBx clustering with PLDA scoring**). Models auto-download (21 MB).

**[measured 07-29] on an 8-min slice of a ≥5-speaker meeting — the clustering threshold is
decisive and the documented default is wrong for this audio:**

| `--threshold` | speakers found | speech per speaker |
|---|---|---|
| 0.30 | **1** | S1 273 s |
| 0.45 | **1** | S1 273 s |
| **0.60 (default)** | **2** | S1 270 s, S2 **2 s** ← total collapse |
| 0.75 | 4 | 118 / 111 / 40 / 2 s |
| 0.90 | 3 | 150 / 118 / 2 s |

Pinning the count works far better than tuning the threshold:

| `--num-speakers` | detected | speech per speaker |
|---|---|---|
| 3 | 2 | 270 / 2 s ← still collapses |
| **4** | 4 | 98 / 72 / 57 / 41 s |
| **5** | 5 | 96 / 70 / 40 / 37 / 25 s |
| **6** | 6 | 97 / 45 / 40 / 35 / 27 / 25 s |

→ **`--num-speakers`, seeded from the calendar attendee list, is the primary control.** Auto
speaker-count detection on this audio is not trustworthy. Full meeting with `--num-speakers 6`:
**[measured 07-29]** 622 segments, 6 speakers, plausible distribution (833 / 550 / 194 / 185 /
182 / 133 s), **12.25 s wall, RTFx 291**.

**Quality is usable but NOT authoritative.** Reading the merged transcript, two failure patterns
are consistent:
- a **"sink" speaker** that absorbs the tail of other people's sentences ("…ну либо просто
  перевести" / *new speaker* "продолжение фразы…" — one continuous sentence, split);
- **question and answer merged into one speaker** inside a long turn.

This is a hard constraint on what the summary may claim — see D8.

Sortformer (already on disk, driven by the lab's `diar-bench`) stays as a **cross-check** for
≤4-speaker calls.

### D3 — Timestamps: **solved, no fallback needed** ⚠ **CORRECTED**
The first draft carried "does `transcribe` emit timestamps?" as the plan's biggest risk, with two
fallback paths. **Read from source and verified by running it:** `transcribe` supports
`--word-timestamps` and `--output-json`; the JSON contains a `wordTimings[]` array of
`{word, startTime, endTime, confidence}` — **[measured 07-29]** 716 entries on an 8-min slice.
Also available: `--language`, `--custom-vocab`, `--model-version v2|v3|110m`,
`--encoder-precision int8|int4`. **The chunking and Swift-wrapper fallbacks are dropped.**

Per-word confidence also makes D8's low-confidence flagging free.

### D4 — `--rttm` is an **input**, not an output ⚠ **CORRECTED**
The GitHub docs read as if `--rttm` writes an RTTM. In source it is **ground-truth annotation
input: "Compute DER/JER against RTTM annotations."** Speaker turns come out via `--output <file>`
(JSON with `segments[] = {startTimeSeconds, endTimeSeconds, speakerId, qualityScore, embedding[]}`).

This is a **bonus**, not a loss: hand-annotate one meeting with the lab's already-built
`annotate.html`, feed the RTTM back with `--rttm`, and **the CLI computes DER/JER itself** — no
separate scorer, and `lab/001`'s open "no DER number yet" finally closes.

### D5 — Two-track stays, and the mic track earns its keep
`lab/006`: mic and system are complementary — a system-only transcript loses the user's own
speech. **[measured 07-29]** on the full meeting: the mic track yields **272 words / 164 s of
speech (4.8 % of 3423 s)** — the user mostly listened, but those 164 s exist nowhere on the
system track. Mic → `Я` for free, no model needed; diarization runs **only on the system track**.

**Nuance the lab could not know:** `lab/006`'s catastrophic finding — ungated Whisper
hallucinating **118 of 133** mic segments over silence — **did not reproduce with Parakeet**.
272 words over 3423 s of mostly-silence, no repeated junk. So the D6 gate is demoted from
"mandatory correctness fix" to "cheap insurance + a way to keep empty spans out of the merge".
Keep it, but it is no longer the load-bearing invariant it was for Whisper.

### D6 — Preprocessing: keep denoise, **drop `loudnorm`** ⚠ **CORRECTED**
`lab/003` swept preprocessing levers against a hand reference and concluded the L2 chain
`highpass=f=80,afftdn=nr=12,loudnorm` is the one that helps (~0.7–1.4 pp WER). It measured the
chain **as a bundle** and never priced its parts. **[measured 07-29] on the 57-min track:**

| chain | wall time | ASR output vs full chain |
|---|---|---|
| plain 48k→16k mono | **1.8 s** | 11.6 % token disagreement |
| `highpass + afftdn` | **10.4 s** | **3.2 % disagreement** |
| `highpass + afftdn + loudnorm` (lab L2) | **120.5 s** | — (reference) |

**`loudnorm` costs ~110 s per track and changes ~3 % of tokens.** Denoise itself matters
(11.6 % change vs plain) and is nearly free. At 2 tracks, dropping `loudnorm` removes **~3.7
minutes** from a pipeline whose entire ML stage is ~22 s.
→ **Default chain: `highpass=f=80,afftdn=nr=12`.** Re-test `loudnorm` against a hand reference in
Phase 4; ship without it until it earns the 110 s. *(Mean confidence is flat across all three
variants — 0.961–0.964 — so confidence cannot adjudicate this; only a reference can.)*

Other levers from `lab/003`, unchanged: `--language ru` pin does not move WER (and Parakeet
auto-LIDs); hotwords are WER-noise with a false-substitution risk (`при`→`IREE`) → **opt-in only**.
*(FluidAudio v0.15.5 rebuilt custom-vocabulary/hotword handling, so this is worth one
re-measurement before writing it off permanently.)*

### D7 — Cleanup & summarization: **Claude, no local LLM**
`lab/007` proved a local **qwen3-14b** does product-grade non-destructive cleanup (change-WER
0.05, canonical terms 25→47) and that the 1.5b rung is unusable. No local LLM runtime is
installed here, and the skill runs inside Claude anyway. **Claude does cleanup + summary**, as the
Air skill does today. *(A local-only mode is explicitly out of scope for this plan.)*
- Keep the **raw** transcript alongside the cleaned view — cleanup is a reversible view.
- Carry `lab/007`'s two prompt constraints: **preserve speaker markers** (the LLM dropped
  `[Я]`/`[—]` in the lab run) and **never invent content** — an audio-blind LLM turns a
  garbled-but-recoverable ASR error into a *fluent wrong* term.
- **Transcripts leave the machine.** State it plainly in `SKILL.md`.

### D8 — Ship the flag, not the fix
`lab/004` showed engine errors are complementary (oracle fusion 7/9 hard items vs 5/9 best
single); `lab/003` pointed at flag-then-re-transcribe. Both need a second engine plus an arbiter.
**v1 marks uncertainty instead of resolving it**, which is now free because both stages emit
confidence:
- ASR: per-word confidence → mark low-confidence spans with their timecode.
- Diarization: given D2's measured failure modes, **speaker labels are advisory**. Hard rule:
  **the summary must never attribute a decision or action item to a person on diarization alone** —
  only when a calendar/self-introduction/vocative anchor corroborates it. Otherwise `SPK_02`.

### D9 — Speaker roster: **one global store, partitioned into disjoint groups** *(decided 07-29)*
A single roster at `~/.acta-notes/roster.json`, partitioned into **groups** (`work`, `personal`, …).
Voices do not overlap between groups — **except the user, who is global**. Matching is done
**inside one group only**, never across the whole store.

```jsonc
{
  "model": "fluidaudio@v0.15.5/speaker-diarization",   // embeddings are model-bound (see below)
  "me":     { "name": "<your name>", "centroids": [[…]] },
  "groups": {
    "work":     { "people": [ { "name": "…", "centroids": [[…]], "enrolled_from": ["<meeting>"] } ] },
    "personal": { "people": [ … ] }
  }
}
```

**Why grouped and not flat:** a flat roster over both worlds makes every personal-call voice a
candidate for a work meeting. Since the casts are disjoint, the group is a hard prior that removes
most of the search space — and a wrong-group match is *confidently wrong*, exactly the failure D8
forbids. Partitioning turns "which of ~40 people?" into "which of ~8?".

**Group resolution runs BEFORE matching**, in this order:
1. explicit override (`/acta-notes … --group personal`);
2. a per-meeting-series memory (this recurring call was group X last time);
3. calendar signal — organizer/attendee domains (the employer's domain → `work`);
4. otherwise **ask**. Never guess the group silently — an unresolved group means names are simply
   not assigned, and the transcript keeps `S1..SN`. A misrouted group is worse than no names.

**Engineering constraints this carries (all real, none hypothetical):**
- **Embeddings are model-bound.** The 256-d vectors come from the offline pipeline's WeSpeaker
  model; they are not comparable across a model change. Store the model tag in the roster and
  **invalidate/re-enroll on a FluidAudio bump** — this is a second reason to pin the version (D2).
- **Enrol only from strong evidence:** a person is added to the roster only from segments that are
  (a) name-anchored by calendar/self-intro/vocative, and (b) carry enough aggregated speech
  (~≥30 s) at a decent `qualityScore`. Store a **centroid per enrolment occasion**, not one
  average — a voice drifts with headset, room, and connection quality.
- **Calibrate the acceptance threshold, don't guess it.** After the first few enrolments, measure
  the same-speaker vs different-speaker cosine distributions on labelled data and set the
  threshold from them. Below threshold → `S2 (не опознан)` + ask, never a best-guess name.
- **The user is special:** the mic track already *is* the user, so his embedding matters only for
  the bleed case (his voice appearing on the system track). Keep one global `me` entry, matched in
  every group.

---

## 2. Artifacts (per meeting folder in `~/Acta/<meeting>/`)

```
transcript.raw.md          # merged, timestamped, speaker-labelled, VERBATIM — never overwritten
transcript.md              # readable view: cleaned, terms canonicalized, same timestamps
diarization.json           # speaker turns + per-segment embeddings (the machine artifact)
speakers.json              # S1..SN → person + evidence + confidence + resolved group (D9)
summary.md                 # the Russian "как обычно" format — unchanged from the Air skill
context.md                 # calendar / source metadata
screenshots/ + screenshots.md
.acta-notes/               # working dir: 16k wavs, per-stage JSON, run log, timings
```

`transcript.raw.md` is the forensic artifact; every later stage is a regenerable view over it.

---

## 3. Pipeline, with measured costs (57-min meeting)

```
  ~/Acta/<meeting>/{mic,system}.wav (48 kHz stereo)
        │
  [S1] ffmpeg → 16 kHz mono + highpass/afftdn, per track          ~10 s × 2   (D6)
        │
  [S2] RMS/VAD gate per track                                     ~1 s        (D5)
        │
        ├── mic ─────[S3a] transcribe --word-timestamps            ~8 s
        │
        └── system ─┬[S3b] transcribe --word-timestamps            ~10 s
                    └[S4]  process --mode offline --num-speakers N ~12 s      (D2)
        │
  [S5] merge: utterances (pause > 0.7 s) → majority speaker        <1 s
        │
  [S6] speaker naming → speakers.json                              (interactive)
        │
  [S7] Claude cleanup + glossary canonicalization                  (D7)
        │
  [S8] context gathering + screenshots
        │
  [S9] summary.md
```

**Total machine time ≈ 45 s** for a 57-minute meeting (was ~4.5 min with `loudnorm`). This is no
longer a background-job problem the way the Air skill's whisper runs were.

**The merge unit is an utterance, not a word** — established in the spike. Per-word max-overlap
assignment flips speakers mid-sentence and leaves ~9 % of words unassigned. Splitting at pauses
> 0.7 s, assigning the majority speaker by overlapped duration, with a nearest-segment fallback,
turned 84 ragged fragments into 34 readable turns on the 8-min slice. Coverage measured
per-word: **91 %** at defaults, **98 %** with `--min-segment-duration 0.2 --min-gap-duration 0.05`
(at some purity cost — the sink-speaker effect worsens). Both knobs need a Phase-2 sweep.

---

## 4. Phases

### Phase 0 — bootstrap & doctor *(mostly DONE in the spike; ~2 h to productize)*
- `scripts/bootstrap.sh`: clone `FluidInference/FluidAudio` **pinned at v0.15.5** into
  `~/.cache/acta-notes/fluidaudio/`, `swift build -c release --product fluidaudiocli`.
  **[measured 07-29]** 150 s build, 357 MB build dir, 10.8 MB binary, **zero external
  dependencies**, builds green on Command Line Tools alone. Idempotent; never rebuilds on a
  matching pin.
- `scripts/doctor.sh`: ffmpeg / swift / binary / models / **free disk** → one status block; refuse
  to start red rather than fail halfway through a 57-minute recording.
- Working state already staged at `~/.cache/acta-notes/fluidaudio` (built) and models at
  `~/Library/Application Support/FluidAudio/Models/`.

### Phase 1 — transcription *(~1 day)*
- `prep_audio.py` — ffmpeg per track, chain from D6, `-ac 1 -ar 16000`.
- `gate.py` — RMS/VAD spans; `lab/006` threshold ≥ **0.02** (silence ~0.004 vs speech ~0.02+;
  0.015 let a hallucination through). Emits an "effectively silent track" verdict, replacing the
  Air skill's manual `volumedetect` step.
- `transcribe.py` — drives `fluidaudiocli transcribe --word-timestamps --output-json` per track.
- **Acceptance** on 3 archived meetings: no repeated-phrase loop (unique/total segment ratio +
  top-repeat count — the Air skill's manual verification, now automated); a listen-only mic track
  produces ~nothing; side-by-side against an existing whisper transcript in `~/Acta` reads at
  least as well.

### Phase 2 — diarization + merge + identity *(2–3 days — the hard phase)*
- `diarize.py` — `process --mode offline`, **`--num-speakers` from the calendar** when known,
  threshold fallback ~0.75 when not (never the 0.6 default — D2).
- **Parameter sweep on 3+ meetings** over `--num-speakers`, `--threshold`,
  `--min-segment-duration`, `--min-gap-duration`, `--step-ratio`; pin defaults from the result.
  Target the sink-speaker artifact specifically.
- `merge.py` — utterance-level assignment per §3 (prototype validated in the spike).
- **Speaker naming** (`speakers.json`), in evidence order: **group resolution (D9)** → voice
  match against that group's roster → calendar attendees → self-intros and vocatives in the
  transcript ("Дим, посмотри второй пункт", "Люб, добавь это в протокол" — ordinary Russian address
  and both strong anchors) → ask the user for the rest. Never guess silently.
- **Phase 2b — the grouped voice roster (D9).** Every diarization segment already carries a 256-d
  `embedding[]` (plus `--export-embeddings` for the standalone dump), so the matching substrate is
  free. Build it in three steps, each independently useful:
  1. **Enrol** — after a meeting's speakers are name-anchored, write centroids into the resolved
     group of `~/.acta-notes/roster.json`.
  2. **Match** — on the next meeting, resolve the group first, then cosine-match within it;
     unmatched speakers stay `S<N>` and get asked about.
  3. **Calibrate** — once ~2 groups × a few people exist, measure the same/different-speaker
     cosine distributions and pin the acceptance threshold from data.
  *Do not block v1 on this — Phase 2a (anchors + ask) must stand on its own, because the roster is
  bootstrapped from its output.*
- **Acceptance:** hand-annotate one meeting with `annotate.html`, feed it back via `--rttm`, and
  record the **DER/JER the CLI reports** as the number future tuning must beat. This closes
  `lab/001`, which never got a committed DER.

### Phase 3 — port the Air skill's context & summary layer *(1 day)*
Straight port, no redesign:
- Step-0 meeting identification, incl. the **typo-in-calendar-subject** lesson (a client name
  misspelled in the subject, which an exact-word search silently misses);
- the **official Teams transcript** short-circuit — still strictly better than any local ASR when
  it exists (real names, no ASR errors) — plus `teams_vtt_to_transcript.py`;
- screenshots: window computation, `~/Desktop` capture-time matching, the **30–60 s lag** between
  slide and screenshot;
- Jira / local `~/dev/<project>` docs / Slack gathering, the `jq` extraction discipline, and the
  **secrets-hygiene rule** (a real auth token was once found in a source doc);
- the exact Russian `summary.md` structure — **unchanged**, "как обычно" must keep working.

### Phase 4 — quality gates & honesty *(1 day)*
- `verify.py`: repeated-phrase detector, unique-segment ratio, per-speaker line tally,
  low-confidence span count, diarization coverage % → a `⚠` block atop `transcript.md`.
- Provenance line: engine + **FluidAudio tag**, denoise chain, diarization mode/`--num-speakers`,
  gate threshold, and which speaker names are **anchored** vs **inferred**.
- The deferred `loudnorm` A/B (D6) and the v0.15.5 hotword re-test (D6) land here.

### Phase 5 — package as a my-tools plugin *(half a day)*
- `tools/acta-notes/plugin/.claude-plugin/plugin.json` + `skills/acta-notes/SKILL.md` + `scripts/`.
- Add `acta-notes` to **`SKILL_PLUGINS`** in the Makefile (skills-only, never `go build`) and to
  `.claude-plugin/marketplace.json`; scripts via `$CLAUDE_PLUGIN_ROOT` (the `ssh-ops` pattern).
- **Salvage — MANDATORY, and it gates two deletions.** Two sources are scheduled to disappear:
  `~/dev/_archive-2026-07-28/` (an archive) and `~/air-rescue/…/acta-meeting-notes` (to be deleted
  per §7.2). Before either goes:
  - from the **lab**: `lab/003` levers, `lab/004` complementarity, `lab/006` two-track, `lab/007`
    cleanup constraints → `references/lab-verdicts.md`;
  - from the **Air skill**: `teams_vtt_to_transcript.py`, the screenshot-alignment rules, the
    calendar-typo lesson, the M365/Jira gathering discipline, and the exact Russian `summary.md`
    structure → ported in Phase 3 and verified against a real meeting *before* deletion.
  The skill must not depend on either path existing at runtime.

---

## 5. What the spike changed in this plan

| first draft said | measurement said |
|---|---|
| "Biggest risk: does `transcribe` emit timestamps? Two fallback paths." | It does — `--word-timestamps` + `--output-json`, word-level with confidence. **Risk closed, fallbacks dropped.** |
| "`--rttm` writes the speaker turns." | `--rttm` **reads** ground truth for DER/JER. Turns come from `--output`. **And the CLI scores DER for us.** |
| "Offline VBx: no speaker cap, best offline quality — use it." | True, but **at the default threshold it collapses to 1–2 speakers.** `--num-speakers` from the calendar is the real control, and labels still split sentences across speakers. |
| "Denoise chain from `lab/003` L2." | `loudnorm` is **91 % of the pipeline's wall time** and changes ~3 % of tokens. **Drop it.** |
| "Per-track silence gate is mandatory (lab/006)." | Whisper's hallucination flood **does not reproduce on Parakeet**. Keep the gate, demote its importance. |
| "Speaker naming: calendar + content cues." | Segments ship **256-d embeddings**; a cross-meeting voice roster is available and much stronger. |

## 6. Risks

| risk | mitigation |
|---|---|
| **Diarization labels are confidently wrong** (measured: sink speaker, Q&A merged) | D8's hard rule — never attribute an action item on diarization alone; Phase-2 sweep + a DER baseline to tune against; Sortformer cross-check |
| Auto speaker-count is unreliable | Seed `--num-speakers` from the calendar; never ship the 0.6 default |
| RU/EN/PT **code-switching** may fire false speaker changes (unvalidated — models trained on English AMI/VoxConverse) | Explicit check during the Phase-2 sweep on a code-switched meeting |
| **19 GB free disk (96 % full)** | Each meeting adds ~220 MB of 16 kHz wavs + a ~3.5 MB diarization JSON (embeddings inline). Delete `.acta-notes/` wavs after a run; strip embeddings from the committed JSON unless the roster needs them |
| FluidAudio API churn (0.15.x moves fast) | Pinned at v0.15.5, recorded in the provenance line, re-resolved deliberately |
| **A version bump silently invalidates the voice roster** — embeddings are model-bound, and a stale centroid produces a confident wrong name rather than a visible error | Roster stores its `model` tag (D9); a mismatch **disables voice matching** and falls back to anchors + ask, until re-enrolment |
| **Misrouted group** — a personal call matched against the work roster names the wrong people | Group is resolved before matching, from override → series memory → calendar domain → **ask**; unresolved group ⇒ no names at all, keep `S1..SN` |
| Claude-side cleanup invents plausible-wrong terms | `lab/007` non-destructive prompt + glossary + **keep the raw transcript** as source of truth |
| Transcripts leave the machine (D7) | Stated up front in `SKILL.md` |

## 7. Decisions taken (2026-07-29)

1. **Name — `acta-notes`.** Plugin and skill both. Every Russian trigger phrase from the Air skill
   is carried into its description so "как обычно" keeps routing correctly.
2. **The Air skill is going away.** `~/air-rescue/…/acta-meeting-notes` will be deleted, so no
   trigger collision to design around — but Phase 5's salvage step becomes **mandatory, not
   optional**: `teams_vtt_to_transcript.py`, the screenshot-alignment rules, the calendar-typo
   lesson and the Russian `summary.md` structure must be copied into `acta-notes` **before** the
   deletion, or they are lost along with the lab archive.
3. **Speaker roster — global store, disjoint groups (`work` / `personal`), user global.** See
   **D9**; the group is resolved before matching and never guessed silently.

*(Nothing blocking remains open. The `loudnorm` A/B and the v0.15.5 hotword re-test are scheduled
work in Phase 4, not open questions.)*

## 8. Effort

~5–6 working days. Phase 0 is effectively done. **Phase 1 (~1 day) already produces a better
transcript than the Air skill on this machine**; Phase 2 is where the remaining risk lives.
