#!/usr/bin/env python3
"""acta-notes Phase 4 — quality gates and provenance.

Reads the transcript the machine chain produced and every stage JSON it left
behind::

    <meeting>/transcript.labeled.md         (S6 — speakers.py apply)
    <meeting>/.acta-notes/prep_audio.json   (S1 — the denoise chain)
    <meeting>/.acta-notes/gate.json         (S2 — the silence threshold)
    <meeting>/.acta-notes/transcribe.json   (S3 — per-word confidence, D3)
    <meeting>/diarization.json              (S4 — mode and segmentation controls)
    <meeting>/.acta-notes/merge.json        (S5 — diarization coverage)
    <meeting>/speakers.json                 (S6 — anchored vs inferred, D8)

and writes two artifacts, both under ``.acta-notes/``::

    verify.json    the machine report — every metric, every check, every gate
    quality.md     the ⚠ block plus the provenance line, for a human

**This stage writes no transcript, ever.** ``quality.md`` is a separate file
precisely so nothing here has to open ``transcript.labeled.md`` for writing:
SKILL.md instructs Claude to prepend it verbatim when it builds
``transcript.md`` at S7. ``transcript.raw.md`` and ``transcript.labeled.md`` are
opened read-only and are byte-identical afterwards.

**The Teams path has no ASR and no diarization.** When an official Teams VTT
produced ``transcript.raw.md``, stages S1–S5 never ran, so their stage JSONs do
not exist. That is not an error: every provenance field they would have filled
reads ``n/a`` and every gate that depends on them is *skipped* rather than
failed. A quality block that invented a coverage number for a transcript nobody
diarized would be worse than one that says ``n/a``.

**Two gates are hard**, and both are failure modes measured rather than
imagined:

``repeated_phrase_loop``
    The ASR hallucination that ``lab/006`` caught at a 0.015 gate threshold — a
    phrase, or a whole line, repeating itself until the decoder escapes. It is
    always a defect, never content, so it exits non-zero.

``diarization_coverage``
    Coverage below the pinned floor means the segmenter collapsed and the
    speaker labels on the page are decoration. Skipped entirely on the Teams
    path, which carries speaker names from the source.

Everything else — the unique-line ratio, the low-confidence spans, the
per-speaker tally — is reported and can warn, but never blocks: a genuinely
repetitive standup and a genuinely noisy line are both real meetings.

Stdlib only — no binary to resolve, no model, no network.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

# --- the files in the chain --------------------------------------------------

WORK_DIRNAME = ".acta-notes"
RAW_TRANSCRIPT_NAME = "transcript.raw.md"
LABELED_TRANSCRIPT_NAME = "transcript.labeled.md"
#: Claude's, at S7. Named here only so nothing in this module can be pointed at it.
CLEAN_TRANSCRIPT_NAME = "transcript.md"

PREP_JSON_NAME = "prep_audio.json"
GATE_JSON_NAME = "gate.json"
TRANSCRIBE_JSON_NAME = "transcribe.json"
#: Written only by ``teams_vtt_to_transcript.py``, and only by a conversion that
#: landed — the positive marker ``detect_source`` keys the Teams path on.
TEAMS_VTT_JSON_NAME = "teams_vtt.json"
MERGE_JSON_NAME = "merge.json"
#: These two live at the meeting root, beside the transcripts.
DIARIZATION_JSON_NAME = "diarization.json"
SPEAKERS_JSON_NAME = "speakers.json"
DICTA_JSON_NAME = "dicta.json"

VERIFY_JSON_NAME = "verify.json"
QUALITY_MD_NAME = "quality.md"

#: Where bootstrap.sh leaves its stamp; doctor.py owns the same path. Read-only
#: here, and only for the FluidAudio tag the provenance line has to name.
STAMP_NAME = ".acta-bootstrap.json"
CACHE_STAMP_RELPATH = Path(".cache") / "acta-notes" / "fluidaudio" / STAMP_NAME

# --- gate constants ----------------------------------------------------------

#: The same line text repeated this many times in a row is a decoder loop, not a
#: meeting. Three is deliberately conservative: two identical short lines
#: ("да.", "да.") happen in real conversation, three in a row do not.
LOOP_CONSECUTIVE_LINES = 3

#: …but three in a row *do* happen across speakers, and this is a hard gate.
#: merge.py cuts a new line at every pause over 0.7 s, so an interleaved
#: two-track call producing `[Я] Да.` / `[SPK_01] Да.` / `[Я] Да.` is an
#: everyday shape, not a defect. A decoder loop repeats inside **one** speaker's
#: stream and is not a one-word backchannel, so the run must be same-speaker and
#: the line must carry at least this many words before it counts.
LOOP_LINE_MIN_WORDS = 3

#: A phrase looping *inside* one line. Both bounds matter: fewer than three
#: words repeats naturally ("ну ну ну"), and a real loop repeats far more than
#: the two times a speaker might for emphasis.
LOOP_PHRASE_MIN_WORDS = 3
LOOP_PHRASE_REPEATS = 4
#: Loop phrases are short; scanning longer n-grams costs time and finds nothing.
LOOP_PHRASE_MAX_WORDS = 8

#: Below this the transcript is mostly the same line over and over. A warn, not
#: a gate — a status round really can be six people saying "готово".
UNIQUE_RATIO_WARN = 0.60

#: Per-word confidence under this is a garbled span worth a timecode. Measured
#: mean confidence on this machine's audio is 0.961–0.964 (lab/003), so 0.5 is
#: well below ordinary variation and only catches genuinely uncertain words.
LOW_CONFIDENCE_THRESHOLD = 0.5
#: One low word is ASR noise; two adjacent is a span a human should re-listen to.
LOW_CONFIDENCE_MIN_SPAN_WORDS = 2
#: Warn once more than this share of words scored low.
LOW_CONFIDENCE_WARN_FRACTION = 0.05
#: How many spans quality.md lists before it says "and N more".
QUALITY_MD_SPAN_LIMIT = 5

#: Diarization coverage — the share of system-track words merge.py assigned by
#: real overlap (fallback words are excluded there, deliberately). Measured 91 %
#: at the shipped segmentation defaults, so 0.85 warns on a harder meeting and
#: 0.80 fails only when the segmenter has actually collapsed.
COVERAGE_WARN = 0.85
COVERAGE_FLOOR = 0.80

# --- statuses ----------------------------------------------------------------

GREEN = "green"
WARN = "warn"
RED = "red"
_SEVERITY = {GREEN: 0, WARN: 1, RED: 2}
_HUMAN_MARKER = {GREEN: "ok  ", WARN: "warn", RED: "FAIL"}
_QUALITY_MARKER = {GREEN: "✅", WARN: "⚠", RED: "⛔"}

STATUS_OK = "ok"
STATUS_WARN = "warn"
STATUS_FAILED = "failed"
STATUS_MISSING = "missing"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

#: Checks allowed to turn the stage red. Everything else reports and may warn.
HARD_GATES = ("transcript", "repeated_phrase_loop", "diarization_coverage")

SOURCE_LOCAL_ASR = "local-asr"
SOURCE_TEAMS_VTT = "teams-vtt"
SOURCE_AUTO = "auto"
#: Neither producer left its marker behind. A third value, not a default: naming
#: a source we cannot evidence is the one thing the provenance line must not do.
SOURCE_UNKNOWN = "unknown"

SOURCE_LABEL = {
    SOURCE_LOCAL_ASR: "локальный ASR (Parakeet TDT 0.6B v3 + офлайн-диаризация VBx)",
    SOURCE_TEAMS_VTT: "официальный транскрипт Teams (VTT)",
    SOURCE_UNKNOWN: (
        "источник не определён — нет ни stage JSON локального ASR, "
        "ни отчёта о конверсии VTT"
    ),
}

NOT_AVAILABLE = "n/a"

#: ``**[HH:MM:SS] LABEL:** text`` — the one line shape both producers of
#: ``transcript.raw.md`` emit and ``speakers.py apply`` preserves.
LINE_RE = re.compile(
    r"^\*\*\[(?P<time>\d{1,2}:\d{2}:\d{2})\]\s*(?P<speaker>[^:*]+?):\*\*\s*(?P<text>.*)$"
)

_PUNCTUATION_RE = re.compile(r"[^\w\s]+", re.UNICODE)
_WHITESPACE_RE = re.compile(r"\s+")


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def labeled_transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / LABELED_TRANSCRIPT_NAME


def verify_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / VERIFY_JSON_NAME


def quality_md_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / QUALITY_MD_NAME


def stamp_path(environ=None) -> Path:
    """Where ``bootstrap.sh`` wrote the stamp — same precedence as ``doctor.py``.

    ``ACTA_CACHE_DIR`` first: bootstrap.sh honours it, doctor.py honours it, and
    hardcoding ``$HOME`` here meant that with the override set doctor reported a
    green pinned FluidAudio tag while quality.md — the document that exists to
    carry provenance — printed ``FluidAudio: n/a`` from the same run.
    """
    environ = os.environ if environ is None else environ
    override = environ.get("ACTA_CACHE_DIR")
    if override:
        return Path(override) / STAMP_NAME
    home = Path(environ.get("HOME") or Path.home())
    return home / CACHE_STAMP_RELPATH


# --- tolerant input loading --------------------------------------------------


def as_number(value):
    """``float(value)`` or ``None`` — never raises.

    Same tolerance as the rest of this file: verify reads stage JSONs that may
    be absent, truncated or hand-edited, and a non-numeric field must degrade
    into "not scored" rather than a traceback that suppresses the verdict.
    """
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_optional_json(path):
    """A stage JSON, or ``None`` when it is absent or unusable.

    Tolerance is the point (the Teams path has no ASR or diarization JSON at
    all), and it is safe because every field these files feed is a *provenance*
    field: an unreadable one reads ``n/a`` and its gate is skipped, which is the
    same honest outcome as never having run the stage.
    """
    path = Path(path)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def load_inputs(meeting_dir) -> dict:
    """Every stage JSON this stage may read; missing ones come back ``None``."""
    meeting_dir = Path(meeting_dir)
    work = work_dir(meeting_dir)
    return {
        "prep_audio": read_optional_json(work / PREP_JSON_NAME),
        "gate": read_optional_json(work / GATE_JSON_NAME),
        "transcribe": read_optional_json(work / TRANSCRIBE_JSON_NAME),
        "teams_vtt": read_optional_json(work / TEAMS_VTT_JSON_NAME),
        "merge": read_optional_json(work / MERGE_JSON_NAME),
        "diarization": read_optional_json(meeting_dir / DIARIZATION_JSON_NAME),
        "speakers": read_optional_json(meeting_dir / SPEAKERS_JSON_NAME),
        "dicta": read_optional_json(meeting_dir / DICTA_JSON_NAME),
    }


def detect_source(inputs: dict) -> str:
    """The source each producer *positively* evidenced, or ``SOURCE_UNKNOWN``.

    Both markers are written only by the path that owns them —
    ``transcribe.json`` by S3, ``teams_vtt.json`` only by a conversion that
    landed. Inferring Teams from a *missing* transcribe.json was wrong in the one
    case that matters: ``.acta-notes/`` is documented as disposable, so a
    reclaimed working dir beside a genuine local-ASR transcript made the
    provenance line — which SKILL.md has Claude prepend verbatim — claim the text
    came from Teams. An unevidenced source now says so instead of guessing.
    """
    if inputs.get("transcribe"):
        return SOURCE_LOCAL_ASR
    if inputs.get("teams_vtt"):
        return SOURCE_TEAMS_VTT
    return SOURCE_UNKNOWN


# --- transcript parsing ------------------------------------------------------


def normalize_text(text: str) -> str:
    """Fold a line to what a loop detector should compare.

    Punctuation and case carry no information about whether the decoder is
    repeating itself, and ``ё``/``е`` is spelled both ways by the same ASR run.
    """
    folded = str(text).lower().replace("ё", "е")
    folded = _PUNCTUATION_RE.sub(" ", folded)
    return _WHITESPACE_RE.sub(" ", folded).strip()


def parse_lines(text: str) -> list[dict]:
    """Every ``**[HH:MM:SS] LABEL:** text`` line, in document order."""
    rows = []
    for index, line in enumerate(text.splitlines()):
        match = LINE_RE.match(line)
        if not match:
            continue
        body = match.group("text").strip()
        rows.append(
            {
                "index": index,
                "timecode": match.group("time"),
                "speaker": match.group("speaker").strip(),
                "text": body,
                "normalized": normalize_text(body),
            }
        )
    return rows


def hms(seconds) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


# --- detectors ---------------------------------------------------------------


def line_metrics(rows) -> dict:
    """Unique/total ratio and the most-repeated line, over non-empty lines."""
    texts = [row["normalized"] for row in rows if row["normalized"]]
    counts: dict[str, int] = {}
    for text in texts:
        counts[text] = counts.get(text, 0) + 1

    top = None
    if counts:
        text, count = max(counts.items(), key=lambda kv: (kv[1], -len(kv[0])))
        top = {"text": text, "count": count}

    return {
        "line_count": len(rows),
        "non_empty_lines": len(texts),
        "unique_lines": len(counts),
        "unique_ratio": round(len(counts) / len(texts), 4) if texts else None,
        "top_repeat": top,
    }


def find_line_loops(
    rows,
    repeats: int = LOOP_CONSECUTIVE_LINES,
    min_words: int = LOOP_LINE_MIN_WORDS,
) -> list[dict]:
    """Runs of the same line, from the same speaker, repeated back to back.

    Both restrictions exist because this feeds a hard gate (``HARD_GATES``): a
    cross-speaker run of "Да." is a conversation, and a one-word run is a
    backchannel. Neither is a decoder loop, and neither may fail a good meeting.
    """
    loops: list[dict] = []
    run: list[dict] = []

    def flush():
        if len(run) < repeats:
            return
        if len(run[0]["normalized"].split()) < min_words:
            return
        loops.append(
            {
                "kind": "line",
                "text": run[0]["text"],
                "speaker": run[0]["speaker"],
                "count": len(run),
                "from_timecode": run[0]["timecode"],
                "to_timecode": run[-1]["timecode"],
            }
        )

    for row in rows:
        if not row["normalized"]:
            flush()
            run = []
            continue
        if (
            run
            and row["normalized"] == run[-1]["normalized"]
            and row["speaker"] == run[-1]["speaker"]
        ):
            run.append(row)
            continue
        flush()
        run = [row]
    flush()
    return loops


def max_phrase_repeat(
    words,
    min_words: int = LOOP_PHRASE_MIN_WORDS,
    max_words: int = LOOP_PHRASE_MAX_WORDS,
    enough: int | None = None,
):
    """The longest run of one n-gram repeating back to back inside a word list.

    Returns ``(repeats, phrase)`` or ``None``. Only short n-grams are scanned:
    a decoder loop repeats a handful of words, and unbounded ``n`` would turn a
    linear stage into a quadratic one on long Teams cues.

    ``enough`` stops the scan at the first run that long. It is what keeps the
    bound honest on the *one* input this gate exists to catch: merge.py only cuts
    a line at a pause over 0.7 s, so a continuous decoder loop arrives as a single
    line of tens of thousands of words, every start position of it opens a run
    reaching to the end, and scanning them all took ~15 s at 16k words and grows
    quadratically from there — in the last stage of the run, which is never
    skipped for freshness. A caller that only needs the verdict passes its
    threshold and the scan stops at start 0.
    """
    total = len(words)
    best = None
    for size in range(min_words, min(max_words, total // 2) + 1):
        start = 0
        while start + size * 2 <= total:
            phrase = words[start : start + size]
            repeats = 1
            cursor = start + size
            while cursor + size <= total and words[cursor : cursor + size] == phrase:
                repeats += 1
                cursor += size
            if repeats > 1 and (best is None or repeats > best[0]):
                best = (repeats, " ".join(phrase))
                if enough is not None and repeats >= enough:
                    return best
            start += 1
    return best


def find_phrase_loops(rows, repeats: int = LOOP_PHRASE_REPEATS) -> list[dict]:
    """Lines that repeat a phrase to themselves — the classic ASR hallucination."""
    loops = []
    for row in rows:
        words = row["normalized"].split()
        if len(words) < LOOP_PHRASE_MIN_WORDS * repeats:
            continue
        found = max_phrase_repeat(words, enough=repeats)
        if found and found[0] >= repeats:
            loops.append(
                {
                    "kind": "phrase",
                    "text": found[1],
                    "count": found[0],
                    "from_timecode": row["timecode"],
                    "to_timecode": row["timecode"],
                }
            )
    return loops


def find_loops(rows) -> list[dict]:
    """Both loop shapes, line loops first (they read worse on the page)."""
    return find_line_loops(rows) + find_phrase_loops(rows)


def speaker_tally(rows) -> list[dict]:
    """Per-speaker line and word counts, ordered by line share."""
    tally: dict[str, dict] = {}
    for row in rows:
        entry = tally.setdefault(
            row["speaker"], {"speaker": row["speaker"], "lines": 0, "words": 0}
        )
        entry["lines"] += 1
        entry["words"] += len(row["text"].split())

    total = sum(entry["lines"] for entry in tally.values())
    out = []
    for entry in tally.values():
        entry["line_share"] = round(entry["lines"] / total, 4) if total else None
        out.append(entry)
    out.sort(key=lambda e: (-e["lines"], e["speaker"]))
    return out


def low_confidence_spans(
    transcribe_report,
    threshold: float = LOW_CONFIDENCE_THRESHOLD,
    min_words: int = LOW_CONFIDENCE_MIN_SPAN_WORDS,
) -> dict:
    """Runs of adjacent low-confidence words, with timecodes (D3, D8).

    D8's "mark uncertainty instead of resolving it" in its cheapest form: the
    per-word confidences are already in the S3 stage JSON, so pointing a human
    at ``00:12:31`` costs nothing and needs no second engine.
    """
    spans: list[dict] = []
    scored = 0
    low = 0

    # A module-level helper taking the run explicitly, not a closure over a
    # mutable local: binding ``run`` as a default argument only worked because
    # every caller below happens to use ``run.clear()``, and a later ``run = []``
    # would have silently disabled span detection with nothing failing.
    def flush(run, track):
        if len(run) < min_words:
            return
        values = [w["confidence"] for w in run]
        spans.append(
            {
                "track": track,
                "start": round(run[0]["start"], 3),
                "end": round(run[-1]["end"], 3),
                "timecode": hms(run[0]["start"]),
                "word_count": len(run),
                "text": " ".join(w["word"] for w in run),
                "mean_confidence": round(sum(values) / len(values), 4),
                "min_confidence": round(min(values), 4),
            }
        )

    for entry in (transcribe_report or {}).get("tracks") or []:
        if not isinstance(entry, dict):
            continue
        track = entry.get("track")
        run: list[dict] = []

        for word in entry.get("words") or []:
            if not isinstance(word, dict):
                continue
            confidence = as_number(word.get("confidence"))
            start = as_number(word.get("start"))
            end = as_number(word.get("end"))
            if confidence is None or start is None or end is None:
                flush(run, track)
                run.clear()
                continue
            scored += 1
            if confidence < threshold:
                low += 1
                run.append(
                    {
                        "word": str(word.get("word") or ""),
                        "start": start,
                        "end": end,
                        "confidence": confidence,
                    }
                )
            else:
                flush(run, track)
                run.clear()
        flush(run, track)
        run.clear()

    spans.sort(key=lambda s: (s["start"], s["track"] or ""))
    return {
        "threshold": threshold,
        "scored_words": scored,
        "low_confidence_words": low,
        "low_confidence_fraction": round(low / scored, 4) if scored else None,
        "span_count": len(spans),
        "spans": spans,
    }


def coverage_from(merge_report):
    """S5's honest coverage — words assigned by real overlap, or ``None``."""
    if not merge_report:
        return None
    coverage = merge_report.get("coverage")
    try:
        return None if coverage is None else float(coverage)
    except (TypeError, ValueError):
        return None


