#!/usr/bin/env bash
# Real unit-test run.
#
# `swift test` merely COMPILES the test bundle but does NOT execute it (there is no `xctest` host
# utility under Command Line Tools), so a failing test still exits 0. Real tests (swift-testing) run
# through the ActaTestRunner executable: it exits non-zero on the first failure.
#
# ⚠️ The runner is NOT launched with `swift run`, and that is not a style choice. swift-testing's
# runtime lives in a framework whose location depends on which toolchain is selected, and pointing
# dyld at it needs DYLD_FRAMEWORK_PATH — which the kernel strips when exec'ing a SIP-protected
# binary, and `swift` is one. Through `swift run` the variable never reaches the runner and the
# process dies at load time with "Library not loaded: @rpath/Testing.framework". So: build, then exec
# the product directly, which is an ordinary binary and keeps the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --product ActaTestRunner

BIN="$(swift build --product ActaTestRunner --show-bin-path)/ActaTestRunner"
[ -x "$BIN" ] || { echo "test.sh: built runner not found at $BIN" >&2; exit 1; }

# Locate swift-testing's runtime. Under a selected Xcode it sits in SharedFrameworks; a toolchain
# that ships it on the default search path needs nothing, so an empty result is not an error.
for candidate in \
  "$(xcode-select -p 2>/dev/null)/../SharedFrameworks" \
  "$(xcrun --find swift 2>/dev/null | xargs dirname 2>/dev/null)/../lib/swift-6.2/macosx"
do
  if [ -d "${candidate}/Testing.framework" ]; then
    export DYLD_FRAMEWORK_PATH="$(cd "$candidate" && pwd)${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
    break
  fi
done

exec "$BIN" "$@"
