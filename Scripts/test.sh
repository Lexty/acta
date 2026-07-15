#!/usr/bin/env bash
# Real unit-test run in a Command Line Tools ONLY environment.
#
# Here `swift test` merely COMPILES the test bundle but does NOT execute it (there is no `xctest`
# host utility), so a failing test still exits 0. Real tests (swift-testing) run through the
# ActaTestRunner executable: it exits non-zero on the first failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

exec swift run ActaTestRunner "$@"
