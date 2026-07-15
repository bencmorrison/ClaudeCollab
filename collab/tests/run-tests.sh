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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
ask="$repo_root/collab/ask.sh"

# Put the fake opencode first on PATH so `command -v opencode` finds it.
fakedir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
cp "$here/fake-opencode" "$fakedir/opencode"
chmod +x "$fakedir/opencode"
export PATH="$fakedir:$PATH"

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
printf '%s' "$ERR" | grep -q "not one of collab-read|collab-build|plan|build" \
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

echo
printf 'wrapper + panel tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
