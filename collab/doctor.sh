#!/usr/bin/env bash
# doctor.sh — preflight health check for ClaudeCollab. Run this after setup, after
# an opencode upgrade, or when something misbehaves. It verifies the pieces the
# slash commands depend on and reports what's wrong in actionable terms.
#
# Token-free by default: it lists auth/models metadata and runs the STATIC agent
# verification + the fake-opencode unit tests — no model is ever called. Pass
# --full to additionally run the verify scripts' runtime probes (they call a free
# model, so they cost a little and need working auth).
#
# Usage:  bash collab/doctor.sh [--full]
# Exit 0 = all REQUIRED checks pass. Non-zero = at least one required check failed
# (warnings alone do not fail the exit).
set -uo pipefail

full=""
case "${1:-}" in
  --full) full=1 ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (use --full or --help)" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

fail=0; warns=0
pass() { printf '\033[32mPASS\033[0m %s\n'  "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n'  "$*"; warns=$((warns+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n'  "$*"; fail=1; }
info() { printf '     %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }

# --- 1. Required tools -------------------------------------------------------
hdr "Tools"
if command -v opencode >/dev/null 2>&1; then
  ver="$(opencode --version 2>/dev/null | head -n1)"
  pass "opencode present (${ver:-version unknown})"
  case "$ver" in
    1.17.20) : ;;  # the version this repo is tested against
    "" ) : ;;
    *) info "note: tested against opencode 1.17.20; you have ${ver}. Re-run the verify scripts if flags/permissions changed." ;;
  esac
else
  bad "opencode NOT found — install: npm install -g opencode-ai (or brew install anomalyco/tap/opencode)"
fi

if command -v jq >/dev/null 2>&1; then
  pass "jq present (needed for --emit-session and the verify scripts)"
else
  bad "jq NOT found — /collaborate (--emit-session) and the verify scripts need it. Install jq."
fi

if command -v timeout >/dev/null 2>&1; then pass "timeout present (COLLAB_TIMEOUT backstop available)"
elif command -v gtimeout >/dev/null 2>&1; then pass "gtimeout present (COLLAB_TIMEOUT backstop available)"
else warn "no timeout/gtimeout on PATH — COLLAB_TIMEOUT will run uncapped (fine; it's an opt-in backstop)"; fi

# --- 2. opencode auth --------------------------------------------------------
hdr "opencode auth"
if command -v opencode >/dev/null 2>&1; then
  authout="$(opencode auth list 2>/dev/null)"
  # The list footer reads like "N credentials". Pull the first integer before it.
  ncred="$(printf '%s\n' "$authout" | grep -oE '[0-9]+ +credential' | grep -oE '[0-9]+' | head -n1)"
  if [ -n "${ncred:-}" ] && [ "$ncred" -gt 0 ] 2>/dev/null; then
    pass "opencode has ${ncred} provider credential(s) configured"
  else
    warn "no opencode provider credentials found — run: opencode auth login (the commands can't reach any model without this)"
  fi
else
  info "skipped (opencode not installed)"
fi

# --- 3. Model selection ------------------------------------------------------
hdr "Model selection"
if [ -n "${COLLAB_MODEL:-}" ]; then
  info "default model: \$COLLAB_MODEL=${COLLAB_MODEL}"
  # Cross-check it against the policy via ask.sh --dry-run (token-free, authoritative:
  # same policy backstop the real call uses), so a denied default is caught here.
  if bash collab/ask.sh --dry-run -m "${COLLAB_MODEL}" "x" >/dev/null 2>&1; then
    pass "default model passes the model policy (collab/models.policy)"
  else
    rc=$?
    case "$rc" in
      3) bad "default \$COLLAB_MODEL=${COLLAB_MODEL} is DENIED by collab/models.policy — the commands will refuse it" ;;
      4) warn "default \$COLLAB_MODEL=${COLLAB_MODEL} is gated 'ask' by collab/models.policy — commands need COLLAB_CONFIRMED=1" ;;
      *) warn "could not evaluate the policy for \$COLLAB_MODEL (ask.sh --dry-run exit $rc)" ;;
    esac
  fi
