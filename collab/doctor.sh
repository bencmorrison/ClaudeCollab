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

# Config file (same resolution ask.sh uses): $COLLAB_CONF, else collab.conf.local.
if [ -n "${COLLAB_CONF:-}" ]; then conf_file="$COLLAB_CONF"
elif [ -f "$repo_root/collab/collab.conf.local" ]; then conf_file="$repo_root/collab/collab.conf.local"
else conf_file=""; fi
conf_get() {
  [ -n "$conf_file" ] && [ -f "$conf_file" ] || return 0
  awk -v k="$1" '
    { line=$0; sub(/^[[:space:]]+/,"",line) }
    line ~ /^#/ || line !~ /=/ { next }
    { eq=index(line,"="); lk=substr(line,1,eq-1); gsub(/[[:space:]]/,"",lk)
      if(lk!=k) next
      lv=substr(line,eq+1); sub(/[[:space:]]+#.*/,"",lv); sub(/^[[:space:]]+/,"",lv); sub(/[[:space:]]+$/,"",lv)
      gsub(/^"|"$/,"",lv); gsub(/^\047|\047$/,"",lv); val=lv }
    END{ if(val!="") print val }' "$conf_file"
}

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
# Effective default: $COLLAB_MODEL (one-off override) else the config file.
eff_model="${COLLAB_MODEL:-}"; msrc="\$COLLAB_MODEL (env)"
if [ -z "$eff_model" ]; then eff_model="$(conf_get COLLAB_MODEL)"; msrc="${conf_file:-collab.conf.local}"; fi
if [ -n "$eff_model" ]; then
  info "default model: ${eff_model} (from ${msrc})"
  # Cross-check it against the policy via ask.sh --dry-run (token-free, authoritative:
  # same policy backstop the real call uses), so a denied default is caught here.
  if bash collab/ask.sh --dry-run -m "${eff_model}" "x" >/dev/null 2>&1; then
    pass "default model passes the model policy"
  else
    rc=$?
    case "$rc" in
      3) bad "default model ${eff_model} is DENIED by the model policy — the commands will refuse it" ;;
      4) warn "default model ${eff_model} is gated 'ask' by the model policy — commands need COLLAB_CONFIRMED=1" ;;
      *) warn "could not evaluate the policy for ${eff_model} (ask.sh --dry-run exit $rc)" ;;
    esac
  fi
else
  info "default model: <opencode's own default> (no COLLAB_MODEL in env or collab.conf.local)."
  info "note: set one via /configure-collab (writes collab.conf.local); prefer a non-Claude model for consults. The policy backstop can't police opencode's built-in default (no -m passed)."
fi
# Panel default, if configured — policy-check each member too (a denied member
# passes the single-model check above silently and only fails at /panel runtime).
eff_models="${COLLAB_MODELS:-}"; [ -n "$eff_models" ] || eff_models="$(conf_get COLLAB_MODELS)"
if [ -n "$eff_models" ]; then
  info "default /panel set: ${eff_models}"
  for pm in ${eff_models//,/ }; do
    bash collab/ask.sh --dry-run -m "$pm" "x" >/dev/null 2>&1
    case $? in
      3) bad "/panel member ${pm} is DENIED by the model policy — /panel will refuse it" ;;
      4) warn "/panel member ${pm} is gated 'ask' — /panel needs COLLAB_CONFIRMED=1 for it" ;;
    esac
  done
fi

# --- 4. Agent definitions ----------------------------------------------------
hdr "Agent definitions"
for def in collab-read collab-build collab-research; do
  if [ -f ".opencode/agent/${def}.md" ]; then pass "${def} agent def present"
  else bad "${def} agent def MISSING (.opencode/agent/${def}.md) — ask.sh falls back to a weaker/unrestricted built-in"; fi
done

# --- 5. Model policy file ----------------------------------------------------
hdr "Model policy"
# Same resolution ask.sh uses: $COLLAB_POLICY, else a RULEFUL .local, else default.
# An empty/comment-only .local is ignored (it must not silently void a committed deny).
_has_rules() { [ -f "$1" ] && grep -qE '^[[:space:]]*(allow|ask|deny)([[:space:]]|$)' "$1" 2>/dev/null; }
if [ -n "${COLLAB_POLICY:-}" ]; then pol="$COLLAB_POLICY"
elif _has_rules "$repo_root/collab/models.policy.local"; then pol="$repo_root/collab/models.policy.local"
else
  pol="$repo_root/collab/models.policy"
  [ -f "$repo_root/collab/models.policy.local" ] && warn "models.policy.local exists but has no rules — ignored; the committed models.policy is in effect (put an explicit rule like 'allow *' in .local to override it)."
