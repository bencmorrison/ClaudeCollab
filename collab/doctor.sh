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
  bad "jq NOT found — /collab:collaborate (--emit-session) and the verify scripts need it. Install jq."
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
  info "note: set one via /collab:configure (writes collab.conf.local); prefer a non-Claude model for consults. The policy backstop can't police opencode's built-in default (no -m passed)."
fi
# Panel default, if configured — policy-check each member too (a denied member
# passes the single-model check above silently and only fails at /collab:panel runtime).
eff_models="${COLLAB_MODELS:-}"; [ -n "$eff_models" ] || eff_models="$(conf_get COLLAB_MODELS)"
if [ -n "$eff_models" ]; then
  info "default /collab:panel set: ${eff_models}"
  for pm in ${eff_models//,/ }; do
    bash collab/ask.sh --dry-run -m "$pm" "x" >/dev/null 2>&1
    case $? in
      3) bad "/collab:panel member ${pm} is DENIED by the model policy — /collab:panel will refuse it" ;;
      4) warn "/collab:panel member ${pm} is gated 'ask' — /collab:panel needs COLLAB_CONFIRMED=1 for it" ;;
    esac
  done
fi

# The install manifest lists exactly what ClaudeCollab put here. A file at one of our
# paths that ISN'T listed is the user's own, shadowing ours. Absent in the source repo
# (nothing was "installed"), in which case both checks below fall back to presence.
manifest_agents="$repo_root/collab/.install-manifest"

# --- 4. Agent definitions ----------------------------------------------------
hdr "Agent definitions"
# Presence is not the property that matters — OURS is. install.sh skips a file already
# at one of our paths, so a user who happens to have their own .opencode/agent/
# collab-read.md keeps it and never gets ours, and a presence-only check reports
# "present" over it. That's the same silent-shadow bug the slash-command check above
# exists to catch (the agent names are distinctive enough that a collision is
# unlikely, but "unlikely" is not what a check is for).
#
# The saving grace, worth knowing: verify-collab-*.sh reads opencode's RESOLVED
# permission map, so a shadowing def that is actually weaker FAILS there loudly. This
# check exists so the failure names its cause instead of looking like our own agent
# def mysteriously regressing.
agents_shadowed=""
for def in collab-read collab-build collab-research collab-watch; do
  f=".opencode/agent/${def}.md"
  if [ ! -f "$f" ]; then
    bad "${def} agent def MISSING ($f) — ask.sh falls back to a weaker/unrestricted built-in (or exits 5 for collab-watch)"
  elif [ -f "$manifest_agents" ] && ! grep -qxF "$f" "$manifest_agents"; then
    agents_shadowed="$agents_shadowed $def"
    warn "${def}: a file is at $f but ClaudeCollab did NOT install it — yours was kept, ours is absent"
  else
    pass "${def} agent def present and ours"
  fi
done
[ -n "$agents_shadowed" ] && warn "  a shadowing def that is weaker will also fail the resolved-config proof below — that's the real check"

# --- 4b. Slash commands ------------------------------------------------------
# The commands live in .claude/commands/collab/, which Claude Code exposes as the
# namespace `/collab:<name>` — so they cannot collide with the user's own commands
# or a bundled skill. (The published docs claim subdirectories do NOT affect the
# command name; observed behaviour contradicts that, and observed is what ships.)
#
# This check exists because the installer's merge-not-clobber rule has a silent side:
# a file already at one of our paths is SKIPPED, so the user keeps their file (good)
# and simply doesn't get ours (invisible). Before this, doctor printed "OK — all
# required checks passed" while a command was shadowed. That's the failure mode this
# project keeps killing: a check that reports clean over a hole.
hdr "Slash commands"
cmds="consult panel workshop review research delegate collaborate witness configure"
missing=""; shadowed=""; present=0
for c in $cmds; do
  f=".claude/commands/collab/${c}.md"
  if [ ! -f "$repo_root/$f" ]; then
    missing="$missing $c"
  elif [ -f "$manifest_agents" ] && ! grep -qxF "$f" "$manifest_agents"; then
    # The file is there but this install didn't put it there — it's the user's.
    shadowed="$shadowed $c"
  else
    present=$((present+1))
  fi
