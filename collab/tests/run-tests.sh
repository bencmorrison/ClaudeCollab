#!/usr/bin/env bash
# run-tests.sh — unit tests for collab/ask.sh using a fake `opencode` on PATH.
# No model is ever called; every assertion is about the argv / behaviour of the
# wrapper. Run:  bash collab/tests/run-tests.sh   (exit 0 = all pass).
#
# Deps: bash, coreutils, and `jq` (the fake-opencode stub uses jq to emit JSON for
# the --emit-session cases; ask.sh itself needs jq only on that path too).
set -uo pipefail

# Hermetic: the ambient environment must not change assertions. A user who followed
# the docs and exported COLLAB_MODEL (README/AGENTS recommend it) would otherwise make
# ask.sh inject `-m …` and fail the "default: no -m" case — so `doctor.sh`, which runs
# this suite, would cry wolf in the exact config the docs tell people to set up. Cases
# that need these vars set them inline as command-prefixes, so clearing the ambient
# values here is safe and correct.
unset COLLAB_MODEL COLLAB_CONFIRMED COLLAB_TIMEOUT COLLAB_POLICY
unset COLLAB_LOG COLLAB_LOG_PROMPTS COLLAB_RUN_ID COLLAB_COMMAND COLLAB_LOG_RETENTION_DAYS

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
ask="$repo_root/collab/ask.sh"

# Put the fake opencode first on PATH so `command -v opencode` finds it.
fakedir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
cp "$here/fake-opencode" "$fakedir/opencode"
chmod +x "$fakedir/opencode"
export PATH="$fakedir:$PATH"

# Send the evidence layer somewhere disposable. Without this the suite would append a
# run to the developer's real collab/logs/ on every invocation — polluting the audit
# trail with fake-opencode's "canned answer" is exactly the kind of noise a watcher
# should never have to reason about.
export COLLAB_LOG_DIR="$fakedir/logs"

# Neutral permissive policy so policy logic doesn't interfere unless a test opts in.
allow_pol="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"; printf 'allow *\n' > "$allow_pol"

argsfile="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"; stdinfile="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"
export FAKE_OPENCODE_ARGS="$argsfile" FAKE_OPENCODE_STDIN="$stdinfile"

