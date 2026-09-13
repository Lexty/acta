#!/usr/bin/env python3
"""acta-notes — the S1–S6 driver.

One entry point for a meeting folder. It runs the machine chain in order and
leaves every stage's JSON, plus its own run log, under ``.acta-notes/``::

    doctor → prep_audio (both tracks) → gate (both tracks)
           → transcribe (non-silent tracks) → diarize run --track system
           → merge → speakers build → speakers apply → verify

**The Teams path is not a branch inside this driver.** ``pipeline.py`` never
invokes ``teams_vtt_to_transcript.py``. When a meeting has an official Teams
transcript the converter *replaces* S1–S5 wholesale — no audio is preprocessed,
gated, transcribed or diarized at all — and writes ``transcript.raw.md``
directly. The run then resumes here with ``--from-stage speakers``, which works
against a folder holding nothing but that file: no ``prep_audio``/``gate``/
``transcribe``/``diarize`` stage JSON is required, and ``doctor`` is not even
selected (the stage list is a prefix cut, and doctor sits before ``speakers``).

**``verify`` is the last stage and is never skipped for freshness.** Its
non-zero exit propagates: this driver exits non-zero, prints the ``quality.md``
block to stderr, and leaves every artifact in place. ``--cleanup-wavs`` deletes
the 16 kHz intermediates only after a run that ends green — never after a
tripped hard gate, because those wavs are what a re-run needs.

**``--force`` here means "ignore stage freshness", nothing more.** It skips this
driver's freshness check *and* is forwarded to every stage that keeps one of its
own (``prep_audio``, ``transcribe``, ``diarize``) — clearing only the driver's
would leave the stage self-skipping while the run log claimed it ran. The one
deliberate exception is ``merge.py``: ``transcript.raw.md`` is the verbatim
forensic artifact and its overwrite protection is not this driver's to lift.
Replacing it stays a hand-typed ``merge.py --force``.

**D5 is enforced upstream and respected here.** ``diarize.py`` is only ever
invoked with ``--track system``; the mic track is ``Я`` by construction, so no
model runs on it. A track the S2 gate called effectively silent is dropped from
the transcribe call with the reason recorded in the run log.

Stage scripts are imported from this file's own directory and driven through
their ``main(argv)`` — same process, same interpreter, no ``sys.path`` games
(script stems like ``gate``, ``merge`` and ``verify`` must never shadow, or be
shadowed by, an installed module of the same name). Every invocation goes
through one injectable ``runner`` so the tests can stub the whole chain.

Stdlib only.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import sys
import time
import traceback
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: Sibling stage scripts live next to this file.
SCRIPTS_DIR = Path(__file__).resolve().parent

WORK_DIRNAME = ".acta-notes"
RUN_JSON_NAME = "pipeline.json"

GATE_JSON_NAME = "gate.json"
QUALITY_MD_NAME = "quality.md"
RAW_TRANSCRIPT_NAME = "transcript.raw.md"
LABELED_TRANSCRIPT_NAME = "transcript.labeled.md"

#: PLAN.md §2 puts both of these at the *meeting root*, beside the transcripts —
#: they are the machine artifacts later stages read, not working files under
#: ``.acta-notes/``. Getting this wrong here does not fail loudly: it silently
#: mis-computes freshness, so ``test_layout.py`` pins these against the paths
#: ``diarize.py`` and ``speakers.py`` actually write.
DIARIZATION_JSON_NAME = "diarization.json"
SPEAKERS_JSON_NAME = "speakers.json"
DICTA_JSON_NAME = "dicta.json"

INPUT_SUFFIX = ".16k.wav"
#: prep_audio's write-through scratch shape (``prep_audio._temp_output_path``).
#: Deliberately not matched by INPUT_SUFFIX's glob — a partial is not a cache.
PARTIAL_SUFFIX = ".16k.part.wav"
TRACK_SUFFIX = ".wav"

DEFAULT_TRACKS = ("mic", "system")

#: D5: the only track a diarizer ever sees.
DIARIZED_TRACK = "system"

#: D5 again, the other side: this track is one known person, never clustered.
MIC_TRACK = "mic"

DEFAULT_CHAIN = "denoise"
CHAIN_CHOICES = ("plain", "denoise", "loudnorm")

#: The chain a track gated as under-levelled is re-converted with. `loudnorm` is
#: not the default (D6: ~110 s per track for ~3 % of tokens), but for a track the
#: pinned RMS gate cannot see it is the difference between a transcript and
#: silence — see `gate.probe_under_levelled`.
RELEVEL_CHAIN = "loudnorm"

#: The canonical stage order. Every name here is addressable by ``--from-stage``
#: and ``--only`` — ``speakers`` and ``verify`` included.
STAGES = (
    "doctor",
    "prep_audio",
    "gate",
    "transcribe",
    "diarize",
    "merge",
    "speakers",
    "dicta_overlay",
    "verify",
)

#: Every stage above is implemented by the sibling script of the same name.
#: ``teams_vtt_to_transcript`` is deliberately not one of them — it is an
#: alternative to S1–S5, not a stage inside them, and this driver never invokes
#: it. Named so that invariant can be asserted rather than merely intended.
TEAMS_CONVERTER_SCRIPT = "teams_vtt_to_transcript"

STATUS_OK = "ok"
STATUS_SKIPPED = "skipped"
STATUS_FAILED = "failed"
STATUS_SILENT = "silent"
#: A run that declined to start rather than one that broke — same spelling and
#: the same exit 2 the stage scripts use for their own overwrite guards.
STATUS_REFUSED = "refused"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2


# --- paths -------------------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def run_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / RUN_JSON_NAME


def gate_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / GATE_JSON_NAME


def quality_md_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / QUALITY_MD_NAME


def track_path(meeting_dir, track: str) -> Path:
    return Path(meeting_dir) / f"{track}{TRACK_SUFFIX}"


def prepped_path(meeting_dir, track: str) -> Path:
    return work_dir(meeting_dir) / f"{track}{INPUT_SUFFIX}"


def diarization_json_path(meeting_dir) -> Path:
    """Mirrors ``diarize.stage_json_path`` / ``merge.diarization_json_path``."""
    return Path(meeting_dir) / DIARIZATION_JSON_NAME


def dicta_json_path(meeting_dir) -> Path:
    return Path(meeting_dir) / DICTA_JSON_NAME


def speakers_json_path(meeting_dir) -> Path:
    """Mirrors ``speakers.speakers_json_path``."""
    return Path(meeting_dir) / SPEAKERS_JSON_NAME


def raw_transcript_path(meeting_dir) -> Path:
    return Path(meeting_dir) / RAW_TRANSCRIPT_NAME


# --- stage loading -----------------------------------------------------------


_MODULE_CACHE: dict[str, object] = {}


def load_script(stem: str):
    """Import ``<scripts>/<stem>.py`` under a namespaced module name, cached."""
    cached = _MODULE_CACHE.get(stem)
    if cached is not None:
        return cached

    path = SCRIPTS_DIR / f"{stem}.py"
    if not path.is_file():
        raise FileNotFoundError(f"no such acta-notes script: {path}")

    qualname = f"acta_notes_pipeline.{stem}"
    spec = importlib.util.spec_from_file_location(qualname, path)
    if spec is None or spec.loader is None:  # pragma: no cover - import plumbing
        raise ImportError(f"cannot build an import spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[qualname] = module
    spec.loader.exec_module(module)

    _MODULE_CACHE[stem] = module
    return module


def default_runner(call: dict) -> int:
    """Drive one stage script's ``main(argv)`` and return its exit code."""
    module = load_script(call["script"])
    try:
        return int(module.main(list(call["argv"])) or 0)
    except SystemExit as exc:  # argparse errors and explicit sys.exit()
        code = exc.code
        if code is None:
            return 0
        return code if isinstance(code, int) else EXIT_FAILED


