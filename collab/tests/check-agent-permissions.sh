#!/usr/bin/env bash
# check-agent-permissions.sh — SOURCE-level lint of the hardened agent defs'
# permission maps. Opencode-free (bash/awk only), so CI can run it per-commit
# without installing opencode. It does NOT prove opencode's resolved enforcement
# (that's `verify-collab-*.sh`, which needs the opencode binary) — it guards the
# realistic regression: a human edits `.opencode/agent/*.md` and weakens it.
#
# It asserts the default-deny-allowlist invariants, computed the way opencode
# resolves them (LAST-MATCH-WINS), on the FRONTMATTER ONLY:
#   - `mode: all` (a `mode: subagent` def silently falls back to full-access build)
#   - the effective floor is deny (an un-listed tool resolves to deny)
#   - every tool's EFFECTIVE action (last rule matching the tool name OR `*`) is
#     allow iff it's in the agent's intended allow-set, else deny
#   - in the `read` map, `*` effectively allows and each secret glob effectively denies
#
# Order-aware + frontmatter-bounded on purpose: earlier presence-only checks on the
# whole file were fooled three ways (found by dogfooding /collab:review 2026-07-15) — an
# unprotected frontmatter passed via a look-alike block in the markdown BODY; a
# `"*": deny` placed AFTER the allows (or a `"*": allow` after the secret denies)
# passed while resolving the opposite way. This version reads only the frontmatter
# and computes effective (last-match) actions, so those all fail as they should.
#
# Run:  bash collab/tests/check-agent-permissions.sh   (exit 0 = all invariants hold)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cd "$repo_root" || exit 1

fail=0
pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=1; }

KNOWN_TOOLS="bash edit write patch grep glob task todowrite webfetch websearch lsp skill"

