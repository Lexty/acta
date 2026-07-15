#!/usr/bin/env bash
# PreToolUse hook for Bash: blocks obviously destructive commands.
# Relevant during autonomous runs (ralphex + --dangerously-skip-permissions).
# Claude Code contract: the tool call arrives as JSON on stdin; exit 2 = block (stderr is shown to
# the model), exit 0 = allow. Philosophy: block only the OBVIOUSLY dangerous, never normal work.
set -euo pipefail

CMD="$(/usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || true)"
[ -z "$CMD" ] && exit 0

block() { echo "Blocked by guard-bash: $1" >&2; echo "Command: $CMD" >&2; exit 2; }

# 1) rm -rf against dangerous targets (root, home, system paths, bare glob, . / ..)
if echo "$CMD" | grep -Eq '\brm\b[^|;&]*-[a-zA-Z]*r[a-zA-Z]*f|\brm\b[^|;&]*-[a-zA-Z]*f[a-zA-Z]*r|\brm\b[^|;&]*-r[a-zA-Z]*\s+-f'; then
  if echo "$CMD" | grep -Eq 'rm[^|;&]*\s(-{1,2}[a-zA-Z]+\s+)*(/|/\*|~|~/|\$HOME|\.|\.\.|\*)(\s|$)'; then
    block "rm -rf against a dangerous target (/, ~, \$HOME, ., .., *)"
  fi
  if echo "$CMD" | grep -Eq 'rm[^|;&]*\s(/Users|/System|/Library|/Applications|/etc|/bin|/sbin|/usr|/var|/opt|/private|/dev)(/|\s|$)'; then
    block "rm -rf against a system path"
  fi
fi

# 2) Fork bomb
echo "$CMD" | grep -Eq ':\(\)\s*\{\s*:\|:&\s*\}\s*;\s*:' && block "fork bomb"

# 3) Writing to devices / formatting
echo "$CMD" | grep -Eq '\bdd\b[^|;&]*of=/dev/' && block "dd to /dev/"
echo "$CMD" | grep -Eq '\bmkfs(\.|\b)' && block "mkfs (formatting)"
echo "$CMD" | grep -Eq '>\s*/dev/(disk|sd|rdisk)' && block "write to /dev/disk"

# 4) git clean -fdx over everything — easily loses uncommitted work
echo "$CMD" | grep -Eq '\bgit\s+clean\b[^|;&]*-[a-zA-Z]*x' && block "git clean -x (wipes .build and uncommitted work; use a targeted path)"

exit 0
