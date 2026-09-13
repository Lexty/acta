#!/usr/bin/env python3
"""acta-notes S5 — utterance-level merge into ``transcript.raw.md``.

Reads the two artifacts the machine stages left behind::

    <meeting>/.acta-notes/transcribe.json   (S3 — per-track word timings, D3)
    <meeting>/diarization.json              (S4 — system-track speaker turns, D2)

and writes the first link of the transcript chain::

    <meeting>/transcript.raw.md             verbatim, SPK_NN labels
    <meeting>/.acta-notes/merge.json        the stage JSON

**The merge unit is an utterance, not a word.** This is the spike's validated
design, not a simplification: per-word max-overlap assignment flips speakers
mid-sentence and leaves ~9 % of words unassigned. Splitting the word stream at
pauses **> 0.7 s**, then giving each utterance the speaker holding the greatest
*overlapped duration*, turned 84 ragged fragments into 34 readable turns on the
8-minute slice.

**Nearest-segment fallback.** An utterance that overlaps no diarization segment
at all (it fell in a gap the segmenter cut out) takes the speaker of the closest
segment in time rather than being dropped or labelled unknown. It is recorded as
``fallback`` in the stage JSON so the coverage number stays honest: ``coverage``
counts only words assigned by real overlap — that is the 91 %-at-defaults figure
the deferred sweep harness has to beat.

**The mic track is ``Я`` by construction (D5).** It is interleaved by timestamp
with no model in the loop: one speaker, known in advance. Only the system track
carries ``SPK_NN`` labels, and only at this stage — ``speakers.py apply`` is what
turns them into names, writing ``transcript.labeled.md`` and leaving this file
untouched.

**``transcript.raw.md`` is the forensic artifact and is never overwritten.** A
second run against a meeting that already has one exits ``2`` and changes
nothing; ``--force`` is the deliberate opt-out. ``teams_vtt_to_transcript.py``,
the *other* producer of this file, obeys the same rule with the same message and
exit code — neither producer may silently clobber the other's output.

Stdlib only — no binary to resolve, no model, no network.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: Spike-validated utterance boundary: a gap **strictly greater** than this ends
#: the current utterance. A module constant rather than a flag default — moving
#: it is a measurement decision (the deferred sweep harness), not a per-run one.
PAUSE_SPLIT_SECONDS = 0.7

#: The mic track's label, fixed by D5: one speaker, known in advance.
MIC_TRACK = "mic"
MIC_LABEL = "Я"
#: The only track diarization runs on, and so the only one carrying SPK_NN.
SYSTEM_TRACK = "system"

#: On identical start times the mic utterance is written first. Arbitrary, but
#: fixed — the same inputs must always produce a byte-identical transcript.
TRACK_ORDER = {MIC_TRACK: 0, SYSTEM_TRACK: 1}

#: How an utterance got its speaker; both land in the stage JSON.
ASSIGNMENT_OVERLAP = "overlap"
ASSIGNMENT_FALLBACK = "fallback"
#: The mic track's utterances are not assigned at all — they are `Я` by track.
ASSIGNMENT_TRACK = "track"

WORK_DIRNAME = ".acta-notes"
STAGE_JSON_NAME = "merge.json"
TRANSCRIBE_JSON_NAME = "transcribe.json"
DIARIZATION_JSON_NAME = "diarization.json"
#: S5's output and the source of truth for everything after it.
RAW_TRANSCRIPT_NAME = "transcript.raw.md"
#: Written by speakers.py apply, never here — named only so the provenance line
#: can point at the next step.
LABELED_TRANSCRIPT_NAME = "transcript.labeled.md"

STATUS_OK = "ok"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"
STATUS_REFUSED = "refused"

EXIT_OK = 0
EXIT_FAILED = 1
#: A caller error — an existing raw transcript, or an input this stage will not
#: invent its way around.
EXIT_USAGE = 2


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def transcribe_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / TRANSCRIBE_JSON_NAME


def diarization_json_path(meeting_dir) -> Path:
    """S4's normalized artifact lives at the meeting root, beside speakers.json."""
    return Path(meeting_dir) / DIARIZATION_JSON_NAME


def transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / RAW_TRANSCRIPT_NAME


def stage_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / STAGE_JSON_NAME