# frontmatter <file> : the YAML between the first `---` and the next `---`. Anything
# in the markdown body (after the closing fence) is ignored — a look-alike block
# there must not influence the result.
frontmatter() { awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f' "$1"; }

# top_perms  (stdin = frontmatter) : "key|value" for each 2-space-indented entry in
# the permission: block (top level; the 4-space read sub-map is skipped). Quotes
# stripped from the key so `"*"` -> `*`.
top_perms() {
  awk '
    /^permission:/{p=1;next}
    p && /^[^ ]/{p=0}
    p && /^  [^ ]/{
      line=$0; sub(/^  /,"",line)
      i=index(line,":"); if(!i) next
      k=substr(line,1,i-1); v=substr(line,i+1)
      gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
      gsub(/"/,"",k); gsub(/\047/,"",k)   # strip quotes (octal \047 = single quote; mawk/BSD-safe)
      print k "|" v
    }'
}
# read_map  (stdin = frontmatter) : "pattern|value" for the 4-space entries under read:.
read_map() {
  awk '
    /^permission:/{p=1}
    p && /^  read:/{r=1;next}
    r && /^  [^ ]/{r=0}
    r && /^    [^ ]/{
      line=$0; sub(/^    /,"",line)
      i=index(line,":"); if(!i) next
      k=substr(line,1,i-1); v=substr(line,i+1)
      gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
      gsub(/"/,"",k); gsub(/\047/,"",k)
      print k "|" v
    }'
}

# effective <entries> <key> : action of the LAST entry whose key equals <key> or `*`
# (opencode's last-match-wins). Empty if nothing matched. This is what makes the
# check order-aware — a later `*` rule overrides an earlier tool rule and vice-versa.
effective() {
  local entries="$1" key="$2" k v act=""
  while IFS='|' read -r k v; do
    [ -n "$k" ] || continue
    if [ "$k" = "$key" ] || [ "$k" = '*' ]; then act="$v"; fi
  done <<EOF
$entries
EOF
  printf '%s' "$act"
}

# check_agent <file> <space-separated expected-allow tools> [read-spec]
#
# read-spec describes the SHAPE of the read map, because they are not all alike:
#   nonsecret          (default) `*` allows, each secret glob denies — the shape used
#                      by collab-read/build/collab:research: "read the repo, except secrets".
#   scoped:<glob>      `*` DENIES and only <glob> allows — collab-watch's inverted
#                      map: "read nothing except the log". Secrets need no globs
#                      here; they're denied by the floor, and listing them would
#                      imply the floor were allow. Asserted anyway (below), since
#                      "secrets are unreadable" is the guarantee either way.
check_agent() {
  local f="$1" expect="$2" readspec="${3:-nonsecret}" label f0="$fail"; label="$(basename "$f")"
  if [ ! -f "$f" ]; then bad "$label" "file not found"; return; fi
  local fm; fm="$(frontmatter "$f")"
  [ -n "$fm" ] || { bad "$label" "no YAML frontmatter block (first line must be '---', closed by '---')"; return; }

  printf '%s\n' "$fm" | grep -qx 'mode: all' \
    || bad "$label" "frontmatter missing 'mode: all' (a subagent def silently falls back to full-access build)"

  local tp; tp="$(printf '%s\n' "$fm" | top_perms)"

  # Effective floor: any tool with no rule of its own must resolve to deny.
  [ "$(effective "$tp" '__floor_probe__')" = "deny" ] \
    || bad "$label" "no effective '\"*\": deny' floor — un-listed tools resolve to allow (missing floor, or a later '\"*\": allow' re-opens everything)"

  # Build the set of tools to check: the known surface + any tool explicitly named
  # at top level (catches an unknown/new tool set to allow). Then each must resolve
  # to allow iff it's in the intended allow-set.
  local keys="$KNOWN_TOOLS" k v
  while IFS='|' read -r k v; do
    case "$k" in ''|'*'|read) continue ;; esac
    case " $keys " in *" $k "*) ;; *) keys="$keys $k" ;; esac
  done <<EOF
$tp
EOF
  local t effact
  for t in $keys; do
    effact="$(effective "$tp" "$t")"
    case " $expect " in
      *" $t "*) [ "$effact" = "allow" ] || bad "$label" "tool '$t' should be ALLOWED but resolves to '${effact:-deny(floor)}'" ;;
      *)        [ "$effact" = "allow" ] && bad "$label" "tool '$t' resolves to ALLOW but is not in the intended allow-set (unintended capability)" || true ;;
    esac
  done

  # read map. Either shape must leave every representative secret effectively denied.
  local rm; rm="$(printf '%s\n' "$fm" | read_map)"
  case "$readspec" in
    scoped:*)
      local scope="${readspec#scoped:}"
      [ "$(effective "$rm" '*')" = "deny" ] \
        || bad "$label" "read map: '*' resolves to '$(effective "$rm" '*')', expected deny — this agent's scope is enforced BY CONSTRUCTION, and an allow floor silently hands it the whole repo"
      [ "$(effective "$rm" "$scope")" = "allow" ] \
        || bad "$label" "read map: scope '$scope' resolves to '$(effective "$rm" "$scope")', expected allow (the agent cannot read the only thing it exists to read)"
      ;;
    *)
      [ "$(effective "$rm" '*')" = "allow" ] \
        || bad "$label" "read map: '*' resolves to '$(effective "$rm" '*')', expected allow (agent can't read non-secret files)"
      ;;
  esac
  local s
  for s in '.env' '*.env' '*.key' '*.pem' '*credentials*'; do
    [ "$(effective "$rm" "$s")" = "deny" ] \
      || bad "$label" "read map: secret '$s' resolves to '$(effective "$rm" "$s")', expected deny (last-match-wins — is a '\"*\": allow' after it?)"
  done

  [ "$fail" -eq "$f0" ] && pass "$label: allowlist invariants hold (frontmatter-bounded, effective/last-match-aware)"
}

echo "== collab-read (allowlist: read-only, no tool allowed) =="
check_agent ".opencode/agent/collab-read.md" ""

echo "== collab-build (allowlist: edit/write/patch/bash) =="
check_agent ".opencode/agent/collab-build.md" "edit write patch bash"

# collab-research is the /collab:research path: the ONLY agent allowed network egress.
# `bash` must stay OUT of this allow-set — it's what keeps the secret-read and
# grep/glob denies real on a path that can reach the network.
echo "== collab-research (allowlist: webfetch/websearch) =="
check_agent ".opencode/agent/collab-research.md" "webfetch websearch"

# collab-watch is the /collab:witness oversight path. Its read map is INVERTED (deny floor,
# only collab/logs/** allowed) — that scoping is the construction guarantee that keeps
# an auditor auditing the log instead of drifting into reviewing the source.
echo "== collab-watch (allowlist: no tool; read scoped to collab/logs/**) =="
check_agent ".opencode/agent/collab-watch.md" "" "scoped:collab/logs/**"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32magent permissions: allowlist invariants hold\033[0m\n'
else printf '\033[31magent permissions: INVARIANT VIOLATED — do not ship\033[0m\n'; fi
exit "$fail"
