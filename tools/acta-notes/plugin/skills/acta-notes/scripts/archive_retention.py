#!/usr/bin/env python3
"""Audio retention for the ``~/Acta`` archive: compress, then prune.

Acta records **48 kHz stereo 16-bit PCM** on two tracks — about 1.7 GB per hour
of meeting. The pipeline downmixes to 16 kHz mono before ASR ever sees it, so
six sevenths of that is data nothing reads. At ~11 h of meetings a week the
archive grows ~19 GB/week, which is a full disk in weeks, not years. Meanwhile
the part with the lasting value — transcripts, summaries, context — is a few
megabytes for the whole archive.

So this script does one thing: for meetings that are **already processed and
signed off**, replace the source wavs with a compressed copy and delete the
originals. At the default Opus 32 kbps mono per track that is ~29 MB/hour
instead of ~1720 — enough to re-listen to a low-confidence span, and enough to
re-run ASR if a better model arrives.

**The whole design is the delete gate.** Losing a meeting's audio to a truncated
encode would be silent and irreversible, so before any source is removed the
encoded file is *fully decoded* and its duration compared against the wav read
with the stdlib ``wave`` module. A container that cannot be decoded to its last
frame never gets its source deleted. That is also why the default is a dry run:
``--apply`` is opt-in.

Eligibility is deliberately conservative. A meeting qualifies only when a
non-empty ``summary.md`` exists (the human sign-off), a transcript with speaker
markers exists, the folder is older than ``--older-than`` days, and — if
``verify.json`` is present at all — no quality check in it is **red**. A meeting
whose gate tripped keeps its audio, because that is exactly the audio someone
will want to listen to; a ``warn`` is not a tripped gate (it does not fail the
pipeline run) and does not withhold the audio. ``--strict-verify`` restores the
older, stricter every-check-green rule.

Usage::

    # what would happen, and how much it would save
    archive_retention.py

    # do it
    archive_retention.py --apply

    # drop regenerable 16 kHz intermediates from .acta-notes/
    archive_retention.py --prune-work --apply

    # bring a meeting's wavs back so pipeline.py can re-run on it
    archive_retention.py --restore 2026-01-15_1519__slack-2026-01-15-15-19 --apply
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

DEFAULT_ARCHIVE = "~/Acta"
WORK_DIRNAME = ".acta-notes"
REPORT_JSON_NAME = "retention.json"

#: ``YYYY-MM-DD_HHMM__slug`` — the archive's folder convention. Anything that
#: does not match is not a meeting and is never touched.
MEETING_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})__")

#: A line like ``**[00:01:02] NAME:**`` — the marker that makes a file a
#: transcript rather than a note. Same shape verify.py gates on.
SPEAKER_MARKER_RE = re.compile(r"^\*\*\[\d{2}:\d{2}:\d{2}\][^:]*:\*\*", re.M)

DEFAULT_OLDER_THAN_DAYS = 7
DEFAULT_BITRATE_KBPS = 32
#: Opus frames are 20 ms and ffmpeg adds a small pre-skip, so an exact match is
#: not expected; anything past this is a truncated or padded encode, not rounding.
DURATION_TOLERANCE_SECONDS = 0.5
#: Decode rate used only to *measure* duration. Lower means less PCM through the
#: pipe; fidelity is irrelevant when all we do is count bytes.
PROBE_RATE = 8000
DEFAULT_TIMEOUT_SECONDS = 3600.0
TIMEOUT_ENV_VAR = "ACTA_FFMPEG_TIMEOUT"

CODEC_OPUS = "opus"
CODEC_FLAC = "flac"
CODEC_SUFFIX = {CODEC_OPUS: ".opus", CODEC_FLAC: ".flac"}

EXIT_OK = 0
EXIT_FAILED = 1
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
    # injected environment really is the whole environment. `path=""`, not
    # `path=None`: which() reads the *process* PATH when handed None.
    found = shutil.which("ffmpeg", path=environ.get("PATH", ""))
    return (Path(found), "path") if found else (None, "path")


def is_executable(path) -> bool:
    p = Path(path)
    return p.is_file() and os.access(str(p), os.X_OK)


def ffmpeg_timeout(environ=None) -> float:
    environ = os.environ if environ is None else environ
    raw = environ.get(TIMEOUT_ENV_VAR)
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


# --- archive inspection ------------------------------------------------------


def meeting_date(name: str):
    """The local calendar date encoded in a meeting folder name, or ``None``."""
    m = MEETING_RE.match(name)
    if not m:
        return None
    try:
        return datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def meeting_dirs(archive) -> list[Path]:
    archive = Path(archive)
    if not archive.is_dir():
        return []
    return sorted(
        p for p in archive.iterdir() if p.is_dir() and meeting_date(p.name)
    )


def source_wavs(meeting_dir) -> list[Path]:
    """Top-level wavs — the recordings themselves, including ``*.full.wav``."""
    return sorted(p for p in Path(meeting_dir).glob("*.wav") if p.is_file())


def work_wavs(meeting_dir) -> list[Path]:
    """16 kHz intermediates under ``.acta-notes/``. Always regenerable."""
    work = Path(meeting_dir) / WORK_DIRNAME
    if not work.is_dir():
        return []
    return sorted(p for p in work.glob("*.wav") if p.is_file())


def wav_duration_seconds(path) -> float | None:
    """Exact duration via the stdlib, so no probe binary is involved."""
    try:
        with contextlib.closing(wave.open(str(path), "rb")) as handle:
            rate = handle.getframerate()
            if rate <= 0:
                return None
            return handle.getnframes() / float(rate)
    except (wave.Error, OSError, EOFError):
        return None


def _non_empty(path) -> bool:
    p = Path(path)
    try:
        return p.is_file() and p.stat().st_size > 0
    except OSError:
        return False


def has_transcript(meeting_dir) -> bool:
    """Is there a transcript with actual speaker-marked lines?"""
    for name in ("transcript.raw.md", "transcript.labeled.md", "transcript.md"):
        path = Path(meeting_dir) / name
        if not _non_empty(path):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if SPEAKER_MARKER_RE.search(text):
            return True
    return False


def verify_state(meeting_dir, strict=False):
    """``("absent"|"green"|"warn"|"not-green", detail)`` from ``verify.json``.

    Absent is not a failure: the oldest meetings in the archive predate the
    current pipeline and have no ``.acta-notes/`` at all. Their ``summary.md``
    is the sign-off instead.

    Only a ``red`` check withholds the audio, because only the three hard gates
    in ``verify.py`` (``transcript``, ``repeated_phrase_loop``,
    ``diarization_coverage`` under its floor) can go red, and those are the ones
    that mean "the transcript may be wrong, someone will want the original".
    A ``warn`` does not fail the pipeline run at all, and treating it as red
    pinned 23 of 155 meetings at full size — among them ``dictation`` warns,
    which are a *text* correlation gap that no amount of re-listening resolves.
    ``strict=True`` restores the old every-check-green rule.
    """
    path = Path(meeting_dir) / WORK_DIRNAME / "verify.json"
    if not path.is_file():
        return "absent", "no verify.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return "not-green", f"unreadable verify.json: {exc}"
    checks = data.get("checks")
    if not isinstance(checks, list) or not checks:
        return "not-green", "verify.json has no checks"
    checks = [c for c in checks if isinstance(c, dict)]
    red = sorted(str(c.get("name")) for c in checks if c.get("status") == "red")
    if red:
        return "not-green", "red: " + ", ".join(red)
    warn = sorted(str(c.get("name")) for c in checks if c.get("status") == "warn")
    other = sorted(
        str(c.get("name"))
        for c in checks
        if c.get("status") not in ("green", "warn", "red")
    )
    if other:
        return "not-green", "unknown status: " + ", ".join(other)
    if warn:
        if strict:
            return "not-green", "not green: " + ", ".join(warn)
        return "warn", "warn (not a hard gate): " + ", ".join(warn)
    return "green", f"{len(checks)} check(s) green"


def eligibility(meeting_dir, cutoff_date, strict=False):
    """``(eligible, reason)`` — why this meeting may or may not lose its audio."""
    meeting_dir = Path(meeting_dir)
    date = meeting_date(meeting_dir.name)
    if date is None:
        return False, "not a meeting folder"
    if date > cutoff_date:
        return False, f"too recent ({date} > {cutoff_date})"
    if not _non_empty(meeting_dir / "summary.md"):
        return False, "no summary.md — not signed off"
    if not has_transcript(meeting_dir):
        return False, "no transcript with speaker markers"
    state, detail = verify_state(meeting_dir, strict=strict)
    if state == "not-green":
        return False, detail
    return True, f"summary + transcript, verify {state} ({detail})"


# --- encode / verify / prune --------------------------------------------------


def encoded_path(wav, codec) -> Path:
    wav = Path(wav)
    return wav.with_suffix(CODEC_SUFFIX[codec])


def encode_command(ffmpeg, wav, out, codec, bitrate_kbps):
    """ffmpeg argv. Mono on purpose: ``mic`` = me, ``system`` = them, and the
    two tracks must stay separate files for diarization to keep meaning."""
    cmd = [str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(wav), "-ac", "1"]
    if codec == CODEC_OPUS:
        cmd += ["-c:a", "libopus", "-b:a", f"{bitrate_kbps}k", "-application", "voip"]
    elif codec == CODEC_FLAC:
        cmd += ["-c:a", "flac", "-ar", "16000"]
    else:  # pragma: no cover - guarded by argparse choices
        raise ValueError(f"unknown codec: {codec}")
    cmd.append(str(out))
    return cmd


def decoded_duration_seconds(ffmpeg, path, timeout=None):
    """Full-decode duration, or ``None`` if the file will not decode.

    This is the delete gate. Streaming raw PCM and counting bytes measures the
    duration exactly *and* proves every frame decodes — a truncated container
    fails here rather than after its source is gone.
    """
    cmd = [
        str(ffmpeg), "-nostdin", "-v", "error", "-i", str(path),
        "-f", "s16le", "-acodec", "pcm_s16le", "-ac", "1", "-ar", str(PROBE_RATE), "-",
    ]
    timeout = ffmpeg_timeout() if timeout is None else timeout
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
    except OSError:
        return None
    total = 0
    try:
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
        proc.stdout.close()
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return None
    finally:
        if proc.stderr is not None:
            proc.stderr.close()
    if rc != 0:
        return None
    return total / 2.0 / PROBE_RATE


def compress_wav(ffmpeg, wav, codec, bitrate_kbps, apply, timeout=None):
    """Encode one wav and, only if the copy verifies, delete the original.

    Returns a record dict. ``status`` is one of ``planned``, ``compressed``,
    ``already``, ``skipped``, ``failed``.
    """
    wav = Path(wav)
    out = encoded_path(wav, codec)
    source_seconds = wav_duration_seconds(wav)
    try:
        source_bytes = wav.stat().st_size
    except OSError:
        source_bytes = 0
    record = {
        "wav": wav.name,
        "encoded": out.name,
        "source_bytes": source_bytes,
        "source_seconds": source_seconds,
    }

    if source_seconds is None:
        record.update(status="skipped", reason="wav duration unreadable")
        return record

    if not apply:
        record.update(status="planned")
        return record

    timeout = ffmpeg_timeout() if timeout is None else timeout
    try:
        proc = subprocess.run(
            encode_command(ffmpeg, wav, out, codec, bitrate_kbps),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        record.update(status="failed", reason="ffmpeg timed out")
        return record
    except OSError as exc:
        record.update(status="failed", reason=f"cannot run ffmpeg: {exc}")
        return record

    if proc.returncode != 0:
        with contextlib.suppress(OSError):
            out.unlink()
        detail = (proc.stderr or b"").decode("utf-8", "replace").strip()
        record.update(status="failed", reason=f"encode failed: {detail[:300]}")
        return record

    decoded = decoded_duration_seconds(ffmpeg, out, timeout=timeout)
    if decoded is None:
        record.update(status="failed", reason="encoded file will not decode")
        return record
    drift = abs(decoded - source_seconds)
    record["encoded_seconds"] = decoded
    record["drift_seconds"] = drift
    if drift > DURATION_TOLERANCE_SECONDS:
        record.update(
            status="failed",
            reason=(
                f"duration drift {drift:.2f}s exceeds "
                f"{DURATION_TOLERANCE_SECONDS}s — source kept"
            ),
        )
        return record

    try:
        record["encoded_bytes"] = out.stat().st_size
    except OSError:
        record["encoded_bytes"] = 0

    try:
        wav.unlink()
    except OSError as exc:
        record.update(status="failed", reason=f"cannot remove source: {exc}")
        return record

    record.update(status="compressed")
    return record


def prune_paths(paths, apply):
    """Delete regenerable files. Returns ``(records, bytes_freed)``."""
    records, freed = [], 0
    for path in paths:
        path = Path(path)
        try:
            size = path.stat().st_size
        except OSError:
            continue
        rec = {"path": path.name, "bytes": size}
        if apply:
            try:
                path.unlink()
            except OSError as exc:
                rec.update(status="failed", reason=str(exc))
                records.append(rec)
                continue
            rec["status"] = "pruned"
        else:
            rec["status"] = "planned"
        freed += size
        records.append(rec)
    return records, freed


def restore_meeting(ffmpeg, meeting_dir, apply, timeout=None):
    """Decode ``<stem>.opus``/``.flac`` back to ``<stem>.wav`` for reprocessing."""
    meeting_dir = Path(meeting_dir)
    records = []
    encoded = sorted(
        p
        for suffix in CODEC_SUFFIX.values()
        for p in meeting_dir.glob(f"*{suffix}")
        if p.is_file()
    )
    timeout = ffmpeg_timeout() if timeout is None else timeout
    for src in encoded:
        out = src.with_suffix(".wav")
        rec = {"encoded": src.name, "wav": out.name}
        if out.exists():
            rec.update(status="skipped", reason="wav already present")
            records.append(rec)
            continue
        if not apply:
            rec["status"] = "planned"
            records.append(rec)
            continue
        cmd = [
            str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(src),
            "-c:a", "pcm_s16le", str(out),
        ]
        try:
            proc = subprocess.run(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            rec.update(status="failed", reason=str(exc))
            records.append(rec)
            continue
        if proc.returncode != 0:
            with contextlib.suppress(OSError):
                out.unlink()
            rec.update(
                status="failed",
                reason=(proc.stderr or b"").decode("utf-8", "replace").strip()[:300],
            )
        else:
            rec["status"] = "restored"
        records.append(rec)
    return records


def write_report(meeting_dir, payload):
    work = Path(meeting_dir) / WORK_DIRNAME
    try:
        work.mkdir(parents=True, exist_ok=True)
        (work / REPORT_JSON_NAME).write_text(
            json.dumps(payload, ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


# --- reporting ---------------------------------------------------------------


def human_bytes(n) -> str:
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(value) < 1024.0 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{value:.1f} TB"  # pragma: no cover


def build_parser():
    p = argparse.ArgumentParser(
        prog="archive_retention.py", description=__doc__.split("\n")[0]
    )
    p.add_argument("archive", nargs="?", default=DEFAULT_ARCHIVE)
    p.add_argument(
        "--older-than",
        type=int,
        default=DEFAULT_OLDER_THAN_DAYS,
        metavar="DAYS",
        help=(
            "only meetings whose folder date is at least this many days old "
            f"(default {DEFAULT_OLDER_THAN_DAYS}); recent audio stays raw so a "
            "re-run with different parameters is still possible"
        ),
    )
    p.add_argument("--codec", choices=sorted(CODEC_SUFFIX), default=CODEC_OPUS)
    p.add_argument(
        "--bitrate",
        type=int,
        default=DEFAULT_BITRATE_KBPS,
        metavar="KBPS",
        help=f"Opus bitrate per mono track (default {DEFAULT_BITRATE_KBPS})",
    )
    p.add_argument(
        "--prune-work",
        action="store_true",
        help=(
            "also delete .acta-notes/*.wav — the 16 kHz intermediates, which "
            "the pipeline regenerates from source on demand"
        ),
    )
    p.add_argument(
        "--restore",
        metavar="MEETING",
        help="decode a meeting's compressed tracks back to wav, then exit",
    )
    p.add_argument(
        "--apply",
        action="store_true",
        help="actually write and delete; without it nothing is modified",
    )
    p.add_argument(
        "--strict-verify",
        action="store_true",
        help="withhold audio when ANY verify.json check is not green, not only a "
        "red one; the pre-2026-09 behaviour, kept for a cautious sweep",
    )
    p.add_argument("--json", action="store_true", help="machine-readable report")
    p.add_argument(
        "--today",
        metavar="YYYY-MM-DD",
        help="treat this as the current date when computing --older-than",
    )
    return p


def main(argv=None, environ=None, stdout=None, today=None):
    args = build_parser().parse_args(argv)
    out = sys.stdout if stdout is None else stdout
    environ = os.environ if environ is None else environ

    archive = Path(args.archive).expanduser()
    if not archive.is_dir():
        print(f"archive_retention: no such archive: {archive}", file=sys.stderr)
        return EXIT_USAGE

    ffmpeg, ffmpeg_source = resolve_ffmpeg_bin(environ)
    need_ffmpeg = args.apply or bool(args.restore)
    if need_ffmpeg and (ffmpeg is None or not is_executable(ffmpeg)):
        print(
            "archive_retention: ffmpeg not found "
            f"(looked via {ffmpeg_source}); set ACTA_FFMPEG_BIN",
            file=sys.stderr,
        )
        return EXIT_USAGE

    if args.restore:
        target = archive / args.restore
        if not target.is_dir():
            print(f"archive_retention: no such meeting: {target}", file=sys.stderr)
            return EXIT_USAGE
        records = restore_meeting(ffmpeg, target, args.apply)
        payload = {"action": "restore", "meeting": target.name, "tracks": records}
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=1), file=out)
        else:
            verb = "restored" if args.apply else "would restore"
            for rec in records:
                print(f"  [{rec['status']:9}] {verb}: {rec['encoded']} -> {rec['wav']}", file=out)
            if not records:
                print("  nothing to restore (no compressed tracks)", file=out)
        failed = [r for r in records if r.get("status") == "failed"]
        return EXIT_FAILED if failed else EXIT_OK

    if today is not None:
        now = today
    elif args.today:
        now = datetime.date.fromisoformat(args.today)
    else:
        now = datetime.date.today()
    cutoff = now - datetime.timedelta(days=args.older_than)

    meetings, totals = [], {
        "eligible": 0,
        "skipped": 0,
        "source_bytes": 0,
        "encoded_bytes": 0,
        "pruned_bytes": 0,
        "failed": 0,
    }

    for meeting in meeting_dirs(archive):
        eligible, reason = eligibility(meeting, cutoff, strict=args.strict_verify)
        entry = {"meeting": meeting.name, "eligible": eligible, "reason": reason}

        if args.prune_work:
            recs, freed = prune_paths(work_wavs(meeting), args.apply)
            if recs:
                entry["work_pruned"] = recs
                totals["pruned_bytes"] += freed

        if not eligible:
            wavs = source_wavs(meeting)
            if wavs or entry.get("work_pruned"):
                entry["source_wavs"] = len(wavs)
                totals["skipped"] += 1
                meetings.append(entry)
            continue

        wavs = source_wavs(meeting)
        if not wavs:
            continue

        totals["eligible"] += 1
        tracks = []
        for wav in wavs:
            rec = compress_wav(
                ffmpeg, wav, args.codec, args.bitrate, args.apply
            )
            tracks.append(rec)
            totals["source_bytes"] += rec.get("source_bytes") or 0
            totals["encoded_bytes"] += rec.get("encoded_bytes") or 0
            if rec.get("status") == "failed":
                totals["failed"] += 1
        entry["tracks"] = tracks
        if args.apply:
            write_report(
                meeting,
                {
                    "codec": args.codec,
                    "bitrate_kbps": args.bitrate if args.codec == CODEC_OPUS else None,
                    "tracks": tracks,
                },
            )
        meetings.append(entry)

    payload = {
        "action": "retention",
        "archive": str(archive),
        "codec": args.codec,
        "older_than_days": args.older_than,
        "cutoff_date": cutoff.isoformat(),
        "applied": bool(args.apply),
        "totals": totals,
        "meetings": meetings,
    }

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=1), file=out)
    else:
        _print_human(payload, out)

    return EXIT_FAILED if totals["failed"] else EXIT_OK


def _print_human(payload, out):
    t = payload["totals"]
    verb = "compressed" if payload["applied"] else "would compress"
    print(
        f"archive_retention — {payload['archive']}  codec={payload['codec']}  "
        f"cutoff={payload['cutoff_date']}  "
        f"{'APPLY' if payload['applied'] else 'DRY RUN'}",
        file=out,
    )
    for entry in payload["meetings"]:
        if entry["eligible"]:
            n = len(entry.get("tracks", []))
            src = sum(r.get("source_bytes") or 0 for r in entry.get("tracks", []))
            enc = sum(r.get("encoded_bytes") or 0 for r in entry.get("tracks", []))
            note = f"{verb} {n} track(s), {human_bytes(src)}"
            if enc:
                note += f" -> {human_bytes(enc)}"
            print(f"  [eligible] {entry['meeting']}: {note}", file=out)
            for rec in entry.get("tracks", []):
                if rec.get("status") in ("failed", "skipped"):
                    print(
                        f"      ! {rec['wav']}: {rec.get('reason', rec['status'])}",
                        file=out,
                    )
        else:
            print(f"  [keep    ] {entry['meeting']}: {entry['reason']}", file=out)
        for rec in entry.get("work_pruned", []):
            print(
                f"      work {rec['status']}: {rec['path']} ({human_bytes(rec['bytes'])})",
                file=out,
            )

    print(
        f"\n  {t['eligible']} meeting(s) eligible, {t['skipped']} kept, "
        f"{t['failed']} failure(s)",
        file=out,
    )
    if t["source_bytes"]:
        saved = t["source_bytes"] - t["encoded_bytes"]
        if payload["applied"]:
            ratio = (
                t["source_bytes"] / t["encoded_bytes"] if t["encoded_bytes"] else 0.0
            )
            print(
                f"  audio {human_bytes(t['source_bytes'])} -> "
                f"{human_bytes(t['encoded_bytes'])}  "
                f"(freed {human_bytes(saved)}, {ratio:.0f}x)",
                file=out,
            )
        else:
            print(
                f"  audio in scope: {human_bytes(t['source_bytes'])} "
                "(run with --apply to compress)",
                file=out,
            )
    if t["pruned_bytes"]:
        print(f"  regenerable intermediates: {human_bytes(t['pruned_bytes'])}", file=out)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
