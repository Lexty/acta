#!/usr/bin/env python3
"""acta-notes S4 — offline VBx diarization of the system track (D2, D4, D5).

Two modes, one binary::

    diarize.py run   <meeting> --track system [--num-speakers N | --threshold T]
    diarize.py score <meeting> --rttm <ground-truth.rttm>

``run`` drives::

    fluidaudiocli process <meeting>/.acta-notes/system.16k.wav --mode offline \\
        --output <meeting>/.acta-notes/system.diar.raw.json \\
        --min-segment-duration 1.0 --min-gap-duration 0.1 \\
        (--num-speakers N | --threshold 0.75)

and normalizes the result into ``<meeting>/diarization.json`` — the per-meeting
machine artifact PLAN.md §2 lists next to ``speakers.json``, not a working file
(the CLI's own JSON stays in ``.acta-notes/`` beside it).

**D2 — offline VBx is the only diarizer v1 ever runs.** ``--mode offline`` selects
segmentation → WeSpeaker embeddings → VBx clustering over the
``speaker-diarization`` model. The streaming engines that are also on disk
(``sortformer``, ``ls-eend``) are never selected; none of their flags is ever
emitted (see ``STREAMING_ONLY_FLAGS``, asserted by the tests).

**D2 — the shipped clustering default is wrong for this audio.** Measured on an
8-min slice of a ≥5-speaker meeting: ``--threshold 0.6`` (the CLI default)
collapses to 2 speakers with **2 s** on the second. So the control is explicit,
always:

* ``--num-speakers N`` — the primary control, seeded from the attendee list.
  Measured: 4/5/6 all produce plausible distributions where auto-detection does not.
* ``--threshold 0.75`` — the fallback when the count is unknown (measured: 4
  speakers). **0.6 is never emitted**, and passing it explicitly is refused.

**Shipped segmentation defaults are emitted explicitly, on purpose.**
``--min-segment-duration 1.0`` and ``--min-gap-duration 0.1`` match the CLI's
current defaults. Emitting them anyway makes the provenance line honest, gives
the deferred sweep harness a named baseline to beat, and turns a future upstream
default change into a non-event. Both are overridable; whatever is used lands in
the stage JSON.

**D5 — ``--track`` is required and is the enforcement mechanism.** The mic track
is ``Я`` by construction: one speaker, known in advance, no model needed. Asking
for ``--track mic`` exits ``2`` **without invoking the binary at all**. This is
deliberately an argument check and not a filename sniff — a renamed file must not
be able to buy a diarization pass over the user's own microphone.

**D4 — ``--rttm`` is an input, not an output.** It feeds hand-annotated ground
truth in and makes the CLI compute DER/JER itself; ``score`` mode captures those
numbers into ``.acta-notes/der.json`` as the baseline future tuning must beat.
Speaker turns always come out of ``--output``, never out of an RTTM.

Embeddings (256-d per segment, ~3.5 MB a meeting) are **stripped by default** and
retained with ``--keep-embeddings`` — the deferred Phase-2b voice roster is what
needs them; nothing in v1 reads them.

The binary comes from ``ACTA_FLUIDAUDIO_BIN`` when set, otherwise the bootstrap
cache path — so tests point the stage at a stub and nothing else changes.

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: Where bootstrap.sh leaves the binary when ACTA_FLUIDAUDIO_BIN is unset. Kept
#: in sync with doctor.py's FLUIDAUDIO_BIN_RELPATH by test_layout.py.
CACHE_BIN_RELPATH = (
    Path(".cache") / "acta-notes" / "fluidaudio" / ".build" / "release" / "fluidaudiocli"
)

#: The only track a model is allowed to run on (D5).
DIARIZED_TRACK = "system"
#: `Я` by construction — refused, loudly, before any work.
MIC_TRACK = "mic"
TRACK_CHOICES = (DIARIZED_TRACK, MIC_TRACK)

MIC_REFUSAL = (
    "refusing --track mic: the mic track is `Я` by construction (D5) — one "
    "speaker, known in advance, so no model runs on it. Diarize the system "
    "track instead."
)

#: v1's diarizer. `--mode offline` is a constant, not a flag default: the
#: streaming engines are a different quality regime and are never selected.
DIARIZATION_MODE = "offline"
DIARIZER = "offline-vbx"
DIARIZATION_MODEL = "speaker-diarization"

#: Flags that only exist in the CLI's streaming mode. None of them may ever
#: appear in an argv this module builds — test_diarize.py asserts it.
STREAMING_ONLY_FLAGS = (
    "--chunk-seconds",
    "--overlap-seconds",
    "--min-speech-duration",
    "--min-silence-gap",
    "--min-active-frames",
    "--num-clusters",
    "--min-embed-update",
)

#: Used when the attendee count is unknown. Measured 07-29: 4 speakers with a
#: plausible spread, where 0.30/0.45 find 1 and the 0.6 default finds 2 (the
#: second holding 2 s of speech).
FALLBACK_THRESHOLD = 0.75

#: The CLI's own default. Measured to collapse this audio; never emitted, and
#: refused when asked for explicitly.
FORBIDDEN_THRESHOLD = 0.6

#: The CLI's shipped segmentation defaults, restated so they are provenance
#: rather than an assumption about someone else's release notes.
DEFAULT_MIN_SEGMENT_DURATION = 1.0
DEFAULT_MIN_GAP_DURATION = 0.1

WORK_DIRNAME = ".acta-notes"
#: PLAN.md §2 lists this at the meeting root, beside speakers.json — it is the
#: machine artifact later stages read, not a working file.
STAGE_JSON_NAME = "diarization.json"
DER_JSON_NAME = "der.json"
INPUT_SUFFIX = ".16k.wav"
RAW_JSON_SUFFIX = ".diar.raw.json"
SCORE_RAW_JSON_SUFFIX = ".diar.score.raw.json"

#: Stable, first-appearance-ordered labels. The CLI's own speakerId strings are
#: kept alongside them; merge.py and speakers.py address speakers by label.
LABEL_PREFIX = "SPK_"

STATUS_OK = "ok"
STATUS_SKIPPED = "skipped"
STATUS_REFUSED = "refused"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"

EXIT_OK = 0
EXIT_FAILED = 1
#: Both the argparse convention and the D5 refusal — a caller that asked for
#: something this stage will not do, not a stage that tried and failed.
EXIT_USAGE = 2

#: Four hours of wall clock for one diarization call. Well above what VBx needs
#: for a long meeting — the ceiling exists so a wedged binary produces a report
#: instead of a run (or a DER sweep) that never ends.
DEFAULT_TIMEOUT_SECONDS = 14400.0
TIMEOUT_ENV_VAR = "ACTA_DIARIZE_TIMEOUT"
#: The shell's convention for "killed by a timeout", so the report is readable.
TIMEOUT_EXIT_CODE = 124
#: The shell's convention for "command found but could not be invoked".
SPAWN_FAILED_EXIT_CODE = 126


# --- binary resolution -------------------------------------------------------


def resolve_fluidaudio_bin(environ=None, home=None):
    """Resolve fluidaudiocli: ``ACTA_FLUIDAUDIO_BIN`` override, then the cache.

    Returns ``(path, source)``. PATH is deliberately not searched: the pin is a
    specific build, and another ``fluidaudiocli`` would cluster with an unknown
    model version — which also silently invalidates any stored embedding.
    """
    environ = os.environ if environ is None else environ
    override = environ.get("ACTA_FLUIDAUDIO_BIN")
    if override:
        return Path(override), "env:ACTA_FLUIDAUDIO_BIN"
    home = Path(home) if home is not None else Path(environ.get("HOME") or Path.home())
    return home / CACHE_BIN_RELPATH, "cache-default"


def is_executable(path) -> bool:
    p = Path(path)
    return p.is_file() and os.access(str(p), os.X_OK)


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def input_path(meeting_dir, track: str = DIARIZED_TRACK) -> Path:
    """S4 reads S1's 16 kHz output, never the raw track."""
    return work_dir(meeting_dir) / f"{track}{INPUT_SUFFIX}"


