#!/usr/bin/env bash
# check-agent-permissions.sh — SOURCE-level lint of the hardened agent defs'
# permission maps. Opencode-free (bash/awk only), so CI can run it per-commit
# without installing opencode. It does NOT prove opencode's resolved enforcement
# (that's `verify-guild-*.sh`, which needs the opencode binary) — it guards the
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
# whole file were fooled three ways (found by dogfooding /guild:review 2026-07-15) — an
# unprotected frontmatter passed via a look-alike block in the markdown BODY; a
# `"*": deny` placed AFTER the allows (or a `"*": allow` after the secret denies)
# passed while resolving the opposite way. This version reads only the frontmatter
# and computes effective (last-match) actions, so those all fail as they should.
#
# Run:  bash modelguild/tests/check-agent-permissions.sh   (exit 0 = all invariants hold)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cd "$repo_root" || exit 1

# Where the hardened agent defs live. Default is the repo-relative .opencode/agent
# (unchanged for CI and the checkout). A --global install places them in opencode's
# global agent dir; doctor.sh passes that here via $GUILD_AGENT_DIR so the SAME lint
# guards the globally-installed defs. An absolute override is cwd-independent.
AGENT_DIR="${GUILD_AGENT_DIR:-.opencode/agent}"

fail=0
pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=1; }

KNOWN_TOOLS="bash edit write patch grep glob task todowrite webfetch websearch lsp skill"
# Canonical expected secret-read carve-outs for every non-scoped agent.
SECRET_GLOBS='*.env *.env.* .env **/.env **/.env.* *.pem **/*.pem *.key **/*.key *.pfx *.p12 id_rsa id_ed25519 **/id_rsa **/id_ed25519 **/.ssh/** **/.aws/** **/.gnupg/** *credentials* **/credentials* **/.netrc **/.git-credentials'

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
#   plain              read is a plain top-level `read: allow` with NO secret-glob submap
#                      — the loosened read-only reviewer shape of guild-read/guild-research
#                      (2026-07-22 realignment): read the repo, dotfiles included.
#   nonsecret          (default) `*` allows, each secret glob denies — guild-build's read
#                      TOOL (defense-in-depth): "read the repo, except secrets".
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

  # read map handling depends on the readspec shape.
  local rm s; rm="$(printf '%s\n' "$fm" | read_map)"
  case "$readspec" in
    plain)
      # Loosened read path (guild-read/guild-research, 2026-07-22 permission realignment):
      # read is a plain top-level `read: allow` with NO secret-glob submap. The secret
      # fences were removed as vendor-asymmetry bias — a review subagent reads the repo,
      # dotfiles included. Assert read resolves to allow at top level AND there is no submap;
      # a re-added secret-glob carve-out (a read submap) is now itself a regression.
      [ "$(effective "$tp" read)" = "allow" ] \
        || bad "$label" "read resolves to '$(effective "$tp" read)', expected a plain top-level 'read: allow'"
      [ -z "$rm" ] \
        || bad "$label" "read has a submap; the loosened path expects a plain 'read: allow' with NO secret-glob carve-outs (removed 2026-07-22 — do not re-fence a read-only reviewer)"
      ;;
    nonsecret|*)
      # guild-build: `*` allows, each secret glob denies (defense-in-depth on the read TOOL).
      [ "$(effective "$rm" '*')" = "allow" ] \
        || bad "$label" "read map: '*' resolves to '$(effective "$rm" '*')', expected allow (agent can't read non-secret files)"
      for s in $SECRET_GLOBS; do
        [ "$(effective "$rm" "$s")" = "deny" ] \
          || bad "$label" "read map: secret '$s' resolves to '$(effective "$rm" "$s")', expected deny (last-match-wins — is a '\"*\": allow' after it?)"
      done
      ;;
  esac

  [ "$fail" -eq "$f0" ] && pass "$label: allowlist invariants hold (frontmatter-bounded, effective/last-match-aware)"
}