pass=0; fail=0
ok()  { printf '\033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

cleanup() { rm -rf "$fakedir" "$allow_pol" "$argsfile" "$stdinfile"; }
trap cleanup EXIT

# run_ask <case-desc> -- <ask.sh args...> : runs ask.sh with the permissive policy,
# capturing stdout/stderr/exit into globals OUT/ERR/RC. Resets the args capture.
OUT=""; ERR=""; RC=0
run_ask() {
  : > "$argsfile"; : > "$stdinfile"
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"
  OUT="$(COLLAB_POLICY="$allow_pol" bash "$ask" "$@" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
# args_has <exact-line> : true if the captured argv contains this exact token line.
args_has() { grep -qxF -- "$1" "$argsfile"; }
# nth_arg <n> : echo the nth captured argv token (1-based).
nth_arg() { sed -n "${1}p" "$argsfile"; }
last_arg() { tail -n1 "$argsfile"; }

echo "== ask.sh wrapper tests (fake opencode, no model calls) =="

# 1. Default read-only agent, plain prompt, no -m.
run_ask "hello there"
{ args_has 'run' && args_has '--agent' && args_has 'collab-read' && args_has '--auto' \
  && [ "$(last_arg)" = "hello there" ] && ! args_has '-m'; } \
  && ok "default: run --agent collab-read --auto, prompt passed, no -m" \
  || no "default agent/args (got: $(tr '\n' ' ' <"$argsfile"))"

# 2. -m selects the model.
run_ask -m openai/gpt-5.5 "q"
{ args_has '-m' && args_has 'openai/gpt-5.5'; } \
  && ok "-m passes provider/model through" \
  || no "-m not forwarded (got: $(tr '\n' ' ' <"$argsfile"))"

# 3. --edit switches to the collab-build agent (hardened editor, not raw build).
#    --allow-dirty so this agent-selection check is independent of the worktree
#    guard (tested separately below) and of this repo's cleanliness during dev.
run_ask --edit --allow-dirty "change a file"
args_has 'collab-build' && ! args_has 'collab-read' && ! args_has 'build' \
  && ok "--edit -> --agent collab-build" \
  || no "--edit did not select collab-build (got: $(tr '\n' ' ' <"$argsfile"))"

# 3b. --research switches to the collab-research agent (web-capable, non-mutating).
#     No worktree guard here: it's a read-only path, which case 3c asserts.
run_ask --research "what changed in X"
args_has 'collab-research' && ! args_has 'collab-read' && ! args_has 'collab-build' \
  && ok "--research -> --agent collab-research" \
  || no "--research did not select collab-research (got: $(tr '\n' ' ' <"$argsfile"))"

# 3c. --research is NOT write-capable, so the clean-worktree guard must not gate it
#     (the guard is write-path only). Run it with a deliberately dirty tree.
dirty_repo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
( cd "$dirty_repo" && git init -q && echo dirty > uncommitted.txt ) 2>/dev/null
: > "$argsfile"
( cd "$dirty_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" --research "q" >/dev/null 2>&1 ); RC=$?
{ [ "$RC" -ne 6 ] && args_has 'collab-research'; } \
  && ok "--research skips the write-path worktree guard (dirty tree still runs)" \
  || no "--research was gated by the worktree guard (rc=$RC)"
rm -rf "$dirty_repo"

# 4. -a plan honoured.
run_ask -a plan "q"
args_has 'plan' && ok "-a plan honoured" || no "-a plan not forwarded"

# 5. -s continues a session.
run_ask -s ses_xyz "q"
{ args_has '-s' && args_has 'ses_xyz'; } \
  && ok "-s forwards the session id" || no "-s not forwarded"

# 6. Prompt with spaces/quotes is a single argv token, not split.
run_ask 'weird "prompt" with   spaces'
[ "$(last_arg)" = 'weird "prompt" with   spaces' ] \
  && ok "prompt with spaces/quotes stays one arg" \
  || no "prompt got mangled (got: '$(last_arg)')"

# 7. stdin was redirected from /dev/null (capture is empty).
run_ask "q"
[ ! -s "$stdinfile" ] \
  && ok "stdin redirected from /dev/null (empty capture)" \
  || no "stdin was NOT empty (the load-bearing redirect is broken)"

# 8. --emit-session: --format json used; SESSION line + extracted text emitted.
FAKE_OPENCODE_TEXT="Hello from fake." FAKE_OPENCODE_SID="ses_abc123" \
  run_ask --emit-session -m openai/gpt-5.5 "q"
{ args_has '--format' && args_has 'json' \
  && printf '%s' "$OUT" | grep -qx 'SESSION: ses_abc123' \
  && printf '%s' "$OUT" | grep -qx 'Hello from fake.'; } \
  && ok "--emit-session emits SESSION id + extracted answer" \
  || no "--emit-session output wrong (got: $(printf '%s' "$OUT" | tr '\n' '|'))"

# 9. Non-zero opencode exit is preserved and reported.
FAKE_OPENCODE_EXIT=7 run_ask "q"
{ [ "$RC" -eq 7 ] && printf '%s' "$ERR" | grep -q 'exited 7'; } \
  && ok "non-zero opencode exit preserved (7) and reported" \
  || no "exit status not preserved/reported (rc=$RC)"

# 10. --dry-run prints the command and does NOT call opencode.
run_ask --dry-run -m openai/gpt-5.5 "q"
{ [ "$RC" -eq 0 ] && ! [ -s "$argsfile" ] \
  && printf '%s' "$OUT" | grep -q 'opencode run --agent collab-read --auto -m openai/gpt-5.5'; } \
  && ok "--dry-run prints command, no opencode call" \
  || no "--dry-run ran opencode or wrong output (rc=$RC, args: $(tr '\n' ' ' <"$argsfile"))"

# 11. Policy deny short-circuits BEFORE calling opencode (exit 3, no argv captured).
deny_pol="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"; printf 'deny openai/gpt-5.5\n' > "$deny_pol"
: > "$argsfile"
OUT="$(COLLAB_POLICY="$deny_pol" bash "$ask" -m openai/gpt-5.5 "q" 2>/dev/null)"; RC=$?
{ [ "$RC" -eq 3 ] && ! [ -s "$argsfile" ]; } \
  && ok "policy deny -> exit 3, opencode never invoked" \
  || no "policy deny not enforced (rc=$RC, args present=$( [ -s "$argsfile" ] && echo yes || echo no))"
rm -f "$deny_pol"

# 12. Policy ask, unconfirmed -> exit 4, no call.
ask_pol="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"; printf 'ask openai/gpt-5.5\n' > "$ask_pol"
: > "$argsfile"
COLLAB_POLICY="$ask_pol" bash "$ask" -m openai/gpt-5.5 "q" >/dev/null 2>&1; RC=$?
{ [ "$RC" -eq 4 ] && ! [ -s "$argsfile" ]; } \
  && ok "policy ask unconfirmed -> exit 4, no call" || no "policy ask not gated (rc=$RC)"
# ...and confirmed -> runs.
: > "$argsfile"
COLLAB_CONFIRMED=1 COLLAB_POLICY="$ask_pol" bash "$ask" -m openai/gpt-5.5 "q" >/dev/null 2>&1; RC=$?
{ [ "$RC" -eq 0 ] && args_has 'openai/gpt-5.5'; } \
  && ok "policy ask + COLLAB_CONFIRMED=1 -> runs" || no "confirmed ask did not run (rc=$RC)"
rm -f "$ask_pol"

# 13. Missing value for -m -> usage error, exit 1, no call.
: > "$argsfile"
COLLAB_POLICY="$allow_pol" bash "$ask" -m >/dev/null 2>&1; RC=$?
{ [ "$RC" -eq 1 ] && ! [ -s "$argsfile" ]; } \
  && ok "missing -m value -> exit 1, no call" || no "missing-value not caught (rc=$RC)"

# 14. collab-read fallback: a copy of ask.sh with no sibling .opencode falls back to
#     plan (never build). Proves the fail-open guard.
tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$tmp_repo/collab"
cp "$ask" "$tmp_repo/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$tmp_repo/collab/" 2>/dev/null || true
: > "$argsfile"
OUT="$(COLLAB_POLICY="$allow_pol" bash "$tmp_repo/collab/ask.sh" "q" 2>/dev/null)"; RC=$?
{ args_has 'plan' && ! args_has 'build'; } \
  && ok "missing collab-read def -> falls back to plan (not build)" \
  || no "fallback wrong (got: $(tr '\n' ' ' <"$argsfile"))"
rm -rf "$tmp_repo"

# 14b. collab-build fallback: --edit with no sibling .opencode falls back to the
#      built-in `build` (the only write-capable built-in), never collab-read/plan.
tmp_repo2="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$tmp_repo2/collab"
cp "$ask" "$tmp_repo2/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$tmp_repo2/collab/" 2>/dev/null || true
: > "$argsfile"; errf2="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"
# --allow-dirty so the worktree guard (tested separately) doesn't gate this fallback check.
OUT="$(COLLAB_POLICY="$allow_pol" bash "$tmp_repo2/collab/ask.sh" --edit --allow-dirty "q" 2>"$errf2")"; RC=$?
ERR2="$(cat "$errf2")"; rm -f "$errf2"
# Must fall back to build AND warn loudly that hardening is gone — the warning is the
# safety-relevant behavior of this fallback, so assert it, not just the agent choice.
{ args_has 'build' && ! args_has 'collab-build' && ! args_has 'collab-read' && ! args_has 'plan' \
  && printf '%s' "$ERR2" | grep -qi 'UNRESTRICTED'; } \
  && ok "missing collab-build def + --edit -> falls back to build with loud UNRESTRICTED warning" \
  || no "collab-build fallback wrong (agent: $(tr '\n' ' ' <"$argsfile"); err: $ERR2)"
rm -rf "$tmp_repo2"

# 14d. collab-research fallback: --research with no sibling .opencode falls back to
#      `plan` (never build) and warns loudly. This path has network egress, so a
#      silent downgrade to a bash-capable agent would be the worst case.
tmp_repo4="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$tmp_repo4/collab"
cp "$ask" "$tmp_repo4/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$tmp_repo4/collab/" 2>/dev/null || true
: > "$argsfile"; errf4="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"
OUT="$(COLLAB_POLICY="$allow_pol" bash "$tmp_repo4/collab/ask.sh" --research "q" 2>"$errf4")"; RC=$?
ERR4="$(cat "$errf4")"; rm -f "$errf4"
{ args_has 'plan' && ! args_has 'build' && ! args_has 'collab-research' \
  && printf '%s' "$ERR4" | grep -qi 'WEAKER'; } \
  && ok "missing collab-research def + --research -> falls back to plan with loud warning" \
  || no "collab-research fallback wrong (agent: $(tr '\n' ' ' <"$argsfile"); err: $ERR4)"
rm -rf "$tmp_repo4"

# 14c. COLLAB_REQUIRE_HARDENED=1 turns a missing def into a hard error (exit 5, no
#      opencode call) instead of falling back to a weaker/unrestricted agent.
tmp_repo3="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$tmp_repo3/collab"
cp "$ask" "$tmp_repo3/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$tmp_repo3/collab/" 2>/dev/null || true
: > "$argsfile"
COLLAB_REQUIRE_HARDENED=1 COLLAB_POLICY="$allow_pol" bash "$tmp_repo3/collab/ask.sh" "q" >/dev/null 2>&1; RC=$?
rc_read=$RC
: > "$argsfile"
COLLAB_REQUIRE_HARDENED=1 COLLAB_POLICY="$allow_pol" bash "$tmp_repo3/collab/ask.sh" --edit "q" >/dev/null 2>&1; RC=$?
{ [ "$rc_read" -eq 5 ] && [ "$RC" -eq 5 ] && ! [ -s "$argsfile" ]; } \
  && ok "COLLAB_REQUIRE_HARDENED=1 + missing def -> exit 5, no fallback, no call" \
  || no "REQUIRE_HARDENED not enforced (read rc=$rc_read, edit rc=$RC)"
rm -rf "$tmp_repo3"

# 14d-g. Clean-worktree guard on the write path. Run the REAL ask.sh with cwd set to
# a temp git repo so the guard sees a controlled state (the collab-build def is still
# found via ask.sh's own path, so agent=collab-build, no fallback). commit.gpgsign is
# forced off so the test never triggers a signing prompt.
guard_repo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
( cd "$guard_repo" && git init -q && git config user.email t@t.co && git config user.name t \
  && git config commit.gpgsign false && git commit -q --allow-empty -m init ) 2>/dev/null
if [ -d "$guard_repo/.git" ]; then
  # clean tree -> proceeds, opencode called, stderr notes the pre-delegation HEAD.
  : > "$argsfile"
  ERRG="$(cd "$guard_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" --edit "q" 2>&1 >/dev/null)"; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-build' && printf '%s' "$ERRG" | grep -qi 'pre-delegation HEAD'; } \
    && ok "guard: clean tree + --edit -> runs, prints pre-delegation HEAD" \
    || no "guard clean-tree wrong (rc=$RCG, err: $ERRG)"

  # dirty tree (untracked file) -> refuses (exit 6), opencode NOT called.
  ( cd "$guard_repo" && : > untracked.txt )
  : > "$argsfile"
  ( cd "$guard_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" --edit "q" ) >/dev/null 2>&1; RCG=$?
  { [ "$RCG" -eq 6 ] && ! [ -s "$argsfile" ]; } \
    && ok "guard: dirty tree + --edit -> exit 6, opencode never called" \
    || no "guard dirty-tree not enforced (rc=$RCG, argv present=$( [ -s "$argsfile" ] && echo yes || echo no))"

  # dirty tree + --allow-dirty -> proceeds anyway.
  : > "$argsfile"
  ( cd "$guard_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" --edit --allow-dirty "q" ) >/dev/null 2>&1; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-build'; } \
    && ok "guard: dirty tree + --allow-dirty -> runs anyway" \
    || no "guard --allow-dirty did not override (rc=$RCG)"

  # dirty tree + READ-ONLY (default agent) -> guard is write-path only, so it runs.
  : > "$argsfile"
  ( cd "$guard_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" "q" ) >/dev/null 2>&1; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-read'; } \
    && ok "guard: dirty tree + read-only -> guard skipped, runs" \
    || no "guard fired on the read-only path (rc=$RCG)"
else
  ok "worktree guard (skipped: git init unavailable in this sandbox)"
fi
rm -rf "$guard_repo"

# 15. COLLAB_MODEL supplies the default model when no -m is given.
: > "$argsfile"
COLLAB_MODEL=openai/gpt-5.5 COLLAB_POLICY="$allow_pol" bash "$ask" "q" >/dev/null 2>&1
{ args_has '-m' && args_has 'openai/gpt-5.5'; } \
  && ok "COLLAB_MODEL used as default model" || no "COLLAB_MODEL not forwarded"

# 16. COLLAB_TIMEOUT shows a timeout prefix in --dry-run (when a timeout bin exists).
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  run_ask_out="$(COLLAB_TIMEOUT=90 COLLAB_POLICY="$allow_pol" bash "$ask" --dry-run "q" 2>/dev/null)"
  printf '%s' "$run_ask_out" | grep -qE '^(timeout|gtimeout) 90 opencode ' \
    && ok "COLLAB_TIMEOUT adds timeout prefix in dry-run" \
    || no "COLLAB_TIMEOUT prefix missing (got: $run_ask_out)"
else
  ok "COLLAB_TIMEOUT prefix (skipped: no timeout binary on this host)"
fi

# 17. Unknown -a value emits a soft note to stderr (but still runs).
run_ask --dry-run -a paln "q"
printf '%s' "$ERR" | grep -q "not one of collab-read|collab-build|collab-research|plan|build" \
  && ok "-a <unknown> emits soft note" || no "-a unknown note missing (err: $ERR)"

# 18. --emit-session + opencode timeout (124): reports timeout, exits 124.
FAKE_OPENCODE_EXIT=124 run_ask --emit-session -m openai/gpt-5.5 "q"
{ [ "$RC" -eq 124 ] && printf '%s' "$ERR" | grep -qi 'timeout'; } \
  && ok "--emit-session timeout(124) reported, exit preserved" \
  || no "emit-session 124 handling wrong (rc=$RC, err: $ERR)"

# 19. --emit-session + empty answer (status 0): warns but still exits 0.
FAKE_OPENCODE_TEXT="" run_ask --emit-session -m openai/gpt-5.5 "q"
{ [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'no answer text'; } \
  && ok "--emit-session empty answer warns, exit 0" \
  || no "emit-session empty-answer handling wrong (rc=$RC, err: $ERR)"

# 20. Policy resolution: a git-ignored collab/models.policy.local is preferred over
#     the committed models.policy when $COLLAB_POLICY is unset; $COLLAB_POLICY still
#     overrides both. (What /configure-collab relies on.)
presol="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$presol/collab"
cp "$ask" "$presol/collab/ask.sh"
printf 'allow *\n' > "$presol/collab/models.policy"                    # default: allow all
printf 'deny openai/gpt-5.5\n' > "$presol/collab/models.policy.local"  # personal: deny it
: > "$argsfile"
bash "$presol/collab/ask.sh" -m openai/gpt-5.5 "q" >/dev/null 2>&1; RC=$?   # no COLLAB_POLICY
[ "$RC" -eq 3 ] \
  && ok "policy: models.policy.local preferred over the committed default" \
  || no "policy .local not preferred (rc=$RC, expected 3=deny)"
COLLAB_POLICY="$allow_pol" bash "$presol/collab/ask.sh" -m openai/gpt-5.5 "q" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] \
  && ok "policy: \$COLLAB_POLICY overrides .local" \
  || no "\$COLLAB_POLICY did not override .local (rc=$RC)"
# 20b. An empty / comment-only .local must NOT silently void a committed deny set
#      (fail-closed: it's skipped, and the committed deny still applies). [review 2026-07-15]
printf '# personal file, no rules yet\n' > "$presol/collab/models.policy.local"
printf 'deny openai/gpt-5.5\nallow *\n' > "$presol/collab/models.policy"
bash "$presol/collab/ask.sh" -m openai/gpt-5.5 "q" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] \
  && ok "policy: empty/comment-only .local doesn't void the committed deny (fail-closed)" \
  || no "empty .local shadowed the committed policy (rc=$RC, expected 3)"
rm -rf "$presol"

# 20c. Unreadable policy file fails CLOSED (deny), not open (allow). Root ignores
#      file perms, so skip there.
if [ "$(id -u)" -ne 0 ]; then
  unrd="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$unrd/collab"
  cp "$ask" "$unrd/collab/ask.sh"
  printf 'deny openai/evil\nallow *\n' > "$unrd/collab/models.policy"; chmod 000 "$unrd/collab/models.policy"
  bash "$unrd/collab/ask.sh" --dry-run -m openai/anything "q" >/dev/null 2>&1; RC=$?
  chmod 644 "$unrd/collab/models.policy"; rm -rf "$unrd"
  [ "$RC" -eq 3 ] \
    && ok "policy: unreadable policy file fails closed (deny), not open" \
    || no "unreadable policy failed OPEN (rc=$RC, expected 3)"
else
  ok "policy: unreadable-fails-closed (skipped as root)"
fi

# 21. Config file: collab.conf.local supplies the default model when both -m and
#     $COLLAB_MODEL are absent; $COLLAB_MODEL still overrides the file.
confrepo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$confrepo/collab"
cp "$ask" "$confrepo/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$confrepo/collab/" 2>/dev/null || true
printf 'COLLAB_MODEL=openai/from-conf\n' > "$confrepo/collab/collab.conf.local"
: > "$argsfile"
COLLAB_POLICY="$allow_pol" bash "$confrepo/collab/ask.sh" "q" >/dev/null 2>&1   # no -m, no env
{ args_has '-m' && args_has 'openai/from-conf'; } \
  && ok "config: collab.conf.local supplies the default model" \
  || no "config file default not used (got: $(tr '\n' ' ' <"$argsfile"))"
: > "$argsfile"
COLLAB_MODEL=openai/from-env COLLAB_POLICY="$allow_pol" bash "$confrepo/collab/ask.sh" "q" >/dev/null 2>&1
{ args_has 'openai/from-env' && ! args_has 'openai/from-conf'; } \
  && ok "config: \$COLLAB_MODEL overrides collab.conf.local" \
  || no "env did not override config file (got: $(tr '\n' ' ' <"$argsfile"))"
# 21b. Inline `# comment` in a config value is stripped (review footgun fix).
printf 'COLLAB_MODEL=openai/commented   # my default\n' > "$confrepo/collab/collab.conf.local"
: > "$argsfile"
COLLAB_POLICY="$allow_pol" bash "$confrepo/collab/ask.sh" "q" >/dev/null 2>&1
{ args_has 'openai/commented' && ! args_has 'openai/commented   # my default'; } \
  && ok "config: inline '# comment' stripped from a value" \
  || no "inline comment not stripped (got: $(tr '\n' ' ' <"$argsfile"))"
# 21c. A config model id starting with '-' is refused (exit 2), not passed as a flag.
printf 'COLLAB_MODEL=--print-logs\n' > "$confrepo/collab/collab.conf.local"
: > "$argsfile"
COLLAB_POLICY="$allow_pol" bash "$confrepo/collab/ask.sh" "q" >/dev/null 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && ! [ -s "$argsfile" ]; } \
  && ok "config: leading-dash model id refused (exit 2, no opencode call)" \
  || no "leading-dash config model not refused (rc=$RC)"
