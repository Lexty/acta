#!/usr/bin/env python3
"""acta-notes — official Microsoft Teams transcript → ``transcript.raw.md``.

**This script REPLACES stages S1–S5; it is never a stage inside them.** When an
official Teams transcript exists it is strictly better than local ASR (real
speaker names, no decoder hallucinations), so no audio is preprocessed, gated,
transcribed or diarized at all: this converter writes ``transcript.raw.md``
directly and the operator resumes with ``pipeline.py --from-stage speakers``.
``pipeline.py`` never invokes this script, and this script never invokes a stage.

    <source>.json | <source>.vtt   →   <meeting>/transcript.raw.md
                                       <meeting>/.acta-notes/teams_vtt.json

The source is either the file the M365 MCP ``read_resource(meetingTranscriptUrl)``
saved — JSON with ``transcripts[].content`` = WEBVTT and ``createdDateTime`` as
the UTC anchor for cue ``t=0`` — or a bare ``.vtt`` exported by hand. Cue times
are offsets from the transcript's start, which is what the line shape wants.

**Same overwrite protection as ``merge.py``, deliberately identical.** The two
are alternative producers of the same file, so a second run against a meeting
that already has a ``transcript.raw.md`` exits ``2`` with the very same message
and changes nothing; ``--force`` is the opt-out. Neither producer may silently
clobber the other's output.

**No ASR, no diarization, and no stage JSON pretending otherwise.** ``verify.py``
decides the transcript's provenance by looking for a *transcribe* stage JSON, so
this path deliberately leaves none — that absence is what makes ``quality.md``
say "официальный транскрипт Teams" and mark the ASR/diarization fields ``n/a``.

**A conversion over a local-ASR meeting supersedes that run's stage JSONs.**
``--force`` here replaces a ``transcript.raw.md`` that ``merge.py`` may have
written, and the S1–S5 stage JSONs left beside it describe a transcript that no
longer exists. Left in place they are not merely stale, they are *read*: verify
would call the source local ASR, print that run's denoise chain and ASR model,
score its per-word confidence against the Teams text and put its diarization
coverage through a hard gate. So a conversion moves them into
``.acta-notes/superseded/`` — archived, not deleted — and the two halves land
together or not at all: the new text is rendered to a sibling file, the archive
runs, and only a clean archive puts the text in place. An archive that fails
leaves the folder exactly as it was and exits non-zero, because "Teams
transcript, local-ASR stage JSON" is precisely the state verify misreads. Only a
conversion that lands writes ``teams_vtt.json``: a refusal or a failure leaves
the one on disk alone, since its cue counts and speakers describe the
``transcript.raw.md`` that is actually there. The
S6+ artifacts (``speakers.json``, ``transcript.labeled.md``, ``verify.json``) are
left for the ``--from-stage speakers`` resume to rewrite, which it does because
they are now older than the transcript.

Stdlib only — no binary to resolve, no model, no network.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import re
import sys
import time
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: Consecutive cues from one speaker are joined into a paragraph until the gap
#: to the next cue reaches this. The Air skill's value, kept: it is what makes
#: timestamps stay navigable instead of one wall of text per speaker turn.
MERGE_GAP_SECONDS = 35.0

#: How close two cues must be for ``dedup`` to treat the later one as a rolling
#: re-send of the earlier rather than something the speaker genuinely said again.
#: Rolling captions are re-emitted within a fraction of a second; without this
#: bound the identical-text rule folded a "Понятно." at 00:05 into one at 00:20
#: and silently lost an utterance from a file whose header promises verbatim.
DEDUP_WINDOW_SECONDS = 2.0

#: The machine runs WEST (+0100); ``--shots`` capture times are local, cue
#: offsets are UTC-anchored. A flag rather than a constant because the salvaged
#: value is a fact about one machine in one season, not about Teams.
LOCAL_UTC_OFFSET_HOURS = 1.0

#: A shot is grabbed ~30–60 s AFTER its slide appears, so the discussion that
#: explains it *precedes* the capture — hence an asymmetric window.
SHOT_WINDOW_BEFORE = 95.0
SHOT_WINDOW_AFTER = 20.0

#: The label a cue with no ``<v Speaker>`` tag gets. Not ``SPK_NN``: nothing was
#: diarized here, and inventing a diarization label would make `speakers.py`
#: treat an unattributed line as a nameable speaker.
UNKNOWN_SPEAKER = "—"

WORK_DIRNAME = ".acta-notes"
STAGE_JSON_NAME = "teams_vtt.json"
#: The shared output — see the module docstring's overwrite note.
RAW_TRANSCRIPT_NAME = "transcript.raw.md"
LABELED_TRANSCRIPT_NAME = "transcript.labeled.md"

#: Where a superseded local-ASR run's stage JSONs are archived. Under
#: ``.acta-notes/`` so the meeting folder itself stays the three transcripts plus
#: ``speakers.json``/``diarization.json``, exactly as SKILL.md describes it.
SUPERSEDED_DIRNAME = "superseded"
#: The S1–S5 stage JSONs that describe the transcript this converter replaces —
#: the same files ``verify.load_inputs`` reads, minus the S6 artifacts the
#: ``--from-stage speakers`` resume rewrites on its own. Under ``.acta-notes/``:
SUPERSEDED_WORK_ARTIFACTS = (
    "prep_audio.json",
    "gate.json",
    "transcribe.json",
    "merge.json",
)
#: …and at the meeting root, where ``diarize.py`` writes it.
SUPERSEDED_ROOT_ARTIFACTS = ("diarization.json",)

STATUS_OK = "ok"
STATUS_FAILED = "failed"
STATUS_REFUSED = "refused"

EXIT_OK = 0
EXIT_FAILED = 1
#: A caller error — an existing raw transcript, or a source this stage will not
#: invent its way around.
EXIT_USAGE = 2

#: WebVTT makes the hours field optional (``MM:SS.TTT``), and hand-exported
#: ``.vtt`` files — the path this converter advertises — routinely use it. The
#: hours group has to be optional or every such cue is skipped silently, with no
#: dropped count to notice it by.
#: Minutes and seconds are range-bounded, not merely two digits: an unbounded
#: ``\d{2}`` let ``00:99:99.000`` through and ``to_seconds`` turned it into a
#: confident 1 h 40 m — a fabricated timecode on a real transcript line, where
#: ``parse_shots`` range-checks the same fields and refuses. A stamp outside the
#: grammar now fails to match, so the block is not a cue at all and is counted by
#: ``count_unparsed_timing_blocks`` instead of quietly reinterpreted.
_TIMESTAMP = r"(?:\d{1,2}:)?[0-5]?\d:[0-5]\d[.,]\d{1,3}"

#: A cue's timing line, matched against **one line of one block** — never
#: scanned across the document. Anchoring matters: a ``NOTE`` comment may
#: legally quote a timestamp arrow, and an unanchored scan matched that quote as
#: a cue whose body then ran to the next blank line, swallowing the real cue
#: that followed it. The result was a transcript with a comment's timecodes and
#: no error to notice it by.
CUE_TIMING_RE = re.compile(rf"({_TIMESTAMP})\s*-->\s*({_TIMESTAMP})[^\n]*")
#: WebVTT blocks are blank-line delimited (whitespace-only counts as blank).
BLOCK_SPLIT_RE = re.compile(r"\r?\n[ \t]*\r?\n")
#: Blocks that are never cues, however much their contents look like one.
NON_CUE_BLOCK_RE = re.compile(r"(?:WEBVTT|NOTE|STYLE|REGION)\b")
#: A comment block specifically. Its body is free text, so — unlike the other
#: three — nothing inside it may be salvaged as a cue. See
#: ``strip_non_cue_prelude`` for why that asymmetry is deliberate.
COMMENT_BLOCK_RE = re.compile(r"NOTE\b")

#: A voice-span *opener*. Spans are cut at the next opener rather than run to a
#: ``</v>``, because Teams does not always close one: letting a span run to
#: ``</v>|\Z`` merged ``<v A>da<v B>soglasna`` into a single ``A`` saying
#: "dasoglasna" — the same silently-dropped-second-voice bug ``finditer`` was
#: meant to fix, one level down.
VOICE_OPEN_RE = re.compile(r"<v\s+([^>]*)>", re.I)
TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"\s+")


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / RAW_TRANSCRIPT_NAME


def stage_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / STAGE_JSON_NAME


def superseded_dir(meeting_dir) -> Path:
    return work_dir(meeting_dir) / SUPERSEDED_DIRNAME


def superseded_candidates(meeting_dir) -> list[Path]:
    """Every S1–S5 artifact a conversion would leave describing the wrong text."""
    meeting_dir = Path(meeting_dir)
    return [work_dir(meeting_dir) / name for name in SUPERSEDED_WORK_ARTIFACTS] + [
        meeting_dir / name for name in SUPERSEDED_ROOT_ARTIFACTS
    ]


def supersede_local_asr(meeting_dir) -> tuple[list[str], list[str]]:
    """Archive the replaced local-ASR run's stage JSONs; returns (moved, failed).

    Called with the new transcript rendered but not yet in place, and a no-op on
    the ordinary Teams-only meeting where none of these files exists. Moved
    rather than deleted: the numbers cost real minutes of ASR and may still be
    worth reading, they just must not be read as provenance for *this* transcript.

    A move that fails is reported, never swallowed, and ``run`` turns that report
    into a failed conversion with nothing written — a stale ``transcribe.json``
    left beside a Teams transcript is exactly the wrong-provenance bug this
    exists to prevent, so it must not be reachable from a green exit.
    """
    moved: list[Path] = []
    failed: list[str] = []
    destination = superseded_dir(meeting_dir)
    for path in superseded_candidates(meeting_dir):
        if not path.is_file():
            continue
        try:
            destination.mkdir(parents=True, exist_ok=True)
            # replace(), not rename(): a second conversion of the same meeting
            # must overwrite the earlier archive instead of dying on it.
            path.replace(destination / path.name)
        except OSError as exc:
            failed.append(f"{path}: {exc}")
            break  # the caller aborts anyway; do not half-archive further
        moved.append(path)

    if failed:
        # All or nothing, and rolled back rather than left half-done:
        # ``verify.detect_source`` keys provenance on ``transcribe.json`` alone,
        # so archiving it and then failing on ``diarization.json`` would leave the
        # *previous* transcript on disk being described as an official Teams one —
        # the same wrong-provenance bug from the other side.
        for path in moved:
            try:
                (destination / path.name).replace(path)
            except OSError as exc:  # pragma: no cover - the move just succeeded
                failed.append(f"{destination / path.name} -> {path}: {exc}")
        return [], failed

    return [path.name for path in moved], failed


def overwrite_refusal(path) -> str:
    """The one refusal message both producers of ``transcript.raw.md`` use.

    Byte-identical to ``merge.py``'s — the two are alternatives writing the same
    file, so a user who hits the guard must see the same thing whichever path
    they took. ``test_teams_vtt_to_transcript.py`` asserts the two strings are
    equal, so this copy cannot drift.
    """
    return (
        f"{path} already exists — it is the verbatim forensic artifact every "
        "later stage is a view over, so this stage refuses to overwrite it. "
        "Pass --force to replace it deliberately."
    )


# --- source loading ----------------------------------------------------------


class SourceError(Exception):
    """The source is absent or holds no usable WEBVTT. Never worked around."""


def read_source(path) -> dict:
    """Resolve the source into ``{content, created, transcript_count, kind}``.

    Two shapes are accepted because two things produce them: the M365 MCP saves
    a JSON envelope, and a hand export is bare WEBVTT. The envelope is preferred
    when present — it is the only one carrying ``createdDateTime``, the UTC
    anchor ``--shots`` alignment needs.
    """
    path = Path(path)
    if not path.is_file():
        raise SourceError(f"no Teams transcript source at {path}")
    try:
        # utf-8-sig, not utf-8: a BOM on the M365 envelope made json.loads raise,
        # the generic ValueError below swallowed it, and the JSON was then read as
        # raw WEBVTT — reported to the operator as "holds no WEBVTT cues", which
        # points at a nonexistent transcript problem and loses the
        # createdDateTime anchor --shots needs.
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise SourceError(f"cannot read {path}: {exc}") from exc

    try:
        data = json.loads(text)
    except ValueError:
        data = None

    if isinstance(data, dict):
        transcripts = data.get("transcripts")
        if not isinstance(transcripts, list) or not transcripts:
            raise SourceError(
                f"{path} is JSON but carries no transcripts[] — is it the file "
                "read_resource(meetingTranscriptUrl) saved?"
            )
        first = transcripts[0]
        if not isinstance(first, dict) or not first.get("content"):
            raise SourceError(f"{path}: transcripts[0] carries no content")
        return {
            "kind": "m365-json",
            "content": str(first["content"]),
            "created": first.get("createdDateTime"),
            "transcript_count": len(transcripts),
        }

    return {
        "kind": "webvtt",
        "content": text,
        "created": None,
        "transcript_count": 1,
    }


def parse_anchor(created):
    """``createdDateTime`` → an aware datetime, or ``None`` when unparseable.

    Graph stamps carry more than six sub-second digits, which ``fromisoformat``
    rejects; trimming them is the whole reason this is not a one-liner. A failure
    is not fatal — the anchor is only used by ``--shots``.

    The result is always *aware*: a stamp without a timezone designator parses
    fine but yields a naive datetime, and ``render_shot_alignment`` subtracts it
    from an aware one — a bare ``TypeError`` traceback *after* the conversion has
    already written ``transcript.raw.md``, the same failure shape ``parse_shots``
    range-checks to avoid. Graph always stamps UTC, so assuming UTC when the
    designator is missing is the reading that matches the field's contract.
    """
    if not created:
        return None
    trimmed = re.sub(r"(\.\d{6})\d+", r"\1", str(created).replace("Z", "+00:00"))
    try:
        parsed = dt.datetime.fromisoformat(trimmed)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        return parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


# --- WEBVTT parsing ----------------------------------------------------------


def to_seconds(stamp: str) -> float:
    """``HH:MM:SS.mmm`` or the equally legal WebVTT ``MM:SS.mmm``."""
    parts = stamp.replace(",", ".").split(":")
    hours, minutes, seconds = (["0"] * (3 - len(parts)) + parts)[-3:]
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def hms(seconds) -> str:
    """``HH:MM:SS``, signed.

    Negative input is reachable: a screenshot taken before the meeting started
    has a negative transcript offset, and Python's floor division rendered that
    as ``-1:59:00``-shaped nonsense rather than ``-00:01:00``.
    """
    total = int(seconds)
    sign = "-" if total < 0 else ""
    total = abs(total)
    return f"{sign}{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def clean_text(raw: str) -> str:
    """Strip cue markup, unescape entities and fold a multi-line cue's breaks.

    ``html.unescape`` is not optional: a WebVTT cue payload is parsed as HTML, so
    an exporter *must* write a spoken ``&`` as ``&amp;`` and a spoken ``<`` as
    ``&lt;``. Without this, ``AT&T``, ``R&D`` and ``M&A`` — ordinary in a real
    meeting — landed in ``transcript.raw.md`` as ``AT&amp;T``, and that file is
    the verbatim forensic artifact everything downstream reads.

    Unescaping runs *after* ``TAG_RE`` so a ``&lt;v Fake&gt;`` inside the speech
    stays literal text rather than turning into markup we would then strip.
    """
    return html.unescape(WHITESPACE_RE.sub(" ", TAG_RE.sub("", raw))).strip()


def clean_speaker(raw: str) -> str:
    """A Teams display name, made safe for the ``**[t] LABEL:**`` line shape.

    ``:`` and ``*`` are the two characters that would make the line stop parsing
    for ``speakers.py`` and ``verify.py``, so they are folded to spaces rather
    than left to corrupt a transcript nothing downstream could read. Entities are
    unescaped first (``Procter &amp; Gamble``), then the fold runs over the
    result — so an escaped ``&#58;`` cannot smuggle a colon past the guard.
    """
    plain = html.unescape(TAG_RE.sub("", raw))
    name = WHITESPACE_RE.sub(" ", plain.replace(":", " ").replace("*", " ")).strip()
    return name or UNKNOWN_SPEAKER


def split_voice_spans(body: str) -> list[tuple[str, str]]:
    """``[(speaker, text)]`` for each ``<v Speaker>`` span in a cue body.

    Each span ends at the next opener (or an explicit ``</v>``, whichever comes
    first), so an unclosed span cannot absorb the speaker after it.

    Text *before* the first opener is credited to ``UNKNOWN_SPEAKER`` rather than
    dropped. It used to vanish: the loop only ever read from ``opener.end()``, so
    ``Say hi: <v A>Hello</v>`` yielded one cue and lost the rest, and because the
    block did parse it was not counted as an unparsed block either — silent loss
    in the verbatim transcript, which is the one thing this converter's counters
    exist to prevent. Crediting it to the unknown speaker matches what the caller
    already does for a cue with no opener at all.
    """
    openers = list(VOICE_OPEN_RE.finditer(body))
    spans: list[tuple[str, str]] = []
    if openers and openers[0].start() > 0:
        lead = body[: openers[0].start()]
        if TAG_RE.sub("", lead).strip():
            spans.append((UNKNOWN_SPEAKER, lead))
    for index, opener in enumerate(openers):
        stop = openers[index + 1].start() if index + 1 < len(openers) else len(body)
        text = body[opener.end() : stop]
        close = text.find("</v>")
        if close != -1:
            text = text[:close]
        spans.append((opener.group(1), text))
    return spans


def strip_non_cue_prelude(block: str):
    """Drop a ``WEBVTT``/``STYLE``/``REGION`` header line, or ``None``.

    Such a block is *supposed* to end at a blank line, but exporters emit one
    glued straight onto the next cue. Dropping the whole block would lose a real
    cue, so the header line alone is removed and the remainder is re-read as an
    ordinary cue block — meaning the timing line still has to sit where the
    WebVTT grammar puts it (line 0 or 1), not merely somewhere below.

    ``NOTE`` is excluded, and that exclusion is the point. A comment's contents
    are free text by spec, so a multi-line ``NOTE`` may legitimately put a
    standalone timing line in its own prose (documenting the cue format, say) —
    a shape indistinguishable from a comment glued onto a cue. Salvaging it
    turned the following prose line into a transcript line carrying the
    comment's timecodes: invented text at an invented time, in the verbatim
    artifact every later stage is a view over. Between fabricating a line and
    dropping one, dropping wins — and the drop is *counted*
    (``count_unparsed_timing_blocks``), where the fabrication was invisible.
    """
    if COMMENT_BLOCK_RE.match(block):
        return None
    lines = block.splitlines()
    if len(lines) < 2:
        return None
    body = lines[1:]
    for index in (0, 1):
        if index < len(body) and CUE_TIMING_RE.fullmatch(body[index].strip()):
            return "\n".join(body)
    return None


def parse_cue_block(block: str):
    """``(start, end, body)`` for one WEBVTT block, or ``None`` if it is not a cue.

    The timing line must be the block's first line, or its second when the cue
    carries an identifier — that is the whole of the WebVTT cue grammar, and
    requiring it is what stops a ``NOTE``/``STYLE`` block from being read as a
    cue because its free text happens to contain ``-->``.
    """
    lines = block.splitlines()
    for index in (0, 1):
        if index >= len(lines):
            break
        timing = CUE_TIMING_RE.fullmatch(lines[index].strip())
        if timing:
            body = "\n".join(lines[index + 1 :]).strip()
            return to_seconds(timing.group(1)), to_seconds(timing.group(2)), body
    return None


def parse_cues(content: str) -> list[dict]:
    """Every ``(start, speaker, text)`` in the WEBVTT, in file order.

    A cue holding several ``<v Speaker>`` spans yields one entry per span — a
    real Teams shape when two people are captioned inside one cue window, and
    the reason this splits every span where the Air skill used a single
    ``search`` and silently dropped the second voice.

    Parsing is block-by-block rather than one regex over the document, so only
    a well-formed cue block can contribute a cue. See ``CUE_TIMING_RE``.
    """
    cues: list[dict] = []
    for block in BLOCK_SPLIT_RE.split(content):
        verdict, block_cues = cues_from_block(block)
        if verdict == BLOCK_CUES:
            cues.extend(block_cues)
    return cues


#: ``cues_from_block`` verdicts. Kept apart because "not a cue block" and "a cue
#: block that yielded nothing" must be counted differently: a bare ``WEBVTT``
#: header is not a lost cue, a timing line whose body came out empty is.
BLOCK_SKIP = "skip"
BLOCK_UNPARSABLE = "unparsable"
BLOCK_CUES = "cues"


def cues_from_block(block: str) -> tuple[str, list[dict]]:
    """``(verdict, cues)`` for one ``\\n\\n``-delimited block.

    The single place that decides what a block yields, so ``parse_cues`` and
    ``count_unparsed_timing_blocks`` cannot disagree about it. They did: the
    counter re-derived "was this block readable?" from ``parse_cue_block() is
    None``, which is true of a malformed timing line but *false* of a valid cue
    whose body strips to nothing (``<v Дмитрий></v>``, a caption-clearing cue).
    Such a cue was dropped by the parser and counted by neither tally, so the
    operator saw a clean run over a transcript missing real lines — exactly the
    "short by three cues looks like a short meeting" failure the counter exists
    to make visible.
    """
    block = block.strip()
    if not block:
        return BLOCK_SKIP, []
    if NON_CUE_BLOCK_RE.match(block):
        stripped = strip_non_cue_prelude(block)
        if stripped is None:
            return BLOCK_SKIP, []
        block = stripped
    parsed = parse_cue_block(block)
    if parsed is None:
        return BLOCK_UNPARSABLE, []

    start, end, body = parsed
    cues: list[dict] = []
    spans = split_voice_spans(body) if body else []
    if spans:
        for speaker, text in spans:
            text = clean_text(text)
            if text:
                cues.append(
                    {
                        "start": start,
                        "end": end,
                        "speaker": clean_speaker(speaker),
                        "text": text,
                    }
                )
    elif body:
        text = clean_text(body)
        if text:
            cues.append(
                {"start": start, "end": end, "speaker": UNKNOWN_SPEAKER, "text": text}
            )
    # A readable timing line that produced no cue is a *lost* cue, not a skip.
    return (BLOCK_CUES, cues) if cues else (BLOCK_UNPARSABLE, [])


def count_unparsed_timing_blocks(content: str) -> int:
    """Blocks that carry ``-->`` yet contributed no cue.

    The converter's defences all work by *refusing* to read a malformed block —
    an out-of-range stamp, a timing line buried in ``NOTE`` prose, a cue whose
    body is empty. Refusing is right; refusing silently is not, because a
    transcript that is short by three cues looks exactly like a short meeting.
    This is the number that makes the difference visible in the stage report.
    """
    unparsed = 0
    for block in BLOCK_SPLIT_RE.split(content):
        block = block.strip()
        if not block or "-->" not in block:
            continue
        if COMMENT_BLOCK_RE.match(block):
            # A comment quoting an arrow inline is ordinary and contributes
            # nothing by design — counting it would cry wolf on a healthy file.
            # A comment holding a timing line *on its own* is the ambiguous shape
            # that either hides a glued cue or reads like one, and that is worth a
            # human glance.
            if any(
                CUE_TIMING_RE.fullmatch(line.strip())
                for line in block.splitlines()[1:]
            ):
                unparsed += 1
            continue
        # Same predicate ``parse_cues`` uses, so the two cannot drift: anything
        # that block does not turn into at least one cue is counted here.
        # BLOCK_SKIP is the bare WEBVTT/STYLE/REGION header — not a lost cue.
        if cues_from_block(block)[0] == BLOCK_UNPARSABLE:
            unparsed += 1
    return unparsed


def dedup(cues) -> list[dict]:
    """Collapse the rolling-caption repeats Teams emits.

    A live caption is re-sent as it grows, so the same sentence arrives several
    times, each a prefix of the next. Two rules, applied against the previous
    cue of the *same speaker* only:

    * identical text → drop the repeat;
    * the previous text is a prefix of this one → the later, longer cue wins,
      keeping the earlier start time (the speaker did begin talking then).

    A repeat that is neither is left alone: people really do say the same short
    thing twice, and this stage's promise is verbatim.

    Both rules are bounded by ``DEDUP_WINDOW_SECONDS``. A re-send is a sub-second
    phenomenon, but neither rule looked at time, so a speaker's "Понятно." at
    00:05:00 and their next one at 00:20:00 collapsed into a single cue: an
    utterance silently dropped, and the survivor's ``end`` stretched over the
    900 s in between, inflating the ``speaker_rollup`` tally by two orders of
    magnitude.
    """
    out: list[dict] = []
    for cue in cues:
        if (
            out
            and out[-1]["speaker"] == cue["speaker"]
            and cue["start"] - out[-1]["end"] <= DEDUP_WINDOW_SECONDS
        ):
            previous = out[-1]
            if previous["text"] == cue["text"]:
                previous["end"] = max(previous["end"], cue["end"])
                continue
            if cue["text"].startswith(previous["text"]):
                previous["text"] = cue["text"]
                previous["end"] = max(previous["end"], cue["end"])
                continue
        out.append(dict(cue))
    return out


def merge_paragraphs(cues, gap: float = MERGE_GAP_SECONDS) -> list[dict]:
    """Join a speaker's consecutive cues until ``gap`` seconds have elapsed.

    The clock runs from the paragraph's *start*, not from the previous cue: the
    point is a navigable timestamp every ~``gap`` seconds, not an unbounded
    paragraph built out of arbitrarily many short pauses.
    """
    out: list[dict] = []
    for cue in cues:
        if (
            out
            and out[-1]["speaker"] == cue["speaker"]
            and cue["start"] - out[-1]["start"] < gap
        ):
            out[-1]["text"] = f"{out[-1]['text']} {cue['text']}"
            out[-1]["end"] = max(out[-1]["end"], cue["end"])
            out[-1]["cue_count"] += 1
            continue
        row = dict(cue)
        row["cue_count"] = 1
        out.append(row)
    return out


def speaker_rollup(rows) -> list[dict]:
    """Per-speaker paragraph and word tally, ordered by speech time."""
    rollup: dict[str, dict] = {}
    for row in rows:
        entry = rollup.setdefault(
            row["speaker"],
            {"speaker": row["speaker"], "paragraphs": 0, "words": 0, "seconds": 0.0},
        )
        entry["paragraphs"] += 1
        entry["words"] += len(row["text"].split())
        entry["seconds"] += max(0.0, row["end"] - row["start"])
    out = []
    for entry in rollup.values():
        entry["seconds"] = round(entry["seconds"], 3)
        out.append(entry)
    out.sort(key=lambda e: (-e["seconds"], e["speaker"]))
    return out


# --- rendering ---------------------------------------------------------------


def render_transcript(title: str, rows, created=None) -> str:
    """``transcript.raw.md`` — the same line shape ``merge.py`` writes.

    Identical on purpose: ``speakers.py apply`` substitutes into it and
    ``verify.py`` parses it, and neither may care which producer ran.
    """
    anchor = f" (t=0 — {created})" if created else ""
    lines = [
        f"# {title} — транскрипт",
        "",
        (
            "_Источник: **официальный транскрипт Microsoft Teams** — имена спикеров "
            "берутся из него, локальный ASR и диаризация не запускались. Таймкоды — "
            f"смещение от начала транскрипта{anchor}. Дословно, без правок; "
            f"`speakers.py apply` пишет `{LABELED_TRANSCRIPT_NAME}`, не трогая этот файл._"
        ),
        "",
    ]
    for row in rows:
        lines.append(f"**[{hms(row['start'])}] {row['speaker']}:** {row['text']}")
        lines.append("")
    return "\n".join(lines)


def shot_offset_seconds(local, anchor, utc_offset_hours) -> float:
    """Transcript offset for a wall-clock capture time, ``HH:MM:SS`` only.

    A shot carries no date, so the date has to come from ``anchor``. Taking it
    from ``anchor`` *unconditionally* was wrong for every meeting that crosses
    local midnight: an anchor of 23:00 UTC at +01:00 is 00:00 local, so a shot at
    00:20 local resolved onto the previous local day and came out at ≈ −24 h —
    which matched no row, printed an empty section, and passed a negative value to
    ``hms``, which is not defined for one.

    Both candidate days are evaluated and the one landing nearest the transcript
    is kept, which is the only reading that can be right for a meeting shorter
    than a day — and every meeting is.
    """
    best = None
    for day_shift in (0, 1, -1):
        candidate = dt.datetime(
            anchor.year,
            anchor.month,
            anchor.day,
            local[0],
            local[1],
            local[2],
            tzinfo=dt.timezone.utc,
        ) + dt.timedelta(days=day_shift, hours=-utc_offset_hours)
        offset = (candidate - anchor).total_seconds()
        if best is None or abs(offset) < abs(best):
            best = offset
    return best


def render_shot_alignment(rows, shots, anchor, utc_offset_hours) -> str:
    """Transcript excerpts around each screenshot's capture time.

    Print-only salvage from the Air skill: it writes no artifact, it just points
    the human at the discussion a slide belongs to.
    """
    lines = ["########## SCREENSHOT ALIGNMENT ##########"]
    for local, label in shots:
        offset = shot_offset_seconds(local, anchor, utc_offset_hours)
        low, high = offset - SHOT_WINDOW_BEFORE, offset + SHOT_WINDOW_AFTER
        stamp = f"{local[0]:02d}:{local[1]:02d}:{local[2]:02d}"
        lines.append("")
        lines.append(f"===== [{stamp}] {label}  (transcript t≈{hms(offset)}) =====")
        for row in rows:
            if low <= row["start"] <= high:
                lines.append(f"  [{hms(row['start'])}] {row['speaker']}: {row['text']}")
    return "\n".join(lines)


def parse_shots(path) -> list:
    """``HH:MM:SS<TAB>label`` lines → ``((h, m, s), label)``, local capture time.

    ``utf-8-sig``, matching ``read_source``: a shots file saved by a Windows
    editor or exported from Excel carries a BOM, which glued itself to the first
    timestamp and failed a well-formed file with ``not a HH:MM:SS<TAB>label
    line: '\\ufeff09:12:30…'`` — an error pointing at the wrong problem.
    """
    shots = []
    for line in Path(path).read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        stamp, _, label = line.partition("\t")
        parts = stamp.strip().split(":")
        if len(parts) != 3:
            raise SourceError(f"not a HH:MM:SS<TAB>label line: {line!r}")
        try:
            hours, minutes, seconds = (int(part) for part in parts)
        except ValueError as exc:
            raise SourceError(f"not a HH:MM:SS<TAB>label line: {line!r}") from exc
        # Range-checked here, not left to ``dt.datetime`` in
        # render_shot_alignment: that raises *after* the conversion has already
        # written transcript.raw.md, turning a typo into a bare traceback on an
        # otherwise successful run. SourceError is handled with a clean exit 2.
        if not (0 <= hours <= 23 and 0 <= minutes <= 59 and 0 <= seconds <= 59):
            raise SourceError(
                f"not a valid wall-clock time (00:00:00–23:59:59): {line!r}"
            )
        shots.append(((hours, minutes, seconds), label.strip()))
    return shots


# --- the stage ---------------------------------------------------------------


def run(
    meeting_dir,
    source,
    title=None,
    force: bool = False,
    gap: float = MERGE_GAP_SECONDS,
    clock=time.monotonic,
) -> dict:
    """Convert a Teams transcript into ``transcript.raw.md``; returns the report."""
    meeting_dir = Path(meeting_dir)
    out_path = transcript_path(meeting_dir)
    report = {
        "stage": "teams_vtt_to_transcript",
        "meeting_dir": str(meeting_dir),
        "source_path": str(source),
        "transcript": str(out_path),
        "transcript_source": "teams-vtt",
        "merge_gap_seconds": float(gap),
        "forced": bool(force),
        "written": False,
        "elapsed_seconds": 0.0,
    }
    started = clock()

    # First, before reading a byte of source: the raw transcript is the forensic
    # artifact, and a run that was going to refuse must not look like work.
    if out_path.exists() and not force:
        report.update({"status": STATUS_REFUSED, "detail": overwrite_refusal(out_path)})
        return report

    try:
        loaded = read_source(source)
    except SourceError as exc:
        report.update({"status": STATUS_FAILED, "detail": str(exc)})
        return report

    report["source_kind"] = loaded["kind"]
    report["created"] = loaded["created"]
    report["transcript_count"] = loaded["transcript_count"]

    cues = parse_cues(loaded["content"])
    report["cue_count"] = len(cues)
    report["unparsed_timing_block_count"] = count_unparsed_timing_blocks(
        loaded["content"]
    )
    if not cues:
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    f"{source} holds no WEBVTT cues — nothing to convert, and an "
                    "empty transcript.raw.md would look like a finished meeting"
                ),
            }
        )
        return report

    deduped = dedup(cues)
    rows = merge_paragraphs(deduped, gap=gap)

    report["deduped_cue_count"] = len(deduped)
    report["dropped_repeat_count"] = len(cues) - len(deduped)
    report["paragraph_count"] = len(rows)
    report["word_count"] = sum(len(row["text"].split()) for row in rows)
    report["speakers"] = speaker_rollup(rows)
    report["speaker_count"] = len(report["speakers"])
    report["duration_seconds"] = round(max(row["end"] for row in rows), 3)

    title = title or meeting_dir.name
    report["title"] = title

    # The transcript and the supersession are one change to this folder, so
    # neither half is allowed to land without the other: a Teams transcript
    # beside a local-ASR ``transcribe.json`` makes verify.py report local ASR,
    # and an archived ``transcribe.json`` beside a local-ASR transcript makes it
    # report Teams. So render to a sibling, archive, and only then move the
    # rendered text into place — an archive that fails aborts with the folder
    # untouched, and the retry is the same command rather than one that has to
    # fight the overwrite refusal.
    out_path.parent.mkdir(parents=True, exist_ok=True)
    staged = out_path.parent / f"{out_path.name}.partial"
    staged.write_text(
        render_transcript(title, rows, created=loaded["created"]), encoding="utf-8"
    )

    superseded, supersede_failed = supersede_local_asr(meeting_dir)
    report["superseded"] = superseded
    report["supersede_failed"] = supersede_failed
    if supersede_failed:
        staged.unlink(missing_ok=True)
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    "could not archive the superseded local-ASR stage JSON "
                    f"({'; '.join(supersede_failed)}) — {out_path.name} was left "
                    "alone, because a Teams transcript beside a local-ASR "
                    "transcribe.json makes verify.py report the wrong source. "
                    f"Move or remove the file(s) into {WORK_DIRNAME}/"
                    f"{SUPERSEDED_DIRNAME}/ and re-run"
                ),
                "elapsed_seconds": round(clock() - started, 3),
            }
        )
        return report

    staged.replace(out_path)

    report["rows"] = rows
    report["written"] = True
    report["status"] = STATUS_OK
    report["detail"] = (
        f"{len(rows)} paragraph(s) over {report['speaker_count']} named speaker(s)"
    )
    report["elapsed_seconds"] = round(clock() - started, 3)
    return report


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = stage_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def render_human(report: dict) -> str:
    lines = [f"acta-notes teams-vtt — {report['status'].upper()}"]
    if report.get("written"):
        lines.append(f"  wrote {report['transcript']}")
    if report.get("cue_count") is not None:
        lines.append(
            f"  {report['cue_count']} cue(s), "
            f"{report.get('dropped_repeat_count', 0)} rolling-caption repeat(s) folded, "
            f"{report.get('paragraph_count', 0)} paragraph(s)"
        )
    if report.get("unparsed_timing_block_count"):
        # Loud, because the alternative reading of a short transcript is
        # "the meeting was short" and nothing else on this page contradicts it.
        lines.append(
            f"  ⚠ {report['unparsed_timing_block_count']} block(s) carried "
            "'-->' but were not well-formed cues and contributed nothing"
        )
    for entry in report.get("speakers") or []:
        lines.append(
            f"  {entry['speaker'][:28]:<28} {entry['seconds']:>8.1f}s  "
            f"{entry['paragraphs']:>4} turn(s)  {entry['words']:>6} word(s)"
        )
    if report.get("superseded"):
        lines.append(
            f"  superseded local-ASR stage JSON → {WORK_DIRNAME}/{SUPERSEDED_DIRNAME}/: "
            + ", ".join(report["superseded"])
        )
    for failure in report.get("supersede_failed") or []:
        # Not a warning on a green run: this list is only ever non-empty on a
        # conversion that stopped, so the detail line below owns the "what now".
        lines.append(f"  ✗ could not archive {failure}")
    if report.get("status") == STATUS_OK:
        lines.append("")
        lines.append(
            "  next: pipeline.py <meeting> --from-stage speakers "
            "(S1–S5 are replaced, not skipped)"
        )
    else:
        lines.append("")
        lines.append(report.get("detail", "conversion failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] == STATUS_OK:
        return EXIT_OK
    if report["status"] == STATUS_REFUSED:
        return EXIT_USAGE
    return EXIT_FAILED


def main(argv=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="teams_vtt_to_transcript.py",
        description=(
            "Convert an official Microsoft Teams transcript into "
            f"{RAW_TRANSCRIPT_NAME}. This REPLACES pipeline.py's stages S1–S5 — "
            "it is not a stage inside them: no audio is preprocessed, gated, "
            "transcribed or diarized. Resume afterwards with "
            "`pipeline.py <meeting> --from-stage speakers`."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "source",
        help=(
            "the file read_resource(meetingTranscriptUrl) saved (JSON with "
            "transcripts[].content), or a bare .vtt export"
        ),
    )
    parser.add_argument(
        "--title",
        metavar="TEXT",
        help="transcript heading (default: the meeting folder's name)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help=(
            f"replace an existing {RAW_TRANSCRIPT_NAME}. Off by default, and the "
            "refusal is merge.py's word for word: the two are alternative "
            "producers of the same forensic artifact"
        ),
    )
    parser.add_argument(
        "--merge-gap",
        type=float,
        default=MERGE_GAP_SECONDS,
        metavar="SECONDS",
        help=(
            "join a speaker's consecutive cues until this much time has passed "
            f"(default: {MERGE_GAP_SECONDS:g} — keeps timestamps navigable)"
        ),
    )
    parser.add_argument(
        "--shots",
        metavar="FILE",
        help=(
            "TSV of `HH:MM:SS<TAB>label` local screenshot capture times; prints "
            "the transcript around each (a shot lands ~30–60 s after its slide)"
        ),
    )
    parser.add_argument(
        "--shots-utc-offset",
        type=float,
        default=LOCAL_UTC_OFFSET_HOURS,
        metavar="HOURS",
        help=(
            "local-time offset from UTC for --shots capture times "
            f"(default: {LOCAL_UTC_OFFSET_HOURS:g}, this machine's WEST)"
        ),
    )
    parser.add_argument("--json", action="store_true", help="print the stage JSON")
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    # Everything `--shots` needs is validated *before* the conversion writes a
    # byte. The alignment is print-only, but it used to be checked afterwards:
    # an unreadable shots file or a source with no `createdDateTime` then left a
    # perfectly good transcript.raw.md plus its stage JSON on disk behind an exit
    # 2, and the obvious retry hit the overwrite refusal instead of the original
    # error. Read the source twice rather than that — it is one text file, and
    # `run` still owns reporting an unusable one.
    shots, anchor = None, None
    if args.shots:
        try:
            shots = parse_shots(args.shots)
        except (OSError, SourceError) as exc:
            print(f"cannot read --shots {args.shots}: {exc}", file=sys.stderr)
            return EXIT_USAGE
        try:
            loaded = read_source(args.source)
        except SourceError:
            loaded = None  # run() reports it, with its own message and exit code
        if loaded is not None:
            anchor = parse_anchor(loaded["created"])
            if anchor is None:
                print(
                    "--shots needs the M365 JSON envelope's createdDateTime as the "
                    "UTC anchor; this source carries none",
                    file=sys.stderr,
                )
                return EXIT_USAGE

    report = run(
        meeting_dir,
        args.source,
        title=args.title,
        force=args.force,
        gap=args.merge_gap,
        clock=clock,
    )
    # A run that did not install a transcript must not leave a stage JSON behind
    # either — and that is every non-OK status, not just the refusal. The numbers
    # in this report (cue counts, speakers, duration) describe the text that was
    # *going* to be written; persisting them over a folder whose
    # transcript.raw.md is unchanged states the provenance of a file that does
    # not exist, and on a re-run over an earlier conversion it also destroys the
    # record that does still describe the transcript on disk. The failure itself
    # is not lost: it is printed (or dumped by --json) and the exit code carries
    # it. This is the same contract the supersession keeps — a conversion that
    # cannot archive the local-ASR stage JSONs leaves the folder as it was.
    rows = report.pop("rows", [])
    if report["status"] == STATUS_OK:
        write_stage_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))

    # Preflighted above, so nothing here can fail a run whose artifacts are
    # already on disk: rows exist only when the conversion succeeded, and a
    # successful conversion means the source parsed, hence an anchor.
    if rows and shots is not None and anchor is not None:
        print()
        print(render_shot_alignment(rows, shots, anchor, args.shots_utc_offset))

    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
