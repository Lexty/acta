#!/usr/bin/env python3
"""acta-notes S1 — per-track audio preprocessing (D6).

Converts each raw meeting track (``<meeting>/mic.wav``, ``<meeting>/system.wav``)
into the 16 kHz mono s16 wav every later stage consumes:

    <meeting>/.acta-notes/<track>.16k.wav

The filter chain is D6's measured default — ``highpass=f=80,afftdn=nr=12``,
**without** ``loudnorm``: denoise costs ~10 s per track and moves 11.6 % of
tokens against plain resampling, while ``loudnorm`` costs a further ~110 s per
track and moves only ~3 %. ``--chain`` exists so the deferred preprocess A/B
(follow-up plan) can re-measure ``loudnorm`` through this same code path instead
of forking it; ``denoise`` stays the default until ``loudnorm`` earns its 110 s
against a hand reference.

Per-track timings and the resulting duration/size land in
``.acta-notes/prep_audio.json``. A track whose 16 kHz output is already fresher
than its source is skipped (``--force`` reconverts).

ffmpeg is resolved from ``ACTA_FFMPEG_BIN`` first, then PATH, so tests can point
the stage at a stub binary.

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import wave
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: D6's chains. ``denoise`` is the shipped default; ``plain`` and ``loudnorm``
#: are the other two arms of the measured comparison, kept selectable so the
#: deferred A/B reuses this stage rather than reimplementing it.
CHAINS = {
    "plain": None,
    "denoise": "highpass=f=80,afftdn=nr=12",
    "loudnorm": "highpass=f=80,afftdn=nr=12,loudnorm",
}
DEFAULT_CHAIN = "denoise"

DEFAULT_TRACKS = ("mic", "system")

SAMPLE_RATE = 16000
CHANNELS = 1
CODEC = "pcm_s16le"

#: One hour of wall clock for one ffmpeg call. Deliberately far above anything a
#: real conversion needs (a 2 h track resamples in well under a minute) — the
#: point is not to bound the work, it is to guarantee the stage JSON gets written
#: at all instead of the run hanging with no record on disk.
DEFAULT_TIMEOUT_SECONDS = 3600.0
TIMEOUT_ENV_VAR = "ACTA_FFMPEG_TIMEOUT"
#: The shell's convention for "killed by a timeout", so the report is readable.
TIMEOUT_EXIT_CODE = 124
#: The shell's convention for "command found but could not be invoked".
SPAWN_FAILED_EXIT_CODE = 126

WORK_DIRNAME = ".acta-notes"
STAGE_JSON_NAME = "prep_audio.json"
OUTPUT_SUFFIX = ".16k.wav"

STATUS_OK = "ok"
STATUS_SKIPPED = "skipped"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"
#: A track this invocation did not select, whose record is kept from the
#: previous report so its provenance is not erased. Never this run's work.
STATUS_CARRIED = "carried"

EXIT_OK = 0
EXIT_FFMPEG_FAILED = 1
EXIT_USAGE = 2


# --- binary resolution -------------------------------------------------------


def resolve_ffmpeg_bin(environ=None):
    """Resolve ffmpeg: ``ACTA_FFMPEG_BIN`` override, then PATH.

    Returns ``(path_or_None, source)``. The env override is what lets the tests
    (and anyone with a hand-built ffmpeg) redirect the whole stage.
    """
    environ = os.environ if environ is None else environ
    override = environ.get("ACTA_FFMPEG_BIN")
    if override:
        return Path(override), "env:ACTA_FFMPEG_BIN"
    # Search the PATH of the environ we were handed, not the process's own, so an
    # injected environment really is the whole environment.
    # `path=""`, not `path=None`: which() reads the *process* PATH when handed
    # None, so an injected environ with no PATH key silently resolved the
    # machine's ffmpeg — the opposite of what the comment above promises.
    found = shutil.which("ffmpeg", path=environ.get("PATH", ""))
    return (Path(found), "path") if found else (None, "path")


def is_executable(path) -> bool:
    p = Path(path)
    return p.is_file() and os.access(str(p), os.X_OK)


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def input_path(meeting_dir, track: str) -> Path:
    return Path(meeting_dir) / f"{track}.wav"


def output_path(meeting_dir, track: str) -> Path:
    return work_dir(meeting_dir) / f"{track}{OUTPUT_SUFFIX}"


def _temp_output_path(dst) -> Path:
    """Sibling scratch path: ffmpeg writes here and we rename on success.

    Without it a killed ffmpeg leaves a truncated ``<track>.16k.wav`` that the
    freshness check would happily treat as a cache hit. The ``.wav`` extension
    stays last: ffmpeg picks the muxer from it and refuses to write a file whose
    suffix it does not recognise.
    """
    dst = Path(dst)
    return dst.with_name(f"{dst.stem}.part{dst.suffix}")


# --- ffmpeg invocation -------------------------------------------------------


def build_argv(ffmpeg, src, dst, chain: str) -> list[str]:
    """Exact argv for one track. ``-af`` is omitted entirely for ``plain``."""
    if chain not in CHAINS:
        raise ValueError(f"unknown chain {chain!r} (choose from {sorted(CHAINS)})")
    argv = [str(ffmpeg), "-hide_banner", "-nostdin", "-y", "-i", str(src)]
    filters = CHAINS[chain]
    if filters:
        argv += ["-af", filters]
    argv += ["-ac", str(CHANNELS), "-ar", str(SAMPLE_RATE), "-c:a", CODEC, str(dst)]
    return argv


def resolve_timeout(environ=None) -> float:
    """Wall-clock ceiling for one ffmpeg call, overridable for a long recording."""
    environ = os.environ if environ is None else environ
    raw = (environ.get(TIMEOUT_ENV_VAR) or "").strip()
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def default_runner(argv, timeout=None) -> tuple[int, str]:
    """Run ffmpeg; a hang becomes ``TIMEOUT_EXIT_CODE``, never an unbounded wait.

    Without a ceiling a wedged ffmpeg took the whole run's forensic record with
    it: this stage's JSON — and ``pipeline.json`` — are only written after
    ``run()`` returns, so a hang left *nothing* on disk to diagnose, which is the
    one outcome the carry-forward machinery exists to prevent.
    """
    timeout = resolve_timeout() if timeout is None else timeout
    try:
        proc = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return TIMEOUT_EXIT_CODE, (
            f"ffmpeg did not exit within {timeout:g}s and was killed; raise "
            f"{TIMEOUT_ENV_VAR} if this recording is genuinely that long"
        )
    except OSError as exc:
        # The binary vanished or lost its exec bit between the run()-level
        # is_executable check and here. Same contract as the timeout branch: a
        # failed track, not an exception that costs us the stage JSON.
        return SPAWN_FAILED_EXIT_CODE, f"could not run ffmpeg ({argv[0]}): {exc}"
    return proc.returncode, proc.stderr.decode("utf-8", "replace")


# --- output inspection -------------------------------------------------------


def previous_chain(meeting_dir, track: str):
    """The chain the existing 16 kHz output for ``track`` was produced with.

    ``None`` when there is no readable record. Mirrors
    ``diarize.previous_parameters``: an mtime alone cannot tell ``--chain
    loudnorm`` from ``--chain denoise``, so without this a chain switch is
    silently ignored *and* the stage JSON goes on to report the chain that was
    asked for as the one that ran — a provenance lie ``quality.md`` repeats.
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
            return entry.get("chain")
    return None


