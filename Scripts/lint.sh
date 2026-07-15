#!/usr/bin/env bash
# SwiftLint wrapper for a machine with Command Line Tools ONLY (no full Xcode).
# The Homebrew SwiftLint binary cannot find sourcekitdInProc.framework, so we point the loader at it.
# "No lintable files" is also treated as success (matters early on, while there is little code).
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
export DYLD_FRAMEWORK_PATH="$(xcode-select -p)/usr/lib:${DYLD_FRAMEWORK_PATH:-}"

out="$(swiftlint lint --quiet "$@" 2>&1)" && code=0 || code=$?

if printf '%s' "$out" | grep -q "No lintable files found"; then
  echo "swiftlint: no .swift files yet — skipping"
  exit 0
fi

printf '%s\n' "$out"
exit "$code"
