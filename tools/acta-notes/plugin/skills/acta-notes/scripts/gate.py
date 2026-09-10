#!/usr/bin/env python3
"""acta-notes S2 — per-track silence/VAD gate (D5).

Reads the 16 kHz mono s16 wav S1 produced::

    <meeting>/.acta-notes/<track>.16k.wav

and reports, per track, where the speech is: frame-wise RMS over the raw
samples, a merged list of speech spans, total speech seconds, the speech
fraction of the track, and an ``effectively_silent`` verdict. This replaces the
Air skill's manual ``ffmpeg -af volumedetect`` eyeball step with something
``pipeline.py`` can branch on — a listen-only track is skipped at S3 instead of
being transcribed into nothing.

**Threshold, pinned:** speech is RMS **≥ 0.02** on the [0, 1] full-scale
normalisation. ``lab/006`` measured silence at ~0.004 and speech at ~0.02+, and
0.015 let a hallucination through. It is a module constant, not a flag default,
because moving it is a measurement decision, not a per-run one.

**What the verdict is *not* based on:** the speech *fraction*. The measured mic
track carries 164 s of real speech inside 3423 s — 4.8 % — and nothing on the
system track covers it (D5). Any fraction-based cutoff loose enough to keep that
track would be meaningless, so the verdict is an absolute floor on speech
seconds and the fraction is reported for diagnostics only.

**Under-levelled tracks are not silent** — the failure this stage used to cause.
The threshold above is absolute, and it is calibrated against a normally-levelled
capture. A track recorded much quieter (2026-08-03 huddle: mic ~30 dB below
``system``, peak RMS 0.1023, speech living at RMS 0.002–0.01) clears the
threshold in *5 frames out of 9529* — never for the ``min_span`` needed to form
a span — so it gated as ``effectively_silent``, ``pipeline.py`` dropped it from
the ASR pass, and the whole run stayed **green while losing one side of the
conversation**. A half transcript is far worse than a loud failure, because
nothing downstream can tell it from a genuine one-sided recording.

So when a track gates as silent this stage asks a second question before
accepting it: *would there be speech here if the track were at a normal level?*
It re-gates at a threshold scaled to the track's own peak
(``threshold * peak_rms / REFERENCE_PEAK_RMS``) and reports ``under_levelled``
when all three hold:

1. the track gated as silent in the first place, and its peak is below reference
   level — above it the probe would just repeat the real gate;
2. the scaled probe finds at least ``silence_floor`` seconds of speech — a lone
   keystroke or click cannot satisfy this, only sustained speech can;
3. its **dynamic range** — peak frame RMS over *median* frame RMS — is at least
   ``MIN_DYNAMIC_RANGE``. This is what separates quiet speech from a dead
   capture at any level: speech has silence between words, so its median frame
   is room tone while its peak is a vowel (measured 2026-08-03: 1700× on the
   quiet mic, 343× on the healthy system track), whereas hiss, hum or a muted
   input are flat (1×). An absolute floor on the peak cannot do this job — a
   sufficiently quiet capture has every frame below the threshold, peaks
   included.

An under-levelled track is reported with ``effectively_silent = False``, because
it is not silent — that misnomer is the bug. It carries a ``suggested_gain`` and
``suggested_chain = "loudnorm"``; ``pipeline.py`` acts on it by re-running S1 for
that track with ``--chain loudnorm`` and re-gating. The pinned threshold is
deliberately left alone: after normalisation the speech genuinely sits at 0.02+,
so the anti-hallucination property ``lab/006`` bought stays intact.

Per-track results land in ``.acta-notes/gate.json``.

Stdlib only — no ffmpeg, no model, no binary to resolve.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import wave
from array import array
from operator import mul
from pathlib import Path

# --- constants ---------------------------------------------------------------

#: lab/006: silence measures ~0.004, speech ~0.02+; 0.015 leaked a hallucination.
#: Full-scale-normalised RMS, so it is independent of sample rate and duration.
SPEECH_RMS_THRESHOLD = 0.02

#: s16 full scale. Samples are divided by this before the threshold comparison.
FULL_SCALE = 32768.0

#: 30 ms is short enough to catch a single word and long enough that one
#: consonant burst does not become a span of its own.
DEFAULT_FRAME_MS = 30

#: Voiced frames closer together than this are one span — speech has gaps
#: between words, and splitting on them would produce thousands of fragments.
DEFAULT_MERGE_GAP_SECONDS = 0.3

#: A span shorter than this after merging is a click, a keystroke or a breath.
DEFAULT_MIN_SPAN_SECONDS = 0.2

#: The whole point of the verdict: a track with less speech than this is not
#: worth an ASR pass. Deliberately generous — the cost of transcribing a nearly
#: empty track is seconds, the cost of dropping a real one is a lost speaker.
SILENT_MAX_SPEECH_SECONDS = 2.0

#: Frame-RMS peak of a normally-levelled speech capture. Used *only* to scale
#: the pinned threshold down to a quiet track's own level when probing for an
#: under-levelled recording — never to gate, and never as a target for ffmpeg.
#: Measured on the same 2026-08-03 pair: `system` peaked at 0.4667 and the
#: loudnorm'd `mic` at 0.2415, so a quarter of full scale sits below a healthy
#: track and above anything a dead one produces.
REFERENCE_PEAK_RMS = 0.25

#: Peak frame RMS over median frame RMS, below which a quiet track is treated as
#: a dead capture rather than an under-levelled one. Speech is bursty — its
#: median frame is the silence between words — so it clears this by two orders of
#: magnitude (2026-08-03: 1700× on the quiet mic, 343× on the healthy system
#: track), while hiss, hum and a muted input sit at ~1×. 8 is far above the
#: latter and far below the former, so the gap is not a tuning knob.
MIN_DYNAMIC_RANGE = 8.0

DEFAULT_TRACKS = ("mic", "system")

WORK_DIRNAME = ".acta-notes"
STAGE_JSON_NAME = "gate.json"
INPUT_SUFFIX = ".16k.wav"

STATUS_OK = "ok"
STATUS_MISSING = "missing"
STATUS_FAILED = "failed"
#: A track a previous invocation gated and this one was not asked about.
#: Mirrors ``prep_audio.STATUS_CARRIED`` — see ``carry_forward_tracks``.
STATUS_CARRIED = "carried"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2


class GateError(Exception):
    """The wav cannot be gated (unsupported format, unreadable file)."""


# --- path derivation ---------------------------------------------------------


def work_dir(meeting_dir) -> Path:
    return Path(meeting_dir) / WORK_DIRNAME


def input_path(meeting_dir, track: str) -> Path:
    """S2 reads S1's output, never the raw 48 kHz track."""
    return work_dir(meeting_dir) / f"{track}{INPUT_SUFFIX}"