# --- stage selection ---------------------------------------------------------


class SelectionError(ValueError):
    """A bad ``--from-stage``/``--only`` combination."""


def select_stages(from_stage=None, only=()) -> tuple[str, ...]:
    """Resolve the stage list, always in canonical order."""
    only = tuple(only or ())
    if from_stage and only:
        raise SelectionError("--from-stage and --only are mutually exclusive")

    if only:
        unknown = [name for name in only if name not in STAGES]
        if unknown:
            raise SelectionError(f"unknown stage(s): {', '.join(unknown)}")
        chosen = set(only)
        return tuple(name for name in STAGES if name in chosen)

    if from_stage:
        if from_stage not in STAGES:
            raise SelectionError(f"unknown stage: {from_stage}")
        return STAGES[STAGES.index(from_stage) :]

    return STAGES


# --- freshness ---------------------------------------------------------------


def stage_inputs(meeting_dir, stage: str) -> list[Path]:
    meeting_dir = Path(meeting_dir)
    if stage == "prep_audio":
        return [track_path(meeting_dir, t) for t in DEFAULT_TRACKS]
    if stage in ("gate", "transcribe"):
        return [prepped_path(meeting_dir, t) for t in DEFAULT_TRACKS]
    if stage == "diarize":
        return [prepped_path(meeting_dir, DIARIZED_TRACK)]
    if stage == "merge":
        return [
            work_dir(meeting_dir) / "transcribe.json",
            diarization_json_path(meeting_dir),
        ]
    if stage == "speakers":
        # speakers.json is both `build`'s output and `apply`'s input, and it is
        # listed as an input for exactly that reason: without it the stage looks
        # fresh whenever both outputs are newer than the raw transcript, so a
        # speakers.json that changed after `apply` ran leaves
        # transcript.labeled.md silently stale. Listing it costs nothing in the
        # normal case (a file is never older than itself) and turns that case
        # into a re-run — an apply-only one, see ``labeling_only_stale``.
        return [raw_transcript_path(meeting_dir), speakers_json_path(meeting_dir)]
    # doctor is a preflight, verify is the verdict, dicta_overlay reads a file
    # outside this folder — none of the three is ever fresh (``is_fresh``).
    return []


def stage_outputs(meeting_dir, stage: str) -> list[Path]:
    meeting_dir = Path(meeting_dir)
    work = work_dir(meeting_dir)
    if stage == "prep_audio":
        # The wavs are listed alongside the report because ``--cleanup-wavs``
        # deletes them: a stage whose real product is gone is not fresh, however
        # new its JSON. Without them a cleaned-up meeting reports prep_audio and
        # gate as current and the next stage that needs a wav dies with
        # "run prep_audio.py first". Only tracks that actually have a source are
        # required, so a single-track meeting still caches.
        return [work / "prep_audio.json"] + [
            prepped_path(meeting_dir, t)
            for t in DEFAULT_TRACKS
            if track_path(meeting_dir, t).is_file()
        ]
    if stage == "gate":
        return [work / GATE_JSON_NAME]
    if stage == "transcribe":
        return [work / "transcribe.json"]
    if stage == "diarize":
        return [diarization_json_path(meeting_dir)]
    if stage == "merge":
        return [raw_transcript_path(meeting_dir)]
    if stage == "speakers":
        return [
            speakers_json_path(meeting_dir),
            meeting_dir / LABELED_TRANSCRIPT_NAME,
        ]
    return []


def stages_feeding_merge(meeting_dir) -> set:
    """The stages whose re-run can restale ``transcript.raw.md``, transitively.

    "Runs before merge" is not the test — *feeds* merge is. A stage qualifies if
    it writes one of merge's inputs, or writes an input of a stage that does:
    ``prep_audio`` never touches merge's inputs itself, but the wavs it produces
    are what transcribe and diarize consume, so a prep_audio re-run does rebuild
    the transcript.

    ``gate`` is the case that makes the distinction load-bearing. It runs before
    merge and writes only ``gate.json``, which nothing downstream consumes — so
    an ordering test counted a deleted or ``failed`` gate.json as "the transcript
    is about to be rebuilt" and aborted the run with exit 2, telling the operator
    to ``merge.py --force`` over their forensic transcript for no reason.
    """
    frontier = {path.resolve() for path in stage_inputs(meeting_dir, "merge")}
    feeding: set = set()
    upstream = STAGES[: STAGES.index("merge")]
    changed = True
    while changed:
        changed = False
        for stage in upstream:
            if stage in feeding:
                continue
            if any(
                path.resolve() in frontier
                for path in stage_outputs(meeting_dir, stage)
            ):
                feeding.add(stage)
                frontier |= {
                    path.resolve() for path in stage_inputs(meeting_dir, stage)
                }
                changed = True
    return feeding


#: Which stage consumes each parameter flag. A flag whose owner is not selected
#: cannot be honoured by the run at all, and ``parameters_changed`` cannot catch
#: that: it only ever *deselects* a cache hit for a stage that is running.
PARAMETER_OWNERS = {
    "chain": "prep_audio",
    "language": "transcribe",
    "custom_vocab": "transcribe",
    "num_speakers": "diarize",
    "attendees": "speakers",
}

#: The flag spelling for each parameter, for messages.
PARAMETER_FLAGS = {
    "chain": "--chain",
    "language": "--language",
    "custom_vocab": "--custom-vocab",
    "num_speakers": "--num-speakers",
    "attendees": "--attendees",
}


def unconsumable_parameters(selected, params) -> list[str]:
    """The passed flags no selected stage can act on, as flag spellings.

    The failure this prevents is silent and green. ``pipeline.py <meeting>
    --from-stage speakers --num-speakers 5`` exits 0 with ``diarization.json``
    still recording the old clustering, because ``diarize`` is not in the
    selected prefix — precisely the "exits green having re-used the old
    2-speaker clustering" symptom ``parameters_changed`` was written to stop,
    arriving through a different door. And ``--from-stage speakers`` is what the
    merge refusal *tells* the operator to run, so this is the likely next
    command after a parameter change, not a hypothetical.
    """
    return [
        PARAMETER_FLAGS[key]
        for key, owner in PARAMETER_OWNERS.items()
        if _parameter_passed(key, params.get(key)) and owner not in selected
    ]


def _parameter_passed(key: str, value) -> bool:
    """Was this parameter actually supplied on the command line?

    Not a blanket truthiness test. ``num_speakers`` is an ``int`` with no lower
    bound in the parser, so ``--num-speakers 0`` is falsy and used to slip past
    this check entirely: ``--from-stage speakers --num-speakers 0`` exited green
    having silently ignored the flag, with ``diarization.json`` still holding the
    old clustering — the exact failure ``unconsumable_parameters`` exists to
    stop. ``parameters_changed`` already uses ``is None`` for the same value.
    Truthiness is right only for ``attendees``, where an empty list genuinely
    cannot be told apart from "omitted".
    """
    if key == "attendees":
        return bool(value)
    return value is not None