def raw_json_path(meeting_dir, track: str = DIARIZED_TRACK) -> Path:
    return work_dir(meeting_dir) / f"{track}{RAW_JSON_SUFFIX}"


def score_raw_json_path(meeting_dir, track: str = DIARIZED_TRACK) -> Path:
    """Scoring never overwrites the run's own CLI output."""
    return work_dir(meeting_dir) / f"{track}{SCORE_RAW_JSON_SUFFIX}"


def stage_json_path(meeting_dir) -> Path:
    return Path(meeting_dir) / STAGE_JSON_NAME


def der_json_path(meeting_dir) -> Path:
    return work_dir(meeting_dir) / DER_JSON_NAME


# --- parameters --------------------------------------------------------------


class ParameterError(ValueError):
    """A control combination this stage refuses to run with."""


def _fmt(value) -> str:
    """Render a float the way the argv should read: ``1.0``, ``0.1``, ``0.75``."""
    return str(float(value))


def resolve_parameters(
    num_speakers=None,
    threshold=None,
    min_segment_duration=DEFAULT_MIN_SEGMENT_DURATION,
    min_gap_duration=DEFAULT_MIN_GAP_DURATION,
) -> dict:
    """Decide the clustering control and record it as provenance.

    ``--num-speakers`` wins when it is known; otherwise the threshold falls back
    to 0.75. The two are mutually exclusive rather than silently co-existing: a
    fixed count makes the threshold inert, and a stage JSON that lists both would
    not describe what actually ran.
    """
    if num_speakers is not None and threshold is not None:
        raise ParameterError(
            "--num-speakers and --threshold are mutually exclusive: a fixed "
            "speaker count makes the clustering threshold inert (D2)"
        )
    if num_speakers is not None:
        num_speakers = int(num_speakers)
        if num_speakers < 1:
            raise ParameterError("--num-speakers must be at least 1")
        control, threshold = "num-speakers", None
    else:
        threshold = FALLBACK_THRESHOLD if threshold is None else float(threshold)
        if threshold == FORBIDDEN_THRESHOLD:
            raise ParameterError(
                f"--threshold {FORBIDDEN_THRESHOLD} is the CLI default and is "
                "refused: measured 07-29 it collapses this audio to 2 speakers "
                "with 2 s of speech on the second (D2). Pass --num-speakers from "
                f"the attendee list, or accept the {FALLBACK_THRESHOLD} fallback"
            )
        control = "threshold"
    return {
        "mode": DIARIZATION_MODE,
        "diarizer": DIARIZER,
        "model": DIARIZATION_MODEL,
        "control": control,
        "num_speakers": num_speakers,
        "threshold": threshold,
        "min_segment_duration": float(min_segment_duration),
        "min_gap_duration": float(min_gap_duration),
    }