# --self-test: prove THIS lint catches the realistic weakenings a human edit could make
# (ported from the retired run-tests.sh meta-tests; the guild-watch cases went with the
# retired witness agent). It re-invokes the lint against crafted agent dirs and asserts it
# passes the real defs and fails each tampered one. Opencode-free; run in CI + doctor.sh.
if [ "${1:-}" = "--self-test" ]; then
  SELF="$here/$(basename "${BASH_SOURCE[0]}")"
  REAL="$repo_root/.opencode/agent"
  st_fail=0
  st_ok() { printf '\033[32mok\033[0m   self-test: %s\n' "$1"; }
  st_no() { printf '\033[31mFAIL\033[0m self-test: %s\n' "$1"; st_fail=1; }
  run_variant() { GUILD_AGENT_DIR="$1" bash "$SELF" >/dev/null 2>&1; }
  d="$(mktemp -d "${TMPDIR:-/tmp}/modelguild-aplint.XXXXXX")"; mkdir -p "$d/agent"
  seed() { cp "$REAL/guild-read.md" "$REAL/guild-build.md" "$REAL/guild-research.md" "$d/agent/"; }

  # S1. The real defs pass.
  seed
  run_variant "$d/agent" && st_ok "real agents pass" || st_no "lint rejects the real agents (false positive)"

  # S2. `write` re-added to guild-read's allow-set (no-write ROLE broken) -> FAIL.
  seed
  printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  "*": deny' \
    '  read: allow' '  grep: allow' '  glob: allow' '  webfetch: allow' '  websearch: allow' \
    '  write: allow' '---' 'body' > "$d/agent/guild-read.md"
  run_variant "$d/agent" && st_no "MISSED write re-added to guild-read" || st_ok "catches write re-added to the read-only guild-read allow-set"

  # S3. Unprotected frontmatter (no floor) with a valid-looking block in the BODY -> FAIL.
  seed
  printf '%s\n' '---' 'description: x' 'mode: all' '---' 'Example (not real frontmatter):' \
    'permission:' '  "*": deny' '  read:' '    "*": allow' > "$d/agent/guild-read.md"
  run_variant "$d/agent" && st_no "MISSED unprotected frontmatter (body block fooled it)" || st_ok "ignores body block, catches missing floor"

  # S4. guild-build with '*': deny placed AFTER the allows (effective = all denied) -> FAIL.
  seed
  printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  edit: allow' '  write: allow' \
    '  patch: allow' '  bash: allow' '  "*": deny' '  read:' '    "*": allow' '---' 'body' \
    > "$d/agent/guild-build.md"
  run_variant "$d/agent" && st_no "MISSED guild-build floor-after-allows (edit path dead)" || st_ok "catches '*': deny placed after the allows"

  # S5. A secret glob removed from guild-build's canonical set -> FAIL.
  seed
  grep -v '"\*\*/\.gnupg/\*\*": deny' "$REAL/guild-build.md" > "$d/agent/guild-build.md"
  run_variant "$d/agent" && st_no "MISSED a removed secret glob from the canonical set" || st_ok "guards the full canonical secret-glob set (guild-build)"

  rm -rf "$d"
  echo
  if [ "$st_fail" -eq 0 ]; then printf '\033[32magent-permissions self-test: the lint catches every tampered variant\033[0m\n'
  else printf '\033[31magent-permissions self-test: FAILED — the lint missed a regression\033[0m\n'; fi
  exit "$st_fail"
fi

# guild-read: read-only reviewer ROLE (2026-07-22 realignment). read+grep+glob+web
# ALLOWED like a Claude review subagent; read is a plain top-level allow (no secret
# globs). no-write/no-task is the role. `plain` readspec asserts the no-submap shape.
echo "== guild-read (allowlist: read/grep/glob/webfetch/websearch) =="
check_agent "$AGENT_DIR/guild-read.md" "grep glob webfetch websearch" plain

echo "== guild-build (allowlist: edit/write/patch/bash) =="
check_agent "$AGENT_DIR/guild-build.md" "edit write patch bash"

# guild-research is the source-backed /guild:research path — now IDENTICAL to
# guild-read (2026-07-22 realignment): read+grep+glob+web allowed, no-write/no-task.
# `bash` stays OUT of the allow-set (that no-shell/no-write scoping is the ROLE).
echo "== guild-research (allowlist: read/grep/glob/webfetch/websearch) =="
check_agent "$AGENT_DIR/guild-research.md" "grep glob webfetch websearch" plain

echo
if [ "$fail" -eq 0 ]; then printf '\033[32magent permissions: allowlist invariants hold\033[0m\n'
else printf '\033[31magent permissions: INVARIANT VIOLATED — do not ship\033[0m\n'; fi
exit "$fail"
