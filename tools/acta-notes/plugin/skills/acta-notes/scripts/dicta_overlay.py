#!/usr/bin/env python3
"""acta-notes S6.5 — mark the dictation that leaked into the mic track.

The problem this stage exists for: `dicta` (the sibling voice-dictation app,
`~/dev/personal/dicta`) captures the same physical microphone that Acta is
recording into ``mic.wav``. Dictating a prompt to an agent while a meeting is
being recorded therefore puts that speech into the meeting's transcript, where
every later reader — the summary above all — takes it for something the user
said *to the meeting*. Muting the microphone in Slack or Teams does not help:
that mutes what the other participants hear, not what Acta captures.

**What is matched is text, not audio.** Both sides run the *same* recogniser —
Parakeet TDT 0.6B v3 via FluidAudio at 16 kHz mono (dicta's
``ParakeetTranscriber``, this skill's ``transcribe.py``) — so one utterance
decoded twice comes out near-identical token for token. That turns the match
from a semantic guess into something close to string equality, and it is why no
audio fingerprinting is needed here.

**Time is a gate, never the verdict.** The transcript's clock is an offset into
the assembled wav; dicta's is wall clock. Between them sit Acta's startup probe,
watchdog restarts (whose wall-clock gap vanishes when the segments are
concatenated) and any segment recovery dropped. The drift is real, unknown in
advance and grows through the meeting, so the window only narrows the search and
the text decides. Two or more confident matches then *calibrate* the offset —
see ``calibrate`` — which both tightens the remaining searches and reports the
measured drift, a diagnostic Acta has no other source for.

**Three verdicts, deliberately not two.** A candidate lands in exactly one of:

* ``matched`` — its text was found in the mic word stream. Safe to treat as
  dictation: the summary rules in ``references/summary-format.md`` exclude or
  qualify it.
* ``suspected`` — dicta recorded a speech window inside the meeting but has no
  text for it (``aborted``, ``empty``, ``capture-fault``: the audio was
  discarded, the person still spoke). Only the window places it, so it is
  reported for a human to check and is **never** given the exclude treatment.
  Marking real meeting speech as dictation is the harmful error here; failing to
  mark a dictation merely leaves the status quo.
* ``unmatched`` — a candidate in the window whose text was *not* found. This is
  the loud one. It very likely means an unmarked dictation is sitting in the
  transcript, and dropping it silently is the one behaviour both sibling
  projects forbid.

**What of the record is copied into the meeting folder.** ``recognised`` in full
for ``matched`` and ``suspected`` (S7 needs it to mark the lines), but only a
short preview for ``unmatched`` — those are dictations that may have nothing to
do with this meeting, and the folder is not the place to duplicate them.

Reads ``.acta-notes/transcribe.json`` (mic word timings), ``.acta-notes/merge.json``
(the utterances the spans map onto) and ``session.json`` (the wall clock the
transcript's zero corresponds to). Writes ``<meeting>/dicta.json`` and nothing
else: no transcript is touched, here or anywhere downstream of it.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import statistics
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

WORK_DIRNAME = ".acta-notes"
TRANSCRIBE_JSON_NAME = "transcribe.json"
MERGE_JSON_NAME = "merge.json"
SESSION_JSON_NAME = "session.json"
STAGE_JSON_NAME = "dicta.json"

#: D5 again: the leaked dictation can only be on the track that is one known
#: person. A match against the system track would be a match against somebody
#: else's voice and is never looked for.
MIC_TRACK = "mic"

#: dicta's §9 record, in the support directory its `Paths.record` names. Under
#: the current uid at 0600, so this stage reads it as the same user and never
#: needs a helper. ``--record`` overrides it; the tests always do.
DICTA_RECORD_RELPATH = "Library/Application Support/dev.personal.dicta/record.jsonl"

#: Half-width of the search band around a candidate's projected offset, before
#: calibration. This is the drift budget, not a precision claim.
#:
#: It doubles as the candidacy window: an attempt is searched in
#: ``[projected - band, projected + duration + band]``, so one whose projection
#: falls further than a band outside ``[0, audio_seconds]`` has no reachable
#: position in the transcript at all. A separate, larger pad would admit
#: candidates that can only ever come back unmatched — which is the one verdict
#: that is supposed to mean something.
DEFAULT_BAND_SECONDS = 90.0

#: The band once the offset has been measured. Still far wider than the residual
#: error, because the drift is piecewise (a watchdog restart moves it in one
#: step) and a single median cannot follow that.
CALIBRATED_BAND_SECONDS = 25.0

#: F1 over the aligned tokens. Same recogniser on both sides puts a true match
#: well above 0.85; the floor sits low enough to survive a clipped first word
#: and high enough that unrelated speech of the same length does not reach it.
DEFAULT_THRESHOLD = 0.65

#: An anchor is only allowed to move the clock if it is beyond argument.
ANCHOR_THRESHOLD = 0.80

#: Below this many tokens a match is not evidence — short Russian fillers
#: ("да, хорошо") occur constantly in a real meeting and would align with
#: anything. Such an attempt becomes ``suspected``, not ``matched``.
MIN_MATCH_TOKENS = 4

#: A textless attempt shorter than this is a misfire, not speech: the record
#: routinely holds runs of them a second apart (a chord pressed twice). They are
#: dropped from the candidate list rather than reported as suspicion.
MIN_SUSPECT_SECONDS = 1.5

#: An utterance covered less than this by the span is reported as partially
#: covered, so S7 marks the part rather than the whole line.
FULL_COVERAGE_RATIO = 0.6

#: Floor on the uncertainty of a *calibrated* window-only placement. Two anchors
#: that happen to agree exactly report a spread of zero, and reporting zero
#: uncertainty from that would be a precision claim nothing supports: the drift
#: is piecewise, and a restart between the anchors and the span moves it in one
#: step that no median can see.
MIN_CALIBRATED_UNCERTAINTY_SECONDS = 2.0

#: How much of an unmatched attempt's text is copied into the meeting folder.
UNMATCHED_PREVIEW_CHARS = 80

#: Words per second used to guess a speech window when the record predates the
#: window fields. Deliberately slow — a wide window is a wider *search*, and the
#: text still decides.
LEGACY_WORDS_PER_SECOND = 2.2
LEGACY_MIN_SECONDS = 2.0
LEGACY_MAX_SECONDS = 600.0

STATUS_OK = "ok"
STATUS_SKIPPED = "skipped"
STATUS_FAILED = "failed"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

#: The window sources that are dicta's own statement that audio existed. A
#: window merely *estimated* from ``at`` is not evidence of speech, so a textless
#: attempt carrying one is dropped rather than reported as a suspicion — the
#: record holds runs of misfired chords that would otherwise each raise one.
ATTESTED_WINDOW_SOURCES = frozenset({"recorded", "audio_seconds"})


# --- paths -------------------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def transcribe_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / TRANSCRIBE_JSON_NAME


def merge_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / MERGE_JSON_NAME


def session_json_path(meeting_dir) -> Path:
    return Path(meeting_dir) / SESSION_JSON_NAME


def stage_json_path(meeting_dir) -> Path:
    # At the meeting root, beside diarization.json and speakers.json: this is a
    # machine artifact a later stage (verify) and a human (S7) both read, not a
    # working file under the disposable .acta-notes/.
    return Path(meeting_dir) / STAGE_JSON_NAME


def default_record_path() -> Path:
    return Path.home() / DICTA_RECORD_RELPATH


# --- reading -----------------------------------------------------------------


def read_optional_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def parse_timestamp(text):
    """dicta's and Acta's ISO 8601, both of which end in ``Z``.

    Returns an aware UTC datetime, or ``None``. Never raises: a hand-edited line
    in the record must cost its own entry and nothing more.
    """
    if not isinstance(text, str) or not text:
        return None
    candidate = text.strip()
    if candidate.endswith(("z", "Z")):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def read_record(path) -> tuple[list[dict], str | None]:
    """dicta's ``record.jsonl``, one entry per attempt (§9's collapsing rule).

    §9: the file is append-only and an attempt whose delivery went differently
    than the saved line claims gets a **second line with the same id**, the last
    of which wins. Implementing that here rather than shelling out to
    ``dictactl`` is deliberate — ``dictactl last`` goes through dicta's control
    socket and so needs a live daemon, while this stage may run days after the
    meeting.

    A line that does not parse is skipped, for §9's own reason: a torn tail from
    an interrupted write must not hide the hundreds of entries before it.

    **Both readings above assume the file is append-only and whole, and that is
    a premise, not a formality.** Rotating or truncating ``record.jsonl`` breaks
    this reader in two ways, and the quieter one is the worse. The loud failure
    is that meetings older than the surviving window stop correlating — and they
    stop by reporting "no candidates", which is indistinguishable from "no
    dictation happened", so the stage would lie green. The quiet failure is
    worse: a superseding line and the line it supersedes could land in different
    files, and the collapse below would then return the **superseded** entry —
    the wrong outcome for that attempt, silently. dicta owns that invariant for
    its own reasons and does not rotate (checked: nothing in its record layer
    rotates, truncates or prunes); this comment exists so that a second reader
    depends on it out loud, because an invariant with one named dependent is one
    that gets dropped when that dependent's reason expires.
    """
    path = Path(path)
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return [], str(exc)

    order: list = []
    latest: dict = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        key = entry.get("id")
        if key is None:
            continue
        if key not in latest:
            order.append(key)
        latest[key] = entry
    return [latest[key] for key in order], None


def mic_words(transcribe_report) -> list[dict]:
    """S3's word timings for the mic track, sorted, with the broken ones dropped.

    Same defensive shape as ``merge.words_for_track``, and for the same reason:
    an interval that ends before it starts is not a short interval, it is a
    broken one, and it would poison every overlap computed from it.
    """
    if not isinstance(transcribe_report, dict):
        return []
    out = []
    for entry in transcribe_report.get("tracks") or []:
        if not isinstance(entry, dict) or entry.get("track") != MIC_TRACK:
            continue
        for word in entry.get("words") or []:
            if not isinstance(word, dict):
                continue
            text = word.get("word")
            start, end = word.get("start"), word.get("end")
            if not text or not isinstance(start, (int, float)):
                continue
            if not isinstance(end, (int, float)) or end <= start:
                continue
            out.append({"word": str(text), "start": float(start), "end": float(end)})
    out.sort(key=lambda w: (w["start"], w["end"]))
    return out


def mic_utterances(merge_report) -> list[dict]:
    """S5's mic rows, carrying the index they hold in ``merge.json``.

    The index travels because it is the only stable handle on a line: two
    utterances of the same text at the same second are not distinguishable by
    value, and S7 has to mark one specific line.
    """
    if not isinstance(merge_report, dict):
        return []
    out = []
    for index, row in enumerate(merge_report.get("utterances") or []):
        if not isinstance(row, dict) or row.get("track") != MIC_TRACK:
            continue
        start, end = row.get("start"), row.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            continue
        out.append(
            {
                "index": index,
                "start": float(start),
                "end": float(end),
                "text": str(row.get("text") or ""),
                "word_count": int(row.get("word_count") or 0),
            }
        )
    return out


# --- normalization -----------------------------------------------------------

_PUNCTUATION = re.compile(r"[^\w\s]", flags=re.UNICODE)


def normalize(text: str) -> str:
    """Casefold, strip punctuation, fold ``ё`` onto ``е``.

    The two recognisers agree on the words and disagree on exactly these three
    things — a trailing full stop, a capital after a pause, and ё, which
    Parakeet emits inconsistently between a 10-second buffer and a 30-minute
    one. Folding them is what makes the comparison a comparison of speech.
    """
    folded = unicodedata.normalize("NFC", text).casefold().replace("ё", "е")
    return _PUNCTUATION.sub(" ", folded)


def tokenize(text: str) -> list[str]:
    return normalize(text).split()


# --- the meeting clock -------------------------------------------------------


def meeting_start(meeting_dir):
    """The wall clock that transcript offset 0 stands for, per ``session.json``.

    ``info.md`` carries the same instant, but ``session.json`` is the marker the
    recorder itself writes and updates, so it is the one to trust.
    """
    manifest = read_optional_json(session_json_path(meeting_dir))
    if not isinstance(manifest, dict):
        return None
    return parse_timestamp(manifest.get("started_at"))


def audio_seconds(words, utterances) -> float:
    """How long the transcript's own clock runs.

    Taken from the last word rather than ``info.md``'s duration: the question
    here is where the *transcript* ends, and a track that stopped early would
    otherwise open a search window over audio that does not exist.
    """
    ends = [w["end"] for w in words] + [u["end"] for u in utterances]
    return max(ends) if ends else 0.0


# --- candidates --------------------------------------------------------------


def speech_window(entry) -> tuple[object, object, str]:
    """One attempt's wall-clock speech window, and how it was arrived at.

    Three sources, in descending order of trust:

    * ``speechStartedAt`` / ``speechEndedAt`` — dicta's own capture boundaries.
    * ``audioSeconds`` back from ``at`` — ``at`` is written after recognition and
      before injection (§9, invariant 10), so it trails the end of speech by the
      decode, which is ~1 % of the utterance at Parakeet's RTF. Close enough to
      be a window; not close enough to be an anchor on its own.
    * the word count of ``recognised`` — for entries written before the window
      fields existed. Wide, and honest about being wide.

    Two things about the recorded pair that are not visible in the field names,
    both confirmed by dicta's author:

    **``speechEndedAt`` does not mean the same thing on both shapes.** On a
    *drained* attempt it is capture handing the buffer over, and ``audioSeconds``
    is that buffer's own length — the honest pair. On an attempt ended while
    collecting (``aborted``, ``capture-fault``, ``capped``) the buffer is
    discarded *after* the record line is written, so the end is resolved from the
    writer's own clock and is late by however long the discard takes. Microseconds
    today, and late rather than early — which is the direction to remember if
    ``MIN_SUSPECT_SECONDS`` is ever tightened, because it makes the window
    marginally too generous rather than too tight.

    **The discriminator between the two shapes is ``audioSeconds``, present or
    absent — never ``at != speechEndedAt``.** On the second shape those two are
    identical to the microsecond (both come from the same ``clock.now``), so the
    comparison appears to work and would be reading an implementation detail as
    a guarantee. Nothing here needs to tell the shapes apart, and nothing added
    later should tell them apart that way.
    """
    started = parse_timestamp(entry.get("speechStartedAt"))
    ended = parse_timestamp(entry.get("speechEndedAt"))
    if started and ended and ended >= started:
        return started, ended, "recorded"

    at = parse_timestamp(entry.get("at"))
    if at is None:
        return None, None, "none"

    duration = entry.get("audioSeconds")
    if isinstance(duration, (int, float)) and duration > 0:
        source = "audio_seconds"
    else:
        words = len(tokenize(str(entry.get("recognised") or "")))
        duration = words / LEGACY_WORDS_PER_SECOND if words else LEGACY_MIN_SECONDS
        source = "estimated"
    duration = max(LEGACY_MIN_SECONDS, min(LEGACY_MAX_SECONDS, float(duration)))
    return at - _seconds(duration), at, source


def _seconds(value) -> timedelta:
    return timedelta(seconds=float(value))


def candidates(entries, start, span_seconds, pad=DEFAULT_BAND_SECONDS) -> list[dict]:
    """The attempts whose speech window intersects the meeting, in time order."""
    if start is None:
        return []
    window_from = start - _seconds(pad)
    window_to = start + _seconds(span_seconds + pad)

    out = []
    for entry in entries:
        began, ended, source = speech_window(entry)
        if began is None or ended is None:
            continue
        if ended < window_from or began > window_to:
            continue
        out.append(
            {
                "attempt_id": entry.get("id"),
                "outcome": str(entry.get("outcome") or ""),
                "mode": str(entry.get("mode") or ""),
                "recognised": str(entry.get("recognised") or ""),
                "final": str(entry.get("final") or ""),
                "target": entry.get("target") if isinstance(entry.get("target"), dict) else None,
                "error": entry.get("error"),
                "speech_started_at": began,
                "speech_ended_at": ended,
                "speech_seconds": round((ended - began).total_seconds(), 3),
                "window_source": source,
                # Offset the span would sit at if the two clocks agreed. The
                # search band is drawn around this, not the other way round.
                "projected_start": round((began - start).total_seconds(), 3),
            }
        )
    out.sort(key=lambda c: c["projected_start"])
    return out


# --- alignment ---------------------------------------------------------------


def align(needle_tokens, words, low, high):
    """Best contiguous run of mic words carrying ``needle_tokens``, within a band.

    ``low``/``high`` bound the mic words considered, in transcript seconds. The
    band is what keeps this cheap and — more importantly — what keeps a phrase
    the user happens to repeat an hour later from matching.

    Returns ``None`` or a dict with the span, the score and the word indices.
    ``autojunk`` is off: difflib's heuristic treats a token appearing in more
    than 1 % of a 200+ element sequence as junk, which in Russian speech is
    exactly ``и``, ``в``, ``не``, ``что`` — the tokens that carry the alignment.
    """
    if not needle_tokens:
        return None

    indices, haystack = [], []
    for index, word in enumerate(words):
        if not low <= word["start"] <= high:
            continue
        # A "word" that normalizes to nothing (bare punctuation) would occupy a
        # position in the sequence that no dictated token can ever fill, so it
        # would depress precision on an otherwise perfect match.
        token = normalize(word["word"]).strip()
        if not token:
            continue
        indices.append(index)
        haystack.append(token)
    if not indices:
        return None

    matcher = difflib.SequenceMatcher(None, needle_tokens, haystack, autojunk=False)
    blocks = [b for b in matcher.get_matching_blocks() if b.size > 0]
    if not blocks:
        return None

    matched = sum(b.size for b in blocks)
    first, last = blocks[0], blocks[-1]
    span_from, span_to = first.b, last.b + last.size  # half-open, into `indices`
    span_len = span_to - span_from
    if span_len <= 0:
        return None

    recall = matched / len(needle_tokens)
    precision = matched / span_len
    score = (
        0.0 if recall + precision == 0 else 2 * recall * precision / (recall + precision)
    )

    word_indices = indices[span_from:span_to]
    return {
        "score": round(score, 4),
        "recall": round(recall, 4),
        "precision": round(precision, 4),
        "matched_tokens": matched,
        "span_tokens": span_len,
        "start": round(words[word_indices[0]]["start"], 3),
        "end": round(max(words[i]["end"] for i in word_indices), 3),
        "word_indices": word_indices,
    }


def search(candidate, words, offset, band):
    """Best alignment for one candidate, with the band drawn around its position.

    No threshold is applied here, deliberately: the caller decides what score is
    good enough, and the two callers want different answers — ``calibrate`` only
    trusts an anchor beyond argument, while the main pass reports the best score
    it found even when it rejects it.
    """
    tokens = tokenize(candidate["recognised"])
    if len(tokens) < MIN_MATCH_TOKENS:
        return None
    low = candidate["projected_start"] + offset - band
    high = candidate["projected_start"] + offset + candidate["speech_seconds"] + band
    return align(tokens, words, low, high)


def calibrate(candidates_, words, band, threshold=ANCHOR_THRESHOLD):
    """Measure the offset between wall clock and transcript clock.

    Only beyond-argument matches vote. The median rather than the mean because a
    single watchdog restart mid-meeting splits the anchors into two groups and
    the mean would land between them, fitting neither; the spread is reported so
    that case is visible rather than averaged away.
    """
    deltas = []
    for candidate in candidates_:
        found = search(candidate, words, 0.0, band)
        if found is None or found["score"] < threshold:
            continue
        deltas.append(found["start"] - candidate["projected_start"])

    if len(deltas) < 2:
        return {
            "calibrated": False,
            "offset_seconds": 0.0,
            "anchors": len(deltas),
            "spread_seconds": None,
        }
    return {
        "calibrated": True,
        "offset_seconds": round(statistics.median(deltas), 3),
        "anchors": len(deltas),
        "spread_seconds": round(max(deltas) - min(deltas), 3),
    }


# --- mapping onto the transcript ---------------------------------------------


def covered_utterances(span_start, span_end, utterances) -> list[dict]:
    """The mic lines a span touches, each with how much of it the span covers."""
    out = []
    for utterance in utterances:
        overlap = min(span_end, utterance["end"]) - max(span_start, utterance["start"])
        if overlap <= 0:
            continue
        duration = utterance["end"] - utterance["start"]
        ratio = 1.0 if duration <= 0 else min(1.0, overlap / duration)
        out.append(
            {
                "index": utterance["index"],
                "start": utterance["start"],
                "end": utterance["end"],
                "timecode": hms(utterance["start"]),
                "text": utterance["text"],
                "word_count": utterance["word_count"],
                "coverage": round(ratio, 3),
                # A line the span only clips is a line S7 marks in part. Saying
                # so here is what stops a whole turn of real meeting speech being
                # excluded because a dictation ended inside it.
                "partial": ratio < FULL_COVERAGE_RATIO,
            }
        )
    return out


def hms(seconds) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def iso(moment) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _identity(candidate: dict) -> dict:
    """The fields every verdict carries, whatever became of the candidate."""
    return {
        "attempt_id": candidate["attempt_id"],
        "outcome": candidate["outcome"],
        "mode": candidate["mode"],
        "speech_started_at": iso(candidate["speech_started_at"]),
        "speech_ended_at": iso(candidate["speech_ended_at"]),
        "speech_seconds": candidate["speech_seconds"],
        "window_source": candidate["window_source"],
        "projected_start": candidate["projected_start"],
        # Which agterm session and pane the text was aimed at. Not decoration:
        # it is the record's own statement that this speech was addressed to a
        # terminal rather than to the people in the meeting.
        "target": candidate["target"],
        # §9's `error`, verbatim and unparsed. It is the accumulated notes of
        # the attempt joined with "; " — a cancel reason, and possibly a
        # dictionary or filter note from an earlier stage, and possibly a
        # complaint that the words could not be recognised.
        #
        # **Deliberately not parsed.** That last one would let a suspicion over
        # a measured-but-textless buffer be downgraded — "a recogniser looked
        # and heard nothing" is much weaker evidence of a leak than "nobody
        # looked". But the field is human-readable by §9 and its contents
        # accumulate, so any rule that reads it is a rule that breaks quietly
        # when a message is reworded — and breaking quietly in the reassuring
        # direction means under-warning about a real leak. The words are worth
        # far more to the person reading quality.md than the downgrade is worth
        # to this report, so they are passed through and nothing here decides on
        # them. If the noise ever justifies the downgrade, the fix is to ask
        # dicta for a structured signal, not to parse this harder.
        "error": candidate["error"],
    }


# --- the stage ---------------------------------------------------------------


def run(
    meeting_dir,
    record=None,
    *,
    band=DEFAULT_BAND_SECONDS,
    threshold=DEFAULT_THRESHOLD,
    clock=time.monotonic,
) -> dict:
    """Correlate one meeting against dicta's record; returns the stage report."""
    meeting_dir = Path(meeting_dir)
    record_path = Path(record) if record else default_record_path()
    report = {
        "stage": "dicta_overlay",
        "meeting_dir": str(meeting_dir),
        "record": str(record_path),
        "band_seconds": band,
        "threshold": threshold,
        "elapsed_seconds": 0.0,
    }
    started = clock()

    def finish(status: str, detail: str) -> dict:
        report["status"] = status
        report["detail"] = detail
        report["elapsed_seconds"] = round(clock() - started, 3)
        return report

    if not record_path.is_file():
        # dicta is not installed, or has never run. Not a failure of this
        # meeting: there is simply nothing that could have leaked.
        return finish(
            STATUS_SKIPPED, f"no dicta record at {record_path} — nothing to correlate"
        )

    transcribe_report = read_optional_json(transcribe_json_path(meeting_dir))
    words = mic_words(transcribe_report)
    if not words:
        # Two different meetings land here and the reader deserves to know which.
        #
        # No S3 report at all is either an unprocessed folder or Path B — an
        # official Teams transcript, whose own timestamps run on Teams' clock
        # rather than Acta's, so a time-only match would be an alignment against
        # a clock this stage cannot see. Both are "come back when S3 has run",
        # and neither is worth guessing between.
        #
        # An S3 report with no mic words is a recording whose mic track was
        # absent or silent. Nothing was captured from the microphone, so by
        # construction nothing could have leaked through it.
        detail = (
            f"no {TRANSCRIBE_JSON_NAME} — S3 has not run here, or this folder "
            "holds an official transcript, whose timestamps run on its own clock "
            "rather than Acta's; either way there is nothing to align against"
            if transcribe_report is None
            else "no mic words in "
            f"{transcribe_json_path(meeting_dir)} — this recording has no mic "
            "track, or S2 found it silent, so nothing could have leaked through it"
        )
        return finish(STATUS_SKIPPED, detail)

    utterances = mic_utterances(read_optional_json(merge_json_path(meeting_dir)))
    start = meeting_start(meeting_dir)
    if start is None:
        return finish(
            STATUS_FAILED,
            f"no usable started_at in {session_json_path(meeting_dir)} — the "
            "transcript's clock cannot be placed on the wall clock",
        )

    span = audio_seconds(words, utterances)
    entries, read_error = read_record(record_path)
    if read_error:
        return finish(STATUS_FAILED, f"cannot read {record_path}: {read_error}")

    report["meeting_started_at"] = iso(start)
    report["audio_seconds"] = round(span, 3)
    report["record_entries"] = len(entries)
    report["mic_word_count"] = len(words)

    found = candidates(entries, start, span, pad=band)
    report["candidate_count"] = len(found)

    calibration = calibrate(found, words, band)
    report["calibration"] = calibration
    offset = calibration["offset_seconds"]
    search_band = CALIBRATED_BAND_SECONDS if calibration["calibrated"] else band
    report["search_band_seconds"] = search_band

    # How far a *window-only* placement may be out. A matched span does not need
    # this — its position comes from the text it was found at — but a suspicion
    # is placed by arithmetic on two clocks, and it is only as good as what
    # measured the difference between them. With no anchors that is the whole
    # drift budget, and saying so is the difference between "check these lines"
    # and "check somewhere in this minute and a half".
    uncertainty = (
        max(calibration["spread_seconds"], MIN_CALIBRATED_UNCERTAINTY_SECONDS)
        if calibration["calibrated"]
        else band
    )
    report["placement_uncertainty_seconds"] = round(uncertainty, 3)

    matched, suspected, unmatched = [], [], []
    for candidate in found:
        tokens = tokenize(candidate["recognised"])
        row = _identity(candidate)

        if len(tokens) >= MIN_MATCH_TOKENS:
            hit = search(candidate, words, offset, search_band)
            if hit is not None and hit["score"] >= threshold:
                row.update(
                    {
                        "recognised": candidate["recognised"],
                        "final": candidate["final"],
                        "transcript_start": hit["start"],
                        "transcript_end": hit["end"],
                        "timecode": hms(hit["start"]),
                        "score": hit["score"],
                        "recall": hit["recall"],
                        "precision": hit["precision"],
                        "matched_words": hit["matched_tokens"],
                        "utterances": covered_utterances(
                            hit["start"], hit["end"], utterances
                        ),
                    }
                )
                matched.append(row)
                continue
            row["best_score"] = hit["score"] if hit else 0.0
            row["reason"] = (
                f"best alignment scored {row['best_score']:.2f}, below {threshold:.2f}"
            )
            row["preview"] = candidate["recognised"][:UNMATCHED_PREVIEW_CHARS]
            unmatched.append(row)
            continue

        # No usable text: either the attempt produced none (the audio was
        # discarded by D16 — but the person still spoke into the microphone Acta
        # was recording), or what it produced is too short to be evidence.
        #
        # Two filters, and both are about not crying wolf. dicta must itself
        # attest that audio existed — an ``at``-derived window is arithmetic, not
        # a measurement — and the speech must be long enough to be speech.
        if candidate["window_source"] not in ATTESTED_WINDOW_SOURCES:
            continue
        if candidate["speech_seconds"] < MIN_SUSPECT_SECONDS:
            continue
        row.update(
            {
                "recognised": candidate["recognised"],
                # Clamped at zero: a window that projects before the audio
                # starts is a drift artifact, and a negative timecode renders as
                # nonsense in quality.md.
                "transcript_start": round(max(0.0, candidate["projected_start"] + offset), 3),
                "transcript_end": round(
                    max(0.0, candidate["projected_start"] + offset)
                    + candidate["speech_seconds"],
                    3,
                ),
                "timecode": hms(max(0.0, candidate["projected_start"] + offset)),
                # Two different attempts land here and they are not equally
                # opaque. One produced nothing at all; the other produced a
                # handful of words that are too few to align on ("да, хорошо"
                # matches anywhere in a real meeting). Reporting both as "no
                # text" hides the words in the second case — and those words are
                # the fastest way for a reader to judge whether the suspicion is
                # worth acting on at all.
                "reason": (
                    f"only {len(tokens)} word(s) recognised, fewer than the "
                    f"{MIN_MATCH_TOKENS} an alignment needs — placed by its "
                    "speech window alone"
                    if tokens
                    else "no text on this attempt — placed by its speech window alone"
                ),
                "text_words": len(tokens),
                "calibrated": calibration["calibrated"],
                "placement": (
                    "calibrated" if calibration["calibrated"] else "uncalibrated"
                ),
                "uncertainty_seconds": round(uncertainty, 3),
            }
        )
        # A window that projects clear of the audio names no line in the
        # transcript, so there is nothing for a reader to check. The pad let it
        # be a candidate; only an intersection makes it a suspicion.
        if row["transcript_start"] >= span or row["transcript_end"] <= 0:
            continue
        # Two readings, and the difference between them is the honest part.
        # ``utterances`` is the best guess — the lines the nominal window lands
        # on. ``lines_within_uncertainty`` is how many lines the placement error
        # could reach instead, and when that number is large the best guess is
        # not one: a reader told "these two lines" would go and mark them.
        row["utterances"] = covered_utterances(
            row["transcript_start"], row["transcript_end"], utterances
        )
        row["lines_within_uncertainty"] = len(
            covered_utterances(
                row["transcript_start"] - uncertainty,
                row["transcript_end"] + uncertainty,
                utterances,
            )
        )
        suspected.append(row)

    report["matched"] = matched
    report["suspected"] = suspected
    report["unmatched"] = unmatched
    report["counts"] = {
        "candidates": len(found),
        "matched": len(matched),
        "suspected": len(suspected),
        "unmatched": len(unmatched),
    }
    report["marked_words"] = sum(row["matched_words"] for row in matched)
    report["marked_share"] = (
        round(report["marked_words"] / len(words), 4) if words else None
    )

    detail = (
        f"{len(matched)} dictation span(s) matched, {len(suspected)} suspected, "
        f"{len(unmatched)} unmatched of {len(found)} candidate(s)"
    )
    return finish(STATUS_OK, detail)


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = stage_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def render_human(report: dict) -> str:
    lines = [f"acta-notes dicta_overlay — {report['status'].upper()}"]
    calibration = report.get("calibration")
    if calibration:
        if calibration["calibrated"]:
            lines.append(
                f"  clock offset {calibration['offset_seconds']:+.1f}s from "
                f"{calibration['anchors']} anchor(s), spread "
                f"{calibration['spread_seconds']:.1f}s"
            )
        else:
            lines.append(
                f"  clock not calibrated ({calibration['anchors']} anchor(s)) — "
                f"searching the full ±{report.get('search_band_seconds')}s band"
            )
    for row in report.get("matched") or []:
        lines.append(
            f"  [{row['timecode']}] dicta #{row['attempt_id']} "
            f"score {row['score']:.2f}  «{row['recognised'][:60]}»"
        )
    for row in report.get("suspected") or []:
        heard = (
            f"«{row['recognised'][:40]}»" if row.get("recognised") else "no text"
        )
        lines.append(
            f"  [{row['timecode']}] dicta #{row['attempt_id']} suspected "
            f"({row['outcome']}, {row['speech_seconds']:.1f}s, {heard}) "
            f"±{row['uncertainty_seconds']:.0f}s, "
            f"{row['lines_within_uncertainty']} line(s) in range"
        )
    for row in report.get("unmatched") or []:
        lines.append(
            f"  dicta #{row['attempt_id']} UNMATCHED — {row['reason']} "
            f"«{row.get('preview', '')}»"
        )
    lines.append("")
    lines.append(report.get("detail", "dicta_overlay failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] in (STATUS_OK, STATUS_SKIPPED):
        return EXIT_OK
    return EXIT_FAILED


def main(argv=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="dicta_overlay.py",
        description=(
            "S6.5: find the voice dictation that leaked from dicta into this "
            "meeting's mic track, and write dicta.json naming the spans."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--record",
        metavar="PATH",
        help=f"dicta's record.jsonl (default: ~/{DICTA_RECORD_RELPATH})",
    )
    parser.add_argument(
        "--band-seconds",
        type=float,
        default=DEFAULT_BAND_SECONDS,
        metavar="S",
        help=(
            "half-width of the search band around a candidate's projected "
            "position, before calibration; also how far outside the recording "
            f"an attempt may fall and still be a candidate (default: "
            f"{DEFAULT_BAND_SECONDS:g})"
        ),
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        metavar="F",
        help=f"F1 an alignment must reach to be a match (default: {DEFAULT_THRESHOLD})",
    )
    parser.add_argument("--json", action="store_true", help="print the stage JSON")
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    report = run(
        meeting_dir,
        record=args.record,
        band=args.band_seconds,
        threshold=args.threshold,
        clock=clock,
    )
    write_stage_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
