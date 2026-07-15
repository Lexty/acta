#!/usr/bin/env bash
# Build and launch an Acta flavor.
# Usage: run.sh [stable|dev]   (default: dev)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAVOR="${1:-dev}"

bash "$ROOT/Scripts/bundle.sh" "$FLAVOR"

case "$FLAVOR" in
  stable) open "$ROOT/Acta.app" ;;
  dev)    open "$ROOT/Acta Dev.app" ;;
esac