rm -rf "$confrepo"

# 21d. conf_get is byte-identical across ask.sh / panel-models.sh / doctor.sh — the
#      parser is duplicated (standalone by design for this copy-based harness), so
#      guard against silent drift. [review 2026-07-15]
xget() { awk '/^conf_get\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$1"; }
cg_a="$(xget "$repo_root/collab/ask.sh")"; cg_p="$(xget "$repo_root/collab/panel-models.sh")"; cg_d="$(xget "$repo_root/collab/doctor.sh")"
{ [ -n "$cg_a" ] && [ "$cg_a" = "$cg_p" ] && [ "$cg_p" = "$cg_d" ]; } \
  && ok "conf_get identical across ask.sh/panel-models.sh/doctor.sh (no drift)" \
  || no "conf_get copies have DRIFTED — fix all three"

# --- panel-models.sh (the /panel model-set resolver; opencode-free) --------------
panel="$repo_root/collab/panel-models.sh"
perrf="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"
# P1. Two distinct cross-provider models -> both listed in order, no warning.
POUT="$(bash "$panel" openai/gpt-5 google/gemini-2.5-pro 2>"$perrf")"; PERR="$(cat "$perrf")"
{ [ "$(printf '%s' "$POUT" | sed -n 1p)" = "openai/gpt-5" ] \
  && [ "$(printf '%s' "$POUT" | sed -n 2p)" = "google/gemini-2.5-pro" ] \
  && [ -z "$PERR" ]; } \
  && ok "panel: distinct cross-provider set -> listed in order, no warning" \
  || no "panel distinct-set wrong (out=$(printf '%s' "$POUT"|tr '\n' ,) err=$PERR)"

# P2. Duplicate id -> dropped with a warning, list de-duplicated.
POUT="$(bash "$panel" openai/gpt-5 openai/gpt-5 google/gemini 2>"$perrf")"; PERR="$(cat "$perrf")"
{ [ "$(printf '%s\n' "$POUT" | grep -c .)" -eq 2 ] && printf '%s' "$PERR" | grep -qi 'duplicate'; } \
  && ok "panel: duplicate id dropped + warned" \
  || no "panel dedupe wrong (out=$(printf '%s' "$POUT"|tr '\n' ,) err=$PERR)"

# P3. Single-provider set -> diversity-theater warning (but still lists them).
POUT="$(bash "$panel" openai/gpt-5 openai/gpt-4 2>"$perrf")"; PERR="$(cat "$perrf")"
{ [ "$(printf '%s\n' "$POUT" | grep -c .)" -eq 2 ] && printf '%s' "$PERR" | grep -qi 'single-family\|diversity'; } \
  && ok "panel: single-provider set warns (diversity theater)" \
  || no "panel single-provider warn missing (err=$PERR)"

# P4. No args -> reads $COLLAB_MODELS (comma-separated), splits it.
POUT="$(COLLAB_MODELS='anthropic/claude-sonnet-5, openai/gpt-5' bash "$panel" 2>/dev/null)"
{ [ "$(printf '%s' "$POUT" | sed -n 1p)" = "anthropic/claude-sonnet-5" ] \
  && [ "$(printf '%s' "$POUT" | sed -n 2p)" = "openai/gpt-5" ]; } \
  && ok "panel: COLLAB_MODELS (comma-separated) parsed in order" \
  || no "panel COLLAB_MODELS parse wrong (out=$(printf '%s' "$POUT"|tr '\n' ,))"

# P5. No models at all -> exit 2, nothing on stdout.
POUT="$(COLLAB_MODELS='' bash "$panel" 2>/dev/null)"; PRC=$?
{ [ "$PRC" -eq 2 ] && [ -z "$POUT" ]; } \
  && ok "panel: no models -> exit 2, empty stdout" \
  || no "panel empty-input wrong (rc=$PRC, out=$POUT)"
rm -f "$perrf"

# P6. panel-models reads COLLAB_MODELS from collab.conf.local when args + env absent.
pconf="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
cp "$panel" "$pconf/panel-models.sh"
printf 'COLLAB_MODELS=openai/a google/b\n' > "$pconf/collab.conf.local"
POUT="$(bash "$pconf/panel-models.sh" 2>/dev/null)"    # no args, no env
{ [ "$(printf '%s' "$POUT" | sed -n 1p)" = "openai/a" ] && [ "$(printf '%s' "$POUT" | sed -n 2p)" = "google/b" ]; } \
  && ok "panel: reads COLLAB_MODELS from collab.conf.local" \
  || no "panel config-file set wrong (out=$(printf '%s' "$POUT" | tr '\n' ,))"
rm -rf "$pconf"

# --- check-agent-permissions.sh meta-tests -------------------------------------
# The lint is itself a security control, so assert it (a) passes the real agents and
# (b) CATCHES the order/bounding evasions that dogfooding /review found (2026-07-15):
# a good-looking block in the markdown BODY, and last-match reorderings.
lintdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$lintdir/collab/tests" "$lintdir/.opencode/agent"
cp "$repo_root/collab/tests/check-agent-permissions.sh" "$lintdir/collab/tests/"
# run_lint : 0 if the lint passes the files currently in $lintdir/.opencode/agent.
run_lint() { ( cd "$lintdir" && bash collab/tests/check-agent-permissions.sh >/dev/null 2>&1 ); }
reset_agents() { cp "$repo_root/.opencode/agent/collab-read.md" "$repo_root/.opencode/agent/collab-build.md" "$repo_root/.opencode/agent/collab-research.md" "$lintdir/.opencode/agent/"; }

# L1. Real, valid agents pass.
reset_agents
run_lint && ok "lint: real agents pass" || no "lint rejects the real agents (false positive)"

# L2. read map with '*': allow AFTER the secret denies (last-match reopens .env) -> FAIL.
reset_agents
printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  "*": deny' '  read:' \
  '    ".env": deny' '    "*.env": deny' '    "*.key": deny' '    "*.pem": deny' '    "*credentials*": deny' \
  '    "*": allow' '---' 'body' > "$lintdir/.opencode/agent/collab-read.md"
run_lint && no "lint MISSED read-map reorder (secret reopened)" || ok "lint: catches read-map '*': allow after secret denies"

# L3. Unprotected frontmatter (no floor) with a valid-looking block in the BODY -> FAIL.
reset_agents
printf '%s\n' '---' 'description: x' 'mode: all' '---' 'Example (not real frontmatter):' \
  'permission:' '  "*": deny' '  read:' '    "*": allow' '    ".env": deny' '    "*.env": deny' \
  '    "*.key": deny' '    "*.pem": deny' '    "*credentials*": deny' > "$lintdir/.opencode/agent/collab-read.md"
run_lint && no "lint MISSED unprotected frontmatter (body block fooled it)" || ok "lint: ignores body block, catches missing floor"

# L4. collab-build with '*': deny placed AFTER the allows (effective = all denied) -> FAIL.
reset_agents
printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  edit: allow' '  write: allow' \
  '  patch: allow' '  bash: allow' '  "*": deny' '  read:' '    "*": allow' '    ".env": deny' \
  '    "*.env": deny' '    "*.key": deny' '    "*.pem": deny' '    "*credentials*": deny' '---' 'body' \
  > "$lintdir/.opencode/agent/collab-build.md"
run_lint && no "lint MISSED collab-build floor-after-allows (edit path dead)" || ok "lint: catches '*': deny placed after the allows"
rm -rf "$lintdir"

# --- check-shebangs.sh meta-tests ----------------------------------------------
# A lint nobody proved can fail is decoration. Assert it accepts the conforming
# form and rejects each way a script could drift off `#!/usr/bin/env bash`.
shb="$repo_root/collab/tests/check-shebangs.sh"
shbdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"

printf '#!/usr/bin/env bash\necho hi\n' > "$shbdir/good.sh"
bash "$shb" "$shbdir/good.sh" >/dev/null 2>&1 \
  && ok "shebang lint: accepts #!/usr/bin/env bash" \
  || no "shebang lint rejects the correct form (false positive)"

printf '#!/bin/bash\necho hi\n' > "$shbdir/bad.sh"
bash "$shb" "$shbdir/bad.sh" >/dev/null 2>&1 \
  && no "shebang lint MISSED #!/bin/bash" \
  || ok "shebang lint: catches #!/bin/bash"

printf '#!/bin/sh\necho hi\n' > "$shbdir/sh.sh"
bash "$shb" "$shbdir/sh.sh" >/dev/null 2>&1 \
  && no "shebang lint MISSED #!/bin/sh" \
  || ok "shebang lint: catches #!/bin/sh"

# A trailing flag still isn't the agreed form (and `env bash -e` is unportable anyway).
printf '#!/usr/bin/env bash -e\necho hi\n' > "$shbdir/flag.sh"
bash "$shb" "$shbdir/flag.sh" >/dev/null 2>&1 \
  && no "shebang lint MISSED '#!/usr/bin/env bash -e'" \
  || ok "shebang lint: catches a trailing-flag variant"

# Extension-less scripts must be covered too — that's how fake-opencode is shaped.
printf '#!/bin/bash\necho hi\n' > "$shbdir/noext"
bash "$shb" "$shbdir/noext" >/dev/null 2>&1 \
  && no "shebang lint MISSED an extension-less script" \
  || ok "shebang lint: covers extension-less scripts"

# A file with no shebang at all is not a script — must be ignored, not failed.
printf 'just data\n' > "$shbdir/data.txt"
bash "$shb" "$shbdir/data.txt" >/dev/null 2>&1 \
  && ok "shebang lint: ignores files without a shebang" \
  || no "shebang lint wrongly failed a non-script file"

rm -rf "$shbdir"

# ---------------------------------------------------------------------------
# Evidence layer (collab/log.sh + ask.sh's hooks) — Phase W0.
# This is the data a watcher agent audits INSTEAD of Claude's own summary, so the
# properties below are the whole point: the pair must be complete, the response must
# be verbatim, and a gap must be loud rather than look clean.
# ---------------------------------------------------------------------------
echo
echo "== evidence layer (log.sh) =="
logsh="$repo_root/collab/log.sh"
# run_logged <run_id> -- <ask args...> : ask.sh with logging pinned to one run.
run_logged() {
  local rid="$1"; shift
  : > "$argsfile"
  COLLAB_POLICY="$allow_pol" COLLAB_RUN_ID="$rid" COLLAB_COMMAND=/consult \
    bash "$ask" "$@" >/dev/null 2>&1 || true
}
newrun() { bash "$logsh" new-run /consult; }
entries() { cat "$COLLAB_LOG_DIR/$1/calls.jsonl" 2>/dev/null; }

# A call writes BOTH halves of the pair, keyed by one call_id.
r="$(newrun)"; run_logged "$r" -m openai/gpt-5 "hello"
n_start="$(entries "$r" | jq -rs '[.[]|select(.status=="started")]|length')"
n_done="$(entries "$r"  | jq -rs '[.[]|select(.status=="completed")]|length')"
same_id="$(entries "$r" | jq -rs '[.[]|select(.type=="call").call_id]|unique|length')"
{ [ "$n_start" = 1 ] && [ "$n_done" = 1 ] && [ "$same_id" = 1 ]; } \
  && ok "log: one call = started+completed sharing one call_id" \
  || no "log: expected 1 started + 1 completed with a shared call_id (got $n_start/$n_done/$same_id ids)"

# The response is recorded VERBATIM — a truncated/paraphrased log would let "the
# model only said X" survive contact with the evidence.
r="$(newrun)"; FAKE_OPENCODE_TEXT='multi
line "quoted" \back\ answer' run_logged "$r" -m m/x "q"
got="$(entries "$r" | jq -rs '[.[]|select(.status=="completed").raw_response][0]')"
[ "$got" = 'multi
line "quoted" \back\ answer' ] \
  && ok "log: raw_response is verbatim (newlines, quotes, backslashes survive)" \
  || no "log: raw_response mangled — got: $got"

# ask.sh must record the selection a watcher needs to judge the call.
r="$(newrun)"; run_logged "$r" -m openai/gpt-5 --research "q"
{ [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].model')" = "openai/gpt-5" ] \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].agent')" = "collab-research" ] \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].command')" = "/consult" ]; } \
  && ok "log: records model, agent and command" \
  || no "log: model/agent/command not recorded correctly"