# --- RMS ---------------------------------------------------------------------


def frame_rms(samples: array) -> float:
    """Full-scale-normalised RMS of one frame of s16 samples.

    ``sum(map(mul, s, s))`` rather than a Python-level loop: a 57-minute track
    is ~55 M samples, and ``audioop`` — which used to do this in C — was removed
    from the stdlib in Python 3.13, so this is the fastest form still available
    without a third-party package (and nothing may be installed globally).
    """
    count = len(samples)
    if not count:
        return 0.0
    total = sum(map(mul, samples, samples))
    return (total / count) ** 0.5 / FULL_SCALE


def iter_frame_rms(handle, frame_samples: int):
    """Yield the RMS of each successive frame of an open wave reader.

    Multi-channel input is treated as one interleaved stream: for a threshold
    decision the union's RMS is as good as a per-channel one, and it keeps the
    stage usable on a raw stereo track when someone is debugging by hand.
    """
    channels = handle.getnchannels()
    swap = sys.byteorder == "big"  # wav is little-endian; array('h') is native
    while True:
        chunk = handle.readframes(frame_samples)
        if not chunk:
            return
        samples = array("h")
        samples.frombytes(chunk[: len(chunk) - len(chunk) % 2])
        if swap:
            samples.byteswap()
        yield frame_rms(samples), len(samples) // channels