def coverage_skip_reason(merge_report, source: str) -> str:
    """Why ``diarization_coverage`` was skipped — a merge report that exists but
    carries no coverage is not the same thing as no merge report at all.

    ``merge.py`` writes ``coverage: null`` whenever the system track had no
    words (a silent system track, a mic-only meeting). Saying "no S5 merge stage
    JSON" there sends a reader looking for a file that is sitting right beside
    the transcript.
    """
    if source == SOURCE_TEAMS_VTT:
        return (
            "skipped — no S5 merge stage JSON "
            f"({SOURCE_LABEL[SOURCE_TEAMS_VTT]} is not diarized here)"
        )
    # A merge report that *failed* is not the mic-only case: it recorded no
    # coverage because it did not finish, and claiming "merged no system words"
    # would read as a property of the recording rather than of the run.
    status = merge_report.get("status") if isinstance(merge_report, dict) else None
    if status is not None and status != "ok":
        return (
            f"skipped — the S5 merge stage reports status '{status}', so its "
            "coverage figure is absent because the merge did not complete, not "
            "because the recording had nothing to score"
        )
    if merge_report:
        return (
            "skipped — S5 merged no system words, so there is no overlap "
            "coverage to score (mic-only or a silent system track)"
        )
    return "skipped — no S5 merge stage JSON to read coverage from"


