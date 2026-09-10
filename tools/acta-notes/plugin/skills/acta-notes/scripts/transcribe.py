#!/usr/bin/env python3
"""acta-notes S3 — Parakeet ASR per track (D1, D3).

Drives the pinned ``fluidaudiocli`` over the 16 kHz mono wavs S1 produced::

    <meeting>/.acta-notes/<track>.16k.wav
        → fluidaudiocli transcribe <wav> --word-timestamps --output-json <raw>
        → <meeting>/.acta-notes/<track>.asr.raw.json   (the CLI's own JSON, kept)
        → <meeting>/.acta-notes/transcribe.json        (the normalized stage JSON)

**D1** pins the engine to Parakeet TDT 0.6B v3 — the CLI's default model version,
so no ``--model-version`` is emitted; whatever the CLI reports is recorded as
provenance instead.

**D3** is why this stage exists in the shape it does: ``transcribe`` really does
emit word-level timings (``wordTimings[] = {word, startTime, endTime,
confidence}``), so S5 can cut utterances on pauses and S4's speaker segments can
be overlapped against them. The per-word confidence that comes along for free is
what makes D8's low-confidence flagging cost nothing later.

**Opt-ins, neither of them default** (D6 measured both as WER-noise):

* ``--language`` — Parakeet auto-LIDs, and pinning ``ru`` did not move WER.
* ``--custom-vocab`` — hotwords carry a false-substitution risk (``при`` → ``IREE``)
  *and* they are the one code path that turns an optional model into a hard
  requirement: v0.15.5 additionally loads ``parakeet-ctc-110m-coreml`` for
  vocabulary boosting. ``doctor.py`` lists that model as optional, so this stage
  records the extra dependency in the stage JSON rather than letting a run
  discover it as a download.

**Failure is loud.** A missing or non-executable binary, a non-zero CLI exit, a
missing/corrupt output JSON, or text-without-timings all fail the stage. There is
no degraded-transcript fallback: a half-transcribed meeting that looks finished is
worse than one that stopped.

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

#: v0.15.5 loads this *in addition* to parakeet-tdt-0.6b-v3 when --custom-vocab
#: is given. doctor.py reports it as optional; --custom-vocab is what promotes it.
CUSTOM_VOCAB_EXTRA_MODEL = "parakeet-ctc-110m-coreml"

DEFAULT_TRACKS = ("mic", "system")

WORK_DIRNAME = ".acta-notes"
STAGE_JSON_NAME = "transcribe.json"
INPUT_SUFFIX = ".16k.wav"
RAW_JSON_SUFFIX = ".asr.raw.json"

STATUS_OK = "ok"
STATUS_EMPTY = "empty"
STATUS_SKIPPED = "skipped"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"
#: A track a previous invocation transcribed and this one was not asked about.
#: Mirrors ``prep_audio.STATUS_CARRIED`` — see ``carry_forward_tracks``.
STATUS_CARRIED = "carried"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

#: Four hours of wall clock for one track. Well above what Parakeet needs for a
#: long meeting on this machine — the ceiling exists so a wedged binary produces a
#: report instead of a run that never ends.
DEFAULT_TIMEOUT_SECONDS = 14400.0
TIMEOUT_ENV_VAR = "ACTA_ASR_TIMEOUT"
#: The shell's convention for "killed by a timeout", so the report is readable.
TIMEOUT_EXIT_CODE = 124
#: The shell's convention for "command found but could not be invoked".
SPAWN_FAILED_EXIT_CODE = 126


# --- binary resolution -------------------------------------------------------


def resolve_fluidaudio_bin(environ=None, home=None):
    """Resolve fluidaudiocli: ``ACTA_FLUIDAUDIO_BIN`` override, then the cache.

    Returns ``(path, source)``. PATH is deliberately not searched: the pin is a
    specific build, and picking up some other ``fluidaudiocli`` would silently
    transcribe with an unknown engine version.
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


def input_path(meeting_dir, track: str) -> Path:
    """S3 reads S1's 16 kHz output, never the raw track."""
    return work_dir(meeting_dir) / f"{track}{INPUT_SUFFIX}"


def raw_json_path(meeting_dir, track: str) -> Path:
    """The CLI's own JSON, kept alongside the normalized stage JSON."""
    return work_dir(meeting_dir) / f"{track}{RAW_JSON_SUFFIX}"


# --- CLI invocation ----------------------------------------------------------