# --- CLI invocation ----------------------------------------------------------


def build_argv(binary, src, out_json, parameters: dict, rttm=None) -> list[str]:
    """Exact argv for one diarization run.

    ``--mode offline`` and the two segmentation bounds are unconditional; the
    clustering control is whatever ``resolve_parameters`` decided. ``--rttm`` is
    ground-truth *input* (D4) and appears only in ``score`` mode.
    """
    argv = [
        str(binary),
        "process",
        str(src),
        "--mode",
        DIARIZATION_MODE,
        "--output",
        str(out_json),
        "--min-segment-duration",
        _fmt(parameters["min_segment_duration"]),
        "--min-gap-duration",
        _fmt(parameters["min_gap_duration"]),
    ]
    if parameters["control"] == "num-speakers":
        argv += ["--num-speakers", str(parameters["num_speakers"])]
    else:
        argv += ["--threshold", _fmt(parameters["threshold"])]
    if rttm:
        argv += ["--rttm", str(rttm)]
    return argv


def resolve_timeout(environ=None) -> float:
    """Wall-clock ceiling for one diarization call, overridable for a long track."""
    environ = os.environ if environ is None else environ
    raw = (environ.get(TIMEOUT_ENV_VAR) or "").strip()
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def default_runner(argv, timeout=None) -> tuple[int, str]:
    """Run the diarizer; a hang becomes ``TIMEOUT_EXIT_CODE``, not an endless wait.

    ``diarization.json`` and this stage's report are written only after ``run()``
    returns, so an unbounded wait on a wedged binary left nothing on disk to
    diagnose — and this stage may be re-invoked several times by the DER sweep,
    where one hang would strand the whole sweep.
    """
    timeout = resolve_timeout() if timeout is None else timeout
    try:
        proc = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return TIMEOUT_EXIT_CODE, (
            f"fluidaudiocli did not exit within {timeout:g}s and was killed; raise "
            f"{TIMEOUT_ENV_VAR} if this recording is genuinely that long"
        )
    except OSError as exc:
        # ``is_executable`` checks the exec bit, not the file's format, so a
        # wrong-architecture build or a text file at ACTA_FLUIDAUDIO_BIN reaches
        # here and raised an OSError straight out of ``run()`` — losing
        # ``diarization.json`` and, mid-sweep, the whole DER sweep with it. Same
        # contract as the timeout branch: a failed run, not an exception.
        return SPAWN_FAILED_EXIT_CODE, f"could not run fluidaudiocli ({argv[0]}): {exc}"
    return proc.returncode, proc.stderr.decode("utf-8", "replace")


