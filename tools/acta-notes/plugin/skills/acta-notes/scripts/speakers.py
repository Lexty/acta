#!/usr/bin/env python3
"""acta-notes Phase 2a — anchor-based speaker naming (D8).

Two modes over the transcript chain::

    build   transcript.raw.md  ->  speakers.json         (+ .acta-notes/speakers.build.json)
    apply   transcript.raw.md  ->  transcript.labeled.md (+ .acta-notes/speakers.apply.json)

**The hard D8 rule lives in code, not in a prompt.** A speaker the transcript
never names stays ``SPK_NN`` and is written out as ``inferred`` with an explicit
``"name": null``. This script has no best-guess path: there is no
"probably the only other attendee", no "longest speaker is the organizer". A
name is emitted only when a *naming anchor* — a span of the transcript, kept
verbatim as evidence — put it there.

Two anchor types, both measured in the spike audio:

``self_intro``
    The speaker names themself (``меня зовут Дмитрий``, ``здравствуйте, я
    Дмитрий``). The strongest anchor there is: the name attaches to the speaker
    of the very line it was found on.

``vocative``
    Someone addresses another participant by name, usually in Russian
    short form at the start of a sentence (``Дим, посмотри второй пункт``,
    ``Люб, добавь это в протокол`` — both ordinary Russian address). The name
    attaches to the *next different speaker who answers*, within a short
    look-ahead window. Weaker than a self-introduction, and scored so.

**Attendee lists are passed in, never fetched.** Claude supplies ``--attendees``
from the calendar; this script does no I/O beyond the meeting folder. When an
attendee list is supplied it also acts as a *filter*: a vocative that matches no
attendee names nobody (``Ром`` against an attendee list holding ``Римма`` is a
near miss, and a confidently wrong name is exactly the failure D8 forbids). With
no attendee list, an anchor's own surface form is the name.

``resolved_group`` (D9) is written on every entry — ``null`` in v1, which has no
roster. It exists so the deferred Phase-2b grouped voice roster is a drop-in
rather than a schema change; ``--group`` records an explicit override without
matching anything against it.

**``apply`` never touches ``transcript.raw.md`` and never writes
``transcript.md``.** The raw transcript is opened read-only; ``transcript.md``
is Claude's, created at S7 from ``transcript.labeled.md`` with ``quality.md``
prepended. Pointing ``--output`` at it exits ``2`` instead of writing it.

``apply`` is source-agnostic: it needs a ``transcript.raw.md`` and nothing else,
so it works identically whether ``merge.py`` or ``teams_vtt_to_transcript.py``
produced that file.

Stdlib only — no binary to resolve, no model, no network.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

# --- names of the files in the chain -----------------------------------------

WORK_DIRNAME = ".acta-notes"
RAW_TRANSCRIPT_NAME = "transcript.raw.md"
LABELED_TRANSCRIPT_NAME = "transcript.labeled.md"
#: Claude's, at S7. Named here only so ``apply`` can refuse to write it.
CLEAN_TRANSCRIPT_NAME = "transcript.md"
SPEAKERS_JSON_NAME = "speakers.json"
BUILD_STAGE_JSON_NAME = "speakers.build.json"
APPLY_STAGE_JSON_NAME = "speakers.apply.json"
#: S3's report, and the VTT converter's. Each is written **only** by the path
#: that owns it, so ``detect_source`` keys on whichever one is actually present
#: rather than reading one path out of the other's absence — the same positive
#: evidence ``verify.detect_source`` uses, so the two documents never disagree
#: about where a transcript came from.
TRANSCRIBE_JSON_NAME = "transcribe.json"
TEAMS_VTT_JSON_NAME = "teams_vtt.json"

SOURCE_LOCAL_ASR = "local-asr"
SOURCE_TEAMS_VTT = "teams-vtt"
#: Neither marker survives — say so rather than name a source we cannot evidence.
SOURCE_UNKNOWN = "unknown"

#: The mic track's label (D5) — one speaker, known in advance, never named here.
MIC_LABEL = "Я"

STATUS_OK = "ok"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"
STATUS_REFUSED = "refused"

EXIT_OK = 0
EXIT_FAILED = 1
#: A caller error — asking ``apply`` to write a file that is not its to write.
EXIT_USAGE = 2

# --- anchors -----------------------------------------------------------------

ANCHOR_SELF_INTRO = "self_intro"
ANCHOR_VOCATIVE = "vocative"

#: Base confidence per anchor type. A self-introduction is first-person and
#: unambiguous; a vocative is second-hand and depends on who answered next.
ANCHOR_CONFIDENCE = {ANCHOR_SELF_INTRO: 0.9, ANCHOR_VOCATIVE: 0.6}
#: Scoring weight when two anchors disagree about one speaker.
ANCHOR_WEIGHT = {ANCHOR_SELF_INTRO: 1.0, ANCHOR_VOCATIVE: 0.5}
#: An anchor whose name also appears on the attendee list is corroborated twice.
ATTENDEE_WEIGHT_BONUS = 1.25
ATTENDEE_CONFIDENCE_BONUS = 0.05
#: Repeated anchors for the same name raise confidence, with a low ceiling —
#: repetition is corroboration, not proof.
CORROBORATION_BONUS = 0.03
CORROBORATION_CAP = 3
MAX_CONFIDENCE = 0.99

#: In anchor-only mode (no ``--attendees``) a name has nothing to be checked
#: against, and the leading-vocative shape — a capitalized word followed by a
#: comma — is ordinary Russian: "Отлично, поехали", "Внимание, коллеги". Only
#: ``ADDRESS_STOPWORDS`` stands between that and a speaker called *Отлично*
#: written out as ``anchored``, and a blacklist can never be complete. So a
#: uncorroborated claim must recur before it becomes a name. Only the *explicit*
#: self-introductions (``меня зовут X``) are exempt — they are pattern-anchored
#: on a phrase that means nothing else, not a guess. The bare ``я X`` shape is
#: not: see ``_SELF_INTRO_PATTERNS``.
VOCATIVE_ONLY_MIN_COUNT = 2

#: How many lines after a vocative may hold the answer. Measured against the
#: spike: the addressee replies immediately or one back-channel later.
VOCATIVE_LOOKAHEAD = 3

#: Shortest address form we accept. Two letters are almost always a particle.
MIN_ANCHOR_LENGTH = 3

RUSSIAN_VOWELS = "аеёиоуыэюяaeiouy"
#: Carried by neither skeleton: ``Ань`` and ``Аня`` are the same address form,
#: and a soft sign in one and not the other must not split them apart.
SOFT_SIGNS = "ьъ"

#: Sentence-initial words that take a comma and are *not* names. Without this
#: list "Так, поехали" would enrol a speaker called Так.
ADDRESS_STOPWORDS = {
    "ага", "блин", "будем", "ведь", "во", "вот", "все", "всё", "второе",
    "давай", "давайте", "да", "далее", "действительно", "думаю", "ещё", "еще",
    "значит", "извини", "извините", "итак", "кажется", "как", "кстати",
    "коллеги", "конечно", "короче", "ладно", "мне", "может", "наверное", "нет",
    "ну", "ок", "окей", "он", "она", "они", "по", "погоди", "погодите",
    "пожалуйста", "понял", "поняла", "понятно", "потом", "привет", "простите",
    "прости", "ребят", "ребята", "с", "секунду", "скажем", "слушай", "слушайте",
    "смотри", "смотрите", "смотрю", "согласен", "спасибо", "так", "там",
    "тогда", "то", "точно", "ты", "уже", "хорошо", "четко", "чётко", "что",
    "эм", "это", "я",
    # Greetings, assents and openers that take a comma exactly like an address.
    # The list is a floor, not a fence — it cannot be made complete, which is
    # why VOCATIVE_ONLY_MIN_COUNT backs it up in anchor-only mode.
    "верно", "внимание", "господа", "дальше", "добрый", "доброе", "друзья",
    "здравствуй", "здравствуйте", "именно", "класс", "круто", "народ",
    "отлично", "правильно", "супер", "хм", "ясно",
    "ok", "okay", "well", "so", "yes", "no", "hi", "hello", "thanks",
}

#: Words that can never be a name captured by the self-introduction patterns.
NAME_STOPWORDS = ADDRESS_STOPWORDS | {"тут", "здесь", "сейчас", "просто"}

#: Given names an address form may open, as an **allowlist**.
#:
#: Measured on a 57-minute recording: `ADDRESS_STOPWORDS` plus
#: `VOCATIVE_ONLY_MIN_COUNT` was not enough. Russian puts a comma after a large
#: open set of introductory words, so `_VOCATIVE_LEADING` harvested
#: «Соответственно», «Единственное», «Допустим», «Стенциально», «Информацию»,
#: «принципе», «клиенты», «решения», «вопросы», «конфигов» — and «Соответственно»
#: recurred three times pointing at one speaker, clearing the corroboration gate
#: and being written out as `anchored` at 0.66. Two of three names the run
#: produced were ordinary adverbs, and 123 transcript lines were relabelled with
#: them: the confidently-wrong name D8 exists to forbid.
#:
#: A blacklist cannot be completed — that is the lesson. So in anchor-only mode
#: the surface must now *pass* a test instead of merely surviving one: it has to
#: be a plausible address form of a known given name (`is_short_form_of`, the
#: same matcher the attendee list uses). Названия, наречия и косвенные падежи
#: не проходят его по первой букве / первой гласной / консонантному скелету.
#:
#: The cost is the honest direction: a given name outside this list is not
#: auto-named in anchor-only mode. It stays in `evidence` as `uncorroborated`,
#: the speaker keeps `SPK_NN`, and the skill asks — exactly what D8 prescribes.
#: With `--attendees` the list is bypassed: the attendee names are authoritative
#: and already do this job (verified on a recorded meeting: supplying attendees
#: named every speaker the lexicon gate had left unnamed, and none of the garbage).
GIVEN_NAME_LEXICON = frozenset(
    """
    александр алексей анатолий андрей антон аркадий арсений артём артур борис
    вадим валентин валерий василий виктор виталий владимир владислав вячеслав
    геннадий георгий глеб григорий даниил денис дмитрий евгений егор иван игорь
    илья кирилл константин лев леонид максим марк матвей михаил никита николай
    олег павел пётр роман руслан семён сергей станислав степан тимофей тимур
    фёдор филипп эдуард юрий ярослав
    алла анастасия анна валентина валерия вера вероника виктория галина дарья
    диана екатерина елена елизавета жанна зоя инна ирина карина кристина ксения
    лариса лидия любовь людмила маргарита марина мария надежда наталья нина
    оксана ольга полина светлана софья тамара татьяна ульяна юлия яна
    айгуль айдар айрат албина алмаз алсу альберт амир анвар булат гульнара
    дамир динар зульфия ильдар ильнур ильшат инсаф ленар линар марат мурат
    наиль назар нияз радик раиль расим рамиль рашид ринат рустам руфина
    фаиль фанис хамит шамиль эльвира эмиль юлдуз
    """.split()
) | frozenset(
    # Irregular hypocorisms, which `is_short_form_of` cannot derive: «Саша» is
    # not an opening of «Александр» (different first letter), nor «Ваня» of
    # «Иван», nor «Таня» of «Татьяна» (skeleton тн vs ттн). They are the forms
    # people are actually addressed by in these meetings, so they are entries in
    # their own right — and that also covers the clipped vocative, since «Саш»
    # *is* an opening of «Саша».
    """
    саша шура ваня женя дима тима паша гриша миша гоша витя коля толя слава
    юра боря костя петя лёша леша лёня леня серёжа сережа вова володя стас
    гена сеня фёдя федя яша даня саня ромa рома руся эдик альберт
    таня катя маша даша наташа лена света оля галя люда надя ира рита лера
    ася зина соня тоня вика юля настя поля люся тася шура
    """.split()
)


def looks_like_given_name(token: str) -> bool:
    """Is ``token`` a plausible address form of some known given name?

    The positive counterpart of ``ADDRESS_STOPWORDS``. Reuses
    ``is_short_form_of`` so «Дим» → Дмитрий and «Люб» → Любовь still pass, while
    «Соответственно», «Единственное», «Учитывая», «Информацию» and the rest of
    the comma-taking open set do not.
    """
    stem = normalize(token)
    if not stem:
        return False
    return any(is_short_form_of(stem, name) for name in GIVEN_NAME_LEXICON)

_NAME = r"[А-Яа-яЁёA-Za-z][А-Яа-яЁёA-Za-z\-]+"

#: ``(pattern, explicit)``. ``explicit`` marks the shapes that *say* a name is
#: being given — ``меня зовут X`` cannot mean anything else, so one occurrence is
#: proof. The bare shapes cannot make that claim: ``я X`` and ``на связи X`` are
#: ordinary sentences that happen to put a capitalized word after a pronoun, and
#: capitalization is the only filter standing behind them. ``Я Zoom открыл`` and
#: ``Я Excel закрыл`` therefore named speakers "Zoom" and "Excel" at confidence
#: 0.90, status ``anchored`` — the confidently-wrong name D8 forbids, dressed as
#: first-person evidence. NAME_STOPWORDS cannot fix this: it is a Russian
#: blacklist and the offenders are capitalized loanwords, an open set. So the
#: bare shapes are corroborated like a vocative instead (see ``resolve_speaker``).
_SELF_INTRO_PATTERNS = [
    (re.compile(rf"мен[яе]\s+зовут\s+(?:—\s*|-\s*)?(?P<name>{_NAME})", re.IGNORECASE), True),
    (re.compile(rf"зовут\s+меня\s+(?P<name>{_NAME})", re.IGNORECASE), True),
    # Bare `я Дмитрий`: the name must be capitalized, or every "я думаю" in the
    # transcript would enrol a speaker.
    (re.compile(r"(?:^|[,.!?]\s*)[яЯ]\s+(?P<name>[А-ЯЁA-Z][а-яёa-z\-]+)"), False),
    (re.compile(rf"на\s+связи\s+(?P<name>[А-ЯЁA-Z][а-яёa-z\-]+)"), False),
]

#: A vocative at the start of a sentence (``Дим, посмотри второй пункт``) or tacked onto
#: its end (``…добавь это в протокол, Люб?``). Both shapes are ordinary Russian address.
#:
#: The trailing form additionally requires a **capitalized** token: mid-sentence
#: every ordinary word is lowercase, so ``Коллеги, начинаем.`` must not enrol a
#: speaker called Начинаем. The leading form cannot use that signal — sentences
#: start capitalized either way — so it leans on ``ADDRESS_STOPWORDS`` instead.
_VOCATIVE_LEADING = re.compile(rf"(?:^|[.!?…]\s+)(?P<name>{_NAME}),")
_VOCATIVE_TRAILING = re.compile(
    r",\s*(?P<name>[А-ЯЁA-Z][А-Яа-яЁёA-Za-z\-]+)\s*[.!?…]*\s*$"
)

#: ``**[HH:MM:SS] LABEL:** text`` — the one line shape both producers of
#: ``transcript.raw.md`` emit, and the only thing ``apply`` rewrites.
LINE_RE = re.compile(
    r"^\*\*\[(?P<time>\d{1,2}:\d{2}:\d{2})\]\s*(?P<speaker>[^:*]+?):\*\*(?P<sep>\s*)(?P<text>.*)$"
)
#: Diarization labels, as ``diarize.py`` mints them (``LABEL_PREFIX`` + index).
SPK_LABEL_RE = re.compile(r"^SPK_\d+$")
#: Any whitespace run, for folding a name back to single spaces after cleaning.
WHITESPACE_RE = re.compile(r"\s+")


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def raw_transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / RAW_TRANSCRIPT_NAME


def labeled_transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / LABELED_TRANSCRIPT_NAME


def speakers_json_path(meeting_dir) -> Path:
    """The artifact itself lives at the meeting root, beside the transcripts."""
    return Path(meeting_dir) / SPEAKERS_JSON_NAME


def stage_json_path(meeting_dir, mode: str) -> Path:
    name = BUILD_STAGE_JSON_NAME if mode == "build" else APPLY_STAGE_JSON_NAME
    return work_dir(meeting_dir) / name


def is_local_asr(meeting_dir) -> bool:
    """True when S3 ran for this meeting."""
    return (work_dir(meeting_dir) / TRANSCRIBE_JSON_NAME).is_file()


def is_teams_vtt(meeting_dir) -> bool:
    """True when a VTT conversion landed for this meeting."""
    return (work_dir(meeting_dir) / TEAMS_VTT_JSON_NAME).is_file()


def detect_source(meeting_dir) -> str:
    """The source that left its own marker behind. Mirrors ``verify.detect_source``.

    Three-way on purpose. Reading "Teams" out of a *missing* transcribe.json made
    ``provenance_note`` claim the names "пришли из самой записи" about a locally
    transcribed meeting whose disposable ``.acta-notes/`` had been reclaimed —
    a provenance lie in the one line that exists to carry provenance.
    """
    if is_local_asr(meeting_dir):
        return SOURCE_LOCAL_ASR
    if is_teams_vtt(meeting_dir):
        return SOURCE_TEAMS_VTT
    return SOURCE_UNKNOWN


# --- attendee matching -------------------------------------------------------


def normalize(token: str) -> str:
    """Lowercase, ``ё`` folded to ``е`` — ASR spells the same name both ways."""
    return token.strip().lower().replace("ё", "е")


def consonant_skeleton(token: str) -> str:
    return "".join(
        ch
        for ch in normalize(token)
        if ch not in RUSSIAN_VOWELS and ch not in SOFT_SIGNS
    )


def first_vowel(token: str) -> str:
    for ch in normalize(token):
        if ch in RUSSIAN_VOWELS:
            return ch
    return ""


def given_name(attendee: str) -> str:
    """The first token of an attendee entry — what people are addressed by."""
    parts = str(attendee).split()
    return parts[0] if parts else ""


def is_short_form_of(stem: str, full: str) -> bool:
    """Is ``stem`` a plausible address form of the given name ``full``?

    Russian short forms are not plain prefixes (``Дим`` → ``Дмитрий`` drops a
    vowel), so a prefix test alone would miss the commonest case. The test that
    does work on real names is the *consonant skeleton*: ``дм`` opens ``дмтрй``,
    ``лб`` opens ``лбвь``.

    Two guards keep it from over-matching, and they are the whole point — a
    confidently wrong name is worse than no name (D8):

    * the first letter must be the same, and
    * the first vowel must be the same — which is what separates ``Ром``
      (``Роман``) from ``Римма``, a near miss the skeleton alone would accept.
    """
    stem, full = normalize(stem), normalize(full)
    if not stem or not full:
        return False
    if stem == full:
        return True
    if stem[0] != full[0]:
        return False
    if first_vowel(stem) != first_vowel(full):
        return False
    if full.startswith(stem):
        return True
    return consonant_skeleton(full).startswith(consonant_skeleton(stem))


def match_attendee(stem: str, attendees):
    """Resolve an anchor's surface form against the attendee list.

    Returns ``(attendee, reason)``. ``reason`` is ``"matched"``, ``"none"`` or
    ``"ambiguous"`` — an anchor matching two attendees names neither of them.
    """
    if not attendees:
        return None, "no-attendees"
    hits = [a for a in attendees if is_short_form_of(stem, given_name(a))]
    if len(hits) == 1:
        return hits[0], "matched"
    if len(hits) > 1:
        return None, "ambiguous"
    return None, "none"


# --- transcript parsing ------------------------------------------------------


class InputError(Exception):
    """An input file is absent or unusable. Never worked around silently."""


def read_transcript(path) -> str:
    path = Path(path)
    if not path.is_file():
        raise InputError(f"no {RAW_TRANSCRIPT_NAME} at {path}")
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:  # pragma: no cover - unreadable file
        raise InputError(f"cannot read {path}: {exc}") from exc


def parse_lines(text: str) -> list[dict]:
    """Every ``**[HH:MM:SS] LABEL:** text`` line, in document order."""
    rows = []
    for index, line in enumerate(text.splitlines()):
        match = LINE_RE.match(line)
        if not match:
            continue
        speaker = match.group("speaker").strip()
        rows.append(
            {
                "index": index,
                "time": match.group("time"),
                "speaker": speaker,
                "text": match.group("text").strip(),
                "is_diarized": bool(SPK_LABEL_RE.match(speaker)),
            }
        )
    return rows


def diarized_labels(rows) -> list[str]:
    """The ``SPK_NN`` labels present, in first-appearance order."""
    seen = []
    for row in rows:
        if row["is_diarized"] and row["speaker"] not in seen:
            seen.append(row["speaker"])
    return seen


# --- anchor extraction -------------------------------------------------------


def _plausible_name(token: str, stopwords) -> bool:
    return (
        len(token) >= MIN_ANCHOR_LENGTH
        and normalize(token) not in stopwords
        and any(ch.isalpha() for ch in token)
    )


def _span(text: str, match) -> str:
    """The matched span, kept verbatim as the evidence a human can re-read."""
    return text[match.start() : match.end()].strip()


def find_self_intros(text: str) -> list[dict]:
    """Self-introductions in one line, deduplicated by surface name."""
    found: list[dict] = []
    seen = set()
    for pattern, explicit in _SELF_INTRO_PATTERNS:
        for match in pattern.finditer(text):
            token = match.group("name")
            if not _plausible_name(token, NAME_STOPWORDS):
                continue
            key = normalize(token)
            if key in seen:
                continue
            seen.add(key)
            found.append(
                {
                    "anchor_type": ANCHOR_SELF_INTRO,
                    "explicit": explicit,
                    "surface": token,
                    "span": _span(text, match),
                }
            )
    return found


def find_vocatives(text: str) -> list[dict]:
    """Names used to address somebody in one line."""
    found: list[dict] = []
    seen = set()
    for pattern in (_VOCATIVE_LEADING, _VOCATIVE_TRAILING):
        for match in pattern.finditer(text):
            token = match.group("name")
            if not _plausible_name(token, ADDRESS_STOPWORDS):
                continue
            key = normalize(token)
            if key in seen:
                continue
            seen.add(key)
            found.append(
                {
                    "anchor_type": ANCHOR_VOCATIVE,
                    "surface": token,
                    "span": _span(text, match),
                }
            )
    return found


def _vocative_target(rows, position, source_speaker):
    """Who answered the address — the next *different* diarized speaker.

    A vocative names the person spoken *to*, so the anchor belongs to whoever
    picks up the turn, not to whoever said it. Beyond the look-ahead window the
    link is guesswork, and the anchor is dropped rather than attached.

    A non-diarized row **ends** the search rather than being skipped over. That
    row is the mic track — the user, by construction (D5) — so "Саш, посмотри"
    answered on the mic names *him*, and stepping over his reply would hand his
    name to whichever ``SPK_NN`` happens to speak next. An attendee list makes it
    worse, not better: the user is normally on it, so the wrong speaker is
    promoted by ``ATTENDEE_WEIGHT_BONUS``. That is the confidently-wrong
    attribution D8 exists to forbid, so the anchor is dropped instead.

    Returns ``(speaker_or_None, reason_or_None)``.
    """
    for row in rows[position + 1 : position + 1 + VOCATIVE_LOOKAHEAD]:
        if row["speaker"] == source_speaker:
            continue
        if not row["is_diarized"]:
            return None, f"answered on the non-diarized {row['speaker']} track"
        return row["speaker"], None
    return None, f"nobody answered within {VOCATIVE_LOOKAHEAD} line(s)"


def collect_anchors(rows) -> tuple[list[dict], list[dict]]:
    """Walk the transcript once; return ``(attached, unattached)`` anchors.

    An anchor carries the label it names, the line it came from and the span
    that proves it. Unattached anchors are kept too — they are the report's
    honest account of what was seen and could not be pinned to a speaker.
    """
    attached: list[dict] = []
    unattached: list[dict] = []

    for position, row in enumerate(rows):
        for anchor in find_self_intros(row["text"]):
            record = dict(anchor)
            record.update(
                {
                    "timecode": row["time"],
                    "line": row["index"],
                    "source_speaker": row["speaker"],
                }
            )
            if row["is_diarized"]:
                record["speaker"] = row["speaker"]
                attached.append(record)
            else:
                # The mic track is the user by construction (D5) — his own
                # self-introduction names nobody this stage is responsible for.
                record["reason"] = f"self-introduction on the {row['speaker']} track"
                unattached.append(record)

        for anchor in find_vocatives(row["text"]):
            record = dict(anchor)
            record.update(
                {
                    "timecode": row["time"],
                    "line": row["index"],
                    "source_speaker": row["speaker"],
                }
            )
            target, reason = _vocative_target(rows, position, row["speaker"])
            if target is None:
                record["reason"] = reason
                unattached.append(record)
            else:
                record["speaker"] = target
                attached.append(record)

    return attached, unattached


# --- resolution --------------------------------------------------------------


def _evidence(anchor, name, attendee, reason) -> dict:
    return {
        "anchor_type": anchor["anchor_type"],
        "surface": anchor["surface"],
        "span": anchor["span"],
        "timecode": anchor["timecode"],
        "source_speaker": anchor["source_speaker"],
        "name": name,
        "matched_attendee": attendee,
        "attendee_match": reason,
    }


def resolve_speaker(anchors, attendees) -> dict:
    """Turn one speaker's anchors into a name — or refuse to.

    Candidates are scored by anchor weight, so a self-introduction outranks any
    number of vocatives. Two rules make the refusal path the default:

    * an anchor that an attendee list *rejects* carries no name at all — it
      stays in ``evidence`` as something a human can look at, and nothing more;
    * a tie between two distinct names resolves to no name. Picking one would
      be the silent guess D8 forbids.
    """
    evidence: list[dict] = []
    candidates: dict[str, dict] = {}
    #: Surfaces dropped for not being name-shaped, kept so the refusal can still
    #: say *what* it withheld — an unexplained `inferred` is not reviewable.
    withheld: dict[str, int] = {}

    for anchor in anchors:
        attendee, reason = match_attendee(anchor["surface"], attendees)
        if attendee is not None:
            name = attendee
        elif attendees and reason in ("none", "ambiguous"):
            # The attendee list is authoritative once supplied: an address it
            # does not know is a near miss, not a new participant.
            name = None
        else:
            name = anchor["surface"][:1].upper() + anchor["surface"][1:]
        evidence.append(_evidence(anchor, name, attendee, reason))
        if name is None:
            continue
        if (
            not attendees
            and not anchor.get("explicit")
            and not looks_like_given_name(anchor["surface"])
        ):
            # Filtered out of the *candidate set*, not just at the final gate.
            # Otherwise the noise still competes: on the measured meeting
            # A genuine anchor «Дим» can tie with noise surfaces such as «Клиенты»
            # or «Принципе», and the tie-break then refuses to name anybody — a true
            # positive lost to three comma-taking nouns. The anchor stays in
            # `evidence` either way, so nothing is hidden from review.
            withheld[name] = withheld.get(name, 0) + 1
            continue
        entry = candidates.setdefault(
            name,
            {
                "name": name,
                "score": 0.0,
                "count": 0,
                "types": set(),
                "attendee": False,
                "explicit": False,
            },
        )
        weight = ANCHOR_WEIGHT[anchor["anchor_type"]]
        if attendee is not None:
            weight *= ATTENDEE_WEIGHT_BONUS
            entry["attendee"] = True
        if anchor.get("explicit"):
            entry["explicit"] = True
        entry["score"] += weight
        entry["count"] += 1
        entry["types"].add(anchor["anchor_type"])

    evidence.sort(
        key=lambda e: (ANCHOR_WEIGHT[e["anchor_type"]] * -1, e["timecode"])
    )

    if not candidates:
        refusal = {
            "name": None,
            "anchor_type": None,
            "confidence": 0.0,
            "evidence": evidence,
        }
        if withheld:
            # Everything this speaker was addressed by failed the name-shape
            # test. Report the most-claimed surface so the refusal is legible.
            top = sorted(withheld.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
            refusal["uncorroborated"] = top
            refusal["rejected_reason"] = "not-a-known-given-name"
        return refusal

    ranked = sorted(candidates.values(), key=lambda c: (-c["score"], c["name"]))
    if len(ranked) > 1 and ranked[0]["score"] == ranked[1]["score"]:
        return {
            "name": None,
            "anchor_type": None,
            "confidence": 0.0,
            "evidence": evidence,
            "conflict": [c["name"] for c in ranked if c["score"] == ranked[0]["score"]],
        }

    best = ranked[0]
    anchor_type = (
        ANCHOR_SELF_INTRO if ANCHOR_SELF_INTRO in best["types"] else ANCHOR_VOCATIVE
    )
    if not attendees and not best["explicit"] and not looks_like_given_name(best["name"]):
        # No attendee list, and the surface is not a plausible address form of
        # any known given name — «Соответственно», «Единственное», «Допустим».
        # Repetition does NOT rescue it: the measured failure recurred three
        # times and was named anyway, which is why this gate is checked before
        # the count and not folded into it.
        return {
            "name": None,
            "anchor_type": None,
            "confidence": 0.0,
            "evidence": evidence,
            "uncorroborated": best["name"],
            "rejected_reason": "not-a-known-given-name",
        }

    if (
        not attendees
        and not best["explicit"]
        and best["count"] < VOCATIVE_ONLY_MIN_COUNT
    ):
        # Name-shaped, but claimed once and with nothing to check it against.
        # Keep it in `evidence` for a human to read and leave the speaker
        # unnamed.
        #
        # Keyed on `explicit`, not on anchor_type: the bare `я Дмитрий` /
        # `на связи Дмитрий` shapes are typed self_intro but carry exactly the
        # vocative's weakness — a capitalized token in an ordinary sentence — so
        # a lone `Я Zoom открыл` used to walk straight past this gate and be
        # written out as an anchored name at 0.90.
        return {
            "name": None,
            "anchor_type": None,
            "confidence": 0.0,
            "evidence": evidence,
            "uncorroborated": best["name"],
        }

    confidence = ANCHOR_CONFIDENCE[anchor_type]
    if best["attendee"]:
        confidence += ATTENDEE_CONFIDENCE_BONUS
    confidence += min(best["count"] - 1, CORROBORATION_CAP) * CORROBORATION_BONUS
    return {
        "name": best["name"],
        "anchor_type": anchor_type,
        "confidence": round(min(confidence, MAX_CONFIDENCE), 3),
        "score": round(best["score"], 4),
        "evidence": evidence,
    }


def _demote(entry: dict, rivals) -> None:
    """Strip a name off a speaker that lost (or tied) a cross-speaker claim.

    D8 again, one level up: ``resolve_speaker`` refuses to pick between two
    names for one speaker, and this refuses to hand one name to two speakers.
    Two diarized voices rendered under the same name is exactly the confident
    wrong attribution D8 exists to prevent, and it is invisible downstream —
    ``transcript.labeled.md`` shows one person, and the provenance block counts
    both as anchored.
    """
    entry["name_conflict"] = {
        "name": entry["name"],
        "also_claimed_by": sorted(rivals),
    }
    entry["name"] = None
    entry["status"] = "inferred"
    entry["anchored"] = False
    entry["anchor_type"] = None
    entry["confidence"] = 0.0


def resolve_name_collisions(speakers: dict, scores: dict) -> None:
    """Ensure no name is attached to two ``SPK_NN`` labels; edits in place.

    The strictly best-scoring claimant keeps the name. A tie — the case where
    picking one would be a coin flip — leaves every claimant unnamed.
    """
    claims: dict[str, list[str]] = {}
    for label, entry in speakers.items():
        if entry["name"] is not None:
            claims.setdefault(entry["name"], []).append(label)

    def rank(label):
        return (-scores.get(label, 0.0), -speakers[label]["confidence"], label)

    for labels in claims.values():
        if len(labels) < 2:
            continue
        ranked = sorted(labels, key=rank)
        tied = rank(ranked[0])[:2] == rank(ranked[1])[:2]
        losers = ranked if tied else ranked[1:]
        for label in losers:
            _demote(speakers[label], [other for other in labels if other != label])


def build_speakers(rows, attendees, group=None) -> dict:
    """``SPK_NN`` → the D8 entry, for every diarized label in the transcript.

    ``SPK_NN`` here *is* PLAN.md's ``S<N>``: the label the transcript actually
    carries, so ``apply`` can substitute on it mechanically.
    """
    attached, unattached = collect_anchors(rows)
    by_speaker: dict[str, list[dict]] = {}
    for anchor in attached:
        by_speaker.setdefault(anchor["speaker"], []).append(anchor)

    tally: dict[str, dict] = {}
    for row in rows:
        if not row["is_diarized"]:
            continue
        entry = tally.setdefault(row["speaker"], {"utterances": 0, "words": 0})
        entry["utterances"] += 1
        entry["words"] += len(row["text"].split())

    speakers: dict[str, dict] = {}
    scores: dict[str, float] = {}
    for label in diarized_labels(rows):
        resolution = resolve_speaker(by_speaker.get(label, []), attendees)
        anchored = resolution["name"] is not None
        scores[label] = resolution.get("score", 0.0)
        entry = {
            "speaker": label,
            "name": resolution["name"],
            # D8 in one field: a speaker is `anchored` only when a span of the
            # transcript put a name on them. Everything else is `inferred` and
            # keeps its SPK_NN label everywhere downstream.
            "status": "anchored" if anchored else "inferred",
            "anchored": anchored,
            "anchor_type": resolution["anchor_type"],
            "confidence": resolution["confidence"],
            "evidence": resolution["evidence"],
            # D9's slot, always written, `null` until the deferred Phase-2b
            # roster fills it. `--group` records an override; nothing in v1
            # matches against it.
            "resolved_group": group,
            "utterances": tally.get(label, {}).get("utterances", 0),
            "words": tally.get(label, {}).get("words", 0),
        }
        if resolution.get("conflict"):
            entry["conflict"] = resolution["conflict"]
        if resolution.get("uncorroborated"):
            # Named here so a human reading speakers.json can see *what* was
            # withheld and why, rather than an unexplained `inferred`.
            entry["uncorroborated"] = resolution["uncorroborated"]
        if resolution.get("rejected_reason"):
            # Which of the two withholding rules fired — "it is not a name" reads
            # very differently from "it is a name, claimed only once".
            entry["rejected_reason"] = resolution["rejected_reason"]
        speakers[label] = entry

    resolve_name_collisions(speakers, scores)

    return {"speakers": speakers, "unattached_anchors": unattached}


# --- build mode --------------------------------------------------------------


def clean_name(raw: str) -> str:
    """An attendee name, made safe for the ``**[t] LABEL:**`` line shape.

    Same policy as ``teams_vtt_to_transcript.clean_speaker``, and for the same
    reason: ``:`` and ``*`` are exactly the characters ``LINE_RE`` (here and in
    ``verify.py``) excludes from a speaker, so substituting a name containing
    one makes every rewritten line stop parsing. The transcript then trips
    verify's ``transcript`` hard gate with "no `**[HH:MM:SS] LABEL:**` lines",
    which points the operator at ASR instead of at the name they typed.
    """
    return WHITESPACE_RE.sub(" ", raw.replace(":", " ").replace("*", " ")).strip()


def parse_attendees(values) -> list[str]:
    """``--attendees "Дмитрий Иванов, Любовь Кузнецова"``, repeatable."""
    out: list[str] = []
    for value in values or []:
        for item in str(value).split(","):
            item = clean_name(item)
            if item and item not in out:
                out.append(item)
    return out


def run_build(meeting_dir, attendees=(), group=None, clock=time.monotonic) -> dict:
    meeting_dir = Path(meeting_dir)
    source = raw_transcript_path(meeting_dir)
    attendees = list(attendees)
    report = {
        "stage": "speakers",
        "mode": "build",
        "meeting_dir": str(meeting_dir),
        "source": str(source),
        "speakers_json": str(speakers_json_path(meeting_dir)),
        "attendees": attendees,
        "group": group,
        "written": False,
        "elapsed_seconds": 0.0,
    }
    started = clock()

    try:
        text = read_transcript(source)
    except InputError as exc:
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": (
                    f"{exc} — run merge.py (local ASR) or "
                    "teams_vtt_to_transcript.py (Teams) first"
                ),
            }
        )
        return report

    rows = parse_lines(text)
    built = build_speakers(rows, attendees, group=group)
    speakers = built["speakers"]

    artifact = {
        "schema": "acta-notes/speakers@1",
        "meeting_dir": str(meeting_dir),
        "source": str(source),
        "attendees": attendees,
        "mic_label": MIC_LABEL,
        "speakers": speakers,
        "unattached_anchors": built["unattached_anchors"],
    }
    out_path = speakers_json_path(meeting_dir)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(artifact, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    anchored = [s for s in speakers.values() if s["anchored"]]
    report.update(
        {
            "status": STATUS_OK,
            "written": True,
            "speakers": speakers,
            "unattached_anchors": built["unattached_anchors"],
            "speaker_count": len(speakers),
            "anchored_count": len(anchored),
            "inferred_count": len(speakers) - len(anchored),
            "line_count": len(rows),
            "detail": (
                f"{len(anchored)} of {len(speakers)} speaker(s) anchored to a name"
            ),
            "elapsed_seconds": round(clock() - started, 3),
        }
    )
    return report


# --- apply mode --------------------------------------------------------------


def read_speakers_json(meeting_dir) -> dict:
    path = speakers_json_path(meeting_dir)
    if not path.is_file():
        raise InputError(f"no {SPEAKERS_JSON_NAME} at {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InputError(f"cannot read {path}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("speakers"), dict):
        raise InputError(f"{path} is not a speakers artifact")
    return data


def name_map(artifact: dict) -> dict:
    """``SPK_NN`` → name, for **anchored** speakers only.

    ``inferred`` speakers are absent from this map on purpose: their label is
    what the labeled transcript must keep showing.

    Collisions are dropped, not resolved. ``build`` already guards this via
    ``resolve_name_collisions``, but ``apply`` routinely runs over a
    ``speakers.json`` this process did not write: SKILL.md tells the operator to
    hand-correct the map and re-run ``pipeline.py --from-stage speakers``, which
    ``labeling_only_stale`` deliberately turns into apply-only — so build's guard
    is bypassed *by design* on the one path where a human just typed the names.
    ``_demote`` cannot be reused here because it needs the anchor scores, which
    only ``build`` has; and picking a winner without them would be the coin flip
    D8 refuses. So every claimant keeps its label, which is visible in the
    transcript and in the provenance note, rather than two diarized voices being
    rendered as one person — the confident wrong attribution that is invisible
    downstream (``verify.speaker_tally`` would merge them and no gate would fire).
    """
    mapping: dict[str, str] = {}
    claims: dict[str, list[str]] = {}
    for label, entry in (artifact.get("speakers") or {}).items():
        if not isinstance(entry, dict):
            continue
        if entry.get("anchored") and entry.get("name"):
            # Cleaned again here, not only in parse_attendees: speakers.json is
            # a file on disk and `apply` may run over one this process did not
            # write. A name is never substituted unless the resulting line
            # still parses.
            name = clean_name(str(entry["name"]))
            if name:
                mapping[label] = name
                claims.setdefault(name, []).append(label)
    for name, labels in claims.items():
        if len(labels) > 1:
            for label in labels:
                del mapping[label]
    return mapping


def name_collisions(artifact: dict) -> dict:
    """``name`` → the labels that all claimed it; ``{}`` when there are none.

    Recomputed rather than returned alongside ``name_map`` so the mapping stays a
    plain ``dict`` for ``relabel``; the input is a handful of speakers.
    """
    claims: dict[str, list[str]] = {}
    for label, entry in (artifact.get("speakers") or {}).items():
        if not isinstance(entry, dict):
            continue
        if entry.get("anchored") and entry.get("name"):
            name = clean_name(str(entry["name"]))
            if name:
                claims.setdefault(name, []).append(label)
    return {
        name: sorted(labels) for name, labels in claims.items() if len(labels) > 1
    }


def provenance_note(mapping: dict, artifact: dict, source: str = SOURCE_UNKNOWN) -> str:
    """One italic line recording what was substituted and what was not."""
    named = ", ".join(
        f"{label} → {name}" for label, name in sorted(mapping.items())
    )
    speakers = artifact.get("speakers") or {}
    kept = sorted(label for label in speakers if label not in mapping)

    if not speakers and source == SOURCE_TEAMS_VTT:
        # No SPK_NN label to resolve at all — the Teams path, where the names
        # in the transcript are the meeting's own and this stage substituted
        # nothing. Saying "nobody was identified" would read as the opposite.
        return (
            "_В транскрипте нет меток `SPK_NN`: имена пришли из самой записи, "
            f"`speakers.py apply` ничего не подставлял. Дословный источник: "
            f"`{RAW_TRANSCRIPT_NAME}`._"
        )

    if not speakers and source == SOURCE_LOCAL_ASR:
        # Local ASR, but nothing was diarized: a mic-only meeting, where every
        # line is the MIC_LABEL by construction (D5). Keyed on the *source*
        # rather than on the emptiness of ``speakers``, because the Teams note
        # above would claim the names came from the recording — a provenance lie
        # about a run whose whole point is provenance.
        return (
            f"_Диаризованных меток `SPK_NN` нет: в записи одна дорожка "
            f"(`{MIC_LABEL}`, D5), подставлять было нечего. Дословный источник: "
            f"`{RAW_TRANSCRIPT_NAME}`._"
        )

    if not speakers:
        # Neither marker is on disk. Both notes above make a claim about where
        # the names came from, and neither is evidenced here — so make none.
        return (
            "_В транскрипте нет меток `SPK_NN`, подставлять было нечего; "
            "источник транскрипта не определён (нет ни stage JSON локального "
            f"ASR, ни отчёта о конверсии VTT). Дословный источник: "
            f"`{RAW_TRANSCRIPT_NAME}`._"
        )

    parts = [
        "_Имена подставлены `speakers.py apply` только по якорям (D8): "
        + (named if named else "ни один спикер не опознан")
    ]
    if kept:
        parts.append(
            ". Без якоря — остаются как есть: " + ", ".join(kept)
        )
    # Named separately from `kept`, because "no anchor" and "one name claimed by
    # two voices" call for different corrections: the second one means
    # speakers.json itself needs editing, and saying only "без якоря" would send
    # the operator looking for an anchor that is already there.
    collisions = name_collisions(artifact)
    if collisions:
        parts.append(
            ". Одно имя заявлено несколькими голосами, поэтому не подставлено "
            "ни одному из них (D8): "
            + "; ".join(
                f"{name} — {', '.join(labels)}"
                for name, labels in sorted(collisions.items())
            )
        )
    parts.append(f". Дословный источник: `{RAW_TRANSCRIPT_NAME}`._")
    return "".join(parts)


def relabel(text: str, mapping: dict) -> tuple[str, int]:
    """Rewrite the label position of every transcript line; touch nothing else.

    Substituting only inside the ``**[HH:MM:SS] LABEL:**`` prefix — rather than
    replacing ``SPK_01`` everywhere — keeps a line that *talks about* a label
    ("SPK_02 не слышно") verbatim, which is the whole promise of the chain.
    """
    out = []
    replaced = 0
    for line in text.splitlines():
        match = LINE_RE.match(line)
        if match:
            speaker = match.group("speaker").strip()
            name = mapping.get(speaker)
            if name:
                line = (
                    f"**[{match.group('time')}] {name}:**"
                    f"{match.group('sep')}{match.group('text')}"
                )
                replaced += 1
        out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else ""), replaced


def insert_note(text: str, note: str) -> str:
    """Put the provenance note just above the first transcript line."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if LINE_RE.match(line):
            lines[index:index] = [note, ""]
            break
    else:
        lines.extend(["", note])
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def refusal_for(path) -> str:
    return (
        f"{path} is not this script's to write. `{CLEAN_TRANSCRIPT_NAME}` is the "
        f"cleaned S7 view Claude builds from `{LABELED_TRANSCRIPT_NAME}` with "
        "`.acta-notes/quality.md` prepended, and `"
        f"{RAW_TRANSCRIPT_NAME}` is the verbatim artifact every later stage is a "
        f"view over. `apply` writes `{LABELED_TRANSCRIPT_NAME}` and nothing else."
    )


