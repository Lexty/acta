#!/usr/bin/env bash
# Собрать и запустить Acta.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT/Scripts/bundle.sh"
open "$ROOT/Acta.app"
