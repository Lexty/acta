#!/usr/bin/env bash
# SwiftLint-обёртка для машины с ТОЛЬКО Command Line Tools (без полного Xcode).
# Homebrew-бинарь SwiftLint не находит sourcekitdInProc.framework → указываем путь загрузчику.
# Также трактуем «нет .swift файлов» как успех (важно на ранних стадиях, пока кода мало).
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
export DYLD_FRAMEWORK_PATH="$(xcode-select -p)/usr/lib:${DYLD_FRAMEWORK_PATH:-}"

out="$(swiftlint lint --quiet "$@" 2>&1)" && code=0 || code=$?

if printf '%s' "$out" | grep -q "No lintable files found"; then
  echo "swiftlint: .swift файлов пока нет — пропуск"
  exit 0
fi

printf '%s\n' "$out"
exit "$code"