# --- checks ------------------------------------------------------------------


def _check(name: str, status: str, detail: str, **extra) -> dict:
    out = {"name": name, "status": status, "detail": detail}
    out.update(extra)
    return out


def dictation_check(report) -> dict:
    """S6.5's verdict, folded into the block a reader sees first.

    Never RED, and not in ``HARD_GATES``: leaked dictation makes a transcript
    *misleading*, not unusable, and stopping the run over it would put the
    operator's only account of what happened behind an exit code.

    The two WARN conditions are the two ways this can still bite. ``unmatched``
    means dicta recorded a dictation during the meeting whose text was not found
    — so it is probably in the transcript, unmarked and unmarkable. ``suspected``
    means an attempt whose text could not place it — none was produced, or too
    few words to align on — sits over a stretch of transcript that only a human
    can judge. Matched spans alone are GREEN: they are the case that worked.
    """
    if not isinstance(report, dict):
        return _check(
            "dictation",
            GREEN,
            "S6.5 did not run — no dicta.json (nothing claims dictation leaked)",
            counts=None,
        )
    status_reported = report.get("status")
    if status_reported == "skipped":
        return _check(
            "dictation",
            GREEN,
            f"S6.5 skipped — {report.get('detail', 'no reason recorded')}",
            counts=None,
        )
    if status_reported != "ok":
        return _check(
            "dictation",
            WARN,
            f"S6.5 did not complete — {report.get('detail', 'no reason recorded')}",
            counts=None,
        )

    counts = report.get("counts") or {}
    matched = int(counts.get("matched") or 0)
    suspected = int(counts.get("suspected") or 0)
    unmatched = int(counts.get("unmatched") or 0)
    share = report.get("marked_share")
    share_text = "" if share is None else f", {share:.1%} слов дорожки mic"

    if not (matched or suspected or unmatched):
        return _check(
            "dictation", GREEN, "голосового ввода в записи не найдено", counts=counts
        )

    detail = f"{matched} фрагмент(ов) голосового ввода{share_text}"
    status = GREEN
    if suspected:
        # Not "без текста": a suspicion may carry a few words that were simply
        # too short to align on. What every one of them has in common is that
        # only the window placed it — that is the fact worth putting here.
        detail += (
            f"; {suspected} под подозрением (место только по окну — проверить)"
        )
        status = WARN
    if unmatched:
        detail += (
            f"; {unmatched} попыт(ок) dicta не найдено в транскрипте — "
            "вероятно, диктовка осталась не помеченной"
        )
        status = WARN
    return _check("dictation", status, detail, counts=counts)