fi
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

# --- 6z. Shebang conformance (needs the git checkout; skipped in installs) ----
if [ -d .git ] && [ -f collab/tests/check-shebangs.sh ]; then
  hdr "Shebang conformance"
  if bash collab/tests/check-shebangs.sh >/dev/null 2>&1; then pass "every script uses #!/usr/bin/env bash"
  else bad "non-conforming shebang(s) — run: bash collab/tests/check-shebangs.sh"; fi
fi

# --- 6a. Agent permission invariants (source-level lint; no opencode needed) --
hdr "Agent permission invariants (source lint)"
if bash collab/tests/check-agent-permissions.sh >/dev/null 2>&1; then
  pass "agent defs hold the default-deny-allowlist invariants ('*': deny floor, no re-open, expected allow-set)"
else
  bad "agent permission invariants VIOLATED — run: bash collab/tests/check-agent-permissions.sh"
fi

# --- 6b. Static agent verification (resolved config; needs opencode) ---------
hdr "Agent permission proof (resolved config)"
if command -v opencode >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if bash collab/verify-collab-read.sh --static >/dev/null 2>&1; then pass "collab-read denies mutation/secrets/egress by construction (resolved config)"
  else bad "collab-read static verification FAILED — run: bash collab/verify-collab-read.sh --static"; fi
  if bash collab/verify-collab-build.sh --static >/dev/null 2>&1; then pass "collab-build has the expected allow/deny shape (resolved config)"
  else bad "collab-build static verification FAILED — run: bash collab/verify-collab-build.sh --static"; fi
  if bash collab/verify-collab-research.sh --static >/dev/null 2>&1; then pass "collab-research reaches the web but cannot mutate (resolved config)"
  else bad "collab-research static verification FAILED — run: bash collab/verify-collab-research.sh --static"; fi
else
  warn "resolved-config proof skipped (needs opencode + jq) — the source lint above still ran"
fi

# --- 6c. Evidence layer (the watcher's data source) --------------------------
# Report the state of collab/logs/ and, crucially, the INTEGRITY of the most recent
# run. An unpaired `started` means a call died with its response unrecorded — the
# exact silent gap that would otherwise read as a clean log.
hdr "Evidence layer (collab/log.sh)"
if [ "${COLLAB_LOG:-on}" = "off" ]; then
  warn "logging is OFF (\$COLLAB_LOG=off) — no evidence is being recorded, so /witness has nothing to audit"
elif [ ! -f collab/log.sh ]; then
  warn "collab/log.sh not present — model calls are not being recorded"
elif ! command -v jq >/dev/null 2>&1; then
  bad "jq missing — ask.sh cannot write the evidence log (see the jq check above)"
else
  logdir="${COLLAB_LOG_DIR:-collab/logs}"
  pass "logging ON (prompts=${COLLAB_LOG_PROMPTS:-full}, retention=${COLLAB_LOG_RETENTION_DAYS:-14}d, dir=$logdir)"
  if [ -d "$logdir" ] && [ -e "$logdir/latest" ]; then
    if bash collab/log.sh verify "$(basename "$(readlink "$logdir/latest" 2>/dev/null || echo latest)")" >/dev/null 2>&1; then
      pass "latest run's log is intact (every started has a completed; hashes match)"
    else
      bad "latest run FAILS integrity — run: bash collab/log.sh verify \$(readlink $logdir/latest)"
    fi
  else
    info "no runs logged yet — the log appears on the first /consult, /panel, …"
  fi
fi

# --- 7. Wrapper unit tests (token-free) --------------------------------------
hdr "Wrapper unit tests"
if bash collab/tests/run-tests.sh >/dev/null 2>&1; then pass "ask.sh unit suite (collab/tests/run-tests.sh) all green"
else bad "ask.sh unit suite FAILED — run: bash collab/tests/run-tests.sh"; fi
# Only meaningful in the ClaudeCollab source tree (install.sh isn't shipped into
# installed projects), so gate on its presence rather than the test file's.
if [ -f install.sh ] && [ -f collab/tests/test-install.sh ]; then
  if bash collab/tests/test-install.sh >/dev/null 2>&1; then pass "installer smoke tests (collab/tests/test-install.sh) all green"
  else bad "installer smoke tests FAILED — run: bash collab/tests/test-install.sh"; fi
fi

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
