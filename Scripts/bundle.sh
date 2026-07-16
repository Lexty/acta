#!/usr/bin/env bash
# Build an Acta .app with SwiftPM without full Xcode (Command Line Tools only).
#
# Two flavors, deliberately different identities so they can coexist:
#
#   stable -> Acta.app      / dev.personal.acta      / archive ~/Acta
#   dev    -> Acta Dev.app  / dev.personal.acta-dev  / archive ~/Acta-dev
#
# Why the identities differ: TCC binds a permission to the app's designated requirement. Both flavors
# are signed with the same local certificate (see Scripts/setup-signing.sh) but with different bundle
# identifiers, so their requirements differ — Screen Recording granted to one is never shared with or
# revoked by the other. Separate archives likewise keep an experimental build from ever writing into
# real recordings.
#
# Why a certificate and not ad-hoc: an ad-hoc signature (codesign -s -) pins the requirement to the
# binary's cdhash, which changes on every rebuild, so macOS revokes the grant every single build. The
# self-signed certificate gives each flavor a STABLE requirement (identifier + certificate leaf), so a
# rebuild keeps its grant. Switching an already-granted app from ad-hoc to the certificate changes its
# requirement once, so it must be granted one final time after the first certificate-signed build.
#
# Usage: bundle.sh [stable|dev]      (default: dev — the safe default; stable is the deliberate act)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLAVOR="${1:-dev}"

case "$FLAVOR" in
  stable)
    APP_NAME="Acta"
    BUNDLE_ID="dev.personal.acta"
    DISPLAY_NAME="Acta"
    ;;
  dev)
    APP_NAME="Acta Dev"
    BUNDLE_ID="dev.personal.acta-dev"
    DISPLAY_NAME="Acta Dev"
    ;;
  *)
    echo "error: unknown flavor '$FLAVOR' (expected: stable | dev)" >&2
    exit 2
    ;;
esac

# --- stable is only ever built from a verified, tagged, clean commit -------------------------------
# Without this guard it is a matter of time before a work-in-progress build gets installed as the
# stable one and that is discovered during a real meeting.
GIT_DESC="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ "$FLAVOR" == "stable" ]]; then
  if ! git diff --quiet HEAD 2>/dev/null || [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "error: refusing to build stable from a dirty tree — commit or stash first" >&2
    exit 1
  fi
  if ! TAG="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
    echo "error: refusing to build stable from an untagged commit ($GIT_SHA)." >&2
    echo "       stable means 'verified live'. Tag it first, e.g.:" >&2
    echo "       git tag -a v0.1.0 -m '<what was verified live>'" >&2
    exit 1
  fi
  echo "==> stable from tag $TAG ($GIT_SHA)"
else
  echo "==> dev from $GIT_DESC"
fi

APP_DIR="$ROOT/$APP_NAME.app"
BIN="$ROOT/.build/release/Acta"

echo "==> swift build -c release"
swift build -c release

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/Acta"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Flavor identity + build provenance. ActaBuildFlavor/ActaBuildRevision are custom keys: with two
# apps installed, "which build produced this recording?" must have an answer.
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
"$PB" -c "Set :CFBundleName $DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
"$PB" -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
"$PB" -c "Add :ActaBuildFlavor string $FLAVOR" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || "$PB" -c "Set :ActaBuildFlavor $FLAVOR" "$APP_DIR/Contents/Info.plist"
"$PB" -c "Add :ActaBuildRevision string $GIT_DESC" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || "$PB" -c "Set :ActaBuildRevision $GIT_DESC" "$APP_DIR/Contents/Info.plist"

# Sign with the local self-signed identity so the designated requirement is stable across rebuilds
# (a TCC grant then survives a rebuild). setup-signing.sh is idempotent and non-interactive, so on a
# fresh machine the first build creates the identity with no prompt.
KEYCHAIN="$HOME/Library/Keychains/acta-codesign.keychain-db"
IDENTITY_CN="Acta Local Signing"
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_CN"; then
  echo "==> no local signing identity yet — running one-time setup"
  bash "$ROOT/Scripts/setup-signing.sh"
fi
security unlock-keychain -p "" "$KEYCHAIN"
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_CN" | grep -oE '[0-9A-F]{40}' | head -1)"
if [[ -z "$IDENTITY" ]]; then
  echo "error: could not resolve the '$IDENTITY_CN' signing identity" >&2
  exit 1
fi

echo "==> codesign (identity=$IDENTITY_CN, identifier=$BUNDLE_ID)"
codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/Acta.entitlements" \
  --keychain "$KEYCHAIN" \
  "$APP_DIR"

echo "==> done: $APP_DIR"
echo "    flavor=$FLAVOR  bundle=$BUNDLE_ID  revision=$GIT_DESC"
codesign --verify --verbose=2 "$APP_DIR" || true
echo "==> designated requirement (stable across rebuilds):"
codesign -d --requirements - "$APP_DIR" 2>&1 | grep designated || true