def stage_skip_reason(meeting_dir, stage: str, silent) -> str | None:
    """Why ``run()`` would skip ``stage`` outright, or ``None`` if it would run.

    The single source of truth for "this stage is not going to execute", called
    by both ``run()`` (which needs the wording) and ``merge_would_refuse`` (which
    only needs the fact). Keeping the two in one place is the point: the
    predictive merge check has to model what ``run()`` does, and when it modelled
    it separately the two drifted. A meeting whose *system* track S2 called
    effectively silent — a failed system capture, a listen-only call — ran green
    once and then refused **every** bare re-run with exit 2, because the
    pre-check counted diarize as about to rebuild merge's inputs while ``run()``
    skipped it for silence. The refusal then offered two wrong ways out:
    ``--replace-transcript``, which lifts the guard on the verbatim transcript
    this whole mechanism protects, or ``--from-stage speakers``, which narrows
    the run. The near-identical mic-only meeting re-ran cleanly, so the failure
    looked arbitrary. ``stages_feeding_merge``'s docstring records the same class
    of divergence having already bitten this check once, with ``gate``.
    """
    if stage != "diarize":
        return None
    if DIARIZED_TRACK in silent:
        return (
            f"the {DIARIZED_TRACK} track is effectively silent (S2) — "
            "nothing to diarize"
        )
    # A mic-only recording: an *absent* system track, not merely a silent one.
    # prep_audio, gate and transcribe all treat a missing track as non-fatal
    # (`ok` with a `missing` entry) because this shape is intended —
    # ``stage_outputs`` requires prepped wavs "only for tracks that actually have
    # a source", verify.coverage_skip_reason has a dedicated "mic-only or a
    # silent system track" message, and speakers.provenance_note a dedicated
    # `Я`/D5 branch. But diarize alone returns ``missing``, whose exit code is
    # EXIT_FAILED, so the driver stopped at S4 and none of those branches was
    # reachable: the silent-system meeting ran end to end while the
    # near-identical no-system meeting dead-ended. ``silent`` cannot cover this —
    # gate.py writes no ``effectively_silent`` key for a track it never found.
    # Keyed on the source tracks rather than on the prepped wav so the skip means
    # "this recording has one track", not "prep_audio has not run"; a system
    # source that exists but produced no wav is a prep_audio failure and stops
    # the run on its own terms.
    if (
        not track_path(meeting_dir, DIARIZED_TRACK).is_file()
        and track_path(meeting_dir, MIC_TRACK).is_file()
    ):
        return (
            f"no {DIARIZED_TRACK} track in this recording — mic-only, so every "
            "line is the mic speaker by construction (D5) and there is nothing "
            "to diarize"
        )
    return None


def merge_would_refuse(meeting_dir, selected, *, force: bool = False, params=None) -> bool:
    """True when merge is selected, would have to run, and would then refuse.

    ``merge.py`` guards ``transcript.raw.md`` — the verbatim forensic artifact —
    and this driver never passes it ``--force``. So a selected merge that is not
    fresh (or is being forced) and finds the file already there is a guaranteed
    exit 2, knowable before a single stage runs.

    The check has to be *predictive*, not a snapshot. The normal way a transcript
    goes stale is that prep_audio/transcribe/diarize re-run **inside this same
    invocation** and rewrite merge's inputs; at pre-check time those JSONs are
    still older than the transcript, so asking "is merge fresh right now" says
    yes and the run burns the whole ASR pass to reach the same exit 2. So a
    selected upstream producer that is itself not fresh — and is therefore about
    to run — counts as a refusal too.
    """
    if "merge" not in selected:
        return False
    if not raw_transcript_path(meeting_dir).exists():
        return False
    if force or not is_fresh(meeting_dir, "merge", params):
        return True

    feeding = stages_feeding_merge(meeting_dir)
    silent = read_silent_tracks(meeting_dir)
    for stage in selected:
        if stage not in feeding:
            continue
        if stage_skip_reason(meeting_dir, stage, silent) is not None:
            # run() will not execute it, so it cannot restale the transcript.
            continue
        if not stage_outputs(meeting_dir, stage) or is_fresh(meeting_dir, stage, params):
            continue
        if not any(path.is_file() for path in stage_inputs(meeting_dir, stage)):
            # Nothing for it to consume, so it cannot rewrite merge's inputs —
            # it will fail the chain on its own terms. Blaming the transcript
            # for that would be a misleading refusal.
            continue
        return True
    return False


#: A stage report that says this is not a cache to reuse, however new its mtime.
#: The case that makes it matter: transcribe fails on ``system`` only, so
#: ``transcribe.json`` still holds the mic words — a re-run that skipped it as
#: "fresh" would merge a transcript containing half the meeting and exit green.
RECORDED_FAILURE_STATUSES = frozenset({STATUS_FAILED, "missing", "refused"})


def stage_report_path(meeting_dir, stage: str):
    """Where a stage records its own ``status``; ``None`` when it records none."""
    meeting_dir = Path(meeting_dir)
    work = work_dir(meeting_dir)
    return {
        "prep_audio": work / "prep_audio.json",
        "gate": gate_json_path(meeting_dir),
        "transcribe": work / "transcribe.json",
        "diarize": diarization_json_path(meeting_dir),
        "merge": work / "merge.json",
        "speakers": speakers_json_path(meeting_dir),
    }.get(stage)


def read_stage_report(meeting_dir, stage: str):
    """A stage's own report as a dict, or ``None`` when there is no readable one."""
    path = stage_report_path(meeting_dir, stage)
    if path is None or not path.is_file():
        return None
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def recorded_failure(meeting_dir, stage: str) -> bool:
    """True when the stage's own report says it did not produce a usable output.

    Deliberately asymmetric: an absent, unreadable or status-less report is *not*
    treated as a failure — the mtime rule already governs those. This only ever
    turns a would-be cache hit into a re-run when the stage itself wrote down
    that it failed.
    """
    report = read_stage_report(meeting_dir, stage)
    if report is None:
        return False
    return report.get("status") in RECORDED_FAILURE_STATUSES


def recorded_chain(meeting_dir):
    """The chain the 16 kHz wavs on disk were built with; ``None`` when unknown.

    The other side of the omission rule in ``parameters_changed``: not asking for
    a chain means "keep the one that is already there", and a stage that has to
    re-run for an unrelated reason (a re-recorded track, wavs deleted by
    ``--cleanup-wavs``) must not quietly swap ``loudnorm`` back to the stage
    default while it is at it. So an unforced run with no ``--chain`` forwards
    what ``prep_audio.json`` recorded. ``--force`` is excluded by its caller:
    SKILL.md makes it the deliberate way back to a default.

    ``None`` when the tracks disagree as well as when there is no record: with no
    single chain in place there is nothing to preserve, and ``DEFAULT_CHAIN`` is
    then the honest answer rather than one track's chain imposed on the rest.
    """
    report = read_stage_report(meeting_dir, "prep_audio")
    if report is None:
        return None
    chains = {
        entry.get("chain")
        for entry in report.get("tracks") or []
        if isinstance(entry, dict) and entry.get("chain")
    }
    return chains.pop() if len(chains) == 1 else None


