#!/usr/bin/env bash
# Runs once after the container is created. Verifies the toolchain and reports
# whether the mounted credentials came through.
set -euo pipefail

echo "== ClaudeCollab dev container =="
chmod +x collab/ask.sh 2>/dev/null || true

printf 'node:     %s\n' "$(node --version 2>/dev/null || echo MISSING)"
printf 'claude:   %s\n' "$(claude --version 2>/dev/null || echo MISSING)"
printf 'opencode: %s\n' "$(opencode --version 2>/dev/null || echo MISSING)"

echo
echo "-- credential check --"
if [ -s "$HOME/.claude/.credentials.json" ]; then
  echo "claude   auth: mounted"
else
  echo "claude   auth: MISSING — run 'claude' on the host to authenticate, then rebuild"
fi
if [ -s "$HOME/.local/share/opencode/auth.json" ]; then
  echo "opencode auth: mounted"
  opencode auth list 2>/dev/null | tail -n +1 || true
else
  echo "opencode auth: MISSING — run 'opencode auth login' on the host, then rebuild"
fi

echo
echo "Ready. Try:  /consult <question>   |   /consensus <question>   |   /delegate <task>"
