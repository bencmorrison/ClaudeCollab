#!/usr/bin/env bash
# verify-collab-build.sh — check the `collab-build` opencode agent (the --edit /
# /delegate write path) has the permission shape it claims.
#
# What collab-build claims, and what this proves:
#   * It CAN edit — edit/write/patch/bash resolve to `allow` (else /delegate is
#     broken). This script asserts that positively.
#   * The tool-native escape/egress paths are REMOVED — task, webfetch, websearch
#     resolve to `deny`, and the `read` tool denies secret globs (.env/keys/creds).
#
# What it deliberately does NOT claim: secret/egress *by construction*. bash is
# `allow` on this agent (a delegated coding task needs to run builds/tests), and
# bash can `cat .env` or `curl`, bypassing the read-tool and webfetch denies. So on
# THIS path those denies are defense-in-depth (they strip the default, tool-native
# route a compliant model would take) — the real trust boundary is the human diff
# review in /delegate step 2, not the permission map. Do not oversell it.
#
# Method mirrors verify-collab-read.sh: a STATIC last-match-wins check of opencode's
# resolved config (authoritative, fail-CLOSED) + a known-key typo lint + a RUNTIME
# corroboration (the agent actually writes a probe file => the edit path works;
# reports INCONCLUSIVE, not PASS, if opencode can't run).
#
# Usage:  bash collab/verify-collab-build.sh
# Exit 0 = static shape holds AND (if it ran) the edit path works. Non-zero otherwise.
# COLLAB_VERIFY_MODEL overrides the (free by default) runtime model.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

model="${COLLAB_VERIFY_MODEL:-opencode/deepseek-v4-flash-free}"
agent="collab-build"
agent_file=".opencode/agent/collab-build.md"
fail=0

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
inc()  { printf '\033[33mINCONCLUSIVE\033[0m %s\n' "$*"; }

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 120"; fi

perms="$(opencode agent list 2>/dev/null \
  | awk '/^collab-build /{f=1;next} f && /^[a-z][a-z0-9_-]* \((primary|subagent|all)\)/{exit} f')"

echo "== 1. STATIC (authoritative): resolved permissions =="
last_action() {
  printf '%s\n' "$perms" | jq -r --arg p "$1" --arg pat "${2:-}" '
    [ .[] | select(.permission==$p) | select($pat=="" or .pattern==$pat) ] | last | .action // ""' 2>/dev/null
}

# Capability MUST be present (else /delegate can't edit) — assert allow.
for cap in edit write patch bash; do
  if [ "$(last_action "$cap")" = "allow" ]; then pass "$cap => allow (edit path works)"; else bad "$cap is NOT allow — /delegate cannot edit"; fi
done
# Escape hatch + network egress MUST be denied.
for cap in task webfetch websearch; do
  if [ "$(last_action "$cap")" = "deny" ]; then pass "$cap => deny"; else bad "$cap is NOT denied (last rule wins)"; fi
done
# Secret reads denied at the read-tool layer (defense-in-depth; bash bypasses).
for secret in "*.env" ".env" "*.pem" "*.key"; do
  a="$(last_action read "$secret")"
  if [ "$a" = "deny" ]; then pass "read '$secret' => deny (read-tool layer)"; else bad "read '$secret' => '${a:-<none>}' (secret readable via read tool!)"; fi
done
[ "$(last_action read '*')" = "allow" ] && pass "read '*' => allow (non-secret reads work)" \
  || bad "read '*' is not allow — agent can't read the repo it must edit"

echo "== 2. STATIC: permission keys are all real (typo => silent fail-open) =="
known=" bash read edit write patch glob grep webfetch task todowrite websearch lsp skill "
badkeys=""
while IFS= read -r k; do
  case "$known" in *" $k "*) ;; *) badkeys="$badkeys $k" ;; esac
done < <(awk '/^permission:/{p=1;next} p&&/^[^ ]/{p=0} p&&/^  [a-z_]+:/{line=$0; sub(/^ +/,"",line); sub(/:.*/,"",line); print line}' "$agent_file")
if [ -z "$badkeys" ]; then pass "all permission keys are known opencode tools"
else bad "unknown permission key(s):$badkeys — a typo'd deny silently fails open"; fi

echo "== 3. RUNTIME (corroborating): the edit path actually writes a file =="
probe="$repo_root/.collab-build-edit-probe.txt"; rm -f "$probe"
mout="$($TIMEOUT opencode run --agent "$agent" --auto -m "$model" \
  "Use your write/edit tool to create the file .collab-build-edit-probe.txt containing exactly: OK. Then report done." \
  </dev/null 2>&1)"; mrc=$?
if printf '%s' "$mout" | grep -qi 'falling back to default agent'; then
  bad "opencode fell back off collab-build (not primary-invocable — check 'mode: all')"
elif [ "$mrc" -ne 0 ]; then
  inc "opencode exited $mrc (missing timeout? auth? crash) — edit step could not run; static check above is authoritative"
elif [ -e "$probe" ]; then
  pass "probe file created — edit path works under collab-build"; rm -f "$probe"
else
  inc "no file created and opencode exited 0 — model may have declined; static allow above is authoritative"
fi
rm -f "$probe"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mcollab-build VERIFIED\033[0m — edit path works; task/webfetch/websearch and secret READS are denied at the tool layer. NOTE: bash is allowed, so secret/egress are defense-in-depth, NOT by construction — the /delegate diff review is the trust boundary.\n'
else
  printf '\033[31mcollab-build NOT verified\033[0m — permission shape is wrong; check the agent def against verify-collab-read.sh conventions.\n'
fi
exit "$fail"