done
ncmds=$(printf '%s\n' $cmds | wc -l | tr -d ' ')
if [ -n "$missing" ]; then bad "slash command(s) MISSING (as /collab:<name>):$missing — reinstall, or they simply won't exist"; fi
if [ -n "$shadowed" ]; then
  warn "these paths hold a file ClaudeCollab did NOT install:$shadowed"
  warn "  yours was kept (deliberate) but ours is absent — that command is not what our docs describe"
  warn "  rename or remove yours and re-run install.sh, or accept that it's shadowed"
fi
# Report the count that is actually OURS. Saying "all 9 present" while warning that
# one of them isn't ours is the self-contradicting clean bill this check exists to
# prevent — the file being present is not the property anyone cares about.
if [ -z "$missing" ] && [ -z "$shadowed" ]; then
  pass "all ${ncmds} ClaudeCollab slash commands present and ours (/collab:*)"
elif [ -z "$missing" ]; then
  pass "${present} of ${ncmds} ClaudeCollab slash commands are ours (see the warning above)"
fi

# --- 4c. The agent guide is ONE file --------------------------------------------
# CLAUDE.md must be a symlink to AGENTS.md. This is the only mechanical guarantee
# behind the "one source of truth for every agent" convention: Claude Code reads
# CLAUDE.md, opencode reads AGENTS.md natively, and if they are two files they drift
# — silently, and in the worst possible way, because a DELEGATED model would then be
# working from different instructions than the Claude reviewing its diff.
#
# Not hypothetical: an in-place `perl -pi` sweep over `git ls-files '*.md'` replaced
# the symlink with a regular file (perl -i unlinks and recreates; it does not follow
# symlinks), and the copy drifted within the same session. sed -i does the same.
# If you must rewrite *.md in place, exclude CLAUDE.md or restore the link after.
hdr "Agent guide"
if [ ! -e CLAUDE.md ]; then
  warn "no CLAUDE.md — Claude Code reads that file; without it Claude gets no project guide"
elif [ -L CLAUDE.md ] && [ "$(readlink CLAUDE.md)" = "AGENTS.md" ]; then
  pass "CLAUDE.md -> AGENTS.md (one guide, both agents read the same bytes)"
elif [ -L CLAUDE.md ]; then
  bad "CLAUDE.md is a symlink to '$(readlink CLAUDE.md)', expected AGENTS.md"
else
  bad "CLAUDE.md is a REGULAR FILE, not a symlink to AGENTS.md — the two guides can now drift, and a delegated model (reads AGENTS.md) would follow different instructions than Claude (reads CLAUDE.md). Fix: rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md"
  if ! diff -q AGENTS.md CLAUDE.md >/dev/null 2>&1; then
    bad "  ...and they have ALREADY drifted ($(diff AGENTS.md CLAUDE.md | grep -c '^[<>]') lines differ) — reconcile before restoring the link, or you will discard whichever edits landed in the copy"
  fi
fi

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
  if bash collab/verify-collab-watch.sh --static >/dev/null 2>&1; then pass "collab-watch reads only collab/logs/** — no source, no shell, no egress (resolved config)"
  else bad "collab-watch static verification FAILED — run: bash collab/verify-collab-watch.sh --static"; fi
else
  warn "resolved-config proof skipped (needs opencode + jq) — the source lint above still ran"
fi

# --- 6c. Evidence layer (the watcher's data source) --------------------------
# Report the state of collab/logs/ and, crucially, the INTEGRITY of the most recent
# run. An unpaired `started` means a call died with its response unrecorded — the
# exact silent gap that would otherwise read as a clean log.
hdr "Evidence layer (collab/log.sh)"
if [ "${COLLAB_LOG:-on}" = "off" ]; then
  warn "logging is OFF (\$COLLAB_LOG=off) — no evidence is being recorded, so /collab:witness has nothing to audit"
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
    info "no runs logged yet — the log appears on the first /collab:consult, /collab:panel, …"
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
