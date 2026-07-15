#!/usr/bin/env bash
# check-frontmatter.sh — validate the YAML frontmatter of the repo's command and
# agent definition files. Cheap structural lint (no YAML parser dependency): it
# asserts each file opens with a `---` fence, closes it, and carries the keys that
# make the file do its job. Catches a dropped fence or a renamed/typo'd key before
# it silently breaks a slash command or an agent's permission map.
#
# Run:  bash collab/tests/check-frontmatter.sh   (exit 0 = all valid)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cd "$repo_root" || exit 1

fail=0
pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=1; }

# has_frontmatter <file> : true if line 1 is `---` and a closing `---` exists after it.
has_frontmatter() {
  [ "$(sed -n '1p' "$1")" = "---" ] || return 1
  sed -n '2,$p' "$1" | grep -qxF -- "---"
}
# fm_has_key <file> <key> : true if `key:` appears within the frontmatter block only.
fm_has_key() {
  awk -v k="$2" '
    NR==1 && $0=="---" {inb=1; next}
    inb && $0=="---" {exit}
    inb && $0 ~ "^" k ":" {found=1; exit}
    END{exit(found?0:1)}' "$1"
}

check() {  # <file> <key1> [key2 ...]
  local f="$1"; shift
  if [ ! -f "$f" ]; then bad "$f" "file not found"; return; fi
  if ! has_frontmatter "$f"; then bad "$f" "missing or unterminated '---' frontmatter fence"; return; fi
  local missing=""
  for k in "$@"; do fm_has_key "$f" "$k" || missing="$missing $k"; done
  if [ -n "$missing" ]; then bad "$f" "frontmatter missing key(s):$missing"; else pass "$f"; fi
}

echo "== slash commands (.claude/commands/*.md) =="
shopt -s nullglob
cmds=(.claude/commands/*.md)
# Guard the array expansion with the count: `"${arr[@]}"` on an empty array under
# `set -u` errors on bash < 4.4 (macOS system bash 3.2), so only loop when non-empty.
if [ ${#cmds[@]} -eq 0 ]; then echo "  (none found)"
else for f in "${cmds[@]}"; do check "$f" description; done; fi

echo "== opencode agents (.opencode/agent/*.md) =="
agents=(.opencode/agent/*.md)
if [ ${#agents[@]} -eq 0 ]; then echo "  (none found)"
else for f in "${agents[@]}"; do check "$f" description mode permission; done; fi

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mfrontmatter: all valid\033[0m\n'
else printf '\033[31mfrontmatter: problems above\033[0m\n'; fi
exit "$fail"
