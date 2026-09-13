# Findings from a bulk archive run

Collected while processing a batch of 44 recorded meetings through `acta-notes`. These are defects
and gaps in the skill itself, not questions about any meeting.

⚠️ **Anonymised on purpose.** The original of this document illustrated every finding with the
meeting it came from — folder names, participants, and verbatim speech. None of that was ours to
publish, so the examples below are reconstructed: the mechanisms, measurements and proposed fixes are
the real ones, the names and utterances are not. Where a number is quoted it was measured; where a
phrase is quoted it is a constructed example of the same shape.

## 1. `speakers.py` — a conjunction matches a given name (false anchor)

The only anchor for a cluster was the surface **«Или»** (the conjunction *or*) opening a sentence.
Its consonant skeleton `л` opens `лья`, and the first letter and first vowel agree, so
`is_short_form_of("или", "илья")` returns True.

**Why the allowlist did not save it:** the name-allowlist gate is bypassed when `--attendees` is
supplied, because the attendee list is declared authoritative (see the comment in `speakers.py`).

**Proposed fix:** a stop-list of function words applied before matching — «или», «либо», «ну», «а»,
«и», «но», «то», «так», «вот». A clause-opening «Или,» is frequent in Russian speech, and the
vocative comma after it makes it indistinguishable from address.

**Workaround used during the run:** rebuild `--from-stage speakers` with an attendee list that
excludes the colliding name; the cluster then correctly stayed unnamed.

## 2. A diarization threshold of 0.75 produces two kinds of error, and no gate sees either

`diarization_coverage` measures word assignment, not cluster purity, so the run is honestly green in
both cases.

- **Under-split.** Worst case in the batch: 5 clusters, one of which holds **8311 of 10336 words
  (80 %)**, at 99.1 % coverage. The label ends up asking itself a question and answering it.
  Rebuilding with `--num-speakers 10` gave 10 clusters, the largest 25 %.
- **Over-split.** Twice, both on one-to-one calls: the single other voice was cut into two labels,
  the second finishing the first one's sentences and never overlapping it in time.

**Consequence for the skill:** `diarize` only ever runs on the `system` track, so a one-to-one call
has exactly **one** voice there — `--num-speakers 1` should be passed immediately. Either document
that in `SKILL.md`, or add a cluster-purity heuristic to `verify` (a label that answers its own
question; a label holding >70 % of words when there are >4 participants).

## 3. The gates do not see loss of capture itself

One 70-minute recording had a `system.wav` that was digital zero end to end, and all five `verify`
checks passed, because a transcript built from one track is valid. `verify` should check the RMS of
the source tracks, not only the result.

## 4. Latin script cannot produce an anchor at all (English-language meetings)

In an English-language training session the host addressed people by name repeatedly and **no anchor
fired**: 0 of 7 speakers identified.

The cause is ordering: `looks_like_given_name` checks against a Cyrillic name lexicon, and that gate
sits **before** the `--attendees` check. A Cyrillic spelling passes, the same name in Latin script
does not, and supplying a Latin `--attendees` list does not help because control never reaches it.

**Consequence:** every English-language meeting — a noticeable share of the archive — yields `SPK_NN`
for all speakers even when names are spoken aloud as direct address.

**Proposed fix:** a Latin branch of the lexicon, or transliteration of the surface into Cyrillic
before matching.

## 5. `merge.py` pulls other speakers' lines into the dominant label

Checked against `diarization.json`: inside one 145-second window the diarizer **correctly** separated
two short interjections by other speakers, but `merge.py` collected the whole span into a single
utterance under a third label, inside which at least three voices are present.

The cause is that utterances are cut only on pauses longer than 0.7 s, and each is labelled by
majority overlap. A short interjection inside a long monologue disappears.

**Important:** this is **not** diarization under-split — `--num-speakers` does not help, and the data
in `diarization.json` is already correct. The fix belongs in `merge.py`: cut an utterance at a
speaker change, not only at a pause.

## 6. The `Я` track can contain other people's speech and ASR hallucinations

In one session the user said nothing at all, yet 156 words landed on `mic` at a mean confidence of
0.528 — fragments of the host's speech and outright hallucinations on a quiet track. This is audio
bleed into the microphone plus Parakeet hallucinating on near-silence. The `low_confidence_spans`
gate did show them (all 19 spans on `mic`), but `Я` still appears as a full participant in the
transcript. Worth a threshold: if almost the whole `mic` track is below confidence, it is more honest
to mark it as "did not speak".

## 7. ⭐ The main one: `is_short_form_of` does not handle suppletive short forms

This explains most of the unidentified speakers across the whole run.