def build_checks(
    rows, metrics, loops, low_conf, coverage, source: str, merge_report=None,
    dicta_report=None,
) -> list[dict]:
    """Every gate, in the order a reader wants them."""
    checks = []

    if rows:
        checks.append(
            _check(
                "transcript",
                GREEN,
                f"{metrics['line_count']} line(s) parsed",
                line_count=metrics["line_count"],
            )
        )
    else:
        checks.append(
            _check(
                "transcript",
                RED,
                (
                    "the transcript holds no `**[HH:MM:SS] LABEL:**` lines — "
                    "nothing to verify"
                ),
                line_count=0,
            )
        )

    if loops:
        worst = max(loops, key=lambda loop: loop["count"])
        checks.append(
            _check(
                "repeated_phrase_loop",
                RED,
                (
                    f"{len(loops)} repeated-phrase loop(s); worst is "
                    f"«{worst['text']}» ×{worst['count']} at {worst['from_timecode']}"
                ),
                loops=loops,
            )
        )
    else:
        checks.append(
            _check("repeated_phrase_loop", GREEN, "no repeated-phrase loop", loops=[])
        )

    ratio = metrics["unique_ratio"]
    if ratio is None:
        checks.append(
            _check("unique_line_ratio", GREEN, "no non-empty lines to compare", ratio=None)
        )
    else:
        status = WARN if ratio < UNIQUE_RATIO_WARN else GREEN
        top = metrics["top_repeat"]
        detail = (
            f"{metrics['unique_lines']}/{metrics['non_empty_lines']} unique "
            f"({ratio:.1%}), top repeat ×{top['count'] if top else 0}"
        )
        checks.append(
            _check(
                "unique_line_ratio",
                status,
                detail,
                ratio=ratio,
                warn_below=UNIQUE_RATIO_WARN,
                top_repeat=top,
            )
        )

    if source == SOURCE_TEAMS_VTT or low_conf["scored_words"] == 0:
        checks.append(
            _check(
                "low_confidence_spans",
                GREEN,
                (
                    f"skipped — {SOURCE_LABEL[SOURCE_TEAMS_VTT]} carries no per-word "
                    "confidence"
                    if source == SOURCE_TEAMS_VTT
                    else "no per-word confidence in the S3 stage JSON"
                ),
                skipped=True,
                span_count=low_conf["span_count"],
            )
        )
    else:
        fraction = low_conf["low_confidence_fraction"] or 0.0
        status = WARN if fraction > LOW_CONFIDENCE_WARN_FRACTION else GREEN
        checks.append(
            _check(
                "low_confidence_spans",
                status,
                (
                    f"{low_conf['span_count']} span(s), "
                    f"{low_conf['low_confidence_words']}/{low_conf['scored_words']} "
                    f"word(s) below {low_conf['threshold']} ({fraction:.1%})"
                ),
                skipped=False,
                span_count=low_conf["span_count"],
                fraction=low_conf["low_confidence_fraction"],
                warn_above=LOW_CONFIDENCE_WARN_FRACTION,
            )
        )

    if coverage is None:
        checks.append(
            _check(
                "diarization_coverage",
                GREEN,
                coverage_skip_reason(merge_report, source),
                skipped=True,
                coverage=None,
            )
        )
    else:
        if coverage < COVERAGE_FLOOR:
            status = RED
        elif coverage < COVERAGE_WARN:
            status = WARN
        else:
            status = GREEN
        checks.append(
            _check(
                "diarization_coverage",
                status,
                (
                    f"{coverage:.1%} of system words assigned by overlap "
                    f"(floor {COVERAGE_FLOOR:.0%}, warn under {COVERAGE_WARN:.0%})"
                ),
                skipped=False,
                coverage=round(coverage, 4),
                floor=COVERAGE_FLOOR,
                warn_below=COVERAGE_WARN,
            )
        )

    checks.append(dictation_check(dicta_report))

    return checks