def is_fresh(src, dst) -> bool:
    """True when ``dst`` exists, is non-empty and is not older than ``src``."""
    src, dst = Path(src), Path(dst)
    if not dst.is_file():
        return False
    try:
        dst_stat = dst.stat()
        src_stat = src.stat()
    except OSError:
        return False
    if dst_stat.st_size == 0:
        return False
    return dst_stat.st_mtime >= src_stat.st_mtime


def wav_info(path) -> dict:
    """Duration/format facts read straight off the wav header (no ffprobe)."""
    path = Path(path)
    info = {"size_bytes": path.stat().st_size}
    with wave.open(str(path), "rb") as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        info.update(
            {
                "sample_rate": rate,
                "channels": handle.getnchannels(),
                "sample_width_bytes": handle.getsampwidth(),
                "frames": frames,
                "duration_seconds": round(frames / rate, 3) if rate else None,
            }
        )
    return info


# --- the stage ---------------------------------------------------------------


def prep_track(
    meeting_dir,
    track: str,
    chain: str = DEFAULT_CHAIN,
    force: bool = False,
    ffmpeg=None,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Convert one track; returns its entry for the stage JSON."""
    src = input_path(meeting_dir, track)
    dst = output_path(meeting_dir, track)
    entry = {
        "track": track,
        "chain": chain,
        "filter": CHAINS[chain],
        "input": str(src),
        "output": str(dst),
    }

    if not src.is_file():
        entry.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no such track file: {src}",
                "elapsed_seconds": 0.0,
            }
        )
        return entry

    # A cache hit has to match on *parameters*, not just on mtime: reusing a
    # denoise-era wav under `--chain loudnorm` would report loudnorm as the
    # filter that ran while the bytes on disk say otherwise.
    same_chain = previous_chain(meeting_dir, track) in (None, chain)

    if not force and same_chain and is_fresh(src, dst):
        # A cached output that cannot be read is not a cache hit: reconvert it
        # rather than let the wave error escape and take the whole run's report
        # with it (pipeline.json is only written after run() returns).
        try:
            info = wav_info(dst)
        except (OSError, wave.Error):
            info = None
        if info is not None:
            entry.update(
                {
                    "status": STATUS_SKIPPED,
                    "detail": "16 kHz output is already fresher than the source",
                    "elapsed_seconds": 0.0,
                    "argv": None,
                }
            )
            entry.update(info)
            return entry

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _temp_output_path(dst)
    argv = build_argv(ffmpeg, src, tmp, chain)
    entry["argv"] = argv

    runner = runner or default_runner
    started = clock()
    code, stderr = runner(argv)
    elapsed = round(clock() - started, 3)
    entry["elapsed_seconds"] = elapsed

    if code != 0:
        tmp.unlink(missing_ok=True)
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": f"ffmpeg exited {code}",
                "exit_code": code,
                "stderr_tail": stderr.strip().splitlines()[-5:],
            }
        )
        return entry

    if not tmp.is_file():
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": f"ffmpeg exited 0 but wrote no output at {tmp}",
                "exit_code": code,
            }
        )
        return entry

    os.replace(tmp, dst)
    # wav_info *before* STATUS_OK, not after: an ffmpeg that exits 0 onto an
    # unreadable wav is a failed conversion, and reporting it `ok` was doubly
    # wrong — the run exited 0 on a broken artifact, and pipeline.py only
    # re-runs a stage on failed|missing|refused, so the bad output was cached
    # as fresh forever and the failure resurfaced at S2 as "could not be gated".
    try:
        info = wav_info(dst)
    except (OSError, wave.Error) as exc:  # a stub or a truncated write
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": f"converted, but the output is not a readable wav: {exc}",
                "exit_code": code,
            }
        )
        return entry
    entry["status"] = STATUS_OK
    entry["detail"] = "converted"
    entry.update(info)
    return entry


def run(
    meeting_dir,
    tracks=DEFAULT_TRACKS,
    chain: str = DEFAULT_CHAIN,
    force: bool = False,
    environ=None,
    runner=None,
    clock=time.monotonic,
) -> dict:
    """Convert every requested track and build the stage report."""
    meeting_dir = Path(meeting_dir)
    ffmpeg, source = resolve_ffmpeg_bin(environ)

    report = {
        "stage": "prep_audio",
        "meeting_dir": str(meeting_dir),
        "chain": chain,
        "filter": CHAINS[chain],
        "sample_rate": SAMPLE_RATE,
        "channels": CHANNELS,
        "forced": bool(force),
        "ffmpeg": {"path": str(ffmpeg) if ffmpeg else None, "source": source},
        "tracks": [],
    }

    # `which` already proved the PATH-resolved binary runnable, but an
    # ACTA_FFMPEG_BIN override is taken on trust — so a typo'd or stale env var
    # reached subprocess.run and raised FileNotFoundError out of run(), leaving
    # *no* prep_audio.json at all. That is precisely the outcome the timeout
    # ceiling in default_runner exists to prevent, arriving through a different
    # door. transcribe.py already gates its own binary this way.
    # Only when we are the ones who will spawn it: an injected ``runner`` never
    # touches the resolved path, so vetting it there would reject a caller that
    # deliberately supplied a symbolic one.
    if runner is None and ffmpeg is not None and not is_executable(ffmpeg):
        report["status"] = STATUS_FAILED
        report["detail"] = (
            f"ffmpeg is not executable at {ffmpeg} (from {source}) — fix "
            "ACTA_FFMPEG_BIN or install ffmpeg"
        )
        report["total_seconds"] = 0.0
        return carry_forward_tracks(meeting_dir, report)

    if ffmpeg is None:
        report["status"] = STATUS_FAILED
        report["detail"] = "ffmpeg not found (set ACTA_FFMPEG_BIN or install ffmpeg)"
        report["total_seconds"] = 0.0
        # Carry the previous report forward even here: main() writes this report
        # unconditionally, so returning with tracks=[] erased the recorded chain
        # of every track without having attempted a single one. previous_chain
        # then found no record, read that as "same chain", and the next run
        # skipped the work while reporting the chain it was *asked* for —
        # the exact provenance lie carry_forward_tracks exists to prevent, and
        # verify.py copies it straight into quality.md.
        return carry_forward_tracks(meeting_dir, report)

    for track in tracks:
        report["tracks"].append(
            prep_track(
                meeting_dir,
                track,
                chain=chain,
                force=force,
                ffmpeg=ffmpeg,
                runner=runner,
                clock=clock,
            )
        )

    statuses = {entry["status"] for entry in report["tracks"]}
    if STATUS_FAILED in statuses:
        report["status"] = STATUS_FAILED
        report["detail"] = "at least one track failed to convert"
    elif statuses <= {STATUS_MISSING}:
        report["status"] = STATUS_FAILED
        report["detail"] = f"no track files found in {meeting_dir}"
    else:
        report["status"] = STATUS_OK
        report["detail"] = "all present tracks are at 16 kHz mono"
    report["total_seconds"] = round(
        sum(entry.get("elapsed_seconds") or 0.0 for entry in report["tracks"]), 3
    )
    # After the verdict, never before it: carried entries describe a previous
    # invocation and must not colour this one's status.
    carry_forward_tracks(meeting_dir, report)
    return report


def carry_forward_tracks(meeting_dir, report: dict) -> dict:
    """Keep the previous report's entries for tracks this run did not touch.

    ``run()`` overwrites ``prep_audio.json`` wholesale, so a ``--track system``
    invocation would erase the record of how ``mic.16k.wav`` was produced. The
    next ``--track mic`` run then finds no recorded chain, treats that as "same
    chain", and reports the chain it was *asked* for as the one that ran — the
    provenance lie ``previous_chain`` exists to prevent, and ``quality.md``
    repeats it. Carried entries are marked as such so nothing reads them as
    this run's work.
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
        f"acta-notes prep_audio — {report['status'].upper()} "
        f"(chain: {report['chain']}, {report['total_seconds']:.1f}s)"
    ]
    for entry in report["tracks"]:
        detail = entry.get("detail", "")
        duration = entry.get("duration_seconds")
        if duration is not None:
            detail = f"{detail} — {duration:.1f}s audio, {entry['size_bytes']} B"
        lines.append(
            f"  [{entry['status']:<7}] {entry['track']:<8} {detail}"
        )
    if report["status"] == STATUS_FAILED:
        lines.append("")
        lines.append(report.get("detail", "prep_audio failed"))
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    if report["status"] == STATUS_OK:
        return EXIT_OK
    return EXIT_FFMPEG_FAILED


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
        prog="prep_audio.py",
        description=(
            "S1: convert each meeting track to 16 kHz mono via ffmpeg "
            "(D6 default chain: highpass=f=80,afftdn=nr=12 — no loudnorm)."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--track",
        dest="tracks",
        action="append",
        metavar="NAME",
        help="track to convert (repeatable; default: mic and system)",
    )
    parser.add_argument(
        "--chain",
        choices=sorted(CHAINS),
        default=DEFAULT_CHAIN,
        help=(
            "filter chain: plain | denoise (default, D6) | loudnorm "
            "(~110 s/track for ~3%% of tokens — measured, deferred A/B)"
        ),
    )
    parser.add_argument(
        "--force", action="store_true", help="reconvert even when the output is fresh"
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

    report = run(
        meeting_dir,
        tracks=tuple(args.tracks) if args.tracks else DEFAULT_TRACKS,
        chain=args.chain,
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