The consonant skeleton only works where the short form **keeps the beginning** of the full name.
Russian short forms frequently replace the stem outright, and then the first letter, the first vowel
and the skeleton all diverge. Run against the real code:

```
Дима  → Дмитрий     OK        Миша  → Михаил      *** FAIL
Юра   → Юрий        OK        Саша  → Александр   *** FAIL
Вася  → Василий     OK        Ваня  → Иван        *** FAIL
Рома  → Роман       OK        Лёша  → Алексей     *** FAIL
Даня  → Даниил      OK        Толя  → Анатолий    *** FAIL
                              Костя → Константин  *** FAIL
                              Женя  → Евгения     *** FAIL
```

**Why it is expensive here:** the forms that fail are exactly the ones spoken most often — «Саш»,
«Миш», «Вань», «Лёш». Confirmed cases in the run: a cluster answering twice to a spoken short form
whose full name was in the attendee list, with no anchor firing; a neighbouring cluster where the
working pair did fire while the failing one beside it did not; a self-introduction the ASR ran
together into a single non-word; and many meetings where one such form is spoken dozens of times and
anchors nobody.

**Proposed fix:** a hypocorism table (short → full), not only the algorithmic skeleton. Keep the
skeleton as a supplement for clipped forms like «Дим»/«Вась», and make the table the primary path.
It is a cheap change with a large effect: it is what turns `SPK_NN` into names in most of the
archive. The pair list above doubles as the regression fixture.

## 8. A vocative is only caught at the start or end of a sentence

In one meeting only one of six clusters was identified although names were spoken as plain address.
Three consecutive misses all had the name **in the middle of the phrase**, comma-delimited on both
sides, followed by a substantive answer. A fourth had no comma at all.

There is also the case where the answer arrives on the non-diarized `Я` track, which currently
discards the anchor.

**Proposed fix:** accept a vocative in any position when it is set off by commas on both sides, and
do not discard the case where the address is spoken from the `Я` track — that is the most reliable
anchor there is, because a speaker cannot be addressing themself.

## 9. `name_conflict` arises from leakage at an utterance boundary

Two clusters both claimed the same person and both were demoted. The cause was not diarization: a
short interjection was glued to the start of a long utterance by someone else — the same defect as
§5. The `merge.py` bug surfaces further down the pipeline as a lost name.

## 10. ⭐ System-audio echo into the `mic` track destroys identification entirely

A 46-minute Teams meeting.

**Measurement:** 61 % of the substantive utterances on the `Я` track reproduce the `system` track
verbatim, delayed by 0–3 s and at worse confidence (0.743 against 0.947). On a neighbouring recording
from the same day the figure is 3 %. The audio was going through speakers, not headphones.

**Cost:** 24 of 27 anchors were discarded with the reason `answered on the non-diarized Я track` —
the "answer" to every vocative was its own echo. Result: **0 of 18 speakers identified.**

**Two consequences for the skill:**

1. The "answered on the `Я` track" branch does not distinguish a real answer from a duplicate of the
   same utterance. It should compare the text: if the "answer" on `Я` is nearly the same text as the
   addressing utterance, that is an echo, not an answer.
2. The same branch is treated as a failure even when it is **correct** — a vocative addressed to the
   microphone's owner is the strongest possible anchor, and it is discarded.

**Practical advice to the user:** record calls wearing headphones. Slack huddles showed no effect;
Teams did.

## 11. Alias-based attendee lists contain no people

In the same meeting neither the person being discussed nor the user appeared among the 58 invitees:
both were included through a company-wide distribution alias. So `--attendees` as a filter would have
rejected a correct name even if the anchor had fired. For all-hands meetings the invitee list is
useless as a filter.

## 12. ⭐ `--attendees` can PRODUCE a confidently wrong name (a D8 violation)

On a noisy multi-party meeting, `--num-speakers 6` together with `--attendees` named one cluster
after the wrong person entirely. By content the cluster was a different participant — he answers to
his own name being called and then discusses his own work.

The documentation presents `--attendees` as a **filter** that can only reject a name. In practice, on
a noisy meeting, it also acts as a **source**: a weak surface match is pulled towards the nearest
name in the list, and the output is a confident wrong attribution — exactly what D8 forbids.

**Workaround during the run:** rebuild `speakers build` **without** `--attendees` (anchor-only); the
false name disappeared.

**Proposed fix:** distinguish "list as filter" from "list as dictionary". A match against the list
should require no *less* evidence than anchor-only, not less.

## 13. "No answer within 3 lines" is too narrow a window

An anchor was reported as `nobody answered within 3 line(s)`. The person did answer — four lines
later. The anchor was lost for nothing.