def run_apply(meeting_dir, output=None, clock=time.monotonic) -> dict:
    meeting_dir = Path(meeting_dir)
    source = raw_transcript_path(meeting_dir)
    out_path = Path(output) if output else labeled_transcript_path(meeting_dir)
    report = {
        "stage": "speakers",
        "mode": "apply",
        "meeting_dir": str(meeting_dir),
        "source": str(source),
        "output": str(out_path),
        "written": False,
        "elapsed_seconds": 0.0,
    }
    started = clock()

    # Before reading anything: the two files this script may never produce.
    if out_path.name in (CLEAN_TRANSCRIPT_NAME, RAW_TRANSCRIPT_NAME):
        report.update({"status": STATUS_REFUSED, "detail": refusal_for(out_path)})
        return report

    try:
        text = read_transcript(source)
        artifact = read_speakers_json(meeting_dir)
    except InputError as exc:
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": f"{exc} — run `speakers.py build` first",
            }
        )
        return report

    mapping = name_map(artifact)
    labeled, replaced = relabel(text, mapping)
    labeled = insert_note(
        labeled, provenance_note(mapping, artifact, source=detect_source(meeting_dir))
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(labeled, encoding="utf-8")

    speakers = artifact.get("speakers") or {}
    report.update(
        {
            "status": STATUS_OK,
            "written": True,
            "named": dict(sorted(mapping.items())),
            "kept_labels": sorted(set(speakers) - set(mapping)),
            "lines_relabeled": replaced,
            "anchored_count": len(mapping),
            "inferred_count": len(speakers) - len(mapping),
            "detail": (
                f"{replaced} line(s) relabeled for {len(mapping)} anchored "
                f"speaker(s); {len(speakers) - len(mapping)} kept SPK_NN"
            ),
            "elapsed_seconds": round(clock() - started, 3),
        }
    )
    return report


# --- CLI ---------------------------------------------------------------------


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = stage_json_path(meeting_dir, report["mode"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def render_human(report: dict) -> str:
    lines = [f"acta-notes speakers {report['mode']} — {report['status'].upper()}"]
    if report["mode"] == "build":
        for label, entry in (report.get("speakers") or {}).items():
            if entry["anchored"]:
                lines.append(
                    f"  {label:<7} {entry['name']}  "
                    f"[{entry['anchor_type']} {entry['confidence']:.2f}]"
                )
            else:
                lines.append(f"  {label:<7} (не опознан — остаётся {label})")
        for anchor in report.get("unattached_anchors") or []:
            lines.append(
                f"  ? {anchor['surface']} @ {anchor['timecode']} — "
                f"{anchor.get('reason', 'unattached')}"
            )
    else:
        for label, name in (report.get("named") or {}).items():
            lines.append(f"  {label:<7} → {name}")
        for label in report.get("kept_labels") or []:
            lines.append(f"  {label:<7} (не опознан — остаётся {label})")
    if report.get("written"):
        lines.append(
            f"  wrote {report.get('speakers_json') or report.get('output')}"
        )
    if report.get("detail"):
        lines.append("")
        lines.append(report["detail"])
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] == STATUS_OK:
        return EXIT_OK
    if report["status"] == STATUS_REFUSED:
        return EXIT_USAGE
    return EXIT_FAILED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="speakers.py",
        description=(
            "Phase 2a: name diarized speakers from naming anchors in "
            f"{RAW_TRANSCRIPT_NAME} (self-introductions and vocatives). A "
            "speaker without an anchor keeps its SPK_NN label — this script "
            "never emits a best guess (D8)."
        ),
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    build = sub.add_parser(
        "build",
        help=f"extract anchors from {RAW_TRANSCRIPT_NAME} into {SPEAKERS_JSON_NAME}",
    )
    build.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    build.add_argument(
        "--attendees",
        action="append",
        metavar="NAMES",
        help=(
            "comma-separated attendee names, passed in by Claude from the "
            "calendar (repeatable). Once supplied the list is authoritative: an "
            "anchor it does not recognise names nobody"
        ),
    )
    build.add_argument(
        "--group",
        metavar="NAME",
        help=(
            "record an explicit D9 group (work, personal, …) on every entry. "
            "Recorded only — v1 has no roster to match against"
        ),
    )
    build.add_argument("--json", action="store_true", help="print the stage JSON")

    apply_ = sub.add_parser(
        "apply",
        help=f"write {LABELED_TRANSCRIPT_NAME} from {RAW_TRANSCRIPT_NAME}",
    )
    apply_.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    apply_.add_argument(
        "--output",
        metavar="PATH",
        help=(
            f"where to write (default: {LABELED_TRANSCRIPT_NAME}). Pointing this "
            f"at {CLEAN_TRANSCRIPT_NAME} or {RAW_TRANSCRIPT_NAME} exits 2"
        ),
    )
    apply_.add_argument("--json", action="store_true", help="print the stage JSON")
    return parser


def main(argv=None, clock=time.monotonic) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    if args.mode == "build":
        report = run_build(
            meeting_dir,
            attendees=parse_attendees(args.attendees),
            group=args.group,
            clock=clock,
        )
    else:
        report = run_apply(meeting_dir, output=args.output, clock=clock)

    # A refusal wrote nothing and must not leave a stage JSON claiming it did.
    if report["status"] != STATUS_REFUSED:
        write_stage_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