def worst_status(checks) -> str:
    """The verdict. Only ``HARD_GATES`` may reach RED — everything else clamps.

    ``HARD_GATES`` is otherwise merely descriptive: it feeds ``gates_tripped``
    but not the status, so a soft check that ever emitted RED would silently
    fail the stage and the run. Enforced here rather than trusted.
    """
    severities = [
        c["status"] if c["name"] in HARD_GATES else min(c["status"], WARN, key=_SEVERITY.get)
        for c in checks
    ]
    return max(severities, key=lambda s: _SEVERITY[s], default=GREEN)


# --- provenance --------------------------------------------------------------


def _fmt_number(value) -> str:
    return NOT_AVAILABLE if value is None else str(value)


def read_stamp(environ=None):
    """The bootstrap stamp, or ``None``. Read-only, and only for the pin."""
    return read_optional_json(stamp_path(environ))


def collect_provenance(inputs: dict, source: str, coverage, environ=None) -> dict:
    """Every field the provenance line names — ``n/a`` when the stage never ran.

    Nothing here is re-derived: the denoise chain comes from the S1 report, the
    diarization controls from the S4 report, the FluidAudio tag from the
    bootstrap stamp. A provenance line that guessed would defeat its own purpose.
    """
    stamp = read_stamp(environ) or {}
    prep = inputs.get("prep_audio") or {}
    gate = inputs.get("gate") or {}
    transcribe = inputs.get("transcribe") or {}
    diarization = inputs.get("diarization") or {}
    speakers_artifact = inputs.get("speakers") or {}

    provenance = {
        "source": source,
        "source_label": SOURCE_LABEL[source],
        "fluidaudio_tag": stamp.get("fluidaudio_tag") or NOT_AVAILABLE,
        "fluidaudio_commit": stamp.get("commit") or NOT_AVAILABLE,
    }

    # --- S1: the denoise chain ---
    # Per track, not the stage's top-level field: an under-levelled track is
    # re-converted at `loudnorm` on its own (pipeline.relevel_calls), so the
    # top-level chain names only the last invocation and would report loudnorm
    # for a `system` track that was never re-levelled. Provenance that quietly
    # attributes one track's preprocessing to another is exactly the kind of
    # claim this block exists to prevent.
    per_track = {
        str(entry.get("track")): entry.get("chain")
        for entry in prep.get("tracks") or []
        if isinstance(entry, dict) and entry.get("chain")
    }
    distinct = sorted(set(per_track.values()))
    if len(distinct) > 1:
        provenance["preprocess_chain"] = ", ".join(
            f"{track}={chain}" for track, chain in sorted(per_track.items())
        )
        provenance["preprocess_filter"] = "по дорожкам"
    elif distinct:
        provenance["preprocess_chain"] = distinct[0]
        provenance["preprocess_filter"] = (
            next(
                (
                    entry.get("filter")
                    for entry in prep.get("tracks") or []
                    if isinstance(entry, dict) and entry.get("chain") == distinct[0]
                ),
                None,
            )
            or prep.get("filter")
            or "—"
        )
    elif prep.get("chain"):
        provenance["preprocess_chain"] = str(prep["chain"])
        provenance["preprocess_filter"] = prep.get("filter") or "—"
    else:
        provenance["preprocess_chain"] = NOT_AVAILABLE
        provenance["preprocess_filter"] = NOT_AVAILABLE

    # --- S2: the gate threshold ---
    provenance["gate_threshold"] = (
        _fmt_number(gate.get("threshold")) if gate else NOT_AVAILABLE
    )

    # --- S3: the ASR engine ---
    if transcribe:
        provenance["asr_engine"] = transcribe.get("engine") or NOT_AVAILABLE
        models = [
            entry.get("model_version")
            for entry in transcribe.get("tracks") or []
            if isinstance(entry, dict) and entry.get("model_version")
        ]
        provenance["asr_model"] = models[0] if models else NOT_AVAILABLE
        provenance["asr_language"] = transcribe.get("language") or "auto"
        provenance["asr_extra_models"] = transcribe.get("extra_models") or []
    else:
        provenance["asr_engine"] = NOT_AVAILABLE
        provenance["asr_model"] = NOT_AVAILABLE
        provenance["asr_language"] = NOT_AVAILABLE
        provenance["asr_extra_models"] = []

    # --- S4: the diarizer and its controls ---
    parameters = diarization.get("parameters") if isinstance(diarization, dict) else None
    if isinstance(parameters, dict):
        provenance["diarization_engine"] = diarization.get("engine") or NOT_AVAILABLE
        provenance["diarization_mode"] = parameters.get("mode") or NOT_AVAILABLE
        provenance["diarization_model"] = parameters.get("model") or NOT_AVAILABLE
        if parameters.get("control") == "num-speakers":
            provenance["diarization_control"] = (
                f"--num-speakers {parameters.get('num_speakers')}"
            )
        else:
            provenance["diarization_control"] = (
                f"--threshold {_fmt_number(parameters.get('threshold'))}"
            )
        provenance["min_segment_duration"] = _fmt_number(
            parameters.get("min_segment_duration")
        )
        provenance["min_gap_duration"] = _fmt_number(parameters.get("min_gap_duration"))
    else:
        provenance["diarization_engine"] = NOT_AVAILABLE
        provenance["diarization_mode"] = NOT_AVAILABLE
        provenance["diarization_model"] = NOT_AVAILABLE
        provenance["diarization_control"] = NOT_AVAILABLE
        provenance["min_segment_duration"] = NOT_AVAILABLE
        provenance["min_gap_duration"] = NOT_AVAILABLE

    # --- S5: coverage ---
    provenance["diarization_coverage"] = (
        NOT_AVAILABLE if coverage is None else f"{coverage:.1%}"
    )

    # --- S6: anchored vs inferred (D8) ---
    entries = speakers_artifact.get("speakers")
    if isinstance(entries, dict) and entries:
        anchored, inferred = [], []
        for label, entry in sorted(entries.items()):
            if not isinstance(entry, dict):
                continue
            if entry.get("anchored") and entry.get("name"):
                anchored.append(
                    {
                        "speaker": label,
                        "name": str(entry["name"]),
                        "anchor_type": entry.get("anchor_type"),
                        "confidence": entry.get("confidence"),
                    }
                )
            else:
                inferred.append(label)
        provenance["anchored"] = anchored
        provenance["inferred"] = inferred
        provenance["speakers_known"] = True
    else:
        provenance["anchored"] = []
        provenance["inferred"] = []
        provenance["speakers_known"] = False

    # --- S6.5: dictation correlated out of the mic track ---
    dicta = inputs.get("dicta")
    if isinstance(dicta, dict) and dicta.get("status") == "ok":
        counts = dicta.get("counts") or {}
        calibration = dicta.get("calibration") or {}
        provenance["dictation"] = (
            f"{counts.get('matched', 0)} фрагм., "
            f"подозрений {counts.get('suspected', 0)}, "
            f"не найдено {counts.get('unmatched', 0)}"
        )
        # The measured drift between Acta's wall clock and the transcript's own.
        # Reported even when it is small: it is the only place this number is
        # ever observed, and a large one is a fact about the recording.
        provenance["dictation_clock"] = (
            f"смещение часов {calibration.get('offset_seconds', 0.0):+.1f} с "
            f"({calibration.get('anchors', 0)} якор.)"
            if calibration.get("calibrated")
            else "часы не откалиброваны"
        )
    else:
        provenance["dictation"] = NOT_AVAILABLE
        provenance["dictation_clock"] = NOT_AVAILABLE

    provenance["raw_transcript"] = RAW_TRANSCRIPT_NAME
    return provenance


