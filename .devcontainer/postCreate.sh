#!/usr/bin/env bash
# Runs once after the container is created. Ensures the persistent volumes are
# writable by `node`, verifies the toolchain, and reports auth status.
set -euo pipefail

# Named volumes are normally seeded node-owned from the image dirs, but chown
# defensively in case a volume initialized root-owned.
sudo chown node:node "$HOME/.claude" "$HOME/.local/share/opencode" "$HOME/.config/gh" 2>/dev/null || true
chmod +x collab/ask.sh 2>/dev/null || true

echo "== ClaudeCollab dev container =="
printf 'node:     %s\n' "$(node --version 2>/dev/null || echo MISSING)"
printf 'claude:   %s\n' "$(claude --version 2>/dev/null || echo MISSING)"
printf 'opencode: %s\n' "$(opencode --version 2>/dev/null || echo MISSING)"

echo
echo "-- auth status --"
if claude -p "ok" >/dev/null 2>&1; then
  echo "claude:   logged in"
else
  echo "claude:   NOT logged in — run 'claude' then '/login' inside this container"
fi
if opencode auth list 2>/dev/null | grep -qiE '[1-9][0-9]* credential|: '; then
  echo "opencode: has credentials"
else
  echo "opencode: no credentials — run 'opencode auth login' inside this container"
fi
if gh auth status >/dev/null 2>&1; then
  echo "gh:       logged in"
else
  echo "gh:       NOT logged in — run 'gh auth login' inside this container"
fi
# Commit signing uses the 1Password SSH agent forwarded in by VS Code (SSH_AUTH_SOCK).
if [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l 2>/dev/null | grep -qi 'signing'; then
  echo "signing:  1Password signing key available via forwarded agent"
else
  echo "signing:  no forwarded signing key — commits may prompt on host or need -c commit.gpgsign=false"
fi

echo
echo "Log in once (persists across rebuilds via named volumes), then try:"
echo "  /consult <question>   |   /consensus <question>   |   /delegate <task>"