def build_argv(binary, src, raw_json, language=None, custom_vocab=None) -> list[str]:
    """Exact argv for one track.

    ``--word-timestamps --output-json`` are the stage's reason for existing (D3)
    and are never optional. The two opt-ins follow them, in a fixed order, so the
    argv recorded in the stage JSON is reproducible by hand.
    """
    argv = [
        str(binary),
        "transcribe",
        str(src),
        "--word-timestamps",
        "--output-json",
        str(raw_json),
    ]
    if language:
        argv += ["--language", str(language)]
    if custom_vocab:
        argv += ["--custom-vocab", str(custom_vocab)]
    return argv


def resolve_timeout(environ=None) -> float:
    """Wall-clock ceiling for one ASR call, overridable for a long recording."""
    environ = os.environ if environ is None else environ
    raw = (environ.get(TIMEOUT_ENV_VAR) or "").strip()
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def default_runner(argv, timeout=None) -> tuple[int, str]:
    """Run the ASR CLI; a hang becomes ``TIMEOUT_EXIT_CODE``, not an endless wait.

    This stage's JSON is written only after ``run()`` returns, so an unbounded
    wait on a wedged binary left no forensic record at all — the outcome the rest
    of this file's error handling is built to avoid.
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
        # here and raised an OSError straight out of ``run()`` — costing the
        # stage JSON this file's error handling exists to preserve. Same contract
        # as the timeout branch: a failed track, not an exception.
        return SPAWN_FAILED_EXIT_CODE, f"could not run fluidaudiocli ({argv[0]}): {exc}"
    return proc.returncode, proc.stderr.decode("utf-8", "replace")


# --- parsing -----------------------------------------------------------------


def as_number(value):
    """``float(value)`` or ``None`` — never raises.

    The CLI's JSON is external input: a field can be present and still not be a
    number (``"startTime": "n/a"``). A bare ``float()`` here would escape the
    stage as a traceback instead of a ``failed`` entry, so a non-numeric value
    is treated exactly like a missing one — the entry is dropped.
    """
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_word_timings(raw: dict) -> list[dict]:
    """Normalize ``wordTimings[]`` into the flat shape S5 consumes.

    The CLI's camelCase and this pipeline's snake_case meet here and nowhere
    else. Entries missing a word or a start time are dropped rather than passed
    on as ``None``: merge.py sorts and overlaps on these numbers. So are entries
    whose timings are present but not numeric, and — mirroring
    ``diarize.parse_segments`` — entries whose span is reversed or empty.
    """
    words = []
    for item in raw.get("wordTimings") or []:
        if not isinstance(item, dict):
            continue
        word = item.get("word")
        start = as_number(item.get("startTime"))
        end = as_number(item.get("endTime"))
        if not word or start is None or end is None:
            continue
        if end <= start:
            # merge.split_utterances measures the pause as
            # `word["start"] - previous["end"]`, so a reversed end fabricates a
            # gap and splits one utterance into several — and skews the
            # utterance's own max(end). Nothing downstream filters these.
            continue
        confidence = as_number(item.get("confidence"))
        words.append(
            {
                "word": word,
                "start": round(start, 3),
                "end": round(end, 3),
                "confidence": (
                    round(confidence, 4) if confidence is not None else None
                ),
            }
        )
    return words


def confidence_stats(words) -> dict:
    """Mean/min over the per-word confidences, ignoring words that carry none."""
    values = [w["confidence"] for w in words if w.get("confidence") is not None]
    if not values:
        return {"mean_confidence": None, "min_confidence": None, "scored_words": 0}
    return {
        "mean_confidence": round(sum(values) / len(values), 4),
        "min_confidence": round(min(values), 4),
        "scored_words": len(values),
    }


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


def summarize(raw: dict, words) -> dict:
    """Provenance the CLI reports about its own run, recorded verbatim-ish."""
    return {
        "text": raw.get("text") or "",
        "mode": raw.get("mode"),
        "model_version": raw.get("modelVersion"),
        "audio_duration_seconds": raw.get("durationSeconds"),
        "processing_seconds": raw.get("processingTimeSeconds"),
        "rtfx": raw.get("rtfx"),
        "cli_confidence": raw.get("confidence"),
        "timings_confirmed": raw.get("timingsConfirmed"),
        "word_count": len(words),
    }


def previous_asr_options(meeting_dir, track: str):
    """``(language, custom_vocab)`` the existing CLI output for ``track`` used.

    ``None`` when there is no readable record. Mirrors
    ``diarize.previous_parameters``: mtimes cannot tell an auto-LID run from a
    ``--language ru`` one, so without this the flag is silently dropped *and*
    the stage JSON reports it — along with the extra custom-vocab model — as
    having been in effect.
    """
    path = work_dir(meeting_dir) / STAGE_JSON_NAME
    if not path.is_file():
        return None
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(report, dict):
        return None
    for entry in report.get("tracks") or []:
        if isinstance(entry, dict) and entry.get("track") == track:
            return (entry.get("language"), entry.get("custom_vocab"))
    return None


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


# --- the stage ---------------------------------------------------------------


def _finish(entry: dict, raw_path) -> dict:
    """Parse a CLI output file into ``entry`` and decide the track's status."""
    try:
        raw = read_raw_json(raw_path)
    except ValueError as exc:
        entry.update({"status": STATUS_FAILED, "detail": str(exc)})
        return entry

    words = parse_word_timings(raw)
    entry["words"] = words
    entry.update(summarize(raw, words))
    entry.update(confidence_stats(words))

    if words:
        entry["status"] = entry.get("status") or STATUS_OK
        entry.setdefault("detail", f"{len(words)} word(s)")
        return entry

    # No timings. Whether that is fine or a failure depends on the text: an empty
    # transcript is a quiet track (the gate usually catches it first), but text
    # without timings means --word-timestamps did not take effect — and S5 cannot
    # cut utterances or assign speakers without them, so it must not pass.
    if entry.get("text"):
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": (
                    "the CLI returned transcript text but no wordTimings — "
                    "S5 cannot merge without word-level timings"
                ),
            }
        )
    else:
        entry.update(
            {
                "status": STATUS_EMPTY,
                "detail": "no speech recognised on this track",
            }
        )
    return entry


