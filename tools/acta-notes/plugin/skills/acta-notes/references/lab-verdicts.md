# Lab verdicts — what was measured, and what it costs to re-learn

Distilled from four concluded experiments (June 2026) whose source directories are an archive
scheduled for deletion. **Everything load-bearing is here**; the originals are gone or going, so
treat this file as the evidence of record. Each verdict names the pipeline decision it pins, so a
future change can be argued against a number rather than an intuition.

Read this before proposing a "quick improvement" to the audio chain, the ASR engine, the silence
gate, or the cleanup prompt. All four of those were swept; three of the obvious ideas lost.

**One caveat governs every number below.** The hand reference used for WER was corrected *from*
whisper-large-v3-turbo's output, so it is turbo-shaped: valid for **ranking levers** (no lever is
the seed, and the ranking held under a second independent reference) and **invalid for absolute
WER or cross-engine comparison**. A blind reference — typed from the audio with unintelligible
spans marked `[?]` and excluded — was tooled but never filled in. Any future absolute claim needs
it first. That is the same human-typed artifact the deferred sweep harness requires.

---

## 1. Preprocessing levers — only denoise helps (lab/003)

Bench: an 8-minute slice of a real Russian meeting's system track. Levers applied cumulatively to
the production engine, scored against the hand reference and re-scored against a second,
independent reference to test robustness.

| lever | WER (ref A) | WER (ref B) | verdict |
|---|---|---|---|
| L0 baseline, auto-language | 0.200 | 0.184 | — |
| L1 `language=ru` pin | 0.200 | 0.192 | **no help under either reference** |
| **L2 denoise** (high-pass + FFT denoise **+ `loudnorm`**) | **0.186** | **0.177** | **the only lever that helps** (~0.7–1.4 pp) |
| L3 VAD / silence-gate as a preprocessing step | 0.198 | 0.204 | worse under both |
| L2+L3 | 0.202 | 0.211 | worse under both |
| L4 hotwords / custom vocabulary | 0.198 | 0.185 | WER-noise, **plus a false substitution** (`при` → `IREE`) |
| L1+L4 | 0.202 | 0.195 | no help |

**What this pins:**

- `prep_audio.py`'s default chain is **denoise** — high-pass + FFT denoise, no `loudnorm`. Note
  what that does and does not inherit: **the 0.186 above was measured with `loudnorm` in the
  chain**, so the shipped chain has no WER number of its own. `loudnorm` was dropped on a separate
  measurement — ~91 % of the pipeline's wall time for ~3 % of tokens changed (PLAN.md D6) — and the
  shipped chain was compared to the full one only by token disagreement, never against a reference.
  Closing that gap is exactly what the deferred `--chain loudnorm` A/B is for; until it runs, do not
  cite 0.186 as the shipped default's WER.
- **A language pin is not a free win.** It drives the Latin-token fraction 0.018 → 0.000 — the
  proxy improves and the metric does not move. `transcribe.py --language` stays opt-in.
- **Hotwords are opt-in and fragile.** They are WER-noise and they invent substitutions; the
  English CTC spotter is a poor fit for a Russian track. `transcribe.py --custom-vocab` is the one
  code path that makes v0.15.5 load `parakeet-ctc-110m-coreml`, which is exactly why doctor lists
  that model as optional rather than required.
- **VAD as a *preprocessing* step is not the same thing as the silence gate** in §3 below. Cutting
  non-speech out of the audio *before* ASR made WER worse. Refusing to transcribe an
  effectively-silent *track* is a different, confirmed decision. `gate.py` does the second and
  never the first.

**Dead ends, already paid for:** beam search (no gain over greedy + context), a bigger model (no
better on this audio), tempo change (different, not better).

---

## 2. Engine choice is not the lever; errors are complementary (lab/004)

Four engines on the same bench — whisper-large-v3-turbo, whisper-large-v3, Parakeet-TDT-0.6b-v3,
GigaAM-v2-CTC (Russian specialist).

- **All engines cluster at ~0.20–0.21 WER** on real meeting audio. Published Russian benchmark
  numbers (2–8 % on clean corpora) **do not transfer**.
- The apparent "whisper-turbo scores 0.069, everyone else 0.20" is a **seed artifact** — turbo
  produced the text the reference was corrected from. Its own family sibling scores 0.212 against
  the same reference. Cross-engine disagreement is ~0.18–0.23 *even within whisper*.
- **Errors are complementary, and that is the real finding.** On nine hand-judged hard terms the
  best single engine got 5/9; **oracle best-per-item fusion got 7/9**. Majority voting would have
  *lost* these: the specialist is often the lone correct voice, outvoted 3:1.
