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
inc()  { printf '\033[33mINCONCLUSIVE\033[0m %s\n' "$*"; warns=$((warns+1)); }
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
cfg() {
  local v="${!1:-}"
  [ -n "$v" ] || v="$(conf_get "$1")"
  [ -n "$v" ] || v="$2"
  printf '%s\n' "$v"
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

# --- 4c. Agent guides -----------------------------------------------------------
# AGENTS.md is the shared source of truth. CLAUDE.md is intentionally a small
# Claude-specific file whose first job is to point Claude back at AGENTS.md; it
# must not become a copied fork of the shared guide.
#
# THIS CHECK IS ABOUT DEVELOPING CLAUDECOLLAB ITSELF, NOT ABOUT USING IT. doctor.sh
# ships in the payload, but CLAUDE.md/AGENTS.md do NOT — install.sh never touches
# them. So in an installed project, CLAUDE.md is the USER'S file about THEIR project,
# and demanding it reference our AGENTS.md and carry our anti-bias guardrails would
# hard-fail doctor for every user who ran the documented preflight. It did: a fresh
# install + an ordinary three-line CLAUDE.md exited 1 with nine FAILs telling the user
# to restructure their own guide around our internal conventions.
#
# Gate on the install manifest, the discriminator this script already uses above:
# absent in the ClaudeCollab source repo (nothing was "installed"), present in every
# install. Same shape as the check-shebangs skip below — a check that needs the
# checkout stays silent outside it, rather than failing someone else's repo.
if [ -f "$manifest_agents" ]; then
  : # installed project — CLAUDE.md is the user's own; nothing here is ours to police
elif [ ! -f AGENTS.md ]; then
  : # no shared guide to point at — not the ClaudeCollab repo
else
hdr "Agent guide"
if [ ! -e CLAUDE.md ]; then
  warn "no CLAUDE.md — Claude Code reads that file; without it Claude gets no project guide"
elif [ -L CLAUDE.md ]; then
  bad "CLAUDE.md is a symlink to '$(readlink CLAUDE.md)', expected a regular Claude-specific file that references AGENTS.md"
else
  first_nonblank="$(awk 'NF { print; exit }' CLAUDE.md 2>/dev/null || true)"
  if printf '%s\n' "$first_nonblank" | grep -Eq 'AGENTS\.md'; then
    pass "CLAUDE.md references AGENTS.md at the top and remains a Claude-specific regular file"
  else
    bad "CLAUDE.md must reference AGENTS.md in its first nonblank line so Claude reads the shared source of truth first"
  fi
  # ONLY rules that exist in CLAUDE.md and NOWHERE ELSE. The parity question, vendor-
  # not-a-threat-model, capability cost, provenance and untrusted-external-output all
  # live in AGENTS.md, which Claude reads via the `@AGENTS.md` import — so CLAUDE.md
  # must NOT restate them, and greping CLAUDE.md for them would demand the duplication
  # that the section below exists to prevent. Guard the file that holds the content.
  #
  # The earlier list did grep for all eight, and the wordings had already drifted:
  # AGENTS.md "would I impose THIS ON AN ANTHROPIC SUBAGENT" vs CLAUDE.md "the same
  # rule on CLAUDE CODE or an Anthropic subagent" — one rule, two phrasings, so the
  # check keyed on authorship accident rather than substance.
  required_claude_patterns='Prefer evidence over intuition
Bias Audit
Verify each consequential claim
Preserve disagreement
Keep shared behavior in'
  missing_claude=""
  while IFS= read -r pat || [ -n "$pat" ]; do
    [ -z "$pat" ] && continue
    grep -Fq "$pat" CLAUDE.md || missing_claude="${missing_claude}
  - $pat"
  done <<EOF
$required_claude_patterns
EOF
  if [ -z "$missing_claude" ]; then
    pass "CLAUDE.md keeps the required anti-bias and verification guardrails"
  else
    bad "CLAUDE.md is missing required Claude-specific guardrail(s):$missing_claude"
  fi

  # Size ceiling — the anti-fork control. The old symlink made CLAUDE.md a copy of
  # AGENTS.md BY CONSTRUCTION; nothing can drift from itself. A regular file has no
  # such guarantee, and the grep above cannot supply one: a CLAUDE.md carrying the
  # whole of AGENTS.md inline still passes every pattern. This is detection, not
  # construction — it can't stop a fork, only make one loud. It works because the
  # honest file is small (the real one is ~20 lines) and a fork is not: inlining
  # AGENTS.md costs 100+. Generous on purpose — it must fire on a copied guide, never
  # on someone adding a legitimate Claude-only rule.
  claude_lines="$(wc -l < CLAUDE.md 2>/dev/null || echo 0)"
  if [ "$claude_lines" -le 60 ]; then
    pass "CLAUDE.md is ${claude_lines} lines — a pointer, not a fork of AGENTS.md"
  else
    bad "CLAUDE.md is ${claude_lines} lines (ceiling 60) — it is supposed to hold ONLY what AGENTS.md does not say, and Claude already reads AGENTS.md via the @AGENTS.md import. If shared rules got copied in, delete the copies; if this is genuinely Claude-only content, raise the ceiling in doctor.sh deliberately."
  fi
fi
fi

# --- 5. Model policy file ----------------------------------------------------
hdr "Model policy"
# Same resolution ask.sh uses: $COLLAB_POLICY, else a RULEFUL .local, else default.
# An empty/comment-only .local is ignored (it must not silently void a committed deny).
_has_rules() {
  [ -f "$1" ] && awk '
    /^[[:space:]]*(#|$)/ { next }
    $1 ~ /^(allow|ask|deny)$/ && NF >= 2 && $2 !~ /^#/ { found=1; exit }
    END { exit !found }' "$1" 2>/dev/null
}
_policy_lint() {
  local file="$1" line tier pat rest line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no+1)); tier=""; pat=""; rest=""
    read -r tier pat rest <<< "$line"
    case "$tier" in ''|'#'*) continue ;; esac
    if [[ ! "$tier" =~ ^(allow|ask|deny)$ ]] || [ -z "$pat" ] || [[ "$pat" = \#* ]] \
        || { [ -n "$rest" ] && [[ "$rest" != \#* ]]; }; then
      printf '%s:%s\n' "$file" "$line_no"
    fi
  done < "$file"
}
local_policy="$repo_root/collab/models.policy.local"
if [ -n "${COLLAB_POLICY:-}" ]; then pol="$COLLAB_POLICY"
elif _has_rules "$local_policy"; then pol="$local_policy"
else
  pol="$repo_root/collab/models.policy"
  [ -f "$local_policy" ] && warn "models.policy.local exists but has no complete rules — ignored; the committed models.policy is in effect (put an explicit rule like 'allow *' in .local to override it)."
fi
if [ -f "$pol" ]; then
  rules=0
  while IFS= read -r line || [ -n "$line" ]; do
    tier=""; pat=""; rest=""; read -r tier pat rest <<< "$line"
    case "$tier" in allow|ask|deny) [ -n "$pat" ] && [[ "$pat" != \#* ]] && rules=$((rules+1)) ;; esac
  done < "$pol"
  malformed="$(_policy_lint "$pol")"
  if [ -n "$malformed" ]; then bad "policy has malformed active rule line(s): $(printf '%s' "$malformed" | tr '\n' ' ')"
  else pass "policy parses cleanly: ${rules} active rule(s) in $(basename "$pol")"; fi
else
  info "no policy file at $pol — default-allow (every model permitted). Add one to gate models."
fi
if [ -f "$local_policy" ] && [ "$local_policy" != "$pol" ]; then
  malformed="$(_policy_lint "$local_policy")"
  [ -z "$malformed" ] || bad "ignored models.policy.local has malformed active rule line(s): $(printf '%s' "$malformed" | tr '\n' ' ')"
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
  if bash collab/verify-collab-read.sh --static >/dev/null 2>&1; then pass "collab-read allows web and denies mutation/secret-read paths (resolved config)"
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
log_setting="$(cfg COLLAB_LOG on)"
if [ "$log_setting" = "off" ]; then
  warn "logging is OFF (\$COLLAB_LOG=off) — no evidence is being recorded, so /collab:witness has nothing to audit"
elif [ ! -f collab/log.sh ]; then
  warn "collab/log.sh not present — model calls are not being recorded"
elif ! command -v jq >/dev/null 2>&1; then
  bad "jq missing — ask.sh cannot write the evidence log (see the jq check above)"
else
  logdir="$(cfg COLLAB_LOG_DIR "$repo_root/collab/logs")"
  pass "logging ON (prompts=$(cfg COLLAB_LOG_PROMPTS full), retention=$(cfg COLLAB_LOG_RETENTION_DAYS 14)d, dir=$logdir)"
  if [ -d "$logdir" ] && [ -e "$logdir/latest" ]; then
    if bash collab/log.sh verify "$(basename "$(readlink "$logdir/latest" 2>/dev/null || echo latest)")" >/dev/null 2>&1; then
      pass "latest run's log is intact (expected/start/completed cardinality, captures, and hashes match)"
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
  for spec in \
    "read|collab-read runtime probes: no mutation/secret contradiction" \
    "build|collab-build runtime probe: edit path works" \
    "research|collab-research runtime probe: no mutation contradiction" \
    "watch|collab-watch runtime probe: source outside log scope denied"; do
    role="${spec%%|*}"; msg="${spec#*|}"
    bash "collab/verify-collab-${role}.sh" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) pass "$msg" ;;
      6) inc "collab-${role} runtime probe could not establish a result — run: bash collab/verify-collab-${role}.sh" ;;
      *) bad "collab-${role} runtime verification FAILED — run: bash collab/verify-collab-${role}.sh" ;;
    esac
  done
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