# --- parsing -----------------------------------------------------------------


def as_number(value):
    """``float(value)`` or ``None`` — never raises.

    The CLI's JSON is external input: a field can be present and still not be a
    number. A bare ``float()`` here would escape the stage as a traceback
    instead of a ``failed`` entry, so a non-numeric value is treated exactly
    like a missing one — the segment is dropped.
    """
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_raw_json(path):
    """Parse the CLI's output file. Raises ``ValueError`` on anything unusable."""
    path = Path(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read the CLI output at {path}: {exc}") from exc
    except ValueError as exc:
        raise ValueError(f"the CLI output at {path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"the CLI output at {path} is not a JSON object")
    return data


def parse_segments(raw: dict, keep_embeddings: bool = False) -> list[dict]:
    """Normalize ``segments[]`` into the shape S5 overlaps word timings against.

    The CLI's camelCase and this pipeline's snake_case meet here and nowhere
    else. Segments without usable bounds are dropped rather than passed on as
    ``None``: merge.py sorts and overlaps on these numbers. Labels are assigned
    in first-appearance order, so a re-run over the same audio yields the same
    ``SPK_NN`` for the same voice.
    """
    labels: dict[str, str] = {}
    segments = []
    for item in raw.get("segments") or []:
        if not isinstance(item, dict):
            continue
        start = as_number(item.get("startTimeSeconds"))
        end = as_number(item.get("endTimeSeconds"))
        speaker_id = item.get("speakerId")
        if start is None or end is None or speaker_id is None:
            continue
        if end <= start:
            continue
        speaker_id = str(speaker_id)
        if speaker_id not in labels:
            labels[speaker_id] = f"{LABEL_PREFIX}{len(labels) + 1:02d}"
        quality = as_number(item.get("qualityScore"))
        # External JSON: every other field here goes through ``as_number``, but
        # this one was handed straight to ``len()``, so a scalar ``"embedding": 5``
        # raised a TypeError out of ``run()`` and cost the stage its report.
        embedding = item.get("embedding") or []
        if not isinstance(embedding, (list, tuple)):
            embedding = []
        entry = {
            "start": round(start, 3),
            "end": round(end, 3),
            "duration": round(end - start, 3),
            "speaker": labels[speaker_id],
            "speaker_id": speaker_id,
            "quality": round(quality, 4) if quality is not None else None,
            "embedding_dim": len(embedding) or None,
        }
        if keep_embeddings:
            values = [as_number(v) for v in embedding]
            entry["embedding"] = [v for v in values if v is not None]
        segments.append(entry)
    return segments


def speaker_rollup(segments) -> list[dict]:
    """Per-speaker duration tally, ordered by speech time.

    This is the view that makes D2's failure modes visible without opening the
    transcript: a "sink" speaker holding most of the meeting, or a speaker with
    2 s of speech, are both obvious here.
    """
    rollup: dict[str, dict] = {}
    for segment in segments:
        entry = rollup.setdefault(
            segment["speaker"],
            {
                "speaker": segment["speaker"],
                "speaker_id": segment["speaker_id"],
                "segments": 0,
                "speech_seconds": 0.0,
                "_quality_sum": 0.0,
                "_quality_count": 0,
            },
        )
        entry["segments"] += 1
        entry["speech_seconds"] += segment["duration"]
        if segment.get("quality") is not None:
            entry["_quality_sum"] += segment["quality"]
            entry["_quality_count"] += 1

    out = []
    for entry in rollup.values():
        count = entry.pop("_quality_count")
        total = entry.pop("_quality_sum")
        entry["speech_seconds"] = round(entry["speech_seconds"], 3)
        entry["mean_quality"] = round(total / count, 4) if count else None
        out.append(entry)
    out.sort(key=lambda e: (-e["speech_seconds"], e["speaker"]))
    return out


def parse_metrics(raw: dict):
    """Pull the DER/JER block the CLI computed from the ``--rttm`` ground truth."""
    metrics = raw.get("metrics")
    if not isinstance(metrics, dict):
        return None

    def num(key):
        value = as_number(metrics.get(key))
        return round(value, 6) if value is not None else None

    return {
        "der": num("der"),
        "jer": num("jer"),
        "miss_rate": num("missRate"),
        "false_alarm_rate": num("falseAlarmRate"),
        "speaker_error_rate": num("speakerErrorRate"),
        "speaker_mapping": metrics.get("speakerMapping") or {},
        "collar_seconds": num("evaluationCollarSeconds"),
        "ignores_overlap": metrics.get("evaluationIgnoresOverlap"),
    }


def _fmt_metric(value, spec: str = ".4f") -> str:
    """A rate, or ``n/a`` — every metric but DER may be absent from the block."""
    return "n/a" if value is None else format(value, spec)


def summarize(raw: dict) -> dict:
    """Provenance the CLI reports about its own run."""
    return {
        "audio_duration_seconds": raw.get("durationSeconds"),
        "processing_seconds": raw.get("processingTimeSeconds"),
        "rtfx": raw.get("realTimeFactor"),
        "cli_speaker_count": raw.get("speakerCount"),
    }


# --- freshness ---------------------------------------------------------------


def is_fresh(src, dst) -> bool:
    """True when the CLI output exists, is non-empty and is not older than the wav."""
    src, dst = Path(src), Path(dst)
    if not dst.is_file():
        return False
    try:
        dst_stat, src_stat = dst.stat(), src.stat()
    except OSError:
        return False
    return dst_stat.st_size > 0 and dst_stat.st_mtime >= src_stat.st_mtime


def previous_parameters(meeting_dir):
    """The parameters the existing ``diarization.json`` was produced with."""
    try:
        data = json.loads(stage_json_path(meeting_dir).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data.get("parameters") if isinstance(data, dict) else None


# --- run mode ----------------------------------------------------------------


def _finish(report: dict, raw_path, keep_embeddings: bool) -> dict:
    """Parse a CLI output file into ``report`` and decide the stage's status."""
    try:
        raw = read_raw_json(raw_path)
    except ValueError as exc:
        report.update({"status": STATUS_FAILED, "detail": str(exc)})
        return report

    segments = parse_segments(raw, keep_embeddings=keep_embeddings)
    speakers = speaker_rollup(segments)
    report.update(summarize(raw))
    report["segments"] = segments
    report["speakers"] = speakers
    report["segment_count"] = len(segments)
    report["speaker_count"] = len(speakers)
    report["speech_seconds"] = round(sum(s["duration"] for s in segments), 3)
    report["embeddings_kept"] = bool(keep_embeddings)
    report["embedding_dim"] = next(
        (s["embedding_dim"] for s in segments if s.get("embedding_dim")), None
    )

    if not segments:
        # Not a crash, but nothing downstream can use it: merge.py would label
        # every word unassigned. Loud beats a transcript of SPK-less lines.
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    "the CLI returned no usable speaker segments — the track is "
                    "silent, or clustering collapsed (D2)"
                ),
            }
        )
        return report

    report["status"] = report.get("status") or STATUS_OK
    report.setdefault(
        "detail",
        f"{len(segments)} segment(s) over {len(speakers)} speaker(s)",
    )
    return report