# --- rendering ---------------------------------------------------------------


def render_provenance_line(provenance: dict) -> str:
    """One italic paragraph naming every provenance field, ``n/a`` included."""
    if provenance["preprocess_chain"] == NOT_AVAILABLE:
        preprocess = NOT_AVAILABLE
    else:
        preprocess = (
            f"{provenance['preprocess_chain']} ({provenance['preprocess_filter']})"
        )

    if provenance["diarization_mode"] == NOT_AVAILABLE:
        diarization = NOT_AVAILABLE
    else:
        diarization = (
            f"{provenance['diarization_mode']} / {provenance['diarization_model']}, "
            f"{provenance['diarization_control']}, "
            f"--min-segment-duration {provenance['min_segment_duration']}, "
            f"--min-gap-duration {provenance['min_gap_duration']}"
        )

    if provenance["speakers_known"]:
        anchored = (
            ", ".join(
                f"{item['speaker']} → {item['name']} ({item['anchor_type']})"
                for item in provenance["anchored"]
            )
            or "никто"
        )
        inferred = ", ".join(provenance["inferred"]) or "нет"
    else:
        anchored = inferred = NOT_AVAILABLE

    # D6 makes `--custom-vocab` an opt-in precisely because hotwords can force a
    # false substitution, so the run that used them is the one that most needs to
    # say so. It was collected into verify.json and then dropped here, leaving the
    # block prepended to transcript.md silent about it.
    asr = (
        f"ASR: {provenance['asr_engine']}, модель {provenance['asr_model']}, "
        f"язык {provenance['asr_language']}"
    )
    extra = provenance.get("asr_extra_models") or []
    if extra:
        asr += f", дополнительно: {', '.join(str(item) for item in extra)}"

    parts = [
        f"Источник: {provenance['source_label']}",
        asr,
        f"FluidAudio: {provenance['fluidaudio_tag']}",
        f"предобработка: {preprocess}",
        f"гейт тишины: RMS ≥ {provenance['gate_threshold']}",
        f"диаризация: {diarization}",
        f"покрытие диаризацией: {provenance['diarization_coverage']}",
        f"имена по якорям (D8): {anchored}",
        f"без якоря: {inferred}",
        f"голосовой ввод (dicta): {provenance['dictation']}"
        + (
            ""
            if provenance["dictation"] == NOT_AVAILABLE
            else f", {provenance['dictation_clock']}"
        ),
        f"дословный источник: `{provenance['raw_transcript']}`",
    ]
    return "_" + "; ".join(parts) + "._"