def recorded_num_speakers(meeting_dir):
    """The ``--num-speakers`` the diarization on disk was built with, or ``None``.

    ``recorded_chain``'s rule applied to D2's primary control. Without it the
    omission rule held for *freshness* only: a bare re-run correctly left a fresh
    ``diarization.json`` alone, but as soon as anything else forced diarize to
    re-run (a re-recorded track, ``--replace-transcript``, wavs removed by
    ``--cleanup-wavs``) the re-run silently dropped ``--num-speakers`` and
    clustered by ``--threshold`` instead — swapping the control the plan calls
    measurably better for the fallback, and exiting green.
    """
    report = read_stage_report(meeting_dir, "diarize")
    if report is None:
        return None
    recorded = report.get("parameters")
    if not isinstance(recorded, dict):
        return None
    value = recorded.get("num_speakers")
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def recorded_asr_option(meeting_dir, key: str):
    """The ``--language``/``--custom-vocab`` the ASR on disk was run with.

    ``None`` when unknown or when the tracks disagree — same reasoning as
    ``recorded_chain``: with no single value in place there is nothing to
    preserve, and the stage default is then the honest answer.
    """
    report = read_stage_report(meeting_dir, "transcribe")
    if report is None:
        return None
    values = {
        entry.get(key)
        for entry in report.get("tracks") or []
        if isinstance(entry, dict) and entry.get(key)
    }
    return values.pop() if len(values) == 1 else None


def recorded_attendees(meeting_dir):
    """The attendee list ``speakers.json`` was built with; ``()`` when unknown.

    The same preservation rule, and the one with the sharpest edge: ``speakers
    build`` re-run without ``--attendees`` produces a map with no anchors at all,
    so a D8 anchor set established by the first run vanished from every later
    rebuild.
    """
    report = read_stage_report(meeting_dir, "speakers")
    if report is None:
        return ()
    recorded = report.get("attendees")
    if not isinstance(recorded, list):
        return ()
    return tuple(str(name) for name in recorded if str(name).strip())


def normalized_attendees(values) -> list[str]:
    """Raw ``--attendees`` argv → the list ``speakers.json`` will record.

    Mirrors ``speakers.parse_attendees`` composed with ``speakers.clean_name``,
    the same way the path helpers above mirror their owning stage: this driver
    forwards the flag verbatim, so the only way to compare what was asked against
    what was built is to normalise it the same way the owner does.
    """
    out: list[str] = []
    for value in values or []:
        for item in str(value).split(","):
            # clean_name: ':' and '*' would break the transcript line grammar.
            item = " ".join(str(item).replace(":", " ").replace("*", " ").split())
            if item and item not in out:
                out.append(item)
    return out


def parameters_changed(meeting_dir, stage: str, params=None) -> bool:
    """True when the artifact on disk was built with different flags than asked.

    Each stage script already guards its own parameters (``prep_audio.
    previous_chain``, ``transcribe.previous_asr_options``, ``diarize.
    previous_parameters``), but this driver decides freshness *before* invoking
    the script — so without this the script is never called and its guard never
    runs. The symptom is the worst kind: ``--num-speakers 6`` over an existing
    run exits green having re-used the old 2-speaker clustering.

    Same asymmetry as ``recorded_failure``: no readable record means the mtime
    rule governs, not a forced re-run.

    A second asymmetry, and the reason every branch below starts by asking what
    this run actually passed: an **omitted** flag expresses no opinion. It means
    "re-use whatever that artifact was built with", not "rebuild it with the
    stage default" — going back to a default deliberately is what ``--force`` is
    for. Without that rule every documented bare re-run turns destructive as soon
    as the *first* run passed a flag: ``pipeline.py <meeting> --from-stage
    speakers`` (the Teams resume, and the way a hand-corrected ``speakers.json``
    gets re-applied) would read "attendees dropped" out of the absent flag and
    rebuild the map over the correction, and a bare whole-pipeline re-run after a
    ``--num-speakers 4`` one would refuse up front because diarize is "about to
    re-run" and would restale ``transcript.raw.md``.
    """
    if not params:
        return False
    report = read_stage_report(meeting_dir, stage)
    if report is None:
        return False

    if stage == "prep_audio":
        chain = params.get("chain")
        if chain is None:
            return False
        return any(
            isinstance(entry, dict) and entry.get("chain") not in (None, chain)
            for entry in report.get("tracks") or []
        )

    if stage == "transcribe":
        vocab = params.get("custom_vocab")
        # Field by field, so dropping one of the two D6 opt-ins does not read as
        # a change to the other: only the ones this run named are compared.
        asked = {
            key: value
            for key, value in (
                ("language", params.get("language")),
                ("custom_vocab", str(vocab) if vocab else None),
            )
            if value is not None
        }
        if not asked:
            return False
        return any(
            any(entry.get(key) != value for key, value in asked.items())
            for entry in report.get("tracks") or []
            # The isinstance guard belongs in the filter, not the value
            # expression: a filter runs first, so a malformed transcribe.json
            # (``{"tracks": ["oops"]}``) raised AttributeError out of run() —
            # past the stage try/except and out of main(), leaving no
            # pipeline.json at all, which is the one file the skill tells the
            # operator to read after a failure.
            if isinstance(entry, dict)
            # A track with no ASR record (missing/skipped) pins nothing.
            and (
                entry.get("language") is not None
                or entry.get("custom_vocab") is not None
                or entry.get("words") is not None
            )
        )

    if stage == "diarize":
        num_speakers = params.get("num_speakers")
        if num_speakers is None:
            return False
        recorded = report.get("parameters")
        if not isinstance(recorded, dict):
            return False
        return recorded.get("num_speakers") != num_speakers

    if stage == "speakers":
        # Against the *parsed* list, not the raw argv: speakers.json records what
        # `parse_attendees` made of the flag, so comparing one
        # `--attendees "A, B"` string against `["A", "B"]` would never match and
        # the stage would re-run on every invocation that passes attendees.
        wanted = normalized_attendees(params.get("attendees"))
        if not wanted:
            # No attendees asked for. The CLI cannot express "explicitly none"
            # anyway (`--attendees ""` normalises to the same empty list), and
            # reading it as a change is the destructive direction: it would send
            # `speakers build` over a map the operator corrected by hand.
            return False
        recorded = report.get("attendees")
        if not isinstance(recorded, list):
            return False
        return list(recorded) != wanted

    return False


def is_fresh(meeting_dir, stage: str, params=None) -> bool:
    """True when every output exists, none is older than any live input, and the
    flags this run asks for match the ones the artifact was built with.

    ``doctor``, ``dicta_overlay`` and ``verify`` declare no outputs, so they are
    never fresh: the preflight is cheap, the verdict must describe *this* run,
    and ``dicta_overlay``'s decisive input — dicta's append-only ``record.jsonl``
    — lives outside the meeting folder and grows with every dictation, so no
    mtime inside the folder can tell whether its answer is still current. The
    stage costs a fraction of a second and no model, so re-running it is cheaper
    than modelling that.
    """
    outputs = stage_outputs(meeting_dir, stage)
    if not outputs:
        return False
    if not all(path.is_file() for path in outputs):
        return False
    if recorded_failure(meeting_dir, stage):
        return False
    if parameters_changed(meeting_dir, stage, params):
        return False

    declared = stage_inputs(meeting_dir, stage)
    inputs = [path for path in declared if path.is_file()]
    if declared and not inputs:
        # Every input this stage consumes is absent. The output is an orphan,
        # not a cache hit — the Teams path is exactly this: transcript.raw.md
        # exists with no transcribe.json/diarization.json behind it, and calling
        # merge "fresh" there let the whole ASR chain run before merge refused.
        return False
    if not inputs:
        return True

    newest_input = max(path.stat().st_mtime for path in inputs)
    oldest_output = min(path.stat().st_mtime for path in outputs)
    return oldest_output >= newest_input