- All engines run far faster than realtime (RTF ~0.005–0.035). **Speed is not what makes fusion a
  deferred step** — the arbiter is.

**What this pins:**

- v1 runs **one multilingual engine** (Parakeet-TDT-0.6b-v3) and does not chase a WER win by
  swapping it. There is no evidence a swap buys anything.
- A second engine only pays for itself **inside a fusion arbiter over flagged spans**, grounded by
  a glossary — never as a replacement, never by majority vote. That is out of v1 scope, and this
  is the number that says why it must not be attempted casually.
- Terms nobody's engine caught are **glossary territory**, not engine territory.

---

## 3. Two tracks are complementary; gate each one (lab/006)

The capture is two files: `mic.wav` (you, clean, one speaker) and `system.wav` (everyone else, as
the meeting app mixes them). Every earlier experiment had transcribed the system track only.

| track | words | mean confidence | mean RMS |
|---|---|---|---|
| mic (you) | 342 | 0.712 | **0.0065** |
| system (others) | 3154 | 0.758 | **0.0628** |

- **Complementary and necessary.** In the measured meeting the user mostly listened — ~89 s of
  real speech across 30 minutes — and a system-only transcript lost all of it. The gain scales
  with how much you talk.
- **The mic track is "you" by construction.** No model is needed to know who is on it. That is why
  `merge.py` labels it `Я` by timestamp and `diarize.py` refuses `--track mic` outright — the
  refusal is a design rule, not a filename heuristic.
- **Ungated whisper hallucinated 118 of 133 mic segments** over the silence ("Продолжение
  следует" ×97). **Confidence did not catch it**: the hallucinations scored 0.71, the real system
  speech 0.76. RMS/VAD is the detector; confidence is not a silence detector.
- **The gate is symmetric.** Which track is silent flips with who is speaking — mic-silent while
  you listen, system-silent while you explain or in a 1:1. Every captured track gets its own gate.
- Threshold: silence sits at ~0.004 RMS, speech at ~0.02+. A first cut at **0.015 let one
  hallucination through** at RMS 0.0179. `gate.py` uses **≥ 0.02** for exactly that reason.

**Demoted, honestly:** the hallucination flood is whisper-specific and did **not** reproduce on
Parakeet in the spike. The gate stays — it is cheap insurance and it saves the transcription of a
track that has nothing on it — but it is no longer the emergency it was for whisper.

---

## 4. Cleanup works, at the mid rung, non-destructively (lab/007)

The raw two-track merge was cleaned chunk-by-chunk by a local LLM with a non-destructive prompt
plus the meeting glossary, over 414 segments / 3662 words.

| model | length ratio | change-WER (raw ↔ cleaned) | canonical glossary terms |
|---|---|---|---|
| **qwen3-14b** | **0.99** | **0.05** | **25 → 47** |
| qwen2.5-1.5b | 0.85 | 0.22 | 25 → 20 |

- The mid-size model is **product-grade**: a light touch, no content loss, nearly double the
  canonical terms, verified by reading aligned raw-vs-cleaned samples.
- The small model is **unusable** — it drops ~15 % of the content (it summarizes), over-rewrites,
  and *breaks* terms it was meant to fix.
- Division of labour: **ASR hears phonetically, the cleanup pass canonicalizes and formats.**
  Acoustic confusions are not fixed by re-decoding; they need a glossary.

**The two constraints this experiment paid for, and the reason they are in `SKILL.md`:**

1. **Preserve speaker markers.** The LLM silently dropped them, and minutes without speaker
   attribution are not minutes.
2. **Never invent content.** The standing risk of an audio-blind cleanup is a *fluent wrong*
   transcript: it turns a garbled-but-recoverable error into a plausible term. Low change-WER and
   a glossary reduce it; nothing eliminates it.

**What this pins:** cleanup is a **reversible view**, not an edit. `transcript.raw.md` is written
once and kept verbatim; both later transcripts are views over it. This is also why v1 puts cleanup
on Claude rather than a local LLM — the constraints, not the model, are what matter, and the
constraints are stated in the skill body.

---

## Limits worth remembering

- One meeting, one language mix (ru with en/pt code-switching), telco audio, one 8-minute bench
  slice. A different meeting could re-rank the levers.
- The hard-item scorecard is nine hand-judged items — illustrative, not statistically robust.
- The proxies (`latin_frac`, `filler_frac`) rank; they do not grade.
- The fusion arbiter was demonstrated by hand, never built or scored.
- The blind reference does not exist. Until it does, no absolute WER claim from this work is
  defensible — including any claim that a change *improved* the transcript.