else
  info "default model: <opencode's own default> (\$COLLAB_MODEL unset). Set COLLAB_MODEL to pin one; prefer a non-Claude model for consults."
  info "note: the policy backstop can't police opencode's built-in default (no -m passed) — pin COLLAB_MODEL if you rely on it."
fi

# --- 4. Agent definitions ----------------------------------------------------
hdr "Agent definitions"
for def in collab-read collab-build; do
  if [ -f ".opencode/agent/${def}.md" ]; then pass "${def} agent def present"
  else bad "${def} agent def MISSING (.opencode/agent/${def}.md) — ask.sh falls back to a weaker/unrestricted built-in"; fi
done

# --- 5. Model policy file ----------------------------------------------------
hdr "Model policy"
pol="${COLLAB_POLICY:-$repo_root/collab/models.policy}"
if [ -f "$pol" ]; then
  rules=0; badlines=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
    # First whitespace-delimited token = the tier. Extract via parameter expansion
    # (not `set -- $line`, which would glob-expand a pattern token like `allow *`).
    tier=${line%%[[:space:]]*}
    case "$tier" in
      ''|'#'*) : ;;
      allow|ask|deny) rules=$((rules+1)) ;;
      *) badlines="$badlines '$tier'" ;;
    esac
  done < "$pol"
  if [ -z "$badlines" ]; then pass "policy parses cleanly: ${rules} active rule(s) in $(basename "$pol")"
  else warn "policy has line(s) with an unknown tier (not allow|ask|deny):${badlines} — those lines are ignored"; fi
else
  info "no policy file at $pol — default-allow (every model permitted). Add one to gate models."
fi

# --- 6. Static agent verification (token-free) -------------------------------
hdr "Agent permission proof (static)"
if command -v opencode >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if bash collab/verify-collab-read.sh --static >/dev/null 2>&1; then pass "collab-read denies mutation/secrets/egress by construction (static)"
  else bad "collab-read static verification FAILED — run: bash collab/verify-collab-read.sh --static"; fi
  if bash collab/verify-collab-build.sh --static >/dev/null 2>&1; then pass "collab-build has the expected allow/deny shape (static)"
  else bad "collab-build static verification FAILED — run: bash collab/verify-collab-build.sh --static"; fi
else
  warn "static verification skipped (needs opencode + jq)"
fi

# --- 7. Wrapper unit tests (token-free) --------------------------------------
hdr "Wrapper unit tests"
if bash collab/tests/run-tests.sh >/dev/null 2>&1; then pass "ask.sh unit suite (collab/tests/run-tests.sh) all green"
else bad "ask.sh unit suite FAILED — run: bash collab/tests/run-tests.sh"; fi

# --- 8. Optional: runtime probes (--full, calls a free model) ----------------
if [ -n "$full" ]; then
  hdr "Agent permission proof (runtime, --full)"
  if bash collab/verify-collab-read.sh >/dev/null 2>&1; then pass "collab-read runtime probes: no mutation/secret contradiction"
  else warn "collab-read runtime probes did not pass cleanly — run: bash collab/verify-collab-read.sh (may be INCONCLUSIVE without auth)"; fi
  if bash collab/verify-collab-build.sh >/dev/null 2>&1; then pass "collab-build runtime probe: edit path works"
  else warn "collab-build runtime probe did not pass cleanly — run: bash collab/verify-collab-build.sh (may be INCONCLUSIVE without auth)"; fi
fi

# --- Summary -----------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32mdoctor: OK\033[0m — all required checks passed'
  [ "$warns" -gt 0 ] && printf ' (%d warning(s) above)' "$warns"
  printf '.\n'
else
  printf '\033[31mdoctor: PROBLEMS\033[0m — fix the FAIL line(s) above before relying on the commands.\n'
fi
exit "$fail"