def labeling_only_stale(meeting_dir, params=None) -> bool:
    """True when ``speakers.json`` is current but the labelled transcript is not.

    The two halves of the ``speakers`` stage have different inputs: ``build``
    derives ``speakers.json`` from ``transcript.raw.md``, ``apply`` derives
    ``transcript.labeled.md`` from ``speakers.json``. When only the second is
    behind — someone corrected the map by hand, or ``apply`` died after a good
    ``build`` — re-running ``build`` would overwrite that map with a freshly
    derived one and lose the correction. So the stage re-runs ``apply`` alone.

    Anything that invalidates the *map* (a newer raw transcript, a recorded
    failure, a changed ``--attendees``) is deliberately not this case: there the
    whole stage has to run, and ``is_fresh`` already says so. A *dropped*
    ``--attendees`` is not one of them — see ``parameters_changed``: the resume
    this exists to serve is documented as the bare
    ``pipeline.py <meeting> --from-stage speakers``, so treating the absent flag
    as a change would rebuild the map on exactly the path that must re-apply it.
    """
    meeting_dir = Path(meeting_dir)
    speakers_json = speakers_json_path(meeting_dir)
    if not speakers_json.is_file():
        return False
    if recorded_failure(meeting_dir, "speakers"):
        return False
    if parameters_changed(meeting_dir, "speakers", params):
        return False

    raw = raw_transcript_path(meeting_dir)
    if not raw.is_file():
        return False
    if speakers_json.stat().st_mtime < raw.stat().st_mtime:
        return False  # the map itself is stale — build has to run again

    labeled = meeting_dir / LABELED_TRANSCRIPT_NAME
    if not labeled.is_file():
        return True
    return labeled.stat().st_mtime < speakers_json.stat().st_mtime


# --- gate results ------------------------------------------------------------


def _read_gate_report(meeting_dir):
    path = gate_json_path(meeting_dir)
    if not path.is_file():
        return None
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def read_silent_tracks(meeting_dir) -> list[str]:
    """The tracks S2 called effectively silent; ``[]`` when there is no gate JSON."""
    report = _read_gate_report(meeting_dir)
    if report is None:
        return []
    silent = report.get("silent_tracks")
    if isinstance(silent, list):
        return [str(track) for track in silent]
    return [
        str(entry.get("track"))
        for entry in report.get("tracks") or []
        if isinstance(entry, dict) and entry.get("effectively_silent")
    ]


def read_under_levelled_tracks(meeting_dir) -> list[str]:
    """Tracks S2 found too quietly recorded for the pinned RMS threshold.

    Deliberately *not* folded into ``read_silent_tracks``: a silent track is
    dropped from the ASR pass, an under-levelled one must be re-levelled and
    re-gated instead. Conflating them is the bug this whole path exists to
    prevent — see ``gate.probe_under_levelled``.
    """
    report = _read_gate_report(meeting_dir)
    if report is None:
        return []
    quiet = report.get("under_levelled_tracks")
    if isinstance(quiet, list):
        return [str(track) for track in quiet]
    return [
        str(entry.get("track"))
        for entry in report.get("tracks") or []
        if isinstance(entry, dict) and entry.get("under_levelled")
    ]


# --- stage argv --------------------------------------------------------------


def _stage_call(stage: str, argv) -> dict:
    return {"stage": stage, "script": stage, "argv": list(argv)}


def relevel_calls(meeting_dir, tracks) -> list[dict]:
    """Re-convert the named tracks at ``loudnorm``, then re-gate everything.

    ``--force`` is not optional here: the 16 kHz output is fresh by mtime, so
    without it prep_audio self-skips and the re-gate re-reads the same too-quiet
    wav. The chain override is deliberate even when the run asked for another
    one — the alternative is honouring ``--chain`` and losing the track, which
    is the failure this exists to prevent. It is recorded per track in
    ``prep_audio.json``, so nothing downstream misreports the provenance.

    The re-gate is run for *all* tracks rather than just the quiet ones: gate.py
    rewrites ``gate.json`` wholesale and carries untouched tracks forward, and a
    full pass keeps that record built by one invocation instead of two.
    """
    target = str(meeting_dir)
    calls = []
    for track in tracks:
        calls.append(
            _stage_call(
                "prep_audio",
                [target, "--track", str(track), "--chain", RELEVEL_CHAIN, "--force"],
            )
        )
    calls.append(_stage_call("gate", [target]))
    return calls


def stage_calls(
    meeting_dir,
    stage: str,
    *,
    chain: str = DEFAULT_CHAIN,
    num_speakers=None,
    attendees=(),
    language=None,
    custom_vocab=None,
    tracks=DEFAULT_TRACKS,
    force: bool = False,
    apply_only: bool = False,
    replace_transcript: bool = False,
) -> list[dict]:
    """The invocation(s) a stage makes, in order.

    ``force`` is forwarded to every stage that keeps its *own* freshness check,
    because this driver's check is not the only one in the way: skipping the
    driver's is necessary but not sufficient, and without the flag the stage
    self-skips while the run log reports ``1 call(s) ok``. ``merge`` is the one
    deliberate exception — see the module docstring.

    ``apply_only`` drops ``speakers build`` from the ``speakers`` stage; the run
    loop sets it from ``labeling_only_stale``.
    """
    target = str(meeting_dir)

    if stage == "doctor":
        # Human render, not --json: the driver reads doctor's *exit code* and
        # never parses its output, so asking for JSON only puts a second
        # document on stdout.
        return [_stage_call(stage, [])]
    if stage == "prep_audio":
        # ``None`` reaches here only from a caller that resolved nothing (``run``
        # always passes a chain); prep_audio's own default is this same value.
        argv = [target, "--chain", chain or DEFAULT_CHAIN]
        if force:
            argv.append("--force")
        return [_stage_call(stage, argv)]
    if stage == "gate":
        # gate.py has no freshness check of its own — it re-reads the wavs every
        # time — so there is no --force to forward.
        return [_stage_call(stage, [target])]
    if stage == "transcribe":
        argv = [target]
        for track in tracks:
            argv += ["--track", track]
        # Both are D6 opt-ins and both are off by default; forwarded so the
        # documented single-invocation path can reach them at all.
        if language:
            argv += ["--language", str(language)]
        if custom_vocab:
            argv += ["--custom-vocab", str(custom_vocab)]
        if force:
            argv.append("--force")
        return [_stage_call(stage, argv)]
    if stage == "diarize":
        # D5: never `--track mic`, whatever else is asked of this driver.
        argv = ["run", target, "--track", DIARIZED_TRACK]
        if num_speakers is not None:
            argv += ["--num-speakers", str(num_speakers)]
        if force:
            argv.append("--force")
        return [_stage_call(stage, argv)]
    if stage == "merge":
        # No --force unless the operator asked for exactly that by name:
        # transcript.raw.md's overwrite protection is not this driver's to lift on
        # its own. ``--replace-transcript`` is the one way in, and it exists
        # because the refusal's other escape is unreachable for a parameter change
        # — see ``run``.
        argv = [target]
        if replace_transcript:
            argv.append("--force")
        return [_stage_call(stage, argv)]
    if stage == "speakers":
        apply_call = _stage_call(stage, ["apply", target])
        if apply_only:
            # The map on disk is the one to apply — rebuilding it would discard a
            # hand correction. See ``labeling_only_stale``.
            return [apply_call]
        build = ["build", target]
        for value in attendees:
            build += ["--attendees", value]
        return [_stage_call(stage, build), apply_call]
    if stage == "dicta_overlay":
        # No --force to forward: the stage declares no outputs and so is never
        # taken as fresh in the first place.
        return [_stage_call(stage, [target])]
    if stage == "verify":
        return [_stage_call(stage, [target])]
    raise SelectionError(f"unknown stage: {stage}")  # pragma: no cover - guarded


