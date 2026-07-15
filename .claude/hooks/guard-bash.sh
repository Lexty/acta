#!/usr/bin/env bash
# PreToolUse-хук на Bash: блокирует заведомо деструктивные команды.
# Актуально при автономном прогоне (ralphex + --dangerously-skip-permissions).
# Контракт Claude Code: на stdin — JSON tool-call; exit 2 = заблокировать (stderr виден модели),
# exit 0 = разрешить. Философия — блокировать только ОЧЕВИДНО опасное, не мешать обычной работе.
set -euo pipefail

CMD="$(/usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || true)"
[ -z "$CMD" ] && exit 0

block() { echo "⛔ Заблокировано guard-bash: $1" >&2; echo "Команда: $CMD" >&2; exit 2; }

# 1) rm -rf по опасным целям (корень, дом, системные пути, голый glob, . / ..)
if echo "$CMD" | grep -Eq '\brm\b[^|;&]*-[a-zA-Z]*r[a-zA-Z]*f|\brm\b[^|;&]*-[a-zA-Z]*f[a-zA-Z]*r|\brm\b[^|;&]*-r[a-zA-Z]*\s+-f'; then
  if echo "$CMD" | grep -Eq 'rm[^|;&]*\s(-{1,2}[a-zA-Z]+\s+)*(/|/\*|~|~/|\$HOME|\.|\.\.|\*)(\s|$)'; then
    block "rm -rf по опасной цели (/, ~, \$HOME, ., .., *)"
  fi
  if echo "$CMD" | grep -Eq 'rm[^|;&]*\s(/Users|/System|/Library|/Applications|/etc|/bin|/sbin|/usr|/var|/opt|/private|/dev)(/|\s|$)'; then
    block "rm -rf по системному пути"
  fi
fi

# 2) Fork-бомба
echo "$CMD" | grep -Eq ':\(\)\s*\{\s*:\|:&\s*\}\s*;\s*:' && block "fork-бомба"

# 3) Запись на устройства / форматирование
echo "$CMD" | grep -Eq '\bdd\b[^|;&]*of=/dev/' && block "dd на /dev/"
echo "$CMD" | grep -Eq '\bmkfs(\.|\b)' && block "mkfs (форматирование)"
echo "$CMD" | grep -Eq '>\s*/dev/(disk|sd|rdisk)' && block "запись в /dev/disk"

# 4) git clean -fdx по всему — легко теряет незакоммиченное
echo "$CMD" | grep -Eq '\bgit\s+clean\b[^|;&]*-[a-zA-Z]*x' && block "git clean -x (сотрёт .build и незакоммиченное; используйте точечно)"

exit 0