def render_dictation_block(dicta: dict) -> list[str]:
    """The S6.5 spans, named so S7 can mark exactly those lines.

    Timecodes and attempt ids rather than prose: this block is prepended to
    ``transcript.md`` verbatim, and the reader's next action is to find those
    lines. A span that only clips a line is said to clip it — marking a whole
    turn of real meeting speech because a dictation ended inside it is the
    over-marking this whole stage is careful to avoid.
    """
    matched = dicta.get("matched") or []
    suspected = dicta.get("suspected") or []
    unmatched = dicta.get("unmatched") or []
    if not (matched or suspected or unmatched):
        return []

    lines = ["", "**Голосовой ввод (dicta) — не реплики встречи:**"]
    for row in matched:
        partial = [u for u in row.get("utterances") or [] if u.get("partial")]
        clipped = f", частично задета {len(partial)} реплик(а)" if partial else ""
        lines.append(
            f"- `{row['timecode']}` dicta #{row['attempt_id']} "
            f"«{row['recognised'][:70]}» (совпадение {row['score']:.2f}{clipped})"
        )
    for row in suspected:
        # The uncertainty is the whole message on an uncalibrated placement: a
        # timecode printed without it reads as a location, and the reader would
        # go and mark the line under it.
        uncertainty = row.get("uncertainty_seconds")
        where = (
            f"`{row['timecode']}`"
            if uncertainty is None
            else f"`{row['timecode']}` ±{uncertainty:.0f} с"
        )
        span = row.get("lines_within_uncertainty")
        reach = "" if span is None else f", в диапазон попадает реплик: {span}"
        # A suspicion may carry a few words — too few to align on, but plenty
        # for a reader to judge in a second. Printing "без текста" over them
        # would hide the one thing that makes the check cheap.
        heard = row.get("recognised")
        what = f"«{heard}»" if heard else "без текста"
        # dicta's own note, verbatim. On most attempts it merely repeats the
        # outcome and is dropped; when it says more — that the words could not
        # be recognised, that the dictionary was degraded — that sentence is
        # what tells the reader whether "без текста" means "nothing was said"
        # or "nobody managed to look".
        note = (row.get("error") or "").strip()
        why = "" if not note or note == row["outcome"] else f", dicta: «{note}»"
        lines.append(
            f"- ⚠ {where} dicta #{row['attempt_id']} — {what} "
            f"({row['outcome']}, {row['speech_seconds']:.1f} с){reach}{why}: "
            "место определено только по окну, проверить на слух"
        )
    for row in unmatched:
        lines.append(
            f"- ⚠ dicta #{row['attempt_id']} в транскрипте не найдена "
            f"({row.get('reason', '')}) — «{row.get('preview', '')}»: "
            "возможно, диктовка осталась не помеченной"
        )
    return lines


def render_quality_md(report: dict) -> str:
    """The ⚠ block Claude prepends verbatim to ``transcript.md`` at S7."""
    lines = ["## ⚠ Качество расшифровки", ""]

    for check in report["checks"]:
        marker = _QUALITY_MARKER[check["status"]]
        lines.append(f"- {marker} **{check['name']}** — {check['detail']}")

    spans = report.get("low_confidence", {}).get("spans") or []
    if spans:
        lines.append("")
        lines.append(
            f"**Низкая уверенность ASR** (< {report['low_confidence']['threshold']}) — "
            "проверить на слух:"
        )
        for span in spans[:QUALITY_MD_SPAN_LIMIT]:
            lines.append(
                f"- `{span['timecode']}` [{span['track']}] «{span['text']}» "
                f"(min {span['min_confidence']})"
            )
        if len(spans) > QUALITY_MD_SPAN_LIMIT:
            lines.append(f"- …ещё {len(spans) - QUALITY_MD_SPAN_LIMIT} фрагмент(ов)")

    lines.extend(render_dictation_block(report.get("dicta") or {}))

    tally = report.get("speakers") or []
    if tally:
        lines.append("")
        lines.append("**Реплики по спикерам:**")
        for entry in tally:
            share = "" if entry["line_share"] is None else f" ({entry['line_share']:.0%})"
            lines.append(
                f"- {entry['speaker']}: {entry['lines']} реплик{share}, "
                f"{entry['words']} слов"
            )

    lines.append("")
    lines.append(render_provenance_line(report["provenance"]))
    lines.append("")
    return "\n".join(lines)


