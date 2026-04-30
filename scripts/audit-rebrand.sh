#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
patterns=(
  '/etc/dockpanel'
  '/var/lib/dockpanel'
  '/var/run/dockpanel'
  '/etc/arc'
  '/var/run/arc'
  '/var/lib/arc'
  'dockpanel.dev'
  'docs.dockpanel.dev'
  'dockpanel_'
  'dockpanel-git-'
  'dockpanel-snapshot:'
)
for p in "${patterns[@]}"; do
  if rg -n --glob '!**/audit-rebrand.sh' --glob '!**/migration-dockpanel-to-arcpanel.md' --glob '!**/CHANGELOG.md' --glob '!**/.claude/**' --glob '!**/node_modules/**' --glob '!**/target/**' --glob '!**/docs/superpowers/**' "$p" .; then
    echo "AUDIT FAIL: found $p"
    FAIL=1
  fi
done
exit "$FAIL"
