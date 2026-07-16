#!/usr/bin/env bash
# Runs once after the container is created. Ensures the persistent volumes are
# writable by `node`, verifies the toolchain, and reports auth status.
set -euo pipefail

# Named volumes are normally seeded node-owned from the image dirs, but chown
# defensively in case a volume initialized root-owned.
sudo chown node:node "$HOME/.claude" "$HOME/.local/share/opencode" "$HOME/.config/gh" 2>/dev/null || true
chmod +x collab/ask.sh 2>/dev/null || true

# Link the selected host Claude config snapshot into the active ~/.claude.
# settings.json is copied only on a fresh volume because host hooks/statusLine/
# paths may need container-specific changes.
host_claude="$(pwd)/.devcontainer/.host-config"
if [ -d "$host_claude" ]; then
  # prepare-host-config.sh dereferences host symlinks, so no host dotfiles tree is
  # needed in the container.
  [ -e "$host_claude/CLAUDE.md" ]             && ln -sfn "$host_claude/CLAUDE.md"             "$HOME/.claude/CLAUDE.md"
  [ -e "$host_claude/statusline-command.sh" ] && ln -sfn "$host_claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
  for sub in commands agents; do
    [ -d "$host_claude/$sub" ] && ln -sfn "$host_claude/$sub" "$HOME/.claude/$sub"
  done
  # Activate host settings.json on a fresh volume (won't clobber once it exists).
  [ -f "$HOME/.claude/settings.json" ] || { [ -e "$host_claude/settings.json" ] && cp -f "$host_claude/settings.json" "$HOME/.claude/settings.json"; }
  echo "host config: imported selected paths from .devcontainer/.host-config"
fi

# Persist ~/.claude.json (Claude Code account/onboarding state). It lives in HOME,
# OUTSIDE the ~/.claude volume, so a rebuild wipes it and forces a re-login even
# though the tokens (~/.claude/.credentials.json) persist. Keep the real file in the
# volume and symlink it back so login survives rebuilds.
persist="$HOME/.claude/home-dot-claude.json"
if [ ! -L "$HOME/.claude.json" ]; then
  [ -f "$HOME/.claude.json" ] && [ ! -f "$persist" ] && mv "$HOME/.claude.json" "$persist"
  [ -f "$persist" ] || echo '{}' > "$persist"
  ln -sfn "$persist" "$HOME/.claude.json"
fi

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
echo "  /collab:consult <question>   |   /collab:panel <question>   |   /collab:delegate <task>   |   /collab:collaborate <problem>"