# A failed call must still close its pair — otherwise a crash reads as a clean log.
r="$(newrun)"; FAKE_OPENCODE_EXIT=3 run_logged "$r" -m m/x "boom"
{ [ "$(entries "$r" | jq -rs '[.[]|select(.status=="completed")][0].exit_code')" = 3 ] \
  && bash "$logsh" verify "$r" >/dev/null 2>&1; } \
  && ok "log: a non-zero exit still writes completed (exit_code recorded, integrity ok)" \
  || no "log: failed call left an unpaired started or lost its exit_code"

# The integrity contract: an unpaired started must FAIL, loudly.
r="$(newrun)"
bash "$logsh" started --call-id c-orphan --command /consult --model m/x --agent collab-read >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED a started with no completed (a silent gap would read as clean)" \
  || ok "log: verify fails an unpaired started (exit 7)"

# A rewritten entry must fail (accidental corruption; not a tamper-proofing claim).
# Two cases, because the chain and the self-check cover different lines: editing a
# NON-final entry breaks the chain, while editing the LAST entry breaks nothing in the
# chain (no successor holds its hash) and is caught only by response_hash.
r="$(newrun)"; run_logged "$r" -m m/x "q"; run_logged "$r" -m m/x "q2"
sed -i '2s/canned answer/SOMETHING ELSE/' "$COLLAB_LOG_DIR/$r/calls.jsonl" 2>/dev/null
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED an edited middle entry (prev_hash chain not checked)" \
  || ok "log: verify fails an edited middle entry (prev_hash mismatch)"