def run(
    meeting_dir,
    track: str,
    num_speakers=None,
    threshold=None,
    min_segment_duration=DEFAULT_MIN_SEGMENT_DURATION,
    min_gap_duration=DEFAULT_MIN_GAP_DURATION,
    keep_embeddings: bool = False,
    force: bool = False,
    environ=None,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Diarize one track. ``--track mic`` is refused before anything happens."""
    meeting_dir = Path(meeting_dir)
    report = {
        "stage": "diarize",
        "meeting_dir": str(meeting_dir),
        "track": track,
        "engine": f"fluidaudiocli process --mode {DIARIZATION_MODE}",
        "forced": bool(force),
        "elapsed_seconds": 0.0,
        "argv": None,
    }

    # D5, first and without a binary in hand: this is an argument check, not a
    # filename sniff, so renaming a file cannot buy a pass over the user's mic.
    if track != DIARIZED_TRACK:
        report.update({"status": STATUS_REFUSED, "detail": MIC_REFUSAL})
        return report

    try:
        parameters = resolve_parameters(
            num_speakers=num_speakers,
            threshold=threshold,
            min_segment_duration=min_segment_duration,
            min_gap_duration=min_gap_duration,
        )
    except ParameterError as exc:
        report.update({"status": STATUS_REFUSED, "detail": str(exc)})
        return report
    report["parameters"] = parameters

    binary, source = resolve_fluidaudio_bin(environ)
    report["binary"] = {"path": str(binary), "source": source}

    src = input_path(meeting_dir, track)
    raw_path = raw_json_path(meeting_dir, track)
    report["input"] = str(src)
    report["raw_json"] = str(raw_path)

    if not src.is_file():
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no 16 kHz track at {src} — run prep_audio.py first",
            }
        )
        return report

    reusable = (
        not force
        and is_fresh(src, raw_path)
        # Same audio *and* same controls: a re-run with a different
        # --num-speakers must not be answered from the previous clustering.
        and previous_parameters(meeting_dir) == parameters
    )
    if reusable:
        report.update(
            {
                "status": STATUS_SKIPPED,
                "detail": "the CLI output is fresh and was produced with these parameters",
            }
        )
        # Re-parsed, not trusted from the previous report: the stage JSON is
        # always complete, whether this run did the work or reused it.
        return _finish(report, raw_path, keep_embeddings)

    if not is_executable(binary):
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    f"fluidaudiocli is not executable at {binary} — run bootstrap.sh "
                    "(or set ACTA_FLUIDAUDIO_BIN)"
                ),
            }
        )
        return report

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    argv = build_argv(binary, src, raw_path, parameters)
    report["argv"] = argv

    runner = runner or default_runner
    started = clock()
    code, stderr = runner(argv)
    report["elapsed_seconds"] = round(clock() - started, 3)

    if code != 0:
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": f"fluidaudiocli exited {code}",
                "exit_code": code,
                "stderr_tail": (stderr or "").strip().splitlines()[-5:],
            }
        )
        return report

    if not raw_path.is_file():
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": f"fluidaudiocli exited 0 but wrote no JSON at {raw_path}",
                "exit_code": code,
            }
        )
        return report

    return _finish(report, raw_path, keep_embeddings)


# --- score mode --------------------------------------------------------------


def score(
    meeting_dir,
    rttm,
    track: str = DIARIZED_TRACK,
    num_speakers=None,
    threshold=None,
    min_segment_duration=DEFAULT_MIN_SEGMENT_DURATION,
    min_gap_duration=DEFAULT_MIN_GAP_DURATION,
    environ=None,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Re-run diarization against hand-annotated ground truth and keep DER/JER.

    D4: ``--rttm`` is an input. The CLI computes the metrics itself and puts them
    in its output JSON; this mode's whole job is to run it with the same
    parameters a real run uses and record the numbers as a baseline.
    """
    meeting_dir = Path(meeting_dir)
    report = {
        "stage": "diarize-score",
        "meeting_dir": str(meeting_dir),
        "track": track,
        "rttm": str(rttm),
        "engine": f"fluidaudiocli process --mode {DIARIZATION_MODE} --rttm",
        "elapsed_seconds": 0.0,
        "argv": None,
        "metrics": None,
    }

    if track != DIARIZED_TRACK:
        report.update({"status": STATUS_REFUSED, "detail": MIC_REFUSAL})
        return report

    try:
        parameters = resolve_parameters(
            num_speakers=num_speakers,
            threshold=threshold,
            min_segment_duration=min_segment_duration,
            min_gap_duration=min_gap_duration,
        )
    except ParameterError as exc:
        report.update({"status": STATUS_REFUSED, "detail": str(exc)})
        return report
    report["parameters"] = parameters

    binary, source = resolve_fluidaudio_bin(environ)
    report["binary"] = {"path": str(binary), "source": source}

    src = input_path(meeting_dir, track)
    raw_path = score_raw_json_path(meeting_dir, track)
    report["input"] = str(src)
    report["raw_json"] = str(raw_path)

    if not src.is_file():
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no 16 kHz track at {src} — run prep_audio.py first",
            }
        )
        return report
    if not Path(rttm).is_file():
        report.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no RTTM ground truth at {rttm}",
            }
        )
        return report
    if not is_executable(binary):
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    f"fluidaudiocli is not executable at {binary} — run bootstrap.sh "
                    "(or set ACTA_FLUIDAUDIO_BIN)"
                ),
            }
        )
        return report

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    argv = build_argv(binary, src, raw_path, parameters, rttm=rttm)
    report["argv"] = argv

    runner = runner or default_runner
    started = clock()
    code, stderr = runner(argv)
    report["elapsed_seconds"] = round(clock() - started, 3)

    if code != 0:
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": f"fluidaudiocli exited {code}",
                "exit_code": code,
                "stderr_tail": (stderr or "").strip().splitlines()[-5:],
            }
        )
        return report

    try:
        raw = read_raw_json(raw_path)
    except ValueError as exc:
        report.update({"status": STATUS_FAILED, "detail": str(exc)})
        return report

    segments = parse_segments(raw)
    report["segment_count"] = len(segments)
    report["speaker_count"] = len(speaker_rollup(segments))
    report.update(summarize(raw))

    metrics = parse_metrics(raw)
    if metrics is None or metrics["der"] is None:
        # A scoring run that produced no number is a failed scoring run: the
        # whole point is the baseline, and "we ran it" is not one.
        report.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    "the CLI reported no DER/JER — check that the RTTM parses and "
                    "covers the same audio"
                ),
            }
        )
        return report

    report["metrics"] = metrics
    report["status"] = STATUS_OK
    # JER is reported separately from DER and an older CLI may omit it; the
    # baseline is the DER, so a missing JER is a gap in the line, not a crash.
    report["detail"] = f"DER {metrics['der']:.4f}, JER {_fmt_metric(metrics['jer'])}"
    return report