def overwrite_refusal(path) -> str:
    """The one refusal message both producers of ``transcript.raw.md`` use.

    ``teams_vtt_to_transcript.py`` repeats it verbatim: the two are alternatives
    writing the same file, so a user who hits the guard must see the same thing
    whichever path they took.
    """
    return (
        f"{path} already exists — it is the verbatim forensic artifact every "
        "later stage is a view over, so this stage refuses to overwrite it. "
        "Pass --force to replace it deliberately."
    )


# --- input loading -----------------------------------------------------------


class InputError(Exception):
    """An input file is absent or unusable. Never worked around silently."""


def as_number(value):
    """``float(value)`` or ``None`` — never raises.

    The upstream stage JSONs are files on disk: a timing can be present and
    still not be a number. A bare ``float()`` here would escape as a traceback
    instead of a stage failure, so a non-numeric timing is treated exactly like
    a missing one — the word or segment is dropped.
    """
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _read_json(path, what: str):
    path = Path(path)
    if not path.is_file():
        raise InputError(f"no {what} at {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise InputError(f"cannot read {what} at {path}: {exc}") from exc
    except ValueError as exc:
        raise InputError(f"{what} at {path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise InputError(f"{what} at {path} is not a JSON object")
    return data


def read_transcribe_json(meeting_dir) -> dict:
    return _read_json(transcribe_json_path(meeting_dir), "the S3 stage JSON")


def read_diarization_json(meeting_dir) -> dict:
    return _read_json(diarization_json_path(meeting_dir), "the S4 diarization JSON")


def words_for_track(transcribe_report: dict, track: str) -> list[dict]:
    """The word timings S3 recorded for one track, sorted by start time.

    Sorting is defensive: the merge's whole output order depends on it, and a
    single out-of-order word would silently split one utterance into two.
    """
    words = []
    for entry in transcribe_report.get("tracks") or []:
        if not isinstance(entry, dict) or entry.get("track") != track:
            continue
        for word in entry.get("words") or []:
            if not isinstance(word, dict):
                continue
            text = word.get("word")
            start, end = as_number(word.get("start")), as_number(word.get("end"))
            if not text or start is None or end is None:
                continue
            # Same rule as ``segments_from``: an interval that ends before it
            # starts is not a shorter interval, it is a broken one. Keeping it
            # poisoned the running ``reach`` in ``split_utterances`` (a low reach
            # inflates the next gap and forces a spurious split) and let
            # ``_utterance`` emit ``end < start``, which every overlap
            # computation in ``assign_speaker`` then read as zero overlap.
            if end <= start:
                continue
            words.append(
                {
                    "word": str(text),
                    "start": start,
                    "end": end,
                    # Through ``as_number`` for the same reason start/end are: an
                    # ASR that emits a string confidence would otherwise reach
                    # ``_utterance``'s ``sum()`` and kill S5 with a raw TypeError
                    # and no merge.json, instead of the structured failed report
                    # every other malformed-input path here produces.
                    "confidence": as_number(word.get("confidence")),
                }
            )
    words.sort(key=lambda w: (w["start"], w["end"]))
    return words


def segments_from(diarization_report: dict) -> list[dict]:
    """S4's normalized ``segments[]``, sorted by start time."""
    segments = []
    for item in diarization_report.get("segments") or []:
        if not isinstance(item, dict):
            continue
        start, end = as_number(item.get("start")), as_number(item.get("end"))
        speaker = item.get("speaker")
        if start is None or end is None or not speaker:
            continue
        if end <= start:
            continue
        segments.append({"start": start, "end": end, "speaker": str(speaker)})
    segments.sort(key=lambda s: (s["start"], s["end"]))
    return segments


# --- utterances --------------------------------------------------------------


def split_utterances(words, pause: float = PAUSE_SPLIT_SECONDS) -> list[dict]:
    """Cut a word stream into utterances at pauses **strictly greater** than
    ``pause``.

    A gap of exactly 0.7 s keeps the utterance together: the boundary was
    measured as "longer than a breath", and making it inclusive would split on
    the very value the spike settled on.
    """
    utterances: list[dict] = []
    current: list[dict] = []
    # The running max, not ``current[-1]["end"]``: a word stream may carry an
    # overlapping tail, and measuring the gap from the *last* word's end while
    # ``_utterance`` reports the *max* end made the two disagree — a 5 s word
    # followed by two short ones split off a second utterance whose span sat
    # entirely inside the first one's.
    reach = None
    for word in words:
        if current and word["start"] - reach > pause:
            utterances.append(_utterance(current))
            current = []
            reach = None
        current.append(word)
        reach = word["end"] if reach is None else max(reach, word["end"])
    if current:
        utterances.append(_utterance(current))
    return utterances


def _utterance(words) -> dict:
    """One utterance built from its words — verbatim, joined with single spaces."""
    confidences = [w["confidence"] for w in words if w.get("confidence") is not None]
    return {
        "start": round(words[0]["start"], 3),
        # max(), not the last word's end: a word stream may carry an overlapping
        # tail, and an utterance that ended before its own last word would break
        # every overlap computation downstream.
        "end": round(max(w["end"] for w in words), 3),
        "text": " ".join(w["word"] for w in words),
        "word_count": len(words),
        "mean_confidence": (
            round(sum(confidences) / len(confidences), 4) if confidences else None
        ),
        "min_confidence": round(min(confidences), 4) if confidences else None,
    }


# --- speaker assignment ------------------------------------------------------


def overlap_seconds(a_start, a_end, b_start, b_end) -> float:
    """Overlapped duration of two intervals; 0.0 when they only touch."""
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _distance(utterance, segment) -> float:
    """Gap between an utterance and a non-overlapping segment, in seconds."""
    if segment["end"] <= utterance["start"]:
        return utterance["start"] - segment["end"]
    return segment["start"] - utterance["end"]


def assign_speaker(utterance, segments):
    """Pick the speaker for one utterance.

    Majority by overlapped duration, because that is what a turn actually is:
    the speaker who was talking for most of it. Ties — including the all-zeros
    case — resolve to the earliest segment, so the result never depends on dict
    iteration order.

    Returns ``(speaker, method, overlapped_seconds)``, or ``(None, None, 0.0)``
    when there are no segments at all (a case the stage refuses upstream).
    """
    if not segments:
        return None, None, 0.0

    totals: dict[str, float] = {}
    first_seen: dict[str, float] = {}
    for segment in segments:
        seconds = overlap_seconds(
            utterance["start"], utterance["end"], segment["start"], segment["end"]
        )
        if seconds <= 0.0:
            continue
        speaker = segment["speaker"]
        totals[speaker] = totals.get(speaker, 0.0) + seconds
        first_seen.setdefault(speaker, segment["start"])

    if totals:
        speaker = min(totals.items(), key=lambda kv: (-kv[1], first_seen[kv[0]]))[0]
        return speaker, ASSIGNMENT_OVERLAP, round(totals[speaker], 3)

    # Nothing overlapped: the utterance fell in a gap the segmenter cut out.
    # The nearest turn in time is a far better guess than dropping the line —
    # and it is recorded as a fallback so coverage does not claim credit for it.
    nearest = min(
        segments, key=lambda s: (_distance(utterance, s), s["start"], s["speaker"])
    )
    return nearest["speaker"], ASSIGNMENT_FALLBACK, 0.0


def assign_utterances(utterances, segments) -> list[dict]:
    """Assign every system utterance, in place, returning the same list."""
    for utterance in utterances:
        speaker, method, seconds = assign_speaker(utterance, segments)
        utterance["speaker"] = speaker
        utterance["assignment"] = method
        utterance["overlap_seconds"] = seconds
    return utterances


# --- interleaving and coverage -----------------------------------------------


def interleave(mic_utterances, system_utterances) -> list[dict]:
    """Order both tracks into one timeline.

    Sorted by start time, then by track (mic first) and then by end time — a
    total order, so re-running the merge on the same inputs is byte-identical.
    """
    rows = []
    for track, utterances in ((MIC_TRACK, mic_utterances), (SYSTEM_TRACK, system_utterances)):
        for utterance in utterances:
            row = dict(utterance)
            row["track"] = track
            if track == MIC_TRACK:
                row["speaker"] = MIC_LABEL
                row["assignment"] = ASSIGNMENT_TRACK
                row["overlap_seconds"] = 0.0
            rows.append(row)
    rows.sort(key=lambda r: (r["start"], TRACK_ORDER[r["track"]], r["end"]))
    return rows


def coverage_stats(system_utterances) -> dict:
    """Per-word coverage over the *system* track only.

    ``coverage`` is the honest number — words whose utterance was assigned by
    real overlap. Fallback words are counted separately: they carry a speaker,
    but claiming them as coverage would hide exactly the segmentation gaps the
    deferred sweep is meant to close.
    """
    total = sum(u["word_count"] for u in system_utterances)
    overlap = sum(
        u["word_count"]
        for u in system_utterances
        if u.get("assignment") == ASSIGNMENT_OVERLAP
    )
    fallback = sum(
        u["word_count"]
        for u in system_utterances
        if u.get("assignment") == ASSIGNMENT_FALLBACK
    )
    return {
        "system_word_count": total,
        "overlap_words": overlap,
        "fallback_words": fallback,
        "unassigned_words": total - overlap - fallback,
        "coverage": round(overlap / total, 4) if total else None,
        "assigned_coverage": (
            round((overlap + fallback) / total, 4) if total else None
        ),
    }


def speaker_rollup(rows) -> list[dict]:
    """Per-speaker line and word tally, ordered by speech time."""
    rollup: dict[str, dict] = {}
    for row in rows:
        entry = rollup.setdefault(
            row["speaker"],
            {
                "speaker": row["speaker"],
                "track": row["track"],
                "utterances": 0,
                "words": 0,
                "seconds": 0.0,
            },
        )
        entry["utterances"] += 1
        entry["words"] += row["word_count"]
        entry["seconds"] += row["end"] - row["start"]
    out = []
    for entry in rollup.values():
        entry["seconds"] = round(entry["seconds"], 3)
        out.append(entry)
    out.sort(key=lambda e: (-e["seconds"], e["speaker"]))
    return out


# --- rendering ---------------------------------------------------------------


def hms(seconds) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def render_transcript(title: str, rows, coverage: dict) -> str:
    """``transcript.raw.md`` — verbatim lines, one blank line apart.

    The line shape (``**[HH:MM:SS] LABEL:** text``) is the Air skill's, kept on
    purpose: ``speakers.py apply`` substitutes into it, the Teams converter
    produces it, and every downstream reader already knows it.
    """
    # A mic-only meeting has no system words, so no diarization ran on it — the
    # source line used to claim VBx anyway, contradicting the same run's
    # `quality.md` (`диаризация: n/a`) in the one file the operator reads first.
    if coverage["coverage"] is None:
        source = (
            "_Источник: локальный ASR (Parakeet TDT 0.6B v3), без диаризации "
            f"(нет системной дорожки). Дорожка: **{MIC_LABEL}** = mic. Реплики "
            f"нарезаны по паузам > {PAUSE_SPLIT_SECONDS} с. Дословно, без правок._"
        )
    else:
        source = (
            "_Источник: локальный ASR (Parakeet TDT 0.6B v3) + офлайн-диаризация "
            f"VBx. Дорожки: **{MIC_LABEL}** = mic, **SPK_NN** = system (имена "
            f"подставляет `speakers.py apply` в `{LABELED_TRANSCRIPT_NAME}`). "
            f"Реплики нарезаны по паузам > {PAUSE_SPLIT_SECONDS} с; покрытие "
            f"диаризацией — {coverage['coverage']:.0%} слов. Дословно, без правок._"
        )
    lines = [
        f"# {title} — транскрипт",
        "",
        source,
        "",
    ]
    for row in rows:
        lines.append(f"**[{hms(row['start'])}] {row['speaker']}:** {row['text']}")
        lines.append("")
    return "\n".join(lines)


# --- the stage ---------------------------------------------------------------


def run(
    meeting_dir,
    title=None,
    force: bool = False,
    pause: float = PAUSE_SPLIT_SECONDS,
    clock=time.monotonic,
) -> dict:
    """Merge S3 and S4 into ``transcript.raw.md``; returns the stage report."""
    meeting_dir = Path(meeting_dir)
    out_path = transcript_path(meeting_dir)
    report = {
        "stage": "merge",
        "meeting_dir": str(meeting_dir),
        "transcript": str(out_path),
        "pause_seconds": float(pause),
        "mic_label": MIC_LABEL,
        "forced": bool(force),
        "written": False,
        "elapsed_seconds": 0.0,
    }
    started = clock()

    # First, before reading a byte of input: the raw transcript is the forensic
    # artifact, and a run that was going to refuse must not look like work.
    if out_path.exists() and not force:
        report.update({"status": STATUS_REFUSED, "detail": overwrite_refusal(out_path)})
        return report

    try:
        transcribe_report = read_transcribe_json(meeting_dir)
    except InputError as exc:
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": f"{exc} — run transcribe.py first",
            }
        )
        return report

    mic_words = words_for_track(transcribe_report, MIC_TRACK)
    system_words = words_for_track(transcribe_report, SYSTEM_TRACK)
    if not mic_words and not system_words:
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    "the S3 stage JSON holds no word timings on either track — "
                    "nothing to merge"
                ),
            }
        )
        return report

    segments: list[dict] = []
    if system_words:
        try:
            segments = segments_from(read_diarization_json(meeting_dir))
        except InputError as exc:
            report.update(
                {
                    "status": STATUS_MISSING,
                    "detail": f"{exc} — run diarize.py run --track system first",
                }
            )
            return report
        if not segments:
            # Every system line would carry no speaker at all. A transcript that
            # looks finished and names nobody is worse than a stage that stopped.
            report.update(
                {
                    "status": STATUS_FAILED,
                    "detail": (
                        f"{diarization_json_path(meeting_dir)} holds no usable "
                        "speaker segments — re-run diarize.py (D2)"
                    ),
                }
            )
            return report

    mic_utterances = split_utterances(mic_words, pause=pause)
    system_utterances = assign_utterances(
        split_utterances(system_words, pause=pause), segments
    )
    rows = interleave(mic_utterances, system_utterances)

    coverage = coverage_stats(system_utterances)
    report.update(coverage)
    report["utterances"] = rows
    report["utterance_count"] = len(rows)
    report["mic_utterance_count"] = len(mic_utterances)
    report["system_utterance_count"] = len(system_utterances)
    report["word_count"] = sum(row["word_count"] for row in rows)
    report["speakers"] = speaker_rollup(rows)
    report["speaker_count"] = len([s for s in report["speakers"] if s["track"] == SYSTEM_TRACK])
    report["segment_count"] = len(segments)

    title = title or meeting_dir.name
    report["title"] = title
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(render_transcript(title, rows, coverage), encoding="utf-8")

    report["written"] = True
    report["status"] = STATUS_OK
    report["detail"] = (
        f"{len(rows)} utterance(s) over {report['speaker_count']} system speaker(s)"
    )
    report["elapsed_seconds"] = round(clock() - started, 3)
    return report


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = stage_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def render_human(report: dict) -> str:
    lines = [f"acta-notes merge — {report['status'].upper()}"]
    if report.get("written"):
        lines.append(f"  wrote {report['transcript']}")
    coverage = report.get("coverage")
    if coverage is not None:
        lines.append(
            f"  coverage {coverage:.1%} by overlap "
            f"({report.get('fallback_words', 0)} word(s) via nearest-segment "
            f"fallback, {report.get('unassigned_words', 0)} unassigned)"
        )
    for entry in report.get("speakers") or []:
        lines.append(
            f"  {entry['speaker']:<7} {entry['seconds']:>8.1f}s  "
            f"{entry['utterances']:>4} turn(s)  {entry['words']:>6} word(s)"
        )
    if report.get("utterance_count") is not None:
        lines.append(
            f"  {report['utterance_count']} utterance(s), "
            f"{report.get('word_count', 0)} word(s), "
            f"{report.get('elapsed_seconds', 0.0):.1f}s"
        )
    if report["status"] != STATUS_OK:
        lines.append("")
        lines.append(report.get("detail", "merge failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] == STATUS_OK:
        return EXIT_OK
    if report["status"] == STATUS_REFUSED:
        return EXIT_USAGE
    return EXIT_FAILED


def main(argv=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="merge.py",
        description=(
            "S5: cut the word stream into utterances at pauses > "
            f"{PAUSE_SPLIT_SECONDS} s, give each the speaker holding the greatest "
            f"overlapped duration, interleave the mic track as `{MIC_LABEL}` (D5), "
            f"and write the verbatim {RAW_TRANSCRIPT_NAME}."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--title",
        metavar="TEXT",
        help="transcript heading (default: the meeting folder's name)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help=(
            f"replace an existing {RAW_TRANSCRIPT_NAME}. Off by default: it is the "
            "verbatim forensic artifact every later stage is a view over"
        ),
    )
    parser.add_argument("--json", action="store_true", help="print the stage JSON")
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    report = run(meeting_dir, title=args.title, force=args.force, clock=clock)
    # A refusal wrote nothing, so it must not leave a stage JSON behind either —
    # the previous merge's numbers still describe the transcript on disk.
    if report["status"] != STATUS_REFUSED:
        write_stage_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