r="$(newrun)"; run_logged "$r" -m m/x "q"
sed -i '$s/canned answer/SOMETHING ELSE/' "$COLLAB_LOG_DIR/$r/calls.jsonl" 2>/dev/null
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED an edited LAST entry (the chain cannot cover the tail — response_hash must)" \
  || ok "log: verify fails an edited last entry (response_hash self-check covers the tail)"

# Concurrency is real: /panel fires 2-3 calls at once. Every line must stay valid JSON
# (no torn appends) and turns must be distinct — computing `turn` outside the lock made
# all three claim turn 1.
r="$(newrun)"
for m in a/1 b/2 c/3; do run_logged "$r" -m "$m" "concurrent q" & done; wait
n="$(entries "$r" | wc -l | tr -d ' ')"; valid="$(entries "$r" | jq -s 'length' 2>/dev/null || echo -1)"
turns="$(entries "$r" | jq -rs '[.[]|select(.status=="started").turn]|unique|length')"
{ [ "$n" = 6 ] && [ "$valid" = 6 ] && [ "$turns" = 3 ]; } \
  && ok "log: 3 concurrent calls -> 6 intact JSONL lines with distinct turns" \
  || no "log: concurrent append corrupted (lines=$n valid=$valid distinct turns=$turns)"

# Prompt privacy (W0.6). `full` is the default (the brief Claude wrote is itself audit
# material); `hash` proves the prompt didn't change without revealing it; `off` means
# off — no text AND no digest.
r="$(newrun)"; COLLAB_LOG_PROMPTS=full run_logged "$r" -m m/x "SENTINEL-abc123"
entries "$r" | grep -qF 'SENTINEL-abc123' \
  && ok "log: COLLAB_LOG_PROMPTS=full records the prompt" \
  || no "log: full mode did not record the prompt"
