#!/usr/bin/env python3
"""acta-notes doctor — preflight for the meeting pipeline.

Checks ffmpeg, the Swift toolchain, the fluidaudiocli bootstrap stamp, the
FluidAudio model set and free disk, and aggregates them into one status:

    green  everything the pipeline needs is present
    warn   usable, but something deserves attention (e.g. disk getting tight)
    red    a run would fail or die mid-meeting — exit code 1

The point of the red/exit-1 contract is that a run refuses to start rather than
crashing halfway through a meeting.

Two design rules worth stating out loud:

* The FluidAudio tag is read from the bootstrap stamp written by ``bootstrap.sh``
  (``~/.cache/acta-notes/fluidaudio/.acta-bootstrap.json``). Doctor never shells
  into git to re-derive it — the stamp is the record of what was actually built.
* Model checks are two-tier, because v1 only ever loads two models. See
  REQUIRED_MODELS / OPTIONAL_MODELS below.

Stdlib only (no numpy, no uv, nothing installed globally).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

# --- pins and constants ------------------------------------------------------

#: The FluidAudio release this plugin is pinned to. bootstrap.sh builds this tag
#: and records it in the stamp; doctor compares the stamp against this constant.
FLUIDAUDIO_TAG = "v0.15.5"

STAMP_NAME = ".acta-bootstrap.json"
FLUIDAUDIO_BIN_RELPATH = Path(".build") / "release" / "fluidaudiocli"

#: Models v1 actually loads. parakeet-tdt-0.6b-v3 does ASR (D1);
#: speaker-diarization backs the offline VBx diarizer (D2). Missing → red.
REQUIRED_MODELS = ("parakeet-tdt-0.6b-v3", "speaker-diarization")

#: Models present on a typical FluidAudio install that v1 never invokes:
#: sortformer and ls-eend are *streaming* diarizers (v1 is offline-only), and
#: parakeet-ctc-110m-coreml is loaded by v0.15.5 only when --custom-vocab
#: hotwords are requested. They are reported present/absent for information and
#: never turn the status warn or red — a machine holding only the two required
#: models must come out green.
OPTIONAL_MODELS = ("sortformer", "ls-eend", "parakeet-ctc-110m-coreml")

MODELS_SUBPATH = Path("Library") / "Application Support" / "FluidAudio" / "Models"

GB = 1024**3

# Disk thresholds — derivation, so the numbers are auditable:
#   * one meeting's 16 kHz mono s16 intermediates cost ~115 MB/h/track, i.e.
#     <= ~250 MB for the mic+system pair of a long meeting;
#   * a full FluidAudio checkout + release build costs ~362 MB (.build ~350 MB);
#   * the ~1.4 GB of models are downloaded once and already present.
# So 2 GB is the floor at which one meeting plus a from-scratch bootstrap still
# completes with headroom, and 5 GB warns while several meetings still fit.
# (An earlier "warn under 15 GB" would fire permanently on a 17 GB-free machine.)
DISK_FAIL_BYTES = 2 * GB
DISK_WARN_BYTES = 5 * GB

GREEN = "green"
WARN = "warn"
RED = "red"

_SEVERITY = {GREEN: 0, WARN: 1, RED: 2}
_MARKER = {GREEN: "ok  ", WARN: "warn", RED: "FAIL"}


# --- environment facade ------------------------------------------------------


class Env:
    """Filesystem / PATH facade.

    Every bit of ambient state doctor reads goes through this object so tests can
    inject a fake filesystem and binary resolver instead of touching the machine.
    """

    def __init__(self, home: str | os.PathLike[str] | None = None, environ=None):
        self.home = Path(home) if home is not None else Path.home()
        self.environ = dict(os.environ if environ is None else environ)

    # -- derived locations --
    @property
    def cache_dir(self) -> Path:
        """Where ``transcribe.py``/``diarize.py`` look absent an env override.

        Deliberately *not* affected by ``ACTA_CACHE_DIR``: those two resolve this
        exact path and nothing else, so this must keep describing where the run
        will actually look — that is what the ``binary_source == "stamp"`` check
        below compares against.
        """
        return self.home / ".cache" / "acta-notes" / "fluidaudio"

    @property
    def stamp_dir(self) -> Path:
        """Where ``bootstrap.sh`` wrote the stamp — it honours ``ACTA_CACHE_DIR``.

        Without this, a bootstrap run with ``ACTA_CACHE_DIR`` set leaves doctor
        reporting "no usable bootstrap stamp" forever: that branch fires before
        any binary check, so exporting ``ACTA_FLUIDAUDIO_BIN`` — the escape
        ``bootstrap.sh --help`` documents — cannot clear it, and ``pipeline.py``
        aborts at stage 0 with no way past.
        """
        override = self.environ.get("ACTA_CACHE_DIR")
        return Path(override) if override else self.cache_dir

    @property
    def stamp_path(self) -> Path:
        return self.stamp_dir / STAMP_NAME

    @property
    def models_dir(self) -> Path:
        return self.home / MODELS_SUBPATH

    # -- overridable primitives --
    def which(self, prog: str) -> str | None:
        return shutil.which(prog)

    def is_file(self, path) -> bool:
        return Path(path).is_file()

    def is_dir(self, path) -> bool:
        return Path(path).is_dir()

    def is_executable(self, path) -> bool:
        p = Path(path)
        return p.is_file() and os.access(str(p), os.X_OK)

    def read_text(self, path) -> str:
        return Path(path).read_text(encoding="utf-8")

    def free_bytes(self, path) -> int:
        st = os.statvfs(str(path))
        return st.f_bavail * st.f_frsize


# --- helpers -----------------------------------------------------------------


def _check(name: str, status: str, detail: str, **extra) -> dict:
    out = {"name": name, "status": status, "detail": detail}
    out.update(extra)
    return out


def read_stamp(env: Env):
    """Return the parsed bootstrap stamp, or None when absent/corrupt."""
    if not env.is_file(env.stamp_path):
        return None
    try:
        stamp = json.loads(env.read_text(env.stamp_path))
    except (OSError, ValueError):
        return None
    return stamp if isinstance(stamp, dict) else None


def resolve_fluidaudio_bin(env: Env, stamp=None):
    """Resolve the fluidaudiocli path: env override, then stamp, then cache path.

    Returns ``(path, source)``. ACTA_FLUIDAUDIO_BIN wins so tests (and anyone
    with a hand-built binary) can point the whole pipeline elsewhere.
    """
    override = env.environ.get("ACTA_FLUIDAUDIO_BIN")
    if override:
        return Path(override), "env:ACTA_FLUIDAUDIO_BIN"
    if stamp and stamp.get("binary_path"):
        return Path(stamp["binary_path"]), "stamp"
    return env.cache_dir / FLUIDAUDIO_BIN_RELPATH, "cache-default"


def resolve_ffmpeg_bin(env: Env):
    """Resolve ffmpeg: ACTA_FFMPEG_BIN override, then PATH."""
    override = env.environ.get("ACTA_FFMPEG_BIN")
    if override:
        return Path(override), "env:ACTA_FFMPEG_BIN"
    found = env.which("ffmpeg")
    return (Path(found), "path") if found else (None, "path")


def _human_bytes(n: int) -> str:
    return f"{n / GB:.1f} GiB"


# --- individual checks -------------------------------------------------------


def check_ffmpeg(env: Env) -> dict:
    path, source = resolve_ffmpeg_bin(env)
    if path is None:
        return _check(
            "ffmpeg", RED, "not found on PATH (set ACTA_FFMPEG_BIN or install ffmpeg)",
            path=None, source=source,
        )
    if not env.is_executable(path):
        return _check(
            "ffmpeg", RED, f"{path} is not executable", path=str(path), source=source
        )
    return _check("ffmpeg", GREEN, str(path), path=str(path), source=source)


def check_swift(env: Env, fluidaudio_ok: bool) -> dict:
    """Swift is a *build* dependency: bootstrap.sh needs it, a run does not.

    So its severity follows the binary it would produce — red only when the
    machine would actually have to build (or rebuild) ``fluidaudiocli``, and a
    warning when a usable binary is already there. Otherwise a machine with a
    working binary and no Xcode Command Line Tools refuses to process meetings
    over a toolchain it will never invoke.
    """
    found = env.which("swift")
    if found:
        return _check("swift", GREEN, found, path=found)
    if fluidaudio_ok:
        return _check(
            "swift", WARN,
            "not found on PATH — fine while fluidaudiocli is built, but "
            "bootstrap.sh cannot rebuild it (Xcode Command Line Tools provide it)",
            path=None,
        )
    return _check(
        "swift", RED,
        "not found on PATH and fluidaudiocli needs building "
        "(Xcode Command Line Tools provide it)",
        path=None,
    )


def check_bootstrap(env: Env) -> dict:
    """Validate the bootstrap stamp — the only source of truth for the tag.

    One exception, and the whole ``ACTA_FLUIDAUDIO_BIN`` contract rests on it:
    the override is the binary transcribe.py and diarize.py will actually invoke,
    so an executable one *can* carry a run on its own. Demanding a stamp on top
    of it made the documented escape hatch inert — a machine with a hand-built
    binary went RED here and pipeline.py aborted at stage 1 — so an override that
    works downgrades a missing or off-pin stamp to a warning. The run proceeds;
    what is lost is only the guarantee of *which* FluidAudio tag those bytes came
    from, which is what the warning says.
    """
    stamp = read_stamp(env)
    binary, source = resolve_fluidaudio_bin(env, stamp)
    overridden = source == "env:ACTA_FLUIDAUDIO_BIN"
    found_tag = stamp.get("fluidaudio_tag") if stamp else None

    if overridden and not env.is_executable(binary):
        return _check(
            "fluidaudio", RED,
            f"ACTA_FLUIDAUDIO_BIN={binary} is not executable — fix the override "
            "or unset it and run bootstrap.sh",
            stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
            found_tag=found_tag, binary_path=str(binary), binary_source=source,
        )

    if stamp is None:
        stamp_problem = f"no usable bootstrap stamp at {env.stamp_path}"
    elif found_tag != FLUIDAUDIO_TAG:
        stamp_problem = f"stamp records {found_tag!r}, pin is {FLUIDAUDIO_TAG!r}"
    else:
        stamp_problem = None

    if stamp_problem and overridden:
        return _check(
            "fluidaudio", WARN,
            f"{binary} via ACTA_FLUIDAUDIO_BIN — usable, but {stamp_problem}, so "
            f"its FluidAudio tag is unverified (run bootstrap.sh to pin "
            f"{FLUIDAUDIO_TAG})",
            stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
            found_tag=found_tag, binary_path=str(binary), binary_source=source,
        )

    if stamp is None:
        return _check(
            "fluidaudio", RED,
            f"no usable bootstrap stamp at {env.stamp_path} — run bootstrap.sh",
            stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
            found_tag=None, binary_path=str(binary), binary_source=source,
        )

    if found_tag != FLUIDAUDIO_TAG:
        return _check(
            "fluidaudio", RED,
            f"stamp records {found_tag!r}, pin is {FLUIDAUDIO_TAG!r} — "
            "run bootstrap.sh --force",
            stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
            found_tag=found_tag, binary_path=str(binary), binary_source=source,
        )

    if not env.is_executable(binary):
        return _check(
            "fluidaudio", RED,
            f"stamp is at {FLUIDAUDIO_TAG} but {binary} is not executable — "
            "run bootstrap.sh --force",
            stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
            found_tag=found_tag, binary_path=str(binary), binary_source=source,
        )

    # The stages do not read the stamp: absent ACTA_FLUIDAUDIO_BIN they resolve
    # the cache default and nothing else. So a stamp pointing somewhere else
    # would let this check go green over a binary no stage will ever invoke —
    # exactly the halfway-through-a-meeting failure doctor exists to prevent.
    if source == "stamp":
        run_binary = env.cache_dir / FLUIDAUDIO_BIN_RELPATH
        if run_binary != binary and not env.is_executable(run_binary):
            return _check(
                "fluidaudio", RED,
                f"the stamp records {binary}, but transcribe.py and diarize.py "
                f"resolve {run_binary}, which is not executable — export "
                f"ACTA_FLUIDAUDIO_BIN={binary} or run bootstrap.sh --force",
                stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
                found_tag=found_tag, binary_path=str(binary),
                binary_source=source, run_binary_path=str(run_binary),
            )

    commit = (stamp.get("commit") or "")[:12]
    detail = f"{FLUIDAUDIO_TAG} ({commit or 'unknown commit'}) — {binary}"
    return _check(
        "fluidaudio", GREEN, detail,
        stamp_path=str(env.stamp_path), expected_tag=FLUIDAUDIO_TAG,
        found_tag=found_tag, commit=stamp.get("commit"),
        built_at=stamp.get("built_at"), swift_version=stamp.get("swift_version"),
        binary_path=str(binary), binary_source=source,
    )


def check_models(env: Env) -> list[dict]:
    """Two-tier model checks — required models can be red, optional ones never."""
    checks = []
    for name in REQUIRED_MODELS:
        present = env.is_dir(env.models_dir / name)
        checks.append(
            _check(
                f"model:{name}",
                GREEN if present else RED,
                "present" if present else f"missing from {env.models_dir}",
                tier="required", present=present, model=name,
            )
        )
    for name in OPTIONAL_MODELS:
        present = env.is_dir(env.models_dir / name)
        checks.append(
            _check(
                f"model:{name}",
                GREEN,  # optional models never degrade the status
                "present" if present else "absent (optional — v1 never loads it)",
                tier="optional", present=present, model=name,
            )
        )
    return checks


def check_disk(env: Env) -> dict:
    try:
        free = env.free_bytes(env.home)
    except OSError as exc:
        return _check("disk", RED, f"cannot stat {env.home}: {exc}", free_bytes=None)

    extra = {
        "free_bytes": free,
        "fail_below_bytes": DISK_FAIL_BYTES,
        "warn_below_bytes": DISK_WARN_BYTES,
    }
    if free < DISK_FAIL_BYTES:
        return _check(
            "disk", RED,
            f"{_human_bytes(free)} free — below the {_human_bytes(DISK_FAIL_BYTES)} floor",
            **extra,
        )
    if free < DISK_WARN_BYTES:
        return _check(
            "disk", WARN,
            f"{_human_bytes(free)} free — below the {_human_bytes(DISK_WARN_BYTES)} comfort line",
            **extra,
        )
    return _check("disk", GREEN, f"{_human_bytes(free)} free", **extra)


# --- aggregation and rendering ----------------------------------------------


def aggregate(checks) -> str:
    status = GREEN
    for check in checks:
        if _SEVERITY[check["status"]] > _SEVERITY[status]:
            status = check["status"]
    return status


def run_checks(env: Env) -> dict:
    bootstrap = check_bootstrap(env)
    checks = [
        check_ffmpeg(env),
        # != RED, not == GREEN: a warned bootstrap (an executable
        # ACTA_FLUIDAUDIO_BIN with an unverified tag) still means there is
        # nothing for Swift to build, so it must not turn swift red.
        check_swift(env, bootstrap["status"] != RED),
        bootstrap,
    ]
    checks.extend(check_models(env))
    checks.append(check_disk(env))
    return {
        "status": aggregate(checks),
        "fluidaudio_tag_pin": FLUIDAUDIO_TAG,
        "models_dir": str(env.models_dir),
        "cache_dir": str(env.cache_dir),
        "stamp_dir": str(env.stamp_dir),
        "checks": checks,
    }


def render_human(report: dict) -> str:
    lines = [f"acta-notes doctor — status: {report['status'].upper()}"]
    for check in report["checks"]:
        lines.append(
            f"  [{_MARKER[check['status']]}] {check['name']:<28} {check['detail']}"
        )
    if report["status"] == RED:
        lines.append("")
        lines.append("Refusing to run: fix the FAIL lines above (bootstrap.sh, disk, ffmpeg).")
    return "\n".join(lines)


def exit_code(report: dict) -> int:
    return 1 if report["status"] == RED else 0


def main(argv=None, env: Env | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="doctor.py",
        description="Preflight the acta-notes pipeline (exit 1 when red).",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit the machine-readable report"
    )
    args = parser.parse_args(argv)

    env = env or Env()
    report = run_checks(env)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_human(report))
    return exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
