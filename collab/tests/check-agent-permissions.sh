#!/usr/bin/env bash
# check-agent-permissions.sh — SOURCE-level lint of the hardened agent defs'
# permission maps. Opencode-free (bash/awk only), so CI can run it per-commit
# without installing opencode. It does NOT prove opencode's resolved enforcement
# (that's `verify-collab-*.sh`, which needs the opencode binary) — it guards the
# realistic regression: a human edits `.opencode/agent/*.md` and weakens it.
#
# It asserts the default-deny-allowlist invariants that make these agents safe:
#   - `mode: all` (a `mode: subagent` def silently falls back to full-access build)
#   - a `"*": deny` floor is present
#   - NO `"*": allow` anywhere (that's the re-open that started the whole saga)
#   - the set of tools set to `allow` is EXACTLY the agent's intended allowlist
#     (collab-read: none — only the `read` map; collab-build: edit/write/patch/bash)
#   - the `read` map allows `*` and denies representative secret globs
#
# Run:  bash collab/tests/check-agent-permissions.sh   (exit 0 = all invariants hold)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cd "$repo_root" || exit 1

fail=0
pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=1; }

# top_perms <file> : emit "key|value" for each 2-space-indented entry in the
# permission: block (top level only; the read sub-map is 4-space-indented and skipped).
# Quotes are stripped from the key so `"*"` -> `*`.
top_perms() {
  awk '
    /^permission:/ {p=1; next}
    p && /^[^ ]/    {p=0}
    p && /^  [^ ]/ {
      line=$0; sub(/^  /,"",line)
      i=index(line,":"); if(!i) next
      k=substr(line,1,i-1); v=substr(line,i+1)
      gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
      gsub(/"/,"",k); gsub(/\047/,"",k)   # strip quotes (octal \047 = single quote; portable to mawk/BSD awk)
      print k "|" v
    }' "$1"
}
# read_map <file> : emit "pattern|value" for the 4-space-indented entries under `read:`.
read_map() {
  awk '
    /^permission:/ {p=1}
    p && /^  read:/ {r=1; next}
    r && /^  [^ ]/ {r=0}          # next top-level key ends the read map
    r && /^    [^ ]/ {
      line=$0; sub(/^    /,"",line)
      i=index(line,":"); if(!i) next
      k=substr(line,1,i-1); v=substr(line,i+1)
      gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
      gsub(/"/,"",k); gsub(/\047/,"",k)   # strip quotes (octal \047 = single quote; portable to mawk/BSD awk)
      print k "|" v
    }' "$1"
}

# check_agent <file> <space-separated-expected-allow-tools>
check_agent() {
  local f="$1" expect="$2" label; label="$(basename "$f")"
  if [ ! -f "$f" ]; then bad "$label" "file not found"; return; fi
  local tp; tp="$(top_perms "$f")"

  grep -qx 'mode: all' "$f" || bad "$label" "missing 'mode: all' (a subagent def silently falls back to full-access build)"

  printf '%s\n' "$tp" | grep -qx '\*|deny' \
    || bad "$label" "no '\"*\": deny' floor — the default-deny allowlist has no floor; un-listed tools would be ALLOWED"
  if printf '%s\n' "$tp" | grep -qx '\*|allow'; then
    bad "$label" "'\"*\": allow' present — this re-opens EVERY tool (the exact regression this lint exists to stop)"
  fi

  # Tools explicitly set to allow at top level must equal the intended allowlist.
  local got; got="$(printf '%s\n' "$tp" | awk -F'|' '$2=="allow" && $1!="*"{print $1}' | sort | tr '\n' ' ')"
  got="$(printf '%s' "$got" | awk '{$1=$1;print}')"   # trim
  local want; want="$(printf '%s\n' $expect | sort | tr '\n' ' ')"
  want="$(printf '%s' "$want" | awk '{$1=$1;print}')"
  if [ "$got" = "$want" ]; then pass "$label: allow-set is exactly {${want:-<none>}} + read map"
  else bad "$label" "allow-set is {${got:-<none>}}, expected {${want:-<none>}} — an unintended tool is allowed (or an intended one dropped)"; fi

  # read map: `*` allowed, and representative secrets denied.
  local rm; rm="$(read_map "$f")"
  printf '%s\n' "$rm" | grep -qx '\*|allow' || bad "$label" "read map does not allow '*' (agent can't read non-secret files)"
  local secret
  for secret in '.env' '*.env' '*.key' '*.pem' '*credentials*'; do
    printf '%s\n' "$rm" | grep -qxF "$secret|deny" \
      || bad "$label" "read map missing secret deny for '$secret'"
  done
  [ "$fail" -eq 0 ] && pass "$label: read map allows '*' and denies representative secret globs" || true
}

echo "== collab-read (allowlist: read-only, no tool allowed) =="
check_agent ".opencode/agent/collab-read.md" ""

echo "== collab-build (allowlist: edit/write/patch/bash) =="
check_agent ".opencode/agent/collab-build.md" "edit write patch bash"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32magent permissions: allowlist invariants hold\033[0m\n'
else printf '\033[31magent permissions: INVARIANT VIOLATED — do not ship\033[0m\n'; fi
exit "$fail"