r="$(newrun)"
# shellcheck disable=SC2209 # env-var prefix on a function call, not an assignment
COLLAB_LOG_PROMPTS=hash run_logged "$r" -m m/x "SENTINEL-abc123"
{ ! entries "$r" | grep -qF 'SENTINEL-abc123'; } \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].prompt_hash')" != "null" ] \
  && ok "log: COLLAB_LOG_PROMPTS=hash keeps the digest, not the text" \
  || no "log: hash mode leaked the prompt or dropped the digest"
r="$(newrun)"; COLLAB_LOG_PROMPTS=off run_logged "$r" -m m/x "SENTINEL-abc123"
{ ! entries "$r" | grep -qF 'SENTINEL-abc123'; } \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].prompt_hash')" = "null" ] \
  && ok "log: COLLAB_LOG_PROMPTS=off records neither text nor digest" \
  || no "log: off mode still recorded prompt text or a digest"

# The knobs must work from the CONFIG FILE, not just env — that's the project's
# convention, and env-only would be a trap: a Claude-driven session runs each command
# in a subshell, so `export COLLAB_LOG_PROMPTS=hash` cannot durably hold.
conf="$fakedir/conf.local"; printf 'COLLAB_LOG_PROMPTS=off\n' > "$conf"
r="$(COLLAB_CONF="$conf" bash "$logsh" new-run /consult)"
COLLAB_POLICY="$allow_pol" COLLAB_CONF="$conf" COLLAB_RUN_ID="$r" COLLAB_COMMAND=/consult \
  bash "$ask" -m m/x "SENTINEL-abc123" >/dev/null 2>&1 || true
{ ! entries "$r" | grep -qF 'SENTINEL-abc123'; } \
  && ok "log: COLLAB_LOG_PROMPTS honoured from collab.conf.local (not env-only)" \
  || no "log: config-file COLLAB_LOG_PROMPTS ignored — the documented knob is a lie"

