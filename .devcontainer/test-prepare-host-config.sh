#!/usr/bin/env bash
# Token-free regression test for host-config staging preflight.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/collab-host-config.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
cd "$tmp"
home="$tmp/home"
stage="$tmp/stage"
timeout_bin=""
if command -v timeout >/dev/null 2>&1; then timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then timeout_bin="gtimeout"; fi
mkdir -p "$home/.claude/commands/internal" "$tmp/external"
printf 'inside\n' > "$home/.claude/commands/internal/value.md"
ln -s internal/value.md "$home/.claude/commands/inside.md"

HOME="$home" CLAUDECOLLAB_HOST_CONFIG_STAGE="$stage" bash "$here/prepare-host-config.sh"
[ "$(cat "$stage/commands/inside.md")" = inside ] || { echo "FAIL: internal symlink was not copied" >&2; exit 1; }

printf 'keep\n' > "$stage/sentinel"
run_preflight() {
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" 5 env HOME="$home" CLAUDECOLLAB_HOST_CONFIG_STAGE="$stage" \
      bash "$here/prepare-host-config.sh" >/dev/null 2>&1
  else
    env HOME="$home" CLAUDECOLLAB_HOST_CONFIG_STAGE="$stage" \
      bash "$here/prepare-host-config.sh" >/dev/null 2>&1
  fi
}

expect_rejected() {
  local label="$1" status
  if run_preflight; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  else
    status=$?
  fi
  [ "$status" -ne 124 ] || { echo "FAIL: $label blocked preflight" >&2; exit 1; }
  [ -f "$stage/sentinel" ] || { echo "FAIL: $label cleared the prior snapshot" >&2; exit 1; }
}

printf 'outside\n' > "$tmp/external/value.md"
ln -s "$tmp/external/value.md" "$home/.claude/settings.json"
expect_rejected "selected external file symlink"

rm -f "$home/.claude/settings.json"
ln -s "$tmp/external" "$home/.claude/commands/external-tree"
expect_rejected "nested external directory symlink"
rm "$home/.claude/commands/external-tree"

ln -s missing.json "$home/.claude/settings.json"
expect_rejected "selected dangling symlink"
rm "$home/.claude/settings.json"

ln -s missing.md "$home/.claude/commands/dangling.md"
expect_rejected "nested dangling symlink"
rm "$home/.claude/commands/dangling.md"

ln -s .. "$home/.claude/commands/internal/cycle"
expect_rejected "cyclic internal directory symlink"
rm "$home/.claude/commands/internal/cycle"

mkfifo "$home/.claude/settings.json"
expect_rejected "selected FIFO"
rm "$home/.claude/settings.json"

mkfifo "$home/.claude/commands/input.pipe"
expect_rejected "nested special file"
rm "$home/.claude/commands/input.pipe"

# A selected tree may itself be an internal symlink. Its target still needs a
# recursive scan before cp -L is allowed to dereference anything below it.
rm -rf "$home/.claude/commands"
mkdir -p "$home/.claude/shared-commands"
ln -s "$tmp/external/value.md" "$home/.claude/shared-commands/external.md"
ln -s shared-commands "$home/.claude/commands"
expect_rejected "external symlink below an internally linked selected tree"

echo "host-config staging preflight: PASS"
