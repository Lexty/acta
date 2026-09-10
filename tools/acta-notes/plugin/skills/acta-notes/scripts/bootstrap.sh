#!/usr/bin/env bash
# acta-notes bootstrap — build the fluidaudiocli binary the pipeline depends on.
#
# Clones FluidInference/FluidAudio pinned at a fixed tag into the acta-notes
# cache and builds `fluidaudiocli` in release mode. On every successful build it
# writes a stamp file; the stamp — not a `git describe` — is the single source of
# truth about what is installed. `doctor.py` reads the same stamp and never
# shells into git to re-derive the tag.
#
# Idempotency: a run is a no-op when the stamp exists, its fluidaudio_tag equals
# the pin below, and the binary it points at is executable. A missing, corrupt or
# mismatched stamp forces a rebuild, as does --force.
set -euo pipefail

FLUIDAUDIO_TAG="v0.15.5"
FLUIDAUDIO_REPO="${ACTA_FLUIDAUDIO_REPO:-https://github.com/FluidInference/FluidAudio.git}"
CACHE_DIR="${ACTA_CACHE_DIR:-$HOME/.cache/acta-notes/fluidaudio}"
STAMP_PATH="$CACHE_DIR/.acta-bootstrap.json"
BIN_RELPATH=".build/release/fluidaudiocli"

FORCE=0

usage() {
	cat <<EOF
Usage: bootstrap.sh [--force] [--help]

Build fluidaudiocli from FluidInference/FluidAudio pinned at $FLUIDAUDIO_TAG.

  --force   rebuild even when the bootstrap stamp is already valid
  --help    show this message

Cache dir : $CACHE_DIR   (override with ACTA_CACHE_DIR)
Stamp file: $STAMP_PATH
Binary    : \$CACHE_DIR/$BIN_RELPATH

ACTA_CACHE_DIR moves the checkout, the stamp, and where doctor.py reads it —
export it for doctor too, or it reports "no usable bootstrap stamp". The run
stages (transcribe.py, diarize.py) do NOT read it: they resolve
\$HOME/.cache/acta-notes/fluidaudio, so a non-default cache dir also needs
ACTA_FLUIDAUDIO_BIN=\$CACHE_DIR/$BIN_RELPATH exported. doctor.py checks exactly
that and stays RED until it is set.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "bootstrap.sh: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

die() {
	echo "bootstrap.sh: $*" >&2
	exit 1
}

# Only python3 is needed to *read* the stamp. git and swift are build
# dependencies and are required below, after the idempotency check has had its
# say — demanding them here failed a guaranteed-no-op second run on a machine
# that has since lost Xcode CLT, contradicting both the "a second run is a
# no-op" promise and doctor.check_swift, which deliberately warns rather than
# fails when a usable binary is already built.
command -v python3 >/dev/null 2>&1 || die "python3 is required but not on PATH"

# --- idempotency: decide from the stamp, never from the checkout -------------
stamp_is_valid() {
	[ -f "$STAMP_PATH" ] || return 1
	python3 - "$STAMP_PATH" "$FLUIDAUDIO_TAG" <<'PY'
import json, os, sys

stamp_path, pin = sys.argv[1], sys.argv[2]
try:
    with open(stamp_path, encoding="utf-8") as fh:
        stamp = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(stamp, dict) or stamp.get("fluidaudio_tag") != pin:
    sys.exit(1)
binary = stamp.get("binary_path") or ""
if not (binary and os.path.isfile(binary) and os.access(binary, os.X_OK)):
    sys.exit(1)
sys.exit(0)
PY
}

if [ "$FORCE" -eq 0 ] && stamp_is_valid; then
	echo "acta-notes: fluidaudiocli already bootstrapped at $FLUIDAUDIO_TAG (stamp: $STAMP_PATH)"
	exit 0
fi

# This run really will build, so now the build toolchain has to be there.
for prog in git swift; do
	command -v "$prog" >/dev/null 2>&1 || die "$prog is required to build fluidaudiocli but is not on PATH"
done

# --- clone / update the pinned checkout -------------------------------------
mkdir -p "$(dirname "$CACHE_DIR")"

if [ -d "$CACHE_DIR/.git" ]; then
	echo "acta-notes: updating existing checkout in $CACHE_DIR"
	# The reused checkout has to be a checkout of the repo this run means to build.
	# An earlier ACTA_FLUIDAUDIO_REPO override otherwise persists silently into a
	# stamp that names the default upstream.
	HAVE_ORIGIN="$(git -C "$CACHE_DIR" remote get-url origin 2>/dev/null || true)"
	[ "$HAVE_ORIGIN" = "$FLUIDAUDIO_REPO" ] ||
		die "$CACHE_DIR is a checkout of '${HAVE_ORIGIN:-<no origin>}', not $FLUIDAUDIO_REPO — remove $CACHE_DIR and re-run"
	git -C "$CACHE_DIR" fetch --tags --depth 1 origin "refs/tags/$FLUIDAUDIO_TAG:refs/tags/$FLUIDAUDIO_TAG" ||
		git -C "$CACHE_DIR" fetch --tags origin
elif [ -e "$CACHE_DIR" ] && [ -n "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
	# An interrupted clone, or a hand-made directory. `git clone` fails here with
	# its own generic "destination path already exists" on this and every
	# subsequent run, leaving a bootstrap that cannot recover and a doctor that
	# stays red with no in-tool remedy — so say what to do about it.
	die "$CACHE_DIR exists but is not a git checkout (an interrupted clone?) — remove it and re-run"
else
	echo "acta-notes: cloning $FLUIDAUDIO_REPO at $FLUIDAUDIO_TAG into $CACHE_DIR"
	git clone --depth 1 --branch "$FLUIDAUDIO_TAG" "$FLUIDAUDIO_REPO" "$CACHE_DIR"
fi

git -C "$CACHE_DIR" checkout --quiet --detach "refs/tags/$FLUIDAUDIO_TAG" ||
	die "cannot check out tag $FLUIDAUDIO_TAG"

# --- build -------------------------------------------------------------------
echo "acta-notes: swift build -c release --product fluidaudiocli (this takes a few minutes)"
(cd "$CACHE_DIR" && swift build -c release --product fluidaudiocli)

BINARY_PATH="$CACHE_DIR/$BIN_RELPATH"
[ -x "$BINARY_PATH" ] || die "build finished but $BINARY_PATH is not executable"

# --- stamp -------------------------------------------------------------------
COMMIT="$(git -C "$CACHE_DIR" rev-parse HEAD)"
# `sed -n 1p`, not `head -n 1`: head exits after the first line and can SIGPIPE
# swift, which under `set -e -o pipefail` would abort the script *here* — after a
# successful multi-minute build and before the stamp is written, so the next run
# rebuilds from scratch.
SWIFT_VERSION="$(swift --version 2>&1 | sed -n 1p)"

python3 - "$STAMP_PATH" "$FLUIDAUDIO_TAG" "$COMMIT" "$BINARY_PATH" "$SWIFT_VERSION" <<'PY'
import datetime, json, sys

stamp_path, tag, commit, binary_path, swift_version = sys.argv[1:6]
stamp = {
    "fluidaudio_tag": tag,
    "commit": commit,
    "binary_path": binary_path,
    "built_at": datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
    "swift_version": swift_version,
}
with open(stamp_path, "w", encoding="utf-8") as fh:
    json.dump(stamp, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

echo "acta-notes: bootstrapped $FLUIDAUDIO_TAG ($COMMIT)"
echo "acta-notes: binary $BINARY_PATH"
echo "acta-notes: stamp  $STAMP_PATH"