# --- spans -------------------------------------------------------------------


def spans_from_frames(
    frames,
    frame_seconds: float,
    duration_seconds: float,
    merge_gap: float = DEFAULT_MERGE_GAP_SECONDS,
    min_span: float = DEFAULT_MIN_SPAN_SECONDS,
    threshold: float = SPEECH_RMS_THRESHOLD,
) -> list[dict]:
    """Turn a per-frame RMS sequence into merged, de-fragmented speech spans.

    ``frames`` is an iterable of RMS values, one per frame, in order. Merging
    happens before the minimum-length filter so that a real utterance broken by
    inter-word gaps is measured whole rather than discarded piece by piece.
    """
    raw: list[list[float]] = []
    for index, rms in enumerate(frames):
        if rms < threshold:
            continue
        start = index * frame_seconds
        end = min(start + frame_seconds, duration_seconds)
        # The epsilon is not cosmetic: frame times are index * frame_seconds, so
        # a gap that is exactly merge_gap lands a float ulp above it.
        if raw and start - raw[-1][1] <= merge_gap + 1e-9:
            raw[-1][1] = end
        else:
            raw.append([start, end])

    spans = []
    for start, end in raw:
        if end - start + 1e-9 < min_span:
            continue
        spans.append(
            {
                "start": round(start, 3),
                "end": round(end, 3),
                "duration": round(end - start, 3),
            }
        )
    return spans


def is_effectively_silent(
    speech_seconds: float, floor: float = SILENT_MAX_SPEECH_SECONDS
) -> bool:
    """Absolute floor, never a fraction — see the module docstring (D5)."""
    return speech_seconds < floor


