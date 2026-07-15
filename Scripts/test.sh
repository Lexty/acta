#!/usr/bin/env bash
# Настоящий прогон юнит-тестов в окружении ТОЛЬКО с Command Line Tools.
#
# `swift test` тут лишь СОБИРАЕТ тестовый бандл, но НЕ исполняет его (нет хост-утилиты `xctest`),
# поэтому падающий тест даёт exit 0. Реальные тесты (swift-testing) прогоняем через
# executable-раннер ActaTestRunner: он падает с ненулевым кодом при первой же ошибке.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

exec swift run ActaTestRunner "$@"