def transcribe_track(
    meeting_dir,
    track: str,
    binary,
    language=None,
    custom_vocab=None,
    force: bool = False,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Transcribe one track; returns its entry for the stage JSON."""
    src = input_path(meeting_dir, track)
    raw_path = raw_json_path(meeting_dir, track)
    entry = {
        "track": track,
        "input": str(src),
        "raw_json": str(raw_path),
        "language": language,
        "custom_vocab": str(custom_vocab) if custom_vocab else None,
        "extra_models": [CUSTOM_VOCAB_EXTRA_MODEL] if custom_vocab else [],
    }

    if not src.is_file():
        entry.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no 16 kHz track at {src} — run prep_audio.py first",
                "elapsed_seconds": 0.0,
                "argv": None,
            }
        )
        return entry

    # A cache hit has to match on *parameters*, not just on mtime — otherwise
    # `--language ru` reuses the auto-LID output and the report claims ru ran.
    previous = previous_asr_options(meeting_dir, track)
    same_options = previous is None or previous == (
        language,
        str(custom_vocab) if custom_vocab else None,
    )

    if not force and same_options and is_fresh(src, raw_path):
        entry.update(
            {
                "status": STATUS_SKIPPED,
                "detail": "the CLI output is already fresher than the 16 kHz track",
                "elapsed_seconds": 0.0,
                "argv": None,
            }
        )
        # Re-parsed, not trusted from a previous report: the stage JSON is always
        # complete, whether this run did the work or reused it.
        return _finish(entry, raw_path)

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    argv = build_argv(binary, src, raw_path, language=language, custom_vocab=custom_vocab)
    entry["argv"] = argv

    runner = runner or default_runner
    started = clock()
    code, stderr = runner(argv)
    entry["elapsed_seconds"] = round(clock() - started, 3)

    if code != 0:
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": f"fluidaudiocli exited {code}",
                "exit_code": code,
                "stderr_tail": (stderr or "").strip().splitlines()[-5:],
            }
        )
        return entry

    if not raw_path.is_file():
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": f"fluidaudiocli exited 0 but wrote no JSON at {raw_path}",
                "exit_code": code,
            }
        )
        return entry

    return _finish(entry, raw_path)


def run(
    meeting_dir,
    tracks=DEFAULT_TRACKS,
    language=None,
    custom_vocab=None,
    force: bool = False,
    environ=None,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Transcribe every requested track and build the stage report."""
    meeting_dir = Path(meeting_dir)
    binary, source = resolve_fluidaudio_bin(environ)

    report = {
        "stage": "transcribe",
        "meeting_dir": str(meeting_dir),
        "engine": "fluidaudiocli transcribe",
        "binary": {"path": str(binary), "source": source},
        "language": language,
        "custom_vocab": str(custom_vocab) if custom_vocab else None,
        "extra_models": [CUSTOM_VOCAB_EXTRA_MODEL] if custom_vocab else [],
        "forced": bool(force),
        "tracks": [],
    }
    if custom_vocab:
        report["extra_models_note"] = (
            f"--custom-vocab makes v0.15.5 additionally load {CUSTOM_VOCAB_EXTRA_MODEL}; "
            "doctor.py reports that model as optional, so this run required more "
            "than the two models a default run needs"
        )

    if not is_executable(binary):
        # Loud, and before any track: a missing engine is not something to
        # discover per-track or to work around.
        report["status"] = STATUS_FAILED
        report["detail"] = (
            f"fluidaudiocli is not executable at {binary} — run bootstrap.sh "
            "(or set ACTA_FLUIDAUDIO_BIN)"
        )
        report["total_seconds"] = 0.0
        # Carry the previous report forward even here, exactly as prep_audio.run
        # does when its own binary is absent: main() writes this report unconditionally,
        # so returning with tracks=[] erased every recorded word list and every
        # recorded --language/--custom-vocab without having attempted a single
        # track. previous_asr_options then found no record, read that as "same
        # options", and the next run skipped the CLI while reporting the language
        # it was *asked* for — the provenance lie carry_forward_tracks exists to
        # prevent, and verify.py copies it straight into quality.md. It also left
        # merge.py with no words at all.
        carry_forward_tracks(meeting_dir, report)
        report["word_count"] = sum(
            entry.get("word_count") or 0 for entry in report["tracks"]
        )
        return report

    for track in tracks:
        report["tracks"].append(
            transcribe_track(
                meeting_dir,
                track,
                binary,
                language=language,
                custom_vocab=custom_vocab,
                force=force,
                runner=runner,
                clock=clock,
            )
        )

    statuses = {entry["status"] for entry in report["tracks"]}
    if STATUS_FAILED in statuses:
        report["status"] = STATUS_FAILED
        report["detail"] = "at least one track failed to transcribe"
    elif statuses <= {STATUS_MISSING}:
        report["status"] = STATUS_FAILED
        report["detail"] = f"no 16 kHz tracks found under {work_dir(meeting_dir)}"
    else:
        report["status"] = STATUS_OK
        report["detail"] = "all present tracks transcribed"

    # A durable per-entry flag, because `status` is not one: carry_forward_tracks
    # overwrites a carried entry's status with STATUS_CARRIED. gate.py's
    # silent_tracks survives the same treatment by keying on `effectively_silent`,
    # a field carry-forward leaves intact; `was_empty` is that idea here.
    for entry in report["tracks"]:
        if entry["status"] == STATUS_EMPTY:
            entry["was_empty"] = True

    report["total_seconds"] = round(
        sum(entry.get("elapsed_seconds") or 0.0 for entry in report["tracks"]), 3
    )
    # After the verdict and the per-run tallies, never before them: carried
    # entries describe a previous invocation and must not colour this one's
    # status or elapsed time.
    carry_forward_tracks(meeting_dir, report)
    # Counted after the carry-forward, because merge.py reads *every* track's
    # words out of this file: the word count has to describe the transcript that
    # can be built from it, not just the tracks this invocation touched.
    report["word_count"] = sum(entry.get("word_count") or 0 for entry in report["tracks"])
    # Also after: "this track carried no speech" is a fact about the recording,
    # like the gate's silent_tracks — not about which tracks this invocation
    # happened to select. Tallied before the carry-forward it silently dropped
    # every previously-empty track on a partial re-run (the `--track system`
    # retry SKILL.md prescribes when the loop gate trips), so the field
    # contradicted its own name whenever it mattered.
    report["empty_tracks"] = [
        entry["track"] for entry in report["tracks"] if entry.get("was_empty")
    ]
    return report


def carry_forward_tracks(meeting_dir, report: dict) -> dict:
    """Keep the previous report's entries for tracks this run did not touch.

    ``run()`` overwrites ``transcribe.json`` wholesale, and merge.py builds the
    transcript from the ``words`` this file records per track — so a
    ``--track system`` invocation (which SKILL.md tells the operator to run when
    the ``repeated_phrase_loop`` gate trips) would erase the mic side and the
    next merge would emit a half-meeting transcript while reporting 100%
    coverage. Erasing the record also defeats ``previous_asr_options``: a
    follow-up ``--track mic --language ru`` would find no recorded language,
    treat that as "same options", skip the CLI and report ``ru`` over an
    auto-LID output. Carried entries are marked so nothing reads them as this
    run's work.
    """
    path = work_dir(meeting_dir) / STAGE_JSON_NAME
    if not path.is_file():
        return report
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return report
    if not isinstance(previous, dict):
        return report

    seen = {entry.get("track") for entry in report["tracks"] if isinstance(entry, dict)}
    for entry in previous.get("tracks") or []:
        if not isinstance(entry, dict) or entry.get("track") in seen:
            continue
        carried = dict(entry)
        carried["status"] = STATUS_CARRIED
        carried["detail"] = "not selected by this run — record kept from the previous one"
        carried["elapsed_seconds"] = 0.0
        report["tracks"].append(carried)
    return report


def write_stage_json(meeting_dir, report: dict) -> Path:
    path = work_dir(meeting_dir) / STAGE_JSON_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def render_human(report: dict) -> str:
    lines = [
        f"acta-notes transcribe — {report['status'].upper()} "
        f"({report.get('word_count', 0)} words, {report.get('total_seconds', 0.0):.1f}s)"
    ]
    for entry in report["tracks"]:
        if entry["status"] in (STATUS_MISSING, STATUS_FAILED):
            lines.append(
                f"  [{entry['status']:<7}] {entry['track']:<8} {entry['detail']}"
            )
            continue
        confidence = entry.get("mean_confidence")
        confidence = "n/a" if confidence is None else f"{confidence:.3f}"
        lines.append(
            f"  [{entry['status']:<7}] {entry['track']:<8} "
            f"{entry.get('word_count', 0)} words, mean confidence {confidence}, "
            f"{entry.get('elapsed_seconds', 0.0):.1f}s"
        )
    if report.get("extra_models"):
        lines.append(f"  extra models loaded: {', '.join(report['extra_models'])}")
    if report["status"] == STATUS_FAILED:
        lines.append("")
        lines.append(report.get("detail", "transcribe failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    return EXIT_OK if report["status"] == STATUS_OK else EXIT_FAILED


def valid_track_name(name) -> bool:
    """A track name is interpolated straight into a filename under the meeting
    folder, so it must not be able to become a *path*.

    ``--track ../../../etc/passwd`` resolved outside the meeting directory and
    was then echoed into the stage JSON. No shell is involved anywhere in this
    chain (every call is an argv list), so this is a containment check rather
    than an injection fix — but a stage that reads and writes outside the folder
    it was pointed at has no business doing so quietly.
    """
    name = str(name)
    return bool(name) and all(ch.isalnum() or ch in "_-" for ch in name)


def main(argv=None, environ=None, runner=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="transcribe.py",
        description=(
            "S3: Parakeet TDT 0.6B v3 ASR per track via "
            "`fluidaudiocli transcribe --word-timestamps --output-json` (D1, D3)."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--track",
        dest="tracks",
        action="append",
        metavar="NAME",
        help="track to transcribe (repeatable; default: mic and system)",
    )
    parser.add_argument(
        "--language",
        metavar="CODE",
        help=(
            "opt-in language hint (e.g. ru). Off by default: Parakeet auto-LIDs "
            "and pinning the language did not move WER (D6)"
        ),
    )
    parser.add_argument(
        "--custom-vocab",
        metavar="FILE",
        help=(
            "opt-in hotword file, one term per line. Off by default: hotwords are "
            "WER-noise with a false-substitution risk (D6). NOTE: FluidAudio "
            f"v0.15.5 additionally loads the {CUSTOM_VOCAB_EXTRA_MODEL} model for "
            "vocabulary boosting — doctor.py treats that model as optional, so "
            "this flag is the one code path that makes it a hard requirement"
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-transcribe even when the CLI output is fresh",
    )
    parser.add_argument("--json", action="store_true", help="print the stage JSON")
    args = parser.parse_args(argv)

    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        parser.error(f"no such meeting folder: {meeting_dir}")
    for name in args.tracks or ():
        if not valid_track_name(name):
            parser.error(
                f"not a usable track name: {name!r} "
                "(letters, digits, '_' and '-' only — it becomes a filename)"
            )
    if args.custom_vocab and not Path(args.custom_vocab).is_file():
        parser.error(f"no such custom-vocab file: {args.custom_vocab}")

    report = run(
        meeting_dir,
        tracks=tuple(args.tracks) if args.tracks else DEFAULT_TRACKS,
        language=args.language,
        custom_vocab=args.custom_vocab,
        force=args.force,
        environ=environ,
        runner=runner,
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