# The off switch, and the token-free paths must stay evidence-free.
before="$(ls "$COLLAB_LOG_DIR" | wc -l | tr -d ' ')"
COLLAB_POLICY="$allow_pol" COLLAB_LOG=off bash "$ask" -m m/x "quiet" >/dev/null 2>&1
[ "$(ls "$COLLAB_LOG_DIR" | wc -l | tr -d ' ')" = "$before" ] \
  && ok "log: COLLAB_LOG=off writes nothing" \
  || no "log: COLLAB_LOG=off still created a run"
COLLAB_POLICY="$allow_pol" bash "$ask" --dry-run -m m/x "dry" >/dev/null 2>&1
[ "$(ls "$COLLAB_LOG_DIR" | wc -l | tr -d ' ')" = "$before" ] \
  && ok "log: --dry-run calls no model and logs nothing" \
  || no "log: --dry-run created a log entry despite calling no model"

# claude-final (W0.5) — without it a watcher can audit dispositions but not the
# summary the developer actually read.
r="$(newrun)"
printf 'the summary the user saw' | COLLAB_RUN_ID="$r" bash "$logsh" final >/dev/null 2>&1
[ "$(entries "$r" | jq -rs '[.[]|select(.type=="claude-final")][0].text')" = "the summary the user saw" ] \
  && ok "log: claude-final records Claude's user-facing answer" \
  || no "log: claude-final entry missing or wrong"