def render_human(report: dict) -> str:
    lines = [f"acta-notes verify — {report['status'].upper()} ({report['source']})"]
    for check in report.get("checks") or []:
        lines.append(
            f"  [{_HUMAN_MARKER[check['status']]}] {check['name']:<22} {check['detail']}"
        )
    if report.get("gates_tripped"):
        lines.append("")
        lines.append("hard gate(s) tripped: " + ", ".join(report["gates_tripped"]))
    if report["status"] == STATUS_MISSING:
        lines.append("")
        lines.append(report.get("detail", "verify failed"))
    return "\n".join(lines)


# --- the stage ---------------------------------------------------------------


def run(meeting_dir, transcript=None, source=SOURCE_AUTO, environ=None, clock=time.monotonic) -> dict:
    """Verify one meeting; returns the stage report. Writes no transcript."""
    meeting_dir = Path(meeting_dir)
    transcript_file = (
        Path(transcript) if transcript else labeled_transcript_path(meeting_dir)
    )
    report = {
        "stage": "verify",
        "meeting_dir": str(meeting_dir),
        "transcript": str(transcript_file),
        "verify_json": str(verify_json_path(meeting_dir)),
        "quality_md": str(quality_md_path(meeting_dir)),
        "elapsed_seconds": 0.0,
    }
    started = clock()

    inputs = load_inputs(meeting_dir)
    resolved_source = detect_source(inputs) if source == SOURCE_AUTO else source
    report["source"] = resolved_source
    report["source_detected"] = source == SOURCE_AUTO
    report["stage_json_present"] = {
        name: value is not None for name, value in sorted(inputs.items())
    }

    # A missing transcript is the empty transcript: every check, metric and
    # provenance field below already handles zero rows, and the one thing that
    # differs — the verdict, and what the `transcript` check says — is patched
    # afterwards. Assembling a second report by hand here would mean a new
    # check silently never reaching the missing-transcript path.
    missing = not transcript_file.is_file()
    read_error = None
    text = ""
    if not missing:
        try:
            text = transcript_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            # An unreadable transcript is a thing to *report*, not to crash on:
            # pipeline.py's runner catches only SystemExit, so the traceback
            # would escape run() and pipeline.json — the whole run log — would
            # never be written.
            missing = True
            read_error = str(exc)
            text = ""
    rows = parse_lines(text)

    metrics = line_metrics(rows)
    loops = find_loops(rows)
    low_conf = low_confidence_spans(inputs.get("transcribe"))
    coverage = coverage_from(inputs.get("merge"))
    checks = build_checks(
        rows,
        metrics,
        loops,
        low_conf,
        coverage,
        resolved_source,
        merge_report=inputs.get("merge"),
        dicta_report=inputs.get("dicta"),
    )

    report["metrics"] = metrics
    report["loops"] = loops
    report["low_confidence"] = low_conf
    report["coverage"] = None if coverage is None else round(coverage, 4)
    report["speakers"] = speaker_tally(rows)
    report["checks"] = checks
    report["gates_tripped"] = [
        check["name"]
        for check in checks
        if check["status"] == RED and check["name"] in HARD_GATES
    ]
    # The S6.5 report travels into verify.json whole: quality.md renders the
    # spans from it, and a reader of verify.json alone should not have to open a
    # second file to see what was marked.
    report["dicta"] = inputs.get("dicta")
    report["provenance"] = collect_provenance(
        inputs, resolved_source, coverage, environ=environ
    )

    severity = worst_status(checks)
    report["status"] = {GREEN: STATUS_OK, WARN: STATUS_WARN, RED: STATUS_FAILED}[severity]
    report["detail"] = (
        "hard gate(s) tripped: " + ", ".join(report["gates_tripped"])
        if report["gates_tripped"]
        else f"{len(rows)} line(s) verified"
    )

    if missing:
        # Nothing to verify — but the provenance was still worth collecting, and
        # pipeline.py wants a quality.md to print either way.
        unreadable = (
            f"unreadable transcript at {transcript_file}: {read_error}"
            if read_error
            else f"no transcript at {transcript_file}"
        )
        for check in checks:
            if check["name"] == "transcript":
                check["detail"] = unreadable
        report["status"] = STATUS_MISSING
        report["detail"] = (
            unreadable
            if read_error
            else (
                f"no {transcript_file.name} at {transcript_file} — run "
                "`speakers.py apply` first"
            )
        )

    report["elapsed_seconds"] = round(clock() - started, 3)
    return report


def write_outputs(meeting_dir, report: dict) -> tuple[Path, Path]:
    """Write ``verify.json`` and ``quality.md``. Never touches a transcript."""
    work = work_dir(meeting_dir)
    work.mkdir(parents=True, exist_ok=True)

    quality = quality_md_path(meeting_dir)
    quality.write_text(render_quality_md(report), encoding="utf-8")

    machine = verify_json_path(meeting_dir)
    machine.write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return machine, quality


def exit_code(report: dict) -> int:
    """Green and warn both pass; a hard gate or a missing transcript does not."""
    return EXIT_OK if report["status"] in (STATUS_OK, STATUS_WARN) else EXIT_FAILED


def main(argv=None, environ=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="verify.py",
        description=(
            "Phase 4: quality gates and provenance over "
            f"{LABELED_TRANSCRIPT_NAME} and the stage JSONs. Writes "
            f"{WORK_DIRNAME}/{VERIFY_JSON_NAME} and {WORK_DIRNAME}/"
            f"{QUALITY_MD_NAME}; writes no transcript — Claude prepends "
            f"{QUALITY_MD_NAME} verbatim when it builds {CLEAN_TRANSCRIPT_NAME} "
            "at S7."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--transcript",
        metavar="PATH",
        help=f"transcript to verify (default: {LABELED_TRANSCRIPT_NAME})",
    )
    parser.add_argument(
        "--source",
        choices=(SOURCE_AUTO, SOURCE_LOCAL_ASR, SOURCE_TEAMS_VTT),
        default=SOURCE_AUTO,
        help=(
            "transcript source for the provenance line. `auto` decides from the "
            "presence of the S3 stage JSON"
        ),
    )
    parser.add_argument("--json", action="store_true", help="print the stage JSON")
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    report = run(
        meeting_dir,
        transcript=args.transcript,
        source=args.source,
        environ=environ,
        clock=clock,
    )
    write_outputs(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
