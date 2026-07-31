#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns and Resources/AppIcon-dev.icns from the
# 1024x1024 masters in Resources/icon-src/.
#
# Uses only sips and iconutil, both shipped with macOS, so this runs on a bare
# machine with Command Line Tools and nothing else — the same constraint
# bundle.sh works under (no full Xcode, no Homebrew).
#
# The masters are already in macOS icon geometry: an 824x824 body centred on a
# transparent 1024x1024 canvas, corners rounded at 184 px (22.4% of the body).
# That 100 px margin is not padding to taste — macOS draws the icon shadow
# there, so anything painted into it reads wrong next to system icons. If you
# replace a master, normalise it to that geometry first: a raw export from an
# image generator is full-bleed and will not match.
#
# Usage: Scripts/make-icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC_DIR="Resources/icon-src"

# master png -> output icns
ICONS=(
  "$SRC_DIR/AppIcon-1024.png:Resources/AppIcon.icns"
  "$SRC_DIR/AppIcon-dev-1024.png:Resources/AppIcon-dev.icns"
)

# iconutil requires exactly these names. The 1x and 2x of adjacent sizes are the
# same pixel count on purpose: icon_32x32.png and icon_16x16@2x.png are both 32.
SIZES=(
  "16:icon_16x16"
  "32:icon_16x16@2x"
  "32:icon_32x32"
  "64:icon_32x32@2x"
  "128:icon_128x128"
  "256:icon_128x128@2x"
  "256:icon_256x256"
  "512:icon_256x256@2x"
  "512:icon_512x512"
  "1024:icon_512x512@2x"
)

for entry in "${ICONS[@]}"; do
  master="${entry%%:*}"
  out="${entry##*:}"

  if [[ ! -f "$master" ]]; then
    echo "error: missing master $master" >&2
    exit 1
  fi

  # A master that is not 1024x1024 would silently yield a blurry or cropped icon
  # set, so refuse rather than guess.
  dims="$(sips -g pixelWidth -g pixelHeight "$master" | awk '/pixel/ {print $2}' | paste -sd x -)"
  if [[ "$dims" != "1024x1024" ]]; then
    echo "error: $master is ${dims}, expected 1024x1024" >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  iconset="$tmp/$(basename "${out%.icns}").iconset"
  mkdir -p "$iconset"

  for size_entry in "${SIZES[@]}"; do
    px="${size_entry%%:*}"
    name="${size_entry##*:}"
    sips -s format png -z "$px" "$px" "$master" --out "$iconset/$name.png" >/dev/null
  done

  iconutil -c icns "$iconset" -o "$out"
  rm -rf "$tmp"

  echo "==> $out ($(du -h "$out" | cut -f1 | tr -d ' ')) from $(basename "$master")"
done

echo "==> done — rebuild to pick the icons up: Scripts/bundle.sh [stable|dev]"