# --- the run -----------------------------------------------------------------


def run(
    meeting_dir,
    *,
    chain=None,
    num_speakers=None,
    attendees=(),
    language=None,
    custom_vocab=None,
    from_stage=None,
    only=(),
    force: bool = False,
    replace_transcript: bool = False,
    cleanup_wavs: bool = False,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Drive the selected stages and build the run log.

    A ``None`` (or empty) parameter is "not asked for" and is what the bare CLI
    re-run produces — see the ``recorded_*`` helpers and the omission rule in
    ``parameters_changed``. Each resolves to what the artifact on disk was built
    with, or to the stage default on a folder that has no record and under
    ``--force``.
    """
    meeting_dir = Path(meeting_dir)
    runner = runner or default_runner
    selected = select_stages(from_stage=from_stage, only=only)
    attendees = tuple(attendees or ())
    # The chain prep_audio is actually invoked with. Kept apart from
    # ``params["chain"]`` below on purpose: freshness is judged against what this
    # run *asked* for, so resolving the omission into the params dict would make
    # every bare re-run look like an explicit `--chain denoise` again.
    if chain is not None:
        effective_chain = chain
    elif force:
        # `--force` is the documented deliberate way back to a stage default, so
        # a forced rebuild uses what this run asked for — here, nothing.
        effective_chain = DEFAULT_CHAIN
    else:
        effective_chain = recorded_chain(meeting_dir) or DEFAULT_CHAIN

    # The same omission rule for the other four flags. It used to cover ``chain``
    # alone, which made it a half-rule: the *freshness* side held for all five
    # (``parameters_changed`` returns False for an omitted flag), but the
    # *invocation* side did not, so an omitted flag was preserved only for as long
    # as the stage did not have to re-run for some unrelated reason. The moment it
    # did, the re-run reverted to the stage default and exited green — with
    # ``quality.md`` then contradicting the previous run's provenance. All four
    # values are already on disk; nothing here asks the operator to repeat them.
    if num_speakers is not None or force:
        effective_num_speakers = num_speakers
    else:
        effective_num_speakers = recorded_num_speakers(meeting_dir)
    if language is not None or force:
        effective_language = language
    else:
        effective_language = recorded_asr_option(meeting_dir, "language")
    if custom_vocab is not None or force:
        effective_custom_vocab = custom_vocab
    else:
        effective_custom_vocab = recorded_asr_option(meeting_dir, "custom_vocab")
    if attendees or force:
        effective_attendees = attendees
    else:
        effective_attendees = recorded_attendees(meeting_dir)

    # What every freshness decision in this run is measured against: a cache hit
    # has to match these, not just the mtimes. The *asked-for* values, not the
    # resolved ones — resolving the omission in here would make every bare re-run
    # look like an explicit re-request of the recorded flag.
    params = {
        "chain": chain,
        "num_speakers": num_speakers,
        "attendees": list(attendees),
        "language": language,
        "custom_vocab": custom_vocab,
    }

    report = {
        "stage": "pipeline",
        "meeting_dir": str(meeting_dir),
        "selected_stages": list(selected),
        # The resolved ones throughout: these fields are provenance, and they have
        # to name what the stages ran under, not the absence of a flag.
        "chain": effective_chain,
        "num_speakers": effective_num_speakers,
        "attendees": list(effective_attendees),
        "language": effective_language,
        "custom_vocab": (
            str(effective_custom_vocab) if effective_custom_vocab else None
        ),
        "forced": bool(force),
        "replace_transcript": bool(replace_transcript),
        "cleanup_wavs": bool(cleanup_wavs),
        "silent_tracks": [],
        "under_levelled_tracks": [],
        "relevelled_tracks": [],
        "stages": [],
        "cleanup": {"requested": bool(cleanup_wavs), "removed": []},
    }

    silent = read_silent_tracks(meeting_dir)
    report["silent_tracks"] = list(silent)
    report["under_levelled_tracks"] = read_under_levelled_tracks(meeting_dir)
    started = clock()
    stopped = None

    # Before the merge check, because this one is a plain contradiction in the
    # command line rather than a state on disk: a flag no selected stage can
    # consume would otherwise be dropped in silence and the run would exit green
    # having ignored it.
    orphaned = unconsumable_parameters(selected, params)
    if orphaned:
        report.update(
            {
                "status": STATUS_REFUSED,
                "detail": (
                    f"{', '.join(orphaned)} cannot be honoured by this stage "
                    f"selection ({', '.join(selected)}): no selected stage "
                    "consumes it, so the run would exit green having ignored it. "
                    "Either widen the selection to include the owning stage "
                    "(with --replace-transcript if that rebuilds "
                    f"{RAW_TRANSCRIPT_NAME}), or drop the flag."
                ),
                "stages": [
                    {
                        "stage": stage,
                        "calls": [],
                        "elapsed_seconds": 0.0,
                        "status": STATUS_SKIPPED,
                        "detail": "not reached",
                    }
                    for stage in selected
                ],
                "total_seconds": round(clock() - started, 3),
            }
        )
        return report

    # Before running anything: `--force` is deliberately not forwarded to
    # merge.py, so a merge that would have to overwrite transcript.raw.md will
    # refuse (exit 2) no matter how long the ASR pass before it took. Say so up
    # front instead of burning minutes of transcription to reach an opaque
    # "merge exited 2" — and never quietly carry on past it, since speakers and
    # verify would then describe a transcript that predates this run.
    if not replace_transcript and merge_would_refuse(
        meeting_dir, selected, force=force, params=params
    ):
        report.update(
            {
                "status": STATUS_REFUSED,
                "detail": (
                    f"{RAW_TRANSCRIPT_NAME} exists and this run would have to "
                    + ("re-merge over it (--force)" if force else "rebuild it")
                    + ", but --force is not forwarded to merge. Either replace it "
                    "deliberately by re-running this with `--replace-transcript`, "
                    "or keep it and resume with `--from-stage speakers`."
                ),
                "stages": [
                    {
                        "stage": stage,
                        "calls": [],
                        "elapsed_seconds": 0.0,
                        "status": STATUS_SKIPPED,
                        "detail": "not reached",
                    }
                    for stage in selected
                ],
                "total_seconds": round(clock() - started, 3),
            }
        )
        return report

    for stage in selected:
        entry = {"stage": stage, "calls": [], "elapsed_seconds": 0.0}
        report["stages"].append(entry)
        stage_started = clock()

        if not force and is_fresh(meeting_dir, stage, params):
            entry["status"] = STATUS_SKIPPED
            entry["detail"] = "outputs are fresh (--force reruns it)"
            continue

        tracks = DEFAULT_TRACKS
        if stage == "transcribe":
            tracks = tuple(t for t in DEFAULT_TRACKS if t not in silent)
            if not tracks:
                entry["status"] = STATUS_SKIPPED
                entry["detail"] = (
                    "every track is effectively silent (S2) — no ASR pass is "
                    "worth running"
                )
                stopped = (
                    STATUS_SILENT,
                    "gate found no speech on any track — stopping before ASR",
                )
                break
            if silent:
                entry["skipped_tracks"] = list(silent)

        # Shared with ``merge_would_refuse`` so the pre-check cannot disagree
        # with what actually happens here.
        skip_reason = stage_skip_reason(meeting_dir, stage, silent)
        if skip_reason is not None:
            entry["status"] = STATUS_SKIPPED
            entry["detail"] = skip_reason
            continue

        # `speakers` re-runs for two different reasons and they want different
        # calls: a stale map needs build+apply, a map that is merely newer than
        # the labelled transcript needs apply alone.
        apply_only = (
            stage == "speakers"
            and not force
            and labeling_only_stale(meeting_dir, params)
        )
        if apply_only:
            entry["apply_only"] = True

        calls = stage_calls(
            meeting_dir,
            stage,
            chain=effective_chain,
            num_speakers=effective_num_speakers,
            attendees=effective_attendees,
            language=effective_language,
            custom_vocab=effective_custom_vocab,
            tracks=tracks,
            force=force,
            apply_only=apply_only,
            replace_transcript=replace_transcript,
        )

        failed = False
        crash = None
        for call in calls:
            # A stage that raises instead of exiting is still a stage failure,
            # not a driver crash: letting it propagate would skip write_run_json
            # and leave no pipeline.json at all — the one file the skill tells
            # the operator to read after a failure. The traceback still goes to
            # stderr so nothing is swallowed.
            try:
                code = int(runner(dict(call)))
            except Exception:  # noqa: BLE001 - deliberately broad, see above
                crash = traceback.format_exc()
                print(crash, file=sys.stderr, end="")
                code = EXIT_FAILED
            entry["calls"].append(
                {"script": call["script"], "argv": list(call["argv"]), "exit_code": code}
            )
            if code != 0:
                failed = True
                # `speakers apply` only ever follows a successful `build`.
                break

        entry["elapsed_seconds"] = round(clock() - stage_started, 3)
        if failed:
            entry["status"] = STATUS_FAILED
            if crash:
                entry["detail"] = f"{stage} raised {crash.strip().splitlines()[-1]}"
                entry["traceback"] = crash
            else:
                entry["detail"] = f"{stage} exited {entry['calls'][-1]['exit_code']}"
            stopped = (STATUS_FAILED, f"{stage} failed — artifacts left in place")
            break

        entry["status"] = STATUS_OK
        entry["detail"] = (
            f"{len(entry['calls'])} call(s) ok"
            + (
                " — speakers.json is newer than transcript.labeled.md, so the "
                "existing map was re-applied, not rebuilt"
                if apply_only
                else ""
            )
        )

        if stage == "gate":
            # A track that gated as under-levelled is re-levelled and re-gated
            # *here*, before `silent` is read for the ASR pass — otherwise this
            # driver drops it and the run ends green with half a conversation
            # missing. One pass only: if loudnorm does not rescue it, the track
            # is genuinely silent and the second gate says so.
            quiet = read_under_levelled_tracks(meeting_dir)
            if quiet:
                entry["under_levelled_tracks"] = list(quiet)
                relevel_failed = False
                for call in relevel_calls(meeting_dir, quiet):
                    try:
                        code = int(runner(dict(call)))
                    except Exception:  # noqa: BLE001 - as in the main call loop
                        crash = traceback.format_exc()
                        print(crash, file=sys.stderr, end="")
                        code = EXIT_FAILED
                    entry["calls"].append(
                        {
                            "script": call["script"],
                            "argv": list(call["argv"]),
                            "exit_code": code,
                        }
                    )
                    if code != 0:
                        relevel_failed = True
                        break
                entry["relevelled_tracks"] = [] if relevel_failed else list(quiet)
                still_quiet = read_under_levelled_tracks(meeting_dir)
                entry["relevel_detail"] = (
                    f"re-levelled {', '.join(quiet)} with --chain "
                    f"{RELEVEL_CHAIN} and re-gated"
                    + (
                        f"; still under-levelled: {', '.join(still_quiet)}"
                        if still_quiet
                        else ""
                    )
                    if not relevel_failed
                    else f"could not re-level {', '.join(quiet)} — see the call log"
                )
                report["relevelled_tracks"] = entry["relevelled_tracks"]
                # Re-stated, not appended to: the count was rendered before the
                # re-level calls existed, so it would under-report them.
                entry["detail"] = (
                    f"{len(entry['calls'])} call(s) ok — {entry['relevel_detail']}"
                )

            silent = read_silent_tracks(meeting_dir)
            report["silent_tracks"] = list(silent)
            report["under_levelled_tracks"] = read_under_levelled_tracks(meeting_dir)

    # A stop leaves the rest of the chain unrun: log those too, so the run
    # record answers "what did *not* happen" without a diff against STAGES.
    logged = {entry["stage"] for entry in report["stages"]}
    for stage in selected:
        if stage not in logged:
            report["stages"].append(
                {
                    "stage": stage,
                    "calls": [],
                    "elapsed_seconds": 0.0,
                    "status": STATUS_SKIPPED,
                    "detail": "not reached",
                }
            )

    for entry in report["stages"]:
        entry.setdefault("status", STATUS_SKIPPED)
        entry.setdefault("detail", "not reached")

    if stopped:
        report["status"], report["detail"] = stopped
    else:
        report["status"] = STATUS_OK
        report["detail"] = f"{len(selected)} stage(s) ok"

    report["total_seconds"] = round(clock() - started, 3)

    # Disk risk (PLAN.md §6): the intermediates go only after a green run that
    # actually reached the quality gates. ``report["status"]`` alone says "the
    # *selected* stages passed", which under `--only doctor` or
    # `--only prep_audio` is green without a single gate having been evaluated —
    # so the wavs were deleted on an unverified meeting, and re-prepping them
    # means re-running ffmpeg over the whole recording.
    verified = any(
        entry["stage"] == "verify" and entry["status"] == STATUS_OK
        for entry in report["stages"]
    )
    if cleanup_wavs and report["status"] == STATUS_OK and verified:
        report["cleanup"]["removed"] = cleanup_intermediates(meeting_dir)
        report["cleanup"]["detail"] = "16 kHz intermediates removed after a green run"
    elif cleanup_wavs and report["status"] == STATUS_OK:
        report["cleanup"]["detail"] = (
            "kept: this run did not run verify to a pass, so nothing has "
            "confirmed the transcript these wavs produced"
        )
    elif cleanup_wavs:
        report["cleanup"]["detail"] = (
            "kept: the run did not end green and a re-run needs them"
        )

    return report


def cleanup_intermediates(meeting_dir) -> list[str]:
    """Delete the 16 kHz wavs and any orphaned partials; returns what was removed.

    ``prep_audio`` writes through ``<track>.16k.part.wav`` and renames on
    success, unlinking the temp only when ffmpeg *exits* non-zero — a killed
    ffmpeg leaves it behind. That shape does not match ``*.16k.wav``, so without
    the second glob ~115 MB/h/track survives a cleanup that reports success.
    """
    work = work_dir(meeting_dir)
    candidates = sorted(
        set(work.glob(f"*{INPUT_SUFFIX}")) | set(work.glob(f"*{PARTIAL_SUFFIX}"))
    )
    removed = []
    for path in candidates:
        try:
            path.unlink()
        except OSError:  # pragma: no cover - the caller keeps going either way
            continue
        removed.append(path.name)
    return removed


# --- CLI ---------------------------------------------------------------------


def write_run_json(meeting_dir, report: dict) -> Path:
    path = run_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def read_quality_md(meeting_dir):
    path = quality_md_path(meeting_dir)
    if not path.is_file():
        return None
    try:
        return path.read_text(encoding="utf-8")
    except OSError:  # pragma: no cover - unreadable file, nothing to report
        return None


def verify_failed(report: dict) -> bool:
    """True when the verify stage itself is what tripped."""
    return any(
        entry["stage"] == "verify" and entry.get("status") == STATUS_FAILED
        for entry in report.get("stages") or []
    )


def render_human(report: dict) -> str:
    lines = [
        f"acta-notes pipeline — {report['status'].upper()} "
        f"({report['total_seconds']:.1f}s) — {report['detail']}"
    ]
    for entry in report["stages"]:
        marker = {
            STATUS_OK: "ok  ",
            STATUS_SKIPPED: "skip",
            STATUS_FAILED: "FAIL",
        }.get(entry["status"], entry["status"])
        lines.append(
            f"  [{marker}] {entry['stage']:<11} {entry.get('detail', '')} "
            f"({entry.get('elapsed_seconds', 0.0):.1f}s)"
        )
    if report.get("relevelled_tracks"):
        lines.append(
            f"  re-levelled (was too quiet for the RMS gate, --chain "
            f"{RELEVEL_CHAIN}): {', '.join(report['relevelled_tracks'])}"
        )
    if report.get("under_levelled_tracks"):
        lines.append(
            f"  ⚠ still under-levelled: {', '.join(report['under_levelled_tracks'])}"
        )
    if report["silent_tracks"]:
        lines.append(f"  silent tracks: {', '.join(report['silent_tracks'])}")
    if report["cleanup"].get("removed"):
        lines.append(f"  removed: {', '.join(report['cleanup']['removed'])}")
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] == STATUS_OK:
        return EXIT_OK
    if report["status"] == STATUS_REFUSED:
        return EXIT_USAGE
    return EXIT_FAILED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pipeline.py",
        description=(
            "Drive the acta-notes machine chain (S1–S6) over one meeting "
            "folder: doctor → prep_audio → gate → transcribe → diarize → merge "
            "→ speakers build → speakers apply → verify. The Teams converter is "
            "never invoked from here — it replaces S1–S5, after which this "
            "driver resumes with `--from-stage speakers`."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--chain",
        choices=CHAIN_CHOICES,
        # No argparse default, deliberately. Every other flag here expresses "no
        # opinion" by being absent, and the freshness rule reads that as "keep
        # what the artifact was built with"; a default string would turn each
        # bare re-run of a `--chain loudnorm` meeting into an explicit request
        # for `denoise` — restaling prep_audio and, with a transcript.raw.md on
        # disk, refusing the run before it starts.
        default=None,
        help=(
            "preprocessing filter chain handed to prep_audio.py (default: "
            "denoise; omitted on a re-run keeps the chain the existing 16 kHz "
            "wavs were built with)"
        ),
    )
    parser.add_argument(
        "--num-speakers",
        type=int,
        metavar="N",
        help=(
            "attendee count, forwarded to diarize.py. The primary control when "
            "it is known; omitting it falls back to the 0.75 threshold"
        ),
    )
    parser.add_argument(
        "--attendees",
        action="append",
        default=[],
        metavar="NAMES",
        help=(
            "comma-separated attendee names forwarded to `speakers build` "
            "(repeatable). Absent, the build still runs anchor-only (D8)"
        ),
    )
    parser.add_argument(
        "--language",
        metavar="LANG",
        help=(
            "opt-in language hint forwarded to transcribe.py (e.g. ru). Off by "
            "default: Parakeet auto-LIDs and pinning it did not move WER (D6)"
        ),
    )
    parser.add_argument(
        "--custom-vocab",
        metavar="FILE",
        help=(
            "opt-in hotword list forwarded to transcribe.py. Off by default: "
            "hotwords carry a false-substitution risk (D6)"
        ),
    )
    parser.add_argument(
        "--from-stage",
        choices=STAGES,
        metavar="STAGE",
        help=(
            "start here and run to the end. `--from-stage speakers` is the "
            "Teams resume point and needs only transcript.raw.md. "
            f"Stages: {', '.join(STAGES)}"
        ),
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        choices=STAGES,
        metavar="STAGE",
        help="run just this stage (repeatable; canonical order is preserved)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help=(
            "run every selected stage even when its outputs are fresh. NOT "
            "forwarded to merge.py — replacing transcript.raw.md stays a "
            "deliberate `merge.py --force`"
        ),
    )
    parser.add_argument(
        "--replace-transcript",
        action="store_true",
        help=(
            "forward --force to merge.py, replacing an existing "
            f"{RAW_TRANSCRIPT_NAME}. The one way past the up-front merge "
            "refusal: without it, a run that would rebuild the transcript "
            "refuses (exit 2, nothing executed)"
        ),
    )
    parser.add_argument(
        "--cleanup-wavs",
        action="store_true",
        help=(
            "delete the 16 kHz intermediates after a run that ends green; a "
            "tripped hard gate keeps them"
        ),
    )
    parser.add_argument("--json", action="store_true", help="print the run JSON")
    return parser


def main(argv=None, runner=None, clock=time.monotonic) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")
    # Same check transcribe.py makes, made here so a typo costs nothing instead
    # of surfacing after prep_audio and gate have already run.
    if args.custom_vocab and not Path(args.custom_vocab).is_file():
        parser.error(f"no such custom-vocab file: {args.custom_vocab}")

    # Stages are driven in-process and print to this process's stdout. Under
    # --json that would interleave their human renders with the run JSON and
    # make the documented `pipeline.py … --json | jq` unparseable, so their
    # output is moved to stderr — still visible, just not on the JSON channel.
    with contextlib.ExitStack() as stack:
        if args.json:
            stack.enter_context(contextlib.redirect_stdout(sys.stderr))
        try:
            report = run(
                meeting_dir,
                chain=args.chain,
                num_speakers=args.num_speakers,
                attendees=tuple(args.attendees),
                language=args.language,
                custom_vocab=args.custom_vocab,
                from_stage=args.from_stage,
                only=tuple(args.only),
                force=args.force,
                replace_transcript=args.replace_transcript,
                cleanup_wavs=args.cleanup_wavs,
                runner=runner,
                clock=clock,
            )
        except SelectionError as exc:
            parser.error(str(exc))
            return EXIT_USAGE  # pragma: no cover - parser.error raises

    write_run_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))

    # A tripped gate must be readable without opening a file: verify's block
    # goes to stderr, and every artifact stays where it is. Only verify's own
    # failure prints it — after an earlier stage failed, any quality.md on disk
    # describes a previous run and would be a lie here.
    if verify_failed(report):
        quality = read_quality_md(meeting_dir)
        if quality:
            print(quality, file=sys.stderr)

    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
