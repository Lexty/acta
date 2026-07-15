#!/usr/bin/env bash
# Сборка Acta.app через SwiftPM без полного Xcode (только Command Line Tools).
# Шаги: swift build -c release → упаковка в .app → ad-hoc codesign со стабильной идентичностью.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Acta"
BUNDLE_ID="dev.personal.acta"
APP_DIR="$ROOT/$APP_NAME.app"
BIN="$ROOT/.build/release/$APP_NAME"

echo "==> swift build -c release"
swift build -c release

if [[ ! -x "$BIN" ]]; then
  echo "ошибка: не найден бинарь $BIN" >&2
  exit 1
fi

echo "==> сборка бандла $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> ad-hoc codesign (identifier=$BUNDLE_ID)"
codesign --force --sign - \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/Acta.entitlements" \
  "$APP_DIR"

echo "==> готово: $APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true