# --- output ------------------------------------------------------------------


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = stage_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def write_der_json(meeting_dir, report: dict) -> Path:
    path = der_json_path(meeting_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def _parameter_line(parameters) -> str:
    if not parameters:
        return ""
    control = (
        f"--num-speakers {parameters['num_speakers']}"
        if parameters["control"] == "num-speakers"
        else f"--threshold {_fmt(parameters['threshold'])}"
    )
    return (
        f"  mode {parameters['mode']}, {control}, "
        f"--min-segment-duration {_fmt(parameters['min_segment_duration'])}, "
        f"--min-gap-duration {_fmt(parameters['min_gap_duration'])}"
    )


def render_human(report: dict) -> str:
    lines = [f"acta-notes diarize — {report['status'].upper()} ({report['track']})"]
    line = _parameter_line(report.get("parameters"))
    if line:
        lines.append(line)
    for entry in report.get("speakers") or []:
        quality = entry.get("mean_quality")
        quality = "n/a" if quality is None else f"{quality:.3f}"
        lines.append(
            f"  {entry['speaker']:<7} {entry['speech_seconds']:>8.1f}s  "
            f"{entry['segments']:>4} seg  quality {quality}  ({entry['speaker_id']})"
        )
    if report.get("segment_count") is not None:
        lines.append(
            f"  {report['segment_count']} segments, "
            f"{report.get('speaker_count', 0)} speakers, "
            f"{report.get('elapsed_seconds', 0.0):.1f}s"
        )
    if report["status"] not in (STATUS_OK, STATUS_SKIPPED):
        lines.append("")
        lines.append(report.get("detail", "diarization failed"))
    return "\n".join(lines)


def render_human_score(report: dict) -> str:
    lines = [f"acta-notes diarize score — {report['status'].upper()}"]
    line = _parameter_line(report.get("parameters"))
    if line:
        lines.append(line)
    metrics = report.get("metrics")
    if metrics:
        lines.append(
            f"  DER {_fmt_metric(metrics['der'])}  "
            f"JER {_fmt_metric(metrics['jer'])}  "
            f"miss {_fmt_metric(metrics['miss_rate'])}  "
            f"false-alarm {_fmt_metric(metrics['false_alarm_rate'])}  "
            f"speaker-error {_fmt_metric(metrics['speaker_error_rate'])}"
        )
    if report["status"] != STATUS_OK:
        lines.append("")
        lines.append(report.get("detail", "scoring failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] in (STATUS_OK, STATUS_SKIPPED):
        return EXIT_OK
    if report["status"] == STATUS_REFUSED:
        return EXIT_USAGE
    return EXIT_FAILED


# --- CLI ---------------------------------------------------------------------


def _add_common_parameters(parser) -> None:
    parser.add_argument(
        "--num-speakers",
        type=int,
        metavar="N",
        help=(
            "exact speaker count — the primary control (D2), seeded from the "
            "attendee list. Mutually exclusive with --threshold"
        ),
    )
    parser.add_argument(
        "--threshold",
        type=float,
        metavar="T",
        help=(
            f"clustering threshold used when the count is unknown (default "
            f"{FALLBACK_THRESHOLD}). The CLI's own {FORBIDDEN_THRESHOLD} default "
            "is refused: measured, it collapses this audio to 2 speakers (D2)"
        ),
    )
    parser.add_argument(
        "--min-segment-duration",
        type=float,
        default=DEFAULT_MIN_SEGMENT_DURATION,
        metavar="SEC",
        help=(
            f"minimum segment duration (default {DEFAULT_MIN_SEGMENT_DURATION}, "
            "always emitted explicitly so the provenance line is honest)"
        ),
    )
    parser.add_argument(
        "--min-gap-duration",
        type=float,
        default=DEFAULT_MIN_GAP_DURATION,
        metavar="SEC",
        help=(
            f"merge segments closer than this (default {DEFAULT_MIN_GAP_DURATION}, "
            "always emitted explicitly)"
        ),
    )


def main(argv=None, environ=None, runner=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="diarize.py",
        description=(
            "S4: offline VBx diarization of the system track via "
            "`fluidaudiocli process --mode offline` (D2), plus DER/JER scoring "
            "against a hand-annotated RTTM (D4)."
        ),
    )
    modes = parser.add_subparsers(dest="mode", required=True)

    run_parser = modes.add_parser(
        "run", help="diarize the system track into diarization.json"
    )
    run_parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    run_parser.add_argument(
        "--track",
        required=True,
        choices=TRACK_CHOICES,
        help=(
            "which track to diarize. Required, and the enforcement point for D5: "
            "`mic` exits 2 without invoking the binary — that track is `Я` by "
            "construction"
        ),
    )
    _add_common_parameters(run_parser)
    run_parser.add_argument(
        "--keep-embeddings",
        action="store_true",
        help=(
            "keep the per-segment 256-d embeddings in diarization.json "
            "(~3.5 MB a meeting); the deferred voice roster is what needs them"
        ),
    )
    run_parser.add_argument(
        "--force", action="store_true", help="re-diarize even when the output is fresh"
    )
    run_parser.add_argument("--json", action="store_true", help="print the stage JSON")

    score_parser = modes.add_parser(
        "score", help="compute DER/JER against a hand-annotated RTTM (D4)"
    )
    score_parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    score_parser.add_argument(
        "--rttm",
        required=True,
        metavar="FILE",
        help=(
            "hand-annotated ground truth, an INPUT (D4): the CLI computes DER/JER "
            "against it. Speaker turns always come from --output, never from here"
        ),
    )
    score_parser.add_argument(
        "--track",
        default=DIARIZED_TRACK,
        choices=TRACK_CHOICES,
        help="track to score (default: system; mic is refused, D5)",
    )
    _add_common_parameters(score_parser)
    score_parser.add_argument("--json", action="store_true", help="print the DER JSON")

    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")

    if args.mode == "run":
        report = run(
            meeting_dir,
            track=args.track,
            num_speakers=args.num_speakers,
            threshold=args.threshold,
            min_segment_duration=args.min_segment_duration,
            min_gap_duration=args.min_gap_duration,
            keep_embeddings=args.keep_embeddings,
            force=args.force,
            environ=environ,
            runner=runner,
            clock=clock,
        )
        # A refusal is a caller error, not a stage result: nothing is written,
        # so a stale diarization.json cannot be mistaken for this run's answer.
        # A *failure* is held to the same rule, and for a sharper reason —
        # diarization.json is a durable meeting-root artifact costing minutes of
        # ML, and a re-run on a machine that has lost ACTA_FLUIDAUDIO_BIN would
        # otherwise replace a valid clustering with {"status": "failed"}. The
        # failure is still on stdout and in the exit code.
        if report["status"] in (STATUS_OK, STATUS_SKIPPED):
            write_stage_json(meeting_dir, report)
        print(json.dumps(report, indent=2, ensure_ascii=False) if args.json else render_human(report))
        return exit_code(report)

    report = score(
        meeting_dir,
        rttm=args.rttm,
        track=args.track,
        num_speakers=args.num_speakers,
        threshold=args.threshold,
        min_segment_duration=args.min_segment_duration,
        min_gap_duration=args.min_gap_duration,
        environ=environ,
        runner=runner,
        clock=clock,
    )
    # Same rule as the `run` branch above, and for the same reason: der.json holds
    # the hand-annotated DER/JER baseline every future tuning pass is measured
    # against, and it is expensive to recreate. A missing ACTA_FLUIDAUDIO_BIN, a
    # mistyped --rttm or a non-zero CLI exit must not replace it with a failure
    # document — the failure is still on stdout and in the exit code.
    if report["status"] == STATUS_OK:
        write_der_json(meeting_dir, report)
    print(
        json.dumps(report, indent=2, ensure_ascii=False)
        if args.json
        else render_human_score(report)
    )
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