# claude-disposition (W0.8) — must be marked as a CLAIM, and the verdict vocabulary
# is fixed so a report can't invent a flattering one.
r="$(newrun)"
COLLAB_RUN_ID="$r" bash "$logsh" disposition --model m/x --point "p" --verdict Adopt >/dev/null 2>&1
[ "$(entries "$r" | jq -rs '[.[]|select(.type=="claude-disposition")][0].claim')" = "true" ] \
  && ok "log: claude-disposition is flagged claim:true (a claim to audit, not a fact)" \
  || no "log: claude-disposition not flagged as a claim"
COLLAB_RUN_ID="$r" bash "$logsh" disposition --model m/x --point "p" --verdict Maybe >/dev/null 2>&1 \
  && no "log: disposition accepted a bogus verdict 'Maybe'" \
  || ok "log: disposition rejects a verdict outside Adopt|Adapt|Reject|Defer"

# new-run must MINT a run, never hand back an ambient one — that would silently merge
# two workflows into a single audit unit.
r1="$(newrun)"; r2="$(COLLAB_RUN_ID="$r1" bash "$logsh" new-run /panel)"
[ -n "$r2" ] && [ "$r1" != "$r2" ] \
  && ok "log: new-run mints a fresh id even when \$COLLAB_RUN_ID is set" \
  || no "log: new-run returned the ambient run id ($r1 == $r2)"

# Retention (W0.6): an unbounded log dir is an indefinite sensitive-data surface.
oldrun="$COLLAB_LOG_DIR/20200101T000000Z-deadbeef"; mkdir -p "$oldrun"
touch -d "60 days ago" "$oldrun" 2>/dev/null || touch -t 202001010000 "$oldrun" 2>/dev/null
bash "$logsh" prune --days 14 >/dev/null 2>&1
[ ! -d "$oldrun" ] && ok "log: prune removes runs past the retention window" \
                   || no "log: prune left a 60-day-old run in place"

echo
printf 'wrapper + panel + lint + log tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