def probe_under_levelled(
    rms_values,
    frame_seconds: float,
    duration_seconds: float,
    peak: float,
    merge_gap: float = DEFAULT_MERGE_GAP_SECONDS,
    min_span: float = DEFAULT_MIN_SPAN_SECONDS,
    threshold: float = SPEECH_RMS_THRESHOLD,
    silence_floor: float = SILENT_MAX_SPEECH_SECONDS,
) -> dict:
    """Re-gate a silent-looking track at its own level. See the module docstring.

    Called only for a track that already gated as silent, so the extra span pass
    costs nothing on a healthy run. Returns the probe's numbers either way — a
    negative answer is worth recording, since it is what distinguishes a *dead*
    capture from a merely quiet one in ``gate.json``.
    """
    result = {
        "under_levelled": False,
        "probe_threshold": None,
        "probe_speech_seconds": 0.0,
        "dynamic_range": None,
        "suggested_gain": None,
        "suggested_chain": None,
    }

    if peak <= 0.0:
        result["detail"] = "digital silence — every frame is zero"
        return result

    # Already at or above reference level: the probe would equal the real gate,
    # so it can only repeat the verdict. Nothing to learn, nothing to fix.
    if peak >= REFERENCE_PEAK_RMS:
        result["detail"] = (
            f"peak RMS {peak:.4f} is already at reference level — "
            "the track is quiet in content, not in level"
        )
        return result

    # Condition 3, computed first because it is the cheap one and the one that
    # rules out a dead capture outright.
    ordered = sorted(rms_values)
    median = ordered[len(ordered) // 2] if ordered else 0.0
    dynamic_range = peak / median if median > 0 else float("inf")
    result["dynamic_range"] = (
        None if dynamic_range == float("inf") else round(dynamic_range, 1)
    )
    if dynamic_range < MIN_DYNAMIC_RANGE:
        result["detail"] = (
            f"peak/median frame RMS is {dynamic_range:.1f}× (floor "
            f"{MIN_DYNAMIC_RANGE}×) — a flat track like this is hiss or a muted "
            "input, not speech recorded too quietly"
        )
        return result

    probe_threshold = threshold * peak / REFERENCE_PEAK_RMS
    spans = spans_from_frames(
        rms_values,
        frame_seconds,
        duration_seconds,
        merge_gap=merge_gap,
        min_span=min_span,
        threshold=probe_threshold,
    )
    probe_speech = sum(span["duration"] for span in spans)

    result["probe_threshold"] = round(probe_threshold, 6)
    result["probe_speech_seconds"] = round(probe_speech, 3)

    # Condition 2: sustained speech, not one click. `spans_from_frames` already
    # applied `min_span`, so a keystroke cannot reach the floor here.
    if probe_speech < silence_floor:
        result["detail"] = (
            f"probing at RMS ≥ {probe_threshold:.5f} found only "
            f"{probe_speech:.1f}s — under the {silence_floor}s floor, so this "
            "is a genuinely silent track, not a quiet one"
        )
        return result

    result["under_levelled"] = True
    result["suggested_gain"] = round(REFERENCE_PEAK_RMS / peak, 2)
    result["suggested_chain"] = "loudnorm"
    result["detail"] = (
        f"recorded ~{result['suggested_gain']:.1f}× too quiet: probing at "
        f"RMS ≥ {probe_threshold:.5f} finds {probe_speech:.1f}s of speech that "
        f"the pinned {threshold} threshold cannot see"
    )
    return result


# --- the stage ---------------------------------------------------------------


def analyze_wav(
    path,
    frame_ms: int = DEFAULT_FRAME_MS,
    merge_gap: float = DEFAULT_MERGE_GAP_SECONDS,
    min_span: float = DEFAULT_MIN_SPAN_SECONDS,
    threshold: float = SPEECH_RMS_THRESHOLD,
    silence_floor: float = SILENT_MAX_SPEECH_SECONDS,
) -> dict:
    """Gate one wav file. Raises :class:`GateError` on an unusable input."""
    path = Path(path)
    try:
        handle = wave.open(str(path), "rb")
    except (OSError, wave.Error) as exc:
        raise GateError(f"cannot read {path}: {exc}") from exc

    with handle:
        rate = handle.getframerate()
        width = handle.getsampwidth()
        channels = handle.getnchannels()
        total_frames = handle.getnframes()
        if width != 2:
            raise GateError(
                f"{path} is {width * 8}-bit; S2 gates the 16-bit output of "
                "prep_audio.py — run S1 first"
            )
        if not rate:
            raise GateError(f"{path} declares a sample rate of 0")

        duration = total_frames / rate
        frame_samples = max(1, int(round(rate * frame_ms / 1000.0)))
        frame_seconds = frame_samples / rate

        peak = 0.0
        energy = 0.0
        counted = 0
        rms_values = []
        for rms, sample_frames in iter_frame_rms(handle, frame_samples):
            rms_values.append(rms)
            peak = max(peak, rms)
            energy += rms * rms * sample_frames
            counted += sample_frames

    spans = spans_from_frames(
        rms_values,
        frame_seconds,
        duration,
        merge_gap=merge_gap,
        min_span=min_span,
        threshold=threshold,
    )
    speech_seconds = sum(span["duration"] for span in spans)
    silent = is_effectively_silent(speech_seconds, silence_floor)

    # Only a silent-looking track is worth a second look, and only there does the
    # extra span pass cost anything.
    probe = (
        probe_under_levelled(
            rms_values,
            frame_seconds,
            duration,
            peak,
            merge_gap=merge_gap,
            min_span=min_span,
            threshold=threshold,
            silence_floor=silence_floor,
        )
        if silent
        else {
            "under_levelled": False,
            "probe_threshold": None,
            "probe_speech_seconds": 0.0,
            "dynamic_range": None,
            "suggested_gain": None,
            "suggested_chain": None,
        }
    )

    return {
        "path": str(path),
        "sample_rate": rate,
        "channels": channels,
        "duration_seconds": round(duration, 3),
        "frame_ms": frame_ms,
        "frame_seconds": round(frame_seconds, 6),
        "threshold": threshold,
        "merge_gap_seconds": merge_gap,
        "min_span_seconds": min_span,
        "silence_floor_seconds": silence_floor,
        "peak_rms": round(peak, 6),
        "mean_rms": round((energy / counted) ** 0.5, 6) if counted else 0.0,
        "span_count": len(spans),
        "spans": spans,
        "speech_seconds": round(speech_seconds, 3),
        "speech_fraction": round(speech_seconds / duration, 6) if duration else 0.0,
        # An under-levelled track is *not* silent, and saying so is the whole
        # point: every consumer branches on this key, so the fix has to land
        # here rather than in a parallel flag each of them must remember.
        "effectively_silent": silent and not probe["under_levelled"],
        "gated_silent_at_threshold": silent,
        "under_levelled": probe["under_levelled"],
        "probe_threshold": probe["probe_threshold"],
        "probe_speech_seconds": probe["probe_speech_seconds"],
        "dynamic_range": probe["dynamic_range"],
        "suggested_gain": probe["suggested_gain"],
        "suggested_chain": probe["suggested_chain"],
        "level_detail": probe.get("detail"),
    }


def gate_track(meeting_dir, track: str, clock=time.monotonic, **options) -> dict:
    """Gate one track; returns its entry for the stage JSON."""
    src = input_path(meeting_dir, track)
    entry = {"track": track, "input": str(src)}

    if not src.is_file():
        entry.update(
            {
                "status": STATUS_MISSING,
                "detail": f"no 16 kHz track at {src} — run prep_audio.py first",
                "elapsed_seconds": 0.0,
            }
        )
        return entry

    started = clock()
    try:
        entry.update(analyze_wav(src, **options))
    except GateError as exc:
        entry.update(
            {
                "status": STATUS_FAILED,
                "detail": str(exc),
                "elapsed_seconds": round(clock() - started, 3),
            }
        )
        return entry

    entry["elapsed_seconds"] = round(clock() - started, 3)
    entry["status"] = STATUS_OK
    if entry.get("under_levelled"):
        entry["detail"] = (
            f"UNDER-LEVELLED — {entry['level_detail']}; "
            f"re-run S1 for this track with --chain loudnorm, then re-gate "
            f"(pipeline.py does it automatically)"
        )
    elif entry["effectively_silent"]:
        # Say *why* it is silent, so "no ASR pass is worth running" can never
        # again be read as a fact that was never checked.
        entry["detail"] = (
            "effectively silent — no ASR pass is worth running "
            f"({entry.get('level_detail') or 'no speech spans found'})"
        )
    else:
        entry["detail"] = f"{entry['span_count']} speech span(s)"
    return entry


def run(meeting_dir, tracks=DEFAULT_TRACKS, clock=time.monotonic, **options) -> dict:
    """Gate every requested track and build the stage report."""
    meeting_dir = Path(meeting_dir)
    report = {
        "stage": "gate",
        "meeting_dir": str(meeting_dir),
        "threshold": options.get("threshold", SPEECH_RMS_THRESHOLD),
        "silence_floor_seconds": options.get(
            "silence_floor", SILENT_MAX_SPEECH_SECONDS
        ),
        "tracks": [],
    }

    for track in tracks:
        report["tracks"].append(gate_track(meeting_dir, track, clock=clock, **options))

    statuses = {entry["status"] for entry in report["tracks"]}
    if STATUS_FAILED in statuses:
        report["status"] = STATUS_FAILED
        report["detail"] = "at least one track could not be gated"
    elif statuses <= {STATUS_MISSING}:
        report["status"] = STATUS_FAILED
        report["detail"] = f"no 16 kHz tracks found under {work_dir(meeting_dir)}"
    else:
        report["status"] = STATUS_OK
        report["detail"] = "all present tracks gated"

    report["total_seconds"] = round(
        sum(entry.get("elapsed_seconds") or 0.0 for entry in report["tracks"]), 3
    )
    # After the verdict and the elapsed tally, never before them: carried
    # entries describe a previous invocation and must not colour this one.
    carry_forward_tracks(meeting_dir, report)
    # A silent track is information, not an error: the verdict travels in the
    # per-track entries and pipeline.py decides what to skip. Collected after
    # the carry-forward, because pipeline.py drops a track from the ASR pass on
    # this list alone — a track this run did not re-gate is still silent.
    report["silent_tracks"] = [
        entry["track"] for entry in report["tracks"] if entry.get("effectively_silent")
    ]
    # Kept separate from `silent_tracks` on purpose: these tracks must *not* be
    # dropped from the ASR pass, they must be re-levelled and re-gated. Carried
    # entries are included — a track this run did not re-gate is still quiet.
    report["under_levelled_tracks"] = [
        entry["track"] for entry in report["tracks"] if entry.get("under_levelled")
    ]
    return report


def carry_forward_tracks(meeting_dir, report: dict) -> dict:
    """Keep the previous report's entries for tracks this run did not touch.

    ``run()`` overwrites ``gate.json`` wholesale, so a ``--track system``
    invocation would erase the record that ``mic`` was effectively silent.
    ``pipeline.read_silent_tracks`` then finds nothing, and the next run spends
    a full ASR pass on a track S2 had already ruled out. Carried entries are
    marked so nothing reads them as this run's work.
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
        f"acta-notes gate — {report['status'].upper()} "
        f"(RMS ≥ {report['threshold']}, {report['total_seconds']:.1f}s)"
    ]
    for entry in report["tracks"]:
        if entry["status"] != STATUS_OK:
            lines.append(f"  [{entry['status']:<7}] {entry['track']:<8} {entry['detail']}")
            continue
        if entry.get("under_levelled"):
            mark = "QUIET  "
        elif entry["effectively_silent"]:
            mark = "silent "
        else:
            mark = "speech "
        lines.append(
            f"  [{mark}] {entry['track']:<8} "
            f"{entry['speech_seconds']:.1f}s speech in "
            f"{entry['duration_seconds']:.1f}s "
            f"({entry['speech_fraction'] * 100:.1f}%), "
            f"{entry['span_count']} span(s), peak RMS {entry['peak_rms']:.4f}"
        )
        if entry.get("under_levelled"):
            lines.append(f"           ⚠ {entry['detail']}")
    if report["status"] == STATUS_FAILED:
        lines.append("")
        lines.append(report.get("detail", "gate failed"))
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


def main(argv=None, clock=time.monotonic) -> int:
    parser = argparse.ArgumentParser(
        prog="gate.py",
        description=(
            "S2: frame-wise RMS gate over the 16 kHz tracks — speech spans, "
            "speech seconds and an effectively-silent verdict per track."
        ),
    )
    parser.add_argument("meeting_dir", help="the ~/Acta/<meeting> folder")
    parser.add_argument(
        "--track",
        dest="tracks",
        action="append",
        metavar="NAME",
        help="track to gate (repeatable; default: mic and system)",
    )
    parser.add_argument(
        "--frame-ms", type=int, default=DEFAULT_FRAME_MS, help="RMS frame length"
    )
    parser.add_argument(
        "--merge-gap",
        type=float,
        default=DEFAULT_MERGE_GAP_SECONDS,
        help="voiced frames closer than this become one span",
    )
    parser.add_argument(
        "--min-span",
        type=float,
        default=DEFAULT_MIN_SPAN_SECONDS,
        help="drop merged spans shorter than this",
    )
    parser.add_argument(
        "--silence-floor",
        type=float,
        default=SILENT_MAX_SPEECH_SECONDS,
        help="a track with less speech than this is effectively silent",
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
    # Every one of these degraded silently rather than erroring: --frame-ms 0
    # clamped to a single sample per frame (a severe slowdown that still looked
    # like a successful gate), and a negative --silence-floor made
    # `is_effectively_silent` unsatisfiable, so a silent track passed the gate.
    if args.frame_ms <= 0:
        parser.error("--frame-ms must be a positive number of milliseconds")
    if args.merge_gap < 0:
        parser.error("--merge-gap cannot be negative")
    if args.min_span < 0:
        parser.error("--min-span cannot be negative")
    if args.silence_floor < 0:
        parser.error("--silence-floor cannot be negative")

    report = run(
        meeting_dir,
        tracks=tuple(args.tracks) if args.tracks else DEFAULT_TRACKS,
        clock=clock,
        frame_ms=args.frame_ms,
        merge_gap=args.merge_gap,
        min_span=args.min_span,
        silence_floor=args.silence_floor,
    )
    write_stage_json(meeting_dir, report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
