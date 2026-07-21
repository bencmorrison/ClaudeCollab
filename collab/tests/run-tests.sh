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
unset COLLAB_CONF COLLAB_MODEL COLLAB_MODELS COLLAB_WATCH_MODEL COLLAB_CONFIRMED
unset COLLAB_TIMEOUT COLLAB_POLICY COLLAB_REQUIRE_HARDENED COLLAB_VERIFY_MODEL
unset COLLAB_LOG COLLAB_LOG_DIR COLLAB_LOG_PROMPTS COLLAB_RUN_ID COLLAB_COMMAND COLLAB_LOG_RETENTION_DAYS
unset FAKE_OPENCODE_ARGS FAKE_OPENCODE_STDIN FAKE_OPENCODE_EXIT FAKE_OPENCODE_TEXT FAKE_OPENCODE_SID

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

pass=0; fail=0; inconclusive=0
ok()  { printf '\033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
inc() { printf '\033[33mINCONCLUSIVE\033[0m %s\n' "$*"; inconclusive=$((inconclusive+1)); }

test_timeout_bin=""
if command -v timeout >/dev/null 2>&1; then test_timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then test_timeout_bin="gtimeout"; fi
run_with_optional_timeout() {
  local seconds="$1"; shift
  if [ -n "$test_timeout_bin" ]; then "$test_timeout_bin" "$seconds" "$@"; else "$@"; fi
}
run_bounded() {
  local seconds="$1"; shift
  [ -n "$test_timeout_bin" ] || return 125
  "$test_timeout_bin" "$seconds" "$@"
}

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
#    No --allow-dirty any more: the write path no longer refuses a dirty tree, so this
#    runs regardless of what state the dev's worktree happens to be in.
run_ask --edit "change a file"
args_has 'collab-build' && ! args_has 'collab-read' && ! args_has 'build' \
  && ok "--edit -> --agent collab-build" \
  || no "--edit did not select collab-build (got: $(tr '\n' ' ' <"$argsfile"))"

# 3b. --research switches to the collab-research agent (web-capable, non-mutating).
#     No worktree guard here: it's a read-only path, which case 3c asserts.
run_ask --research "what changed in X"
args_has 'collab-research' && ! args_has 'collab-read' && ! args_has 'collab-build' \
  && ok "--research -> --agent collab-research" \
  || no "--research did not select collab-research (got: $(tr '\n' ' ' <"$argsfile"))"

# 3c. --research is read-only, so the write path's baseline snapshot must not touch it.
#     Run it with a deliberately dirty tree.
dirty_repo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
( cd "$dirty_repo" && git init -q && echo dirty > uncommitted.txt ) 2>/dev/null
: > "$argsfile"
( cd "$dirty_repo" && COLLAB_POLICY="$allow_pol" bash "$ask" --research "q" >/dev/null 2>&1 ); RC=$?
{ [ "$RC" -ne 6 ] && args_has 'collab-research'; } \
  && ok "--research is unaffected by the write path (dirty tree still runs)" \
  || no "--research was gated on the write path (rc=$RC)"
rm -rf "$dirty_repo"

# 3d. --watch selects the collab-watch oversight agent. (-m is required on this path
#     now — an unpinned watcher is refused; see 3e2.)
COLLAB_LOG_DIR="$repo_root/collab/logs" run_ask --watch -m openai/gpt-5.5 "audit the log"
args_has 'collab-watch' && ! args_has 'collab-read' \
  && ok "--watch -> --agent collab-watch" \
  || no "--watch did not select collab-watch (got: $(tr '\n' ' ' <"$argsfile"))"

# 3e. The watcher must NOT be a Claude model without explicit confirmation: Claude is
#     the party under audit, so a same-family auditor is not the independent check
#     /collab:witness reports itself to be — and the developer can't tell from the report.
for m in anthropic/claude-opus-4-5 some-provider/claude-3; do
  : > "$argsfile"
  COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" bash "$ask" --watch --dry-run -m "$m" "audit" >/dev/null 2>&1; RC=$?
  { [ "$RC" -eq 8 ] && ! [ -s "$argsfile" ]; } \
    && ok "--watch refuses Claude model '$m' (exit 8, never invoked)" \
    || no "--watch ran a Claude watcher '$m' (rc=$RC) — Claude auditing Claude"
done
COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" COLLAB_CONFIRMED=1 bash "$ask" --watch --dry-run -m anthropic/claude-opus-4-5 "audit" >/dev/null 2>&1 \
  && ok "--watch allows a Claude model once COLLAB_CONFIRMED=1 (user's call, not ours)" \
  || no "--watch still refused a Claude model after explicit confirmation"

# 3e2. An UNPINNED watcher model must be refused. This is the hole the Claude-model
#      check had: with no -m and no $COLLAB_WATCH_MODEL/$COLLAB_MODEL, `model` is
#      empty, no -m reaches opencode, opencode uses ITS OWN default — and the check
#      below never fires, because "" matches no pattern. If that default is Claude,
#      Claude audits Claude in silence. (Found by dogfooding /collab:review, 2026-07-15.)
: > "$argsfile"
( unset COLLAB_MODEL COLLAB_WATCH_MODEL
  COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" bash "$ask" --watch --dry-run "audit" >/dev/null 2>&1 ); RC=$?
{ [ "$RC" -eq 8 ] && ! [ -s "$argsfile" ]; } \
  && ok "--watch refuses an UNPINNED model (exit 8) — opencode's own default may be Claude" \
  || no "--watch ran with no model id (rc=$RC) — opencode's default could be Claude, unchecked"

# 3f. $COLLAB_WATCH_MODEL is preferred over the general default, but an explicit -m
#     still wins — the watcher is pinned separately from the model doing the work.
: > "$argsfile"
COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" COLLAB_MODEL=openai/gpt-5.4 COLLAB_WATCH_MODEL=openai/gpt-5.5 \
  bash "$ask" --watch --dry-run "audit" >/dev/null 2>&1
OUT="$(COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" COLLAB_MODEL=openai/gpt-5.4 COLLAB_WATCH_MODEL=openai/gpt-5.5 \
  bash "$ask" --watch --dry-run "audit" 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'gpt-5.5' \
  && ok "--watch prefers \$COLLAB_WATCH_MODEL over \$COLLAB_MODEL" \
  || no "--watch ignored \$COLLAB_WATCH_MODEL (got: $OUT)"
OUT="$(COLLAB_LOG_DIR="$repo_root/collab/logs" COLLAB_POLICY="$allow_pol" COLLAB_WATCH_MODEL=openai/gpt-5.5 \
  bash "$ask" --watch --dry-run -m openai/gpt-5.4 "audit" 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'gpt-5.4' \
  && ok "--watch: an explicit -m beats \$COLLAB_WATCH_MODEL" \
  || no "--watch overrode an explicit -m (got: $OUT)"

# 3g. NO fallback on the watch path. Every other agent degrades to a weaker built-in;
#     this one must hard-fail (exit 5) even WITHOUT COLLAB_REQUIRE_HARDENED, because
#     any weaker agent can read the repo's source and would "audit" that instead of
#     the log — still producing a confident report, just not an audit.
watchdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$watchdir/collab" "$watchdir/.opencode/agent"
cp "$ask" "$watchdir/collab/"; printf 'allow *\n' > "$watchdir/collab/models.policy"
: > "$argsfile"
( cd "$watchdir" && COLLAB_LOG=off bash collab/ask.sh --watch --dry-run -m openai/gpt-5.5 "audit" >/dev/null 2>&1 ); RC=$?
{ [ "$RC" -eq 5 ] && ! [ -s "$argsfile" ]; } \
  && ok "--watch hard-fails (exit 5) when the def is missing — no silent downgrade of oversight" \
  || no "--watch fell back to a weaker agent with the def missing (rc=$RC)"
# ...and the MISSING DEF wins over the model complaint when both are wrong: "reinstall
# the def" is the actionable error; "pick a non-Claude model" sends you chasing the
# wrong thing.
( cd "$watchdir" && COLLAB_LOG=off bash collab/ask.sh --watch --dry-run -m anthropic/claude-opus-4-5 "audit" >/dev/null 2>&1 ); RC=$?
[ "$RC" -eq 5 ] \
  && ok "--watch reports the missing def (5) ahead of the model refusal (8)" \
  || no "--watch reported the model complaint over the missing def (rc=$RC)"
rm -rf "$watchdir"

# 3h. Validate the effective evidence root, with env > config precedence. Prompt
# wording cannot widen collab-watch's mechanical collab/logs/** read scope.
: > "$argsfile"
COLLAB_LOG_DIR="$fakedir/outside-watch-scope" COLLAB_POLICY="$allow_pol" \
  bash "$ask" --watch --dry-run -m openai/gpt-5.5 "audit" >/dev/null 2>&1; RC=$?
{ [ "$RC" -eq 5 ] && ! [ -s "$argsfile" ]; } \
  && ok "--watch rejects an env COLLAB_LOG_DIR outside collab/logs/**" \
  || no "--watch accepted unreadable evidence root from env (rc=$RC)"
watchconf="$fakedir/watch.conf"
printf 'COLLAB_LOG_DIR=%s\n' "$fakedir/outside-from-config" > "$watchconf"
COLLAB_CONF="$watchconf" COLLAB_POLICY="$allow_pol" \
  bash "$ask" --watch --dry-run -m openai/gpt-5.5 "audit" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 5 ] \
  && ok "--watch rejects an outside COLLAB_LOG_DIR from config" \
  || no "--watch ignored configured evidence root (rc=$RC)"
COLLAB_CONF="$watchconf" COLLAB_LOG_DIR="$repo_root/collab/logs/nested" COLLAB_POLICY="$allow_pol" \
  bash "$ask" --watch --dry-run -m openai/gpt-5.5 "audit" >/dev/null 2>&1 \
  && ok "--watch accepts an in-scope env root and env overrides config" \
  || no "--watch log-root env > config precedence is wrong"
# GNU realpath is intentionally unavailable on stock macOS. A failing fixture at the
# front of PATH proves watch validation does not call it, and the spaced suffix proves
# canonicalization does not split paths.
printf '#!/usr/bin/env bash\nexit 99\n' > "$fakedir/realpath"; chmod +x "$fakedir/realpath"
COLLAB_LOG_DIR="$repo_root/collab/logs/path with spaces/../audits" COLLAB_POLICY="$allow_pol" \
  bash "$ask" --watch --dry-run -m openai/gpt-5.5 "audit" >/dev/null 2>&1 \
  && ok "--watch canonicalizes in-scope paths with spaces without realpath" \
  || no "--watch still depends on realpath or mishandles a spaced path"
rm -f "$fakedir/realpath"

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
OUT="$(COLLAB_POLICY="$allow_pol" bash "$tmp_repo2/collab/ask.sh" --edit "q" 2>"$errf2")"; RC=$?
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

# 14e. COLLAB_AGENT_DIR governs the wrapper's def-EXISTENCE (fallback) check. It changes
#      ONLY whether the wrapper falls back; opencode still resolves --agent from its own
#      config. These cases prove the env/config value is consulted instead of the default
#      sibling path, in both directions. (Path-resolution plumbing for a future shared
#      install — PLAN.md "Global install", change B.)
#
# 14e-i. def ABSENT at COLLAB_AGENT_DIR (points at an empty dir) even though the REAL
#        ask.sh has the def at its default sibling location -> must fall back to plan.
#        Proves the default is NOT consulted when the env var is set.
emptyad="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
: > "$argsfile"
COLLAB_AGENT_DIR="$emptyad" COLLAB_LOG=off COLLAB_POLICY="$allow_pol" bash "$ask" "q" >/dev/null 2>&1
{ args_has 'plan' && ! args_has 'collab-read'; } \
  && ok "COLLAB_AGENT_DIR (empty dir) -> real ask.sh falls back to plan (default path ignored)" \
  || no "COLLAB_AGENT_DIR not consulted for the fallback check (got: $(tr '\n' ' ' <"$argsfile"))"
rm -rf "$emptyad"

# 14e-ii. def PRESENT at COLLAB_AGENT_DIR, with a wrapper copy that has NO sibling
#         .opencode -> the env dir makes the otherwise-missing def "present", so NO
#         fallback: collab-read is used. The reverse of 14e-i.
tmp_ad="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$tmp_ad/collab"
cp "$ask" "$tmp_ad/collab/ask.sh"
adir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; : > "$adir/collab-read.md"
: > "$argsfile"
COLLAB_AGENT_DIR="$adir" COLLAB_LOG=off COLLAB_POLICY="$allow_pol" bash "$tmp_ad/collab/ask.sh" "q" >/dev/null 2>&1
{ args_has 'collab-read' && ! args_has 'plan' && ! args_has 'build'; } \
  && ok "COLLAB_AGENT_DIR with the def present -> no fallback (collab-read used)" \
  || no "COLLAB_AGENT_DIR did not satisfy the def check (got: $(tr '\n' ' ' <"$argsfile"))"

# 14e-iii. Same, but COLLAB_AGENT_DIR supplied via collab.conf.local (config path, not
#          env) -> also honored. Proves conf_get feeds the resolution.
adconf="$(mktemp "${TMPDIR:-/tmp}/collab.XXXXXX")"; printf 'COLLAB_AGENT_DIR=%s\n' "$adir" > "$adconf"
: > "$argsfile"
COLLAB_CONF="$adconf" COLLAB_LOG=off COLLAB_POLICY="$allow_pol" bash "$tmp_ad/collab/ask.sh" "q" >/dev/null 2>&1
{ args_has 'collab-read' && ! args_has 'plan' && ! args_has 'build'; } \
  && ok "COLLAB_AGENT_DIR from collab.conf.local -> no fallback (collab-read used)" \
  || no "COLLAB_AGENT_DIR from config not consulted (got: $(tr '\n' ' ' <"$argsfile"))"
rm -f "$adconf"; rm -rf "$tmp_ad" "$adir"

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

# 14d-f. The write path's BASELINE SNAPSHOT (there is no clean-worktree guard any
# more — it was unjustified asymmetry: an Anthropic subagent editing these same files
# gets no such gate, and a delegated model is the same class of actor. Delegating onto
# live uncommitted work is the actual use case). Run the REAL ask.sh with cwd in a temp
# git repo. commit.gpgsign is forced off so no signing prompt fires.
guard_repo="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
( cd "$guard_repo" && git init -q && git config user.email t@t.co && git config user.name t \
  && git config commit.gpgsign false && git commit -q --allow-empty -m init ) 2>/dev/null
if [ -d "$guard_repo/.git" ]; then
  # A DIRTY tree must simply run — this is the case the old guard refused outright.
  ( cd "$guard_repo" && : > untracked.txt && printf 'x\n' > tracked.txt && git add tracked.txt )
  : > "$argsfile"
  ERRG="$(cd "$guard_repo" && COLLAB_POLICY="$allow_pol" COLLAB_LOG=off bash "$ask" --edit -m m/x "q" 2>&1 >/dev/null)"; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-build'; } \
    && ok "write path: a DIRTY worktree runs (no clean-tree refusal)" \
    || no "write path refused a dirty tree (rc=$RCG) — the guard is back (err: $ERRG)"

  # ...and it tells you how to get your work back if the model overwrites it.
  printf '%s' "$ERRG" | grep -q 'git checkout' \
    && ok "write path: prints how to restore clobbered work from the snapshot" \
    || no "write path did not print a recovery instruction on a dirty tree"

  # --allow-dirty is a legacy no-op: old scripts may still pass it, but dirty trees
  # are allowed regardless.
  : > "$argsfile"
  ( cd "$guard_repo" && COLLAB_POLICY="$allow_pol" COLLAB_LOG=off bash "$ask" --edit --allow-dirty -m m/x "q" ) >/dev/null 2>&1; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-build'; } \
    && ok "--allow-dirty accepted as a legacy no-op" \
    || no "--allow-dirty should be a no-op compatibility flag (rc=$RCG)"

  # The read-only path never touched any of this and still must not.
  : > "$argsfile"
  ( cd "$guard_repo" && COLLAB_POLICY="$allow_pol" COLLAB_LOG=off bash "$ask" -m m/x "q" ) >/dev/null 2>&1; RCG=$?
  { [ "$RCG" -eq 0 ] && args_has 'collab-read'; } \
    && ok "read-only path unaffected by the write-path snapshot" \
    || no "read-only path broke (rc=$RCG)"
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
printf '%s' "$ERR" | grep -q "not one of collab-read|collab-build|collab-research|collab-watch|plan|build" \
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
#     overrides both. (What /collab:configure relies on.)
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
# A tier with no pattern is malformed, not a rule, and likewise cannot shadow the
# committed deny. If explicitly selected, malformed policy must be loud and fail closed.
printf 'deny\n' > "$presol/collab/models.policy.local"
errp="$presol/policy.err"
bash "$presol/collab/ask.sh" -m openai/gpt-5.5 "q" >/dev/null 2>"$errp"; RC=$?
[ "$RC" -eq 3 ] \
  && ok "policy: local bare deny cannot override the committed deny policy" \
  || no "malformed local bare deny shadowed the committed policy (rc=$RC)"
COLLAB_POLICY="$presol/collab/models.policy.local" bash "$presol/collab/ask.sh" \
  -m openai/other "q" >/dev/null 2>"$errp"; RC=$?
{ [ "$RC" -eq 3 ] && grep -q 'malformed model policy rule' "$errp"; } \
  && ok "policy: selected malformed active line is reported and fails closed" \
  || no "selected malformed policy silently failed open (rc=$RC)"
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

# 21e. Doctor's evidence display uses the same env > config > default precedence as
# the logger, rather than reporting defaults while log.sh applies file settings.
dcfg="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$dcfg/collab"
cp "$repo_root/collab/doctor.sh" "$repo_root/collab/log.sh" "$dcfg/collab/"
printf 'COLLAB_LOG=off\nCOLLAB_LOG_DIR=/from-config\nCOLLAB_LOG_PROMPTS=hash\nCOLLAB_LOG_RETENTION_DAYS=31\n' > "$dcfg/conf"
dout="$(COLLAB_CONF="$dcfg/conf" run_with_optional_timeout 60 bash "$dcfg/collab/doctor.sh" 2>&1)"
printf '%s' "$dout" | sed -n '/== Evidence layer/,/^$/p' | grep -q 'logging is OFF' \
  && ok "doctor/evidence: COLLAB_LOG is read from the config file" \
  || no "doctor/evidence: ignored config-file COLLAB_LOG"
dout="$(COLLAB_CONF="$dcfg/conf" COLLAB_LOG=on COLLAB_LOG_DIR=/from-env COLLAB_LOG_PROMPTS=off \
  COLLAB_LOG_RETENTION_DAYS=7 run_with_optional_timeout 60 bash "$dcfg/collab/doctor.sh" 2>&1)"
dsec="$(printf '%s' "$dout" | sed -n '/== Evidence layer/,/^$/p')"
{ printf '%s' "$dsec" | grep -q 'prompts=off' && printf '%s' "$dsec" | grep -q 'retention=7d' \
  && printf '%s' "$dsec" | grep -q 'dir=/from-env'; } \
  && ok "doctor/evidence: env overrides config for every logging knob" \
  || no "doctor/evidence: env > config > default precedence drifted: $dsec"
printf 'deny openai/blocked\nallow *\n' > "$dcfg/collab/models.policy"
printf 'deny\n' > "$dcfg/collab/models.policy.local"
dout="$(COLLAB_LOG=off run_with_optional_timeout 60 bash "$dcfg/collab/doctor.sh" 2>&1)"
dsec="$(printf '%s' "$dout" | sed -n '/== Model policy ==/,/^$/p')"
{ printf '%s' "$dsec" | grep -q 'FAIL.*malformed' && printf '%s' "$dsec" | grep -q 'models.policy.local'; } \
  && ok "doctor/policy: malformed active-looking local line is flagged" \
  || no "doctor/policy: malformed local policy was silently ignored: $dsec"
rm -rf "$dcfg"

# 21d. conf_get is byte-identical across ask.sh / panel-models.sh / doctor.sh — the
#      parser is duplicated (standalone by design for this copy-based harness), so
#      guard against silent drift. [review 2026-07-15]
xget() { awk '/^conf_get\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$1"; }
cg_a="$(xget "$repo_root/collab/ask.sh")"; cg_p="$(xget "$repo_root/collab/panel-models.sh")"; cg_d="$(xget "$repo_root/collab/doctor.sh")"
{ [ -n "$cg_a" ] && [ "$cg_a" = "$cg_p" ] && [ "$cg_p" = "$cg_d" ]; } \
  && ok "conf_get identical across ask.sh/panel-models.sh/doctor.sh (no drift)" \
  || no "conf_get copies have DRIFTED — fix all three"

# --- panel-models.sh (the /collab:panel model-set resolver; opencode-free) --------------
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
# (b) CATCHES the order/bounding evasions that dogfooding /collab:review found (2026-07-15):
# a good-looking block in the markdown BODY, and last-match reorderings.
lintdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$lintdir/collab/tests" "$lintdir/.opencode/agent"
cp "$repo_root/collab/tests/check-agent-permissions.sh" "$lintdir/collab/tests/"
# run_lint : 0 if the lint passes the files currently in $lintdir/.opencode/agent.
run_lint() { ( cd "$lintdir" && bash collab/tests/check-agent-permissions.sh >/dev/null 2>&1 ); }
reset_agents() { cp "$repo_root/.opencode/agent/collab-read.md" "$repo_root/.opencode/agent/collab-build.md" "$repo_root/.opencode/agent/collab-research.md" "$repo_root/.opencode/agent/collab-watch.md" "$lintdir/.opencode/agent/"; }

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

# L5. collab-watch with an OPENED read map (`read "*": allow` + secret globs — i.e.
#     made to look exactly like every other agent here) -> must FAIL. This is the
#     realistic regression: it doesn't look like sabotage, it looks like someone
#     making the watcher "consistent" or fixing a read error. And nothing else would
#     catch it — the reports would keep coming, fluent and confident, but the auditor
#     would be reading the SOURCE instead of the LOG.
reset_agents
printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  "*": deny' '  read:' \
  '    "*": allow' '    ".env": deny' '    "*.env": deny' '    "*.key": deny' '    "*.pem": deny' \
  '    "*credentials*": deny' '---' 'body' \
  > "$lintdir/.opencode/agent/collab-watch.md"
run_lint && no "lint MISSED collab-watch's read scope being opened to the whole repo (auditor becomes a consultant)" \
         || ok "lint: catches collab-watch's read scope widened past collab/logs/**"

# L6. collab-watch scoped but with bash re-allowed -> must FAIL. A shell routes around
#     the read scope entirely (`cat src/foo.c`), reducing the scoping to advice.
reset_agents
printf '%s\n' '---' 'description: x' 'mode: all' 'permission:' '  "*": deny' '  bash: allow' '  read:' \
  '    "*": deny' '    "collab/logs/**": allow' '---' 'body' \
  > "$lintdir/.opencode/agent/collab-watch.md"
run_lint && no "lint MISSED bash re-allowed on collab-watch (read scope bypassable via shell)" \
         || ok "lint: catches bash re-allowed on collab-watch"

# L7. Every intended secret glob is guarded from one canonical set in the lint.
reset_agents
grep -v '"\*\*/\.gnupg/\*\*": deny' "$repo_root/.opencode/agent/collab-read.md" > "$lintdir/.opencode/agent/collab-read.md"
run_lint && no "lint MISSED a removed secret glob from the canonical set" \
         || ok "lint: guards the full canonical secret-glob set"
rm -rf "$lintdir"

# --- doctor.sh "Agent guide" meta-tests ----------------------------------------
# doctor.sh's CLAUDE.md check is the only thing standing between "the anti-bias
# guardrails are in CLAUDE.md" and "they quietly aren't". These tests RUN it against
# fixture guides and assert on its verdict.
#
# The first version of this block grep'd doctor.sh for the eight guardrail strings —
# i.e. it asserted that doctor.sh contains the literals that doctor.sh's own heredoc
# contains. It passed with the check neutered (`bad …` -> `pass "neutered"`), which is
# the whole point of a lint meta-test defeated. Per the note under check-shebangs
# below: a lint nobody proved can fail is decoration. Assert BEHAVIOUR, not text.
#
# Two hazards shape the fixture, both load-bearing:
#   1. doctor.sh RUNS THIS SUITE (its "ask.sh unit suite" check). A fixture carrying
#      collab/tests/ would recurse: tests -> doctor -> tests -> ... The fixture omits
#      collab/tests/ so that check just fails, harmlessly, without re-entering.
#   2. doctor.sh pins repo_root to ITS OWN location and cds there, so it cannot be
#      aimed at a fixture from outside — the copy under test must live IN the fixture.
# Other checks fail in a bare fixture, so the exit code is not assertable. We assert on
# the Agent-guide section instead, keying on the FAIL/PASS prefix: `FAIL` is printed
# ONLY by doctor's bad(), which is also the only thing that sets fail=1. So asserting
# the FAIL line is equivalent to asserting the check contributes a non-zero exit — and
# it catches bad()->warn(), an unreachable branch, and a broken loop, which the old
# text-grep could not.
# These need the ClaudeCollab repo's OWN CLAUDE.md/AGENTS.md as source material — and
# run-tests.sh SHIPS IN THE PAYLOAD, with doctor.sh running it, so in an installed
# project neither file exists. That is the same trap the check under test exists to
# fix (payload code assuming it runs in the ClaudeCollab repo), and it bites here in a
# nastier way: a fixture built by `grep -v` from a MISSING file is empty, doctor FAILs
# on the empty file, and the assertion goes green having proved nothing. A false pass
# is worse than the false failure beside it. Gate on the source files, like doctor does.
if [ ! -f "$repo_root/CLAUDE.md" ] || [ ! -f "$repo_root/AGENTS.md" ]; then
  ok "doctor/guide meta-tests (skipped: no CLAUDE.md/AGENTS.md — not the ClaudeCollab repo)"
else
docdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
mkdir -p "$docdir/collab"
cp "$repo_root/collab/doctor.sh" "$docdir/collab/doctor.sh"
printf '%s\n' '# ClaudeCollab — agent guide' 'shared source of truth' > "$docdir/AGENTS.md"

# Print doctor's "Agent guide" section only. Colour codes survive; we grep plain words.
guide_section() { ( cd "$docdir" && run_with_optional_timeout 60 bash collab/doctor.sh 2>&1 ) | sed -n '/== Agent guide ==/,/^$/p'; }

# D1. The real CLAUDE.md must PASS — if the check false-positives on the shipping
#     file, every later assertion here is meaningless and doctor cries wolf.
cp "$repo_root/CLAUDE.md" "$docdir/CLAUDE.md"
sec="$(guide_section)"
{ printf '%s' "$sec" | grep -q 'PASS' && ! printf '%s' "$sec" | grep -q 'FAIL'; } \
  && ok "doctor/guide: the real CLAUDE.md passes" \
  || no "doctor/guide: REJECTS the real CLAUDE.md (false positive): $sec"

# D2. A guardrail dropped from CLAUDE.md must FAIL, and must name the one that went
#     missing. This is the drift the check exists for: an edit that quietly removes the
#     Bias Audit leaves Claude with no instruction to run one. Note the pattern set is
#     ONLY rules unique to CLAUDE.md — the parity/vendor/provenance rules live in
#     AGENTS.md and are read via the @import, so CLAUDE.md must not restate them and
#     doctor must not demand it (that would mandate the fork D7 exists to catch).
grep -v 'Prefer evidence over intuition' "$repo_root/CLAUDE.md" > "$docdir/CLAUDE.md"
sec="$(guide_section)"
{ printf '%s' "$sec" | grep -q 'FAIL' && printf '%s' "$sec" | grep -q 'Prefer evidence over intuition'; } \
  && ok "doctor/guide: catches a guardrail dropped from CLAUDE.md, and names it" \
  || no "doctor/guide: MISSED a dropped guardrail (drift goes unreported): $sec"

# D3. Losing the AGENTS.md top-reference must FAIL: the @import is what makes CLAUDE.md
#     a pointer rather than a fork, so without it Claude never reads the shared guide.
{ echo '# Claude notes'; grep -v '^@AGENTS.md' "$repo_root/CLAUDE.md"; } > "$docdir/CLAUDE.md"
sec="$(guide_section)"
printf '%s' "$sec" | grep -q 'FAIL' \
  && ok "doctor/guide: catches CLAUDE.md not referencing AGENTS.md up top" \
  || no "doctor/guide: MISSED a CLAUDE.md that never points at AGENTS.md: $sec"

# D4. A symlinked CLAUDE.md must FAIL. This was the OLD invariant (CLAUDE.md -> AGENTS.md);
#     it is now wrong, and a stale symlink left by an old checkout must be reported, not
#     silently accepted — under it Claude would read AGENTS.md and get NO Claude-specific
#     bias checks at all, which is the failure this whole section exists to prevent.
rm -f "$docdir/CLAUDE.md"; ln -s AGENTS.md "$docdir/CLAUDE.md"
sec="$(guide_section)"
printf '%s' "$sec" | grep -q 'FAIL' \
  && ok "doctor/guide: catches a stale CLAUDE.md -> AGENTS.md symlink" \
  || no "doctor/guide: ACCEPTED a symlinked CLAUDE.md (Claude gets no bias checks): $sec"
rm -f "$docdir/CLAUDE.md"

# D7. THE FORK. A CLAUDE.md carrying the whole of AGENTS.md inline must FAIL. This is
#     the case the guardrail greps CANNOT catch — a fork passes every pattern, because
#     the patterns are present; they're just surrounded by a copy of the shared guide.
#     The old symlink made this impossible by construction (nothing drifts from itself);
#     the ceiling only makes it loud. Without this test the ceiling is a magic number
#     nobody proved fires.
{ cat "$repo_root/CLAUDE.md"; cat "$repo_root/AGENTS.md"; } > "$docdir/CLAUDE.md"
sec="$(guide_section)"
{ printf '%s' "$sec" | grep -q 'FAIL' && printf '%s' "$sec" | grep -q 'fork of AGENTS.md\|ceiling'; } \
  && ok "doctor/guide: catches CLAUDE.md forking AGENTS.md inline (greps alone can't)" \
  || no "doctor/guide: ACCEPTED a CLAUDE.md with AGENTS.md copied into it: $sec"

# D8. The ceiling must not fire on the real file, with room to add a Claude-only rule.
#     A ceiling that bites honest edits gets raised until it means nothing.
cp "$repo_root/CLAUDE.md" "$docdir/CLAUDE.md"
real_lines="$(wc -l < "$repo_root/CLAUDE.md")"
[ "$real_lines" -le 40 ] \
  && ok "doctor/guide: real CLAUDE.md is ${real_lines} lines — well inside the 60 ceiling" \
  || no "doctor/guide: real CLAUDE.md is ${real_lines} lines — near the 60 ceiling; it is drifting toward a fork"

# D5. THE INSTALLED-PROJECT REGRESSION. doctor.sh ships in the payload but CLAUDE.md /
#     AGENTS.md do not, so in a user's project CLAUDE.md is THEIR file about THEIR
#     project. Policing it hard-failed doctor for every user who ran the documented
#     preflight: a fresh install + an ordinary CLAUDE.md exited 1 with nine FAILs telling
#     them to restructure their guide around our internal conventions. The manifest is
#     the discriminator. This asserts the section does not run at all in an install.
printf '# My Project\n\nRun tests with npm test.\n' > "$docdir/CLAUDE.md"
printf 'collab/doctor.sh\n' > "$docdir/collab/.install-manifest"
sec="$(guide_section)"
[ -z "$sec" ] \
  && ok "doctor/guide: silent in an installed project (user's CLAUDE.md is not ours to police)" \
  || no "doctor/guide: POLICES the user's own CLAUDE.md in an install (hard-fails their preflight): $sec"
rm -f "$docdir/collab/.install-manifest"

# D6. No AGENTS.md => not the ClaudeCollab repo => nothing to point at, so stay silent
#     rather than demand a reference to a file that does not exist. (The pre-fix check
#     told installed users to `ln -s AGENTS.md CLAUDE.md` — a file they don't have.)
rm -f "$docdir/AGENTS.md"
sec="$(guide_section)"
[ -z "$sec" ] \
  && ok "doctor/guide: silent when there is no AGENTS.md to reference" \
  || no "doctor/guide: demands an AGENTS.md reference where no AGENTS.md exists: $sec"
rm -rf "$docdir"
fi

# Doctor --full must not turn a runtime probe's explicit inconclusive exit into PASS.
incdoc="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$incdoc/collab"
cp "$repo_root/collab/doctor.sh" "$incdoc/collab/doctor.sh"
for role in read build research watch; do
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--static" ] && exit 0\nexit 6\n' > "$incdoc/collab/verify-collab-$role.sh"
done
iout="$(run_with_optional_timeout 60 bash "$incdoc/collab/doctor.sh" --full 2>&1)"
isec="$(printf '%s' "$iout" | sed -n '/== Agent permission proof (runtime, --full) ==/,/^$/p')"
{ [ "$(printf '%s' "$isec" | grep -c 'INCONCLUSIVE')" -eq 4 ] && ! printf '%s' "$isec" | grep -q 'PASS'; } \
  && ok "doctor/full: exit 6 is reported INCONCLUSIVE, never PASS" \
  || no "doctor/full: inconclusive runtime probes were misreported: $isec"
rm -rf "$incdoc"

# A hard runtime contradiction is a required doctor failure, not a warning.
harddoc="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$harddoc/collab"
cp "$repo_root/collab/doctor.sh" "$harddoc/collab/doctor.sh"
for role in read build research watch; do
  if [ "$role" = read ]; then vrc=1; else vrc=6; fi
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--static" ] && exit 0\nexit %s\n' "$vrc" > "$harddoc/collab/verify-collab-$role.sh"
done
houtf="$harddoc/out"; run_with_optional_timeout 60 bash "$harddoc/collab/doctor.sh" --full > "$houtf" 2>&1; hrc=$?
hsec="$(sed -n '/== Agent permission proof (runtime, --full) ==/,/^$/p' "$houtf")"
{ [ "$hrc" -ne 0 ] && printf '%s' "$hsec" | grep -q 'FAIL.*collab-read runtime verification'; } \
  && ok "doctor/full: exit 1 is a hard FAIL and sets doctor non-zero" \
  || no "doctor/full: hard runtime contradiction was downgraded (rc=$hrc): $hsec"
rm -rf "$harddoc"

# --- doctor.sh GLOBAL-INSTALL awareness (Slice D1) -----------------------------
# A --global install lays the agent defs into opencode's global agent dir and the
# commands into <CLAUDE_DIR>/commands/collab — NOT the repo-relative .opencode/agent
# and .claude/commands paths. Before D1, doctor false-FAILed "MISSING" on every def
# and command of a healthy global install, the source lint failed the same way, and the
# wrapper-unit check ran run-tests.sh (a repo-development suite with repo-only fixtures)
# and false-FAILed too — the exact "your install is broken" cry-wolf this repo kills. Do
# a REAL sandboxed global install and run the INSTALLED doctor, asserting the fixed
# sections are healthy AND the whole run exits 0 with no FAIL line.
#
# No recursion guard is needed: in global mode doctor SKIPS run-tests.sh (this suite) with
# a neutral note, and its installer-smoke check is gated on install.sh, which a global
# install does not place — so the installed global doctor runs no nested test suite at all.
# Gated on install.sh (only in the ClaudeCollab checkout; absent in an installed project).
if [ -f "$repo_root/install.sh" ]; then
  gdoc="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; mkdir -p "$gdoc/.config"
  # Run the installed doctor in a SANITIZED environment mirroring a real end-user shell:
  #   - strip $fakedir from PATH so doctor doesn't find THIS harness's fake `opencode`
  #     (which would make the resolved-config proof run against the stub and false-FAIL —
  #     an artifact of the test rig, not of doctor).
  #   - clear the COLLAB_* vars this suite exports (COLLAB_LOG_DIR etc.) so doctor reads
  #     the INSTALLED conf.local, not the rig's logging dir.
  gclean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$fakedir" | paste -sd ':' -)"
  if HOME="$gdoc" XDG_CONFIG_HOME="$gdoc/.config" bash "$repo_root/install.sh" --global >/dev/null 2>&1; then
    gout="$(PATH="$gclean_path" HOME="$gdoc" XDG_CONFIG_HOME="$gdoc/.config" \
            COLLAB_LOG_DIR='' COLLAB_LOG='' COLLAB_CONF='' COLLAB_POLICY='' COLLAB_MODEL='' COLLAB_MODELS='' COLLAB_AGENT_DIR='' \
            run_with_optional_timeout 120 bash "$gdoc/.claude/collab/doctor.sh" 2>&1)"; grc=$?
    gagents="$(printf '%s\n' "$gout" | sed -n '/== Agent definitions ==/,/^$/p')"
    gcmds="$(printf '%s\n' "$gout" | sed -n '/== Slash commands ==/,/^$/p')"
    glint="$(printf '%s\n' "$gout" | sed -n '/== Agent permission invariants (source lint) ==/,/^$/p')"
    { [ "$(printf '%s' "$gagents" | grep -c 'present and ours')" -eq 4 ] && ! printf '%s' "$gagents" | grep -qE 'MISSING|did NOT install'; } \
      && ok "doctor/global: all four agent defs found in the global agent dir (no false MISSING)" \
      || no "doctor/global: agent-def check false-fails in a global install: $gagents"
    { printf '%s' "$gcmds" | grep -q 'all 9 ClaudeCollab slash commands present and ours' && ! printf '%s' "$gcmds" | grep -q 'MISSING'; } \
      && ok "doctor/global: all nine slash commands found under commands/collab (no false MISSING)" \
      || no "doctor/global: slash-command check false-fails in a global install: $gcmds"
    { printf '%s' "$glint" | grep -q 'PASS' && ! printf '%s' "$glint" | grep -q 'FAIL'; } \
      && ok "doctor/global: source lint passes against the global agent dir" \
      || no "doctor/global: source lint false-fails in a global install: $glint"
    printf '%s' "$gout" | grep -q '== Agent guide ==' \
      && no "doctor/global: polices the user's own CLAUDE.md in a global install (out of scope)" \
      || ok "doctor/global: Agent-guide section stays silent (global = installed, CLAUDE.md is the user's)"
    printf '%s' "$gout" | grep -q 'wrapper unit suite skipped in a global install' \
      && ok "doctor/global: wrapper unit suite is skipped with a neutral note (repo-only fixtures)" \
      || no "doctor/global: wrapper unit suite was not skipped in a global install: $(printf '%s' "$gout" | sed -n '/== Wrapper unit tests ==/,/^$/p')"
    # The headline property: with opencode available, a CLEAN global install must not cry
    # wolf — exit 0, no FAIL. In a credential-free/opencode-free CI, opencode is legitimately
    # absent, so doctor CORRECTLY FAILs on that missing prerequisite (a true fail, not a
    # global-layout false-fail) — the D1 property is already covered by the three per-section
    # assertions above, which need no opencode. So only assert the exit-0 headline where
    # opencode actually exists; otherwise assert no NON-opencode FAIL slipped in.
    # Gate on opencode as DOCTOR sees it — the SANITIZED gclean_path, not the suite's own
    # PATH. This suite puts a FAKE `opencode` on PATH that gclean_path strips, so an
    # unqualified `command -v opencode` reports present on an opencode-free CI runner and
    # wrongly takes the exit-0 branch while doctor (no opencode) correctly FAILs.
    if PATH="$gclean_path" command -v opencode >/dev/null 2>&1; then
      { [ "$grc" -eq 0 ] && ! printf '%s' "$gout" | grep -q 'FAIL'; } \
        && ok "doctor/global: a clean global install exits 0 with zero FAIL lines" \
        || no "doctor/global: clean global install did not exit clean (rc=$grc): $(printf '%s' "$gout" | grep 'FAIL' | head -3)"
    else
      # Exclude the derived "doctor: PROBLEMS — fix the FAIL line(s)" SUMMARY (it contains the
      # word FAIL but is not a per-check failure); assert no per-check FAIL other than opencode.
      { ! printf '%s' "$gout" | grep 'FAIL' | grep -v 'PROBLEMS' | grep -qvi 'opencode'; } \
        && ok "doctor/global: opencode-free env — only the true opencode-absent FAIL, no global-layout false-fail" \
        || no "doctor/global: an unexpected non-opencode FAIL in a global install: $(printf '%s' "$gout" | grep 'FAIL' | grep -v 'PROBLEMS' | grep -vi 'opencode' | head -3)"
    fi
  else
    no "doctor/global: install.sh --global failed in the meta-test sandbox"
  fi
  rm -rf "$gdoc"
fi

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

# --- check-shellcheck.sh meta-tests --------------------------------------------
# Prove the lint accepts a clean script, catches a real warning-level finding, and
# SKIPS cleanly when shellcheck is absent — so CI's macOS job and shellcheck-less devs
# never false-fail. The accept/catch cases need shellcheck; the skip case never does.
scc="$repo_root/collab/tests/check-shellcheck.sh"
sccdir="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"

# Skip-when-absent: give the child an empty PATH so shellcheck is genuinely absent,
# then assert a clean exit + the skip note. Stripping shellcheck's dir from PATH is
# UNRELIABLE on usrmerge Linux (where /bin and /usr/bin are the same directory, so
# removing one leaves shellcheck reachable via the other — which false-passed locally
# on macOS, where the dirs are separate, and failed on the Linux CI runner).
# check-shellcheck.sh runs no external command before its skip-and-exit, so an empty
# PATH is safe; bash is invoked by its absolute path so the child still starts.
scc_bash="$(command -v bash)"
scc_out="$(PATH=/nonexistent "$scc_bash" "$scc" "$sccdir/none.sh" 2>&1)"; scc_rc=$?
{ [ "$scc_rc" -eq 0 ] && printf '%s' "$scc_out" | grep -qi 'not installed'; } \
  && ok "shellcheck lint: skips cleanly (exit 0 + note) when shellcheck is absent" \
  || no "shellcheck lint did not skip cleanly without shellcheck (rc=$scc_rc): $scc_out"

if command -v shellcheck >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\necho hi\n' > "$sccdir/good.sh"
  bash "$scc" "$sccdir/good.sh" >/dev/null 2>&1 \
    && ok "shellcheck lint: accepts a clean script" \
    || no "shellcheck lint rejects a clean script (false positive)"
  # `echo $(ls)` is SC2046 (word splitting) — a stable warning-level finding.
  printf '#!/usr/bin/env bash\necho $(ls)\n' > "$sccdir/bad.sh"
  bash "$scc" "$sccdir/bad.sh" >/dev/null 2>&1 \
    && no "shellcheck lint MISSED a warning-level issue (SC2046)" \
    || ok "shellcheck lint: catches a warning-level issue (SC2046)"
else
  ok "shellcheck lint: accept/catch cases skipped (shellcheck not installed here)"
fi

rm -rf "$sccdir"

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
  COLLAB_POLICY="$allow_pol" COLLAB_RUN_ID="$rid" COLLAB_COMMAND=/collab:consult \
    bash "$ask" "$@" >/dev/null 2>&1 || true
}
newrun() { bash "$logsh" new-run /collab:consult; }
entries() { cat "$COLLAB_LOG_DIR/$1/calls.jsonl" 2>/dev/null; }

# A call writes exactly one complete lifecycle, keyed by one call_id.
r="$(newrun)"; run_logged "$r" -m openai/gpt-5 "hello"
n_expected="$(entries "$r" | jq -rs '[.[]|select(.type=="expected-call")]|length')"
n_start="$(entries "$r" | jq -rs '[.[]|select(.status=="started")]|length')"
n_done="$(entries "$r"  | jq -rs '[.[]|select(.status=="completed")]|length')"
same_id="$(entries "$r" | jq -rs '[.[]|select(.type=="call").call_id]|unique|length')"
{ [ "$n_expected" = 1 ] && [ "$n_start" = 1 ] && [ "$n_done" = 1 ] && [ "$same_id" = 1 ] \
  && bash "$logsh" verify "$r" >/dev/null 2>&1; } \
  && ok "log: one call = exactly one expected+started+completed lifecycle that verifies" \
  || no "log: expected one intact lifecycle (got $n_expected/$n_start/$n_done/$same_id ids)"

# The response is recorded VERBATIM — a truncated/paraphrased log would let "the
# model only said X" survive contact with the evidence.
r="$(newrun)"; FAKE_OPENCODE_TEXT='multi
line "quoted" \back\ answer' run_logged "$r" -m m/x "q"
got="$(entries "$r" | jq -rs '[.[]|select(.status=="completed").raw_response][0]')"
[ "$got" = 'multi
line "quoted" \back\ answer' ] \
  && ok "log: raw_response is verbatim (newlines, quotes, backslashes survive)" \
  || no "log: raw_response mangled — got: $got"

# Byte-exact, including trailing newlines. `$(cat f)` strips them, which would make
# "verbatim, untruncated" false AND hash the already-truncated value — so verify would
# cheerfully confirm a copy it had itself lost bytes from.
r="$(newrun)"; FAKE_OPENCODE_TEXT='trailing newlines matter

' run_logged "$r" -m m/x "q"
# Compare the JSON-ENCODED value, not a $(...) capture — command substitution strips
# trailing newlines, so capturing the field to compare it would silently destroy the
# exact bytes under test and the assertion would pass no matter what.
got="$(entries "$r" | jq -rs '[.[]|select(.status=="completed").raw_response][0]|@json')"
[ "$got" = '"trailing newlines matter\n\n\n"' ] \
  && ok "log: raw_response keeps trailing newlines (byte-exact, not \$(cat)-stripped)" \
  || no "log: trailing bytes lost from raw_response — 'untruncated' is not true (got: $got)"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && ok "log: verify agrees with the byte-exact writer (hashes the same bytes)" \
  || no "log: verify disagrees with its own writer on trailing bytes"

# Logging must NEVER fail the call it records: a broken log write costs the entry,
# never the answer. A durable expected-call remains even when temp initialization fails.
#
# A broken temp dir is induced with a stub on PATH, NOT with TMPDIR=/nonexistent.
# BSD mktemp (stock macOS) IGNORES TMPDIR for the bare invocation ask.sh makes,
# using Darwin's per-user dir instead — probed on the runner, where
# `TMPDIR=/nonexistent-dir-for-tmp mktemp` exits 0 and returns /var/folders/…/T/….
# So the old fixture induced NOTHING on macOS: the rc=0 assertion below went green
# having proven nothing, and only the verify assertion going red revealed it. Same
# class as the doctor/guide tests that passed for the wrong reason (PLAN.md Ph3).
#
# The stub must fail ONLY the TMPDIR-dependent invocations (no explicit template)
# and delegate the rest — which is precisely what GNU mktemp does under a bogus
# TMPDIR, since an explicit template ignores it. That distinction is load-bearing,
# not incidental: log.sh writes `expected-call` via `mktemp "$rd/.entry.XXXXXX"`
# under the RUN DIR so it survives exactly this failure, and that surviving entry
# is the only thing that makes the gap visible to verify. A blanket-failing stub
# destroys it, and verify then correctly reports a clean single-call run — which is
# the false-clean this test exists to forbid.
initrun="$(newrun)"
real_mktemp="$(command -v mktemp)"
cat > "$fakedir/mktemp" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in -*) ;; *) exec "$real_mktemp" "\$@" ;; esac; done
exit 1
STUB
chmod +x "$fakedir/mktemp"
out="$(COLLAB_POLICY="$allow_pol" COLLAB_RUN_ID="$initrun" COLLAB_COMMAND=/collab:consult \
        bash "$ask" -m m/x "q" 2>/dev/null)"; rc=$?
rm -f "$fakedir/mktemp"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'canned answer'; } \
  && ok "log: a failing log write does not fail the model call (answer still returned, rc=0)" \
  || no "log: broken logging broke the call it exists to record (rc=$rc)"
run_logged "$initrun" -m m/x "second call succeeds"
bash "$logsh" verify "$initrun" >/dev/null 2>&1 \
  && no "log: verify PASSED a multi-call run whose first call failed capture initialization" \
  || ok "log: expected-call exposes initialization failure in a multi-call run"

# Response tee failure is distinct from initialization failure: completed is present,
# but capture_state=failed must make integrity fail rather than treating empty as valid.
r="$(newrun)"
printf '#!/usr/bin/env bash\n/bin/cat\nexit 1\n' > "$fakedir/tee"; chmod +x "$fakedir/tee"
run_logged "$r" -m m/x "capture fails"
rm -f "$fakedir/tee"
[ "$(entries "$r" | jq -rs '[.[]|select(.status=="completed")][0].capture_state')" = "failed" ] \
  && ! bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && ok "log: response-capture failure is durable and cannot verify clean" \
  || no "log: response-capture failure was lost or verified clean"

# THE call with no model pinned must still log. log.sh parsed args with ${2:?}, which
# aborts on an EMPTY value — and ask.sh legitimately passes `--model ''` when nothing is
# pinned (opencode then uses its own default). ask.sh swallows log.sh's stderr, so the
# entire evidence layer silently recorded NOTHING for any user without a configured
# default model. Every other case here passes -m, which is exactly why nothing caught it.
r="$(newrun)"
( unset COLLAB_MODEL
  COLLAB_POLICY="$allow_pol" COLLAB_RUN_ID="$r" COLLAB_COMMAND=/collab:consult \
    bash "$ask" "no model pinned" >/dev/null 2>&1 || true )
n="$(entries "$r" | jq -rs 'length' 2>/dev/null || echo 0)"
n_expected="$(entries "$r" | jq -rs '[.[]|select(.type=="expected-call")]|length' 2>/dev/null || echo 0)"
n_start="$(entries "$r" | jq -rs '[.[]|select(.status=="started")]|length' 2>/dev/null || echo 0)"
n_done="$(entries "$r" | jq -rs '[.[]|select(.status=="completed")]|length' 2>/dev/null || echo 0)"
{ [ "$n_expected" = 1 ] && [ "$n_start" = 1 ] && [ "$n_done" = 1 ] \
  && bash "$logsh" verify "$r" >/dev/null 2>&1; } \
  && ok "log: a call with NO -m writes exactly one complete lifecycle that verifies" \
  || no "log: unpinned model lifecycle is incomplete ($n entries; $n_expected/$n_start/$n_done)"

# ask.sh must record the selection a watcher needs to judge the call.
r="$(newrun)"; run_logged "$r" -m openai/gpt-5 --research "q"
{ [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].model')" = "openai/gpt-5" ] \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].agent')" = "collab-research" ] \
  && [ "$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].command')" = "/collab:consult" ]; } \
  && ok "log: records model, agent and command" \
  || no "log: model/agent/command not recorded correctly"

# A failed call must still close its pair — otherwise a crash reads as a clean log.
r="$(newrun)"; FAKE_OPENCODE_EXIT=3 run_logged "$r" -m m/x "boom"
{ [ "$(entries "$r" | jq -rs '[.[]|select(.status=="completed")][0].exit_code')" = 3 ] \
  && bash "$logsh" verify "$r" >/dev/null 2>&1; } \
  && ok "log: a non-zero exit still writes completed (exit_code recorded, integrity ok)" \
  || no "log: failed call left an unpaired started or lost its exit_code"

# The integrity contract, BOTH directions. A started with no completed is the obvious
# gap; a completed with no started is the same silent loss wearing a disguise (the
# prompt and turn are gone) and a one-way check reports "all paired" over it.
r="$(newrun)"
COLLAB_RUN_ID="$r" bash "$logsh" expect --call-id c-orphan --command /collab:consult --model m/x --agent collab-read >/dev/null 2>&1
COLLAB_RUN_ID="$r" bash "$logsh" started --call-id c-orphan --command /collab:consult --model m/x --agent collab-read >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED a started with no completed (a silent gap would read as clean)" \
  || ok "log: verify fails an unpaired started (exit 7)"

r="$(newrun)"; printf 'an answer' > "$fakedir/resp.txt"
COLLAB_RUN_ID="$r" bash "$logsh" expect --call-id c-lonely --command /collab:consult --model m/x --agent collab-read >/dev/null 2>&1
COLLAB_RUN_ID="$r" bash "$logsh" completed --call-id c-lonely --exit 0 --model m/x \
  --agent collab-read --capture-state complete --response-file "$fakedir/resp.txt" >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED a completed with no started (the prompt vanished and it reported 'all paired')" \
  || ok "log: verify fails an unpaired completed (the lost prompt is a gap too)"

# Set membership is insufficient: duplicate starts or completions must fail exact
# cardinality even though every call_id appears on both sides.
r="$(newrun)"; run_logged "$r" -m m/x "q"
cid="$(entries "$r" | jq -rs '[.[]|select(.type=="call")][0].call_id')"
COLLAB_RUN_ID="$r" bash "$logsh" started --call-id "$cid" --command /collab:consult --model m/x --agent collab-read >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED duplicate started cardinality" \
  || ok "log: verify requires exactly one started entry per call_id"
r="$(newrun)"; run_logged "$r" -m m/x "q"
cid="$(entries "$r" | jq -rs '[.[]|select(.type=="call")][0].call_id')"
COLLAB_RUN_ID="$r" bash "$logsh" completed --call-id "$cid" --exit 0 --command /collab:consult \
  --model m/x --agent collab-read --capture-state complete --response-file "$fakedir/resp.txt" >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED duplicate completed cardinality" \
  || ok "log: verify requires exactly one completed entry per call_id"

# Malformed IDs can be internally hash-consistent, so the structural check must not
# count them as non-vacuous evidence. Rebuild both self-hashes and the chain after
# mutation to prove rejection is about call_id validity rather than stale digests.
rehash_log() {
  local file="$1" source output
  local prev="" line payload hash final
  source="$file.unhashed"; output="$file.rehashed"
  mv "$file" "$source"; : > "$output"
  while IFS= read -r line; do
    payload="$(printf '%s' "$line" | jq -cS --arg prev "$prev" 'del(.entry_hash) | .prev_hash=$prev')"
    hash="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
    final="$(printf '%s' "$payload" | jq -c --arg hash "$hash" '. + {entry_hash:$hash}')"
    printf '%s\n' "$final" >> "$output"
    prev="$(printf '%s' "$final" | sha256sum | awk '{print $1}')"
  done < "$source"
  mv "$output" "$file"; rm -f "$source"
}

for malformed_id in null empty; do
  r="$(newrun)"; run_logged "$r" -m m/x "q"
  logfile="$COLLAB_LOG_DIR/$r/calls.jsonl"
  if [ "$malformed_id" = null ]; then
    jq -c 'if .type=="expected-call" or .type=="call" then .call_id=null else . end' "$logfile" > "$logfile.tmp"
  else
    jq -c 'if .type=="expected-call" or .type=="call" then .call_id="" else . end' "$logfile" > "$logfile.tmp"
  fi
  mv "$logfile.tmp" "$logfile"; rehash_log "$logfile"
  bash "$logsh" verify "$r" >/dev/null 2>&1 \
    && no "log: verify PASSED a self-consistent $malformed_id call_id lifecycle" \
    || ok "log: verify rejects self-consistent $malformed_id expected-call IDs"
done

r="$(newrun)"; run_logged "$r" -m m/x "q1"; run_logged "$r" -m m/x "q2"
logfile="$COLLAB_LOG_DIR/$r/calls.jsonl"
cid="$(jq -rs '[.[]|select(.type=="expected-call")][0].call_id' "$logfile")"
jq -c --arg cid "$cid" 'if .type=="expected-call" or .type=="call" then .call_id=$cid else . end' \
  "$logfile" > "$logfile.tmp"
mv "$logfile.tmp" "$logfile"; rehash_log "$logfile"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED self-consistent duplicate expected-call IDs" \
  || ok "log: verify rejects self-consistent duplicate expected-call IDs"

# A rewritten entry must fail (accidental corruption; not a tamper-proofing claim).
# Two cases, because the chain and the self-check cover different lines: editing a
# NON-final entry breaks the chain, while editing the LAST entry breaks nothing in the
# chain (no successor holds its hash) and is caught only by response_hash.
# NB: `sed -i` is GNU-only (BSD/macOS sed needs an argument), so rewrite via a temp
# file — the suite has to pass on macOS too.
rewrite_line() {  # rewrite_line <file> <line-no|$> <old> <new>
  awk -v n="$2" -v o="$3" -v w="$4" '{ if (NR==n || (n=="$" && NR==c)) sub(o,w); print }' \
      c="$(wc -l < "$1")" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
r="$(newrun)"; run_logged "$r" -m m/x "q"; run_logged "$r" -m m/x "q2"
rewrite_line "$COLLAB_LOG_DIR/$r/calls.jsonl" 3 "canned answer" "SOMETHING ELSE"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED an edited middle entry (prev_hash chain not checked)" \
  || ok "log: verify fails an edited middle entry (prev_hash mismatch)"

r="$(newrun)"; run_logged "$r" -m m/x "q"
rewrite_line "$COLLAB_LOG_DIR/$r/calls.jsonl" '$' "canned answer" "SOMETHING ELSE"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED an edited LAST entry (the chain cannot cover the tail — response_hash must)" \
  || ok "log: verify fails an edited last entry (response_hash self-check covers the tail)"

# Concurrency is real: /collab:panel fires 2-3 calls at once. Every line must stay valid JSON
# (no torn appends) and turns must be distinct — computing `turn` outside the lock made
# all three claim turn 1.
r="$(newrun)"
for m in a/1 b/2 c/3; do run_logged "$r" -m "$m" "concurrent q" & done; wait
n="$(entries "$r" | wc -l | tr -d ' ')"; valid="$(entries "$r" | jq -s 'length' 2>/dev/null || echo -1)"
turns="$(entries "$r" | jq -rs '[.[]|select(.status=="started").turn]|unique|length')"
{ [ "$n" = 9 ] && [ "$valid" = 9 ] && [ "$turns" = 3 ]; } \
  && ok "log: 3 concurrent calls -> 9 intact JSONL lines with distinct turns" \
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

# Pin prompt/hash semantics directly, including trailing newlines that command
# substitution would strip before both storage and hashing.
r="$(newrun)"; pf="$fakedir/prompt-exact"; rf="$fakedir/prompt-response"
printf 'prompt with trailing bytes\n\n' > "$pf"; : > "$rf"
COLLAB_RUN_ID="$r" bash "$logsh" expect --call-id c-prompt --command /collab:consult --model m/x --agent collab-read >/dev/null
turn="$(COLLAB_RUN_ID="$r" COLLAB_LOG_PROMPTS=full bash "$logsh" started --call-id c-prompt \
  --command /collab:consult --model m/x --agent collab-read --prompt-file "$pf")"
COLLAB_RUN_ID="$r" bash "$logsh" completed --call-id c-prompt --exit 0 --turn "$turn" \
  --command /collab:consult --model m/x --agent collab-read --capture-state complete --response-file "$rf" >/dev/null
expected_prompt_hash="$(sha256sum "$pf" | awk '{print $1}')"
prompt_json="$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].prompt|@json')"
logged_prompt_hash="$(entries "$r" | jq -rs '[.[]|select(.status=="started")][0].prompt_hash')"
{ [ "$prompt_json" = '"prompt with trailing bytes\n\n"' ] \
  && [ "$logged_prompt_hash" = "$expected_prompt_hash" ] \
  && bash "$logsh" verify "$r" >/dev/null 2>&1; } \
  && ok "log: prompt and prompt_hash cover exact bytes including trailing newlines" \
  || no "log: prompt bytes/hash semantics drifted (prompt=$prompt_json hash=$logged_prompt_hash)"

# The knobs must work from the CONFIG FILE, not just env — that's the project's
# convention, and env-only would be a trap: a Claude-driven session runs each command
# in a subshell, so `export COLLAB_LOG_PROMPTS=hash` cannot durably hold.
conf="$fakedir/conf.local"; printf 'COLLAB_LOG_PROMPTS=off\n' > "$conf"
r="$(COLLAB_CONF="$conf" bash "$logsh" new-run /collab:consult)"
COLLAB_POLICY="$allow_pol" COLLAB_CONF="$conf" COLLAB_RUN_ID="$r" COLLAB_COMMAND=/collab:consult \
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

# A mutation is a hard runtime contradiction even when opencode itself exits nonzero.
# This fixture supplies resolved permissions and simulates that exact failure without
# contacting a model.
vfix="$fakedir/read-verifier"; mkdir -p "$vfix/collab" "$vfix/.opencode/agent" "$vfix/bin"
cp "$repo_root/collab/verify-collab-read.sh" "$vfix/collab/"
cp "$repo_root/.opencode/agent/collab-read.md" "$vfix/.opencode/agent/"
cat > "$vfix/bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = agent ] && [ "${2:-}" = list ]; then
  set -f
  globs='*.env *.env.* .env **/.env **/.env.* *.pem **/*.pem *.key **/*.key *.pfx *.p12 id_rsa id_ed25519 **/id_rsa **/id_ed25519 **/.ssh/** **/.aws/** **/.gnupg/** *credentials* **/credentials* **/.netrc **/.git-credentials'
  # shellcheck disable=SC2086 # Deliberately split the fixed fixture glob list.
  set -- $globs
  printf 'collab-read (all)\n'
  jq -nc --args '$ARGS.positional as $g | [{permission:"*",pattern:"*",action:"deny"},{permission:"read",pattern:"*",action:"allow"},{permission:"webfetch",pattern:"*",action:"allow"},{permission:"websearch",pattern:"*",action:"allow"}] + ($g | map({permission:"read",pattern:.,action:"deny"}))' "$@"
  exit 0
fi
prompt="${!#}"
if [[ "$prompt" = *'.collab-read-deny-probe.txt'* ]]; then
  probe="${prompt#*PWNED > }"; probe="${probe%% *}"
  printf 'PWNED\n' > "$probe"
fi
exit 9
EOF
chmod +x "$vfix/bin/opencode"
( cd "$vfix" && PATH="$vfix/bin:$PATH" bash collab/verify-collab-read.sh > verifier.out 2>&1 ); vrc=$?
{ [ "$vrc" -eq 1 ] && grep -q 'mutation DENY FAILED' "$vfix/verifier.out" \
  && grep -q 'collab-read NOT verified' "$vfix/verifier.out"; } \
  && ok "verify/read: created mutation is FAIL even when opencode exits nonzero" \
  || no "verify/read: nonzero opencode status hid a created mutation (rc=$vrc)"

# --- the delegate diff: what the model ACTUALLY changed ------------------------
# Without this in the log, /collab:witness can only audit the model's REPORT of its work,
# never the work — on the command PLAN calls the highest-value watcher target.
dele="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
( cd "$dele" && git init -q . && git config user.email t@t && git config user.name t
  # gpgsign OFF: this repo signs commits via the 1Password agent, and a test that
  # fires a host approval prompt (or fails waiting for one) is not a test.
  git config commit.gpgsign false
  # This sandbox must keep its OWN log next to its own repo — the suite exports a
  # shared $COLLAB_LOG_DIR at the top, which would send this run's entries somewhere
  # else entirely and leave the assertions below looking at an empty directory.
  unset COLLAB_LOG_DIR
  mkdir -p collab .opencode/agent
  cp "$ask" "$logsh" collab/
  cp "$repo_root/.opencode/agent/collab-build.md" .opencode/agent/
  printf 'allow *\n' > collab/models.policy
  printf 'ignored-secret.bin\ncollab/logs/\n' > .gitignore
  printf 'orig\n' > a.txt && git add -A && git commit -qm init
  # A fake opencode that behaves like a model doing real work: edits a tracked file
  # AND creates a new one (the case a plain `git diff <sha>` cannot see).
  cat > oc <<'EOF'
#!/usr/bin/env bash
printf 'orig\nCLAUDE-WIP\nMODEL-EDIT\n' > a.txt
printf 'new file from the model\n' > model-added.txt
printf '\000\001MODEL-BINARY\377' > model-binary.bin
echo "did the work"
EOF
  chmod +x oc && mkdir -p bin && mv oc bin/opencode && export PATH="$PWD/bin:$PATH"
  # Claude is MID-WORK: dirty tree + an untracked scratch file of its own.
  printf 'orig\nCLAUDE-WIP\n' > a.txt && printf 'claude notes\n' > claude-scratch.txt
  # Assign, then export: `export X="$(cmd)"` makes export's status the statement's,
  # masking a failing new-run (SC2155). Split so the assignment carries cmd's status.
  COLLAB_RUN_ID="$(bash collab/log.sh new-run /collab:delegate)"
  export COLLAB_RUN_ID
  COLLAB_COMMAND=/collab:delegate bash collab/ask.sh --edit "work" >/dev/null 2>&1
  printf '%s' "$COLLAB_RUN_ID" > .runid ) 2>/dev/null
drun="$(cat "$dele/.runid" 2>/dev/null || true)"
dlog="$dele/collab/logs/$drun/calls.jsonl"

[ -n "$drun" ] && [ -f "$dlog" ] \
  && ok "delegate: runs on a DIRTY worktree (no clean-tree refusal)" \
  || no "delegate: did not run on a dirty tree — the guard is back, or logging broke"

dpatch="$(ls "$dele/collab/logs/$drun"/diff-*.patch 2>/dev/null | head -1)"
[ -n "$dpatch" ] && ok "delegate: the diff is recorded in the run dir (witness can read it)" \
                 || no "delegate: NO diff patch recorded — /collab:witness cannot audit a delegation"
if [ -n "$dpatch" ]; then
  grep -q 'MODEL-EDIT' "$dpatch" \
    && ok "delegate: patch captures the model's edit" || no "delegate: patch missing the model's edit"
  grep -q 'model-added.txt' "$dpatch" \
    && ok "delegate: patch captures a CREATED file (git diff <sha> is blind to these)" \
    || no "delegate: patch missing the model's NEW file — the review would not show it"
  grep -q 'GIT binary patch' "$dpatch" \
    && ok "delegate: patch includes applicable binary contents (--binary)" \
    || no "delegate: binary change is only summarized, not reviewable/applicable"
  ( cd "$dele" && git apply --reverse --check "$dpatch" ) >/dev/null 2>&1 \
    && ok "delegate: recorded binary patch is mechanically applicable" \
    || no "delegate: recorded patch cannot be applied in reverse to the captured after-state"
  { ! grep -q 'claude notes' "$dpatch"; } \
    && ok "delegate: Claude's own uncommitted work is NOT attributed to the model" \
    || no "delegate: the patch blames the model for Claude's in-progress work"
fi
# The base tree must be recoverable — that's what replaces the old refusal.
btree="$(jq -rs '[.[]|select(.type=="delegate-diff").base_tree][0] // ""' "$dlog" 2>/dev/null)"
if [ -n "$btree" ]; then
  ( cd "$dele" && printf 'CLOBBERED\n' > a.txt && git checkout "$btree" -- a.txt 2>/dev/null )
  grep -q 'CLAUDE-WIP' "$dele/a.txt" 2>/dev/null \
    && ok "delegate: clobbered uncommitted work is recoverable from the base tree" \
    || no "delegate: could not restore work from the recorded base tree"
else
  no "delegate: no base_tree recorded — clobbered work would be unrecoverable"
fi
# The patch is part of the record's integrity, not a loose file beside it.
( cd "$dele" && unset COLLAB_LOG_DIR && bash collab/log.sh verify "$drun" >/dev/null 2>&1 ) \
  && ok "delegate: log verifies with the diff entry present" || no "delegate: verify fails on a delegate run"
printf 'tampered\n' >> "$dpatch" 2>/dev/null
( cd "$dele" && unset COLLAB_LOG_DIR && bash collab/log.sh verify "$drun" >/dev/null 2>&1 ) \
  && no "delegate: verify PASSED a tampered patch — the diff is outside the integrity contract" \
  || ok "delegate: verify catches a tampered patch (the diff is covered by the hashes)"

# Ignored changes cannot be represented without copying potentially secret bytes into
# Git objects/logs. Detect them by ephemeral aggregate fingerprint and fail completeness.
( cd "$dele" || exit
  cat > bin/opencode <<'EOF'
#!/usr/bin/env bash
printf 'TOP-SECRET-IGNORED-BYTES\000' > ignored-secret.bin
echo "changed ignored state"
EOF
  chmod +x bin/opencode
  export PATH="$PWD/bin:$PATH"
  unset COLLAB_LOG_DIR
  COLLAB_RUN_ID="$(bash collab/log.sh new-run /collab:delegate)"; export COLLAB_RUN_ID
  COLLAB_COMMAND=/collab:delegate bash collab/ask.sh --edit "ignored work" >/dev/null 2>.ignored-err
  printf '%s' "$COLLAB_RUN_ID" > .ignored-runid )
irun="$(cat "$dele/.ignored-runid")"
ilog="$dele/collab/logs/$irun/calls.jsonl"
{ [ "$(jq -rs '[.[]|select(.type=="delegate-diff")][0].capture_complete' "$ilog")" = "false" ] \
  && grep -q 'INCOMPLETE' "$dele/.ignored-err"; } \
  && ok "delegate: ignored-path activity is detected and explicitly marks the patch incomplete" \
  || no "delegate: ignored change was silently presented as a complete patch"
{ ! grep -R -a -q 'TOP-SECRET-IGNORED-BYTES\|ignored-secret.bin' "$dele/collab/logs/$irun" 2>/dev/null; } \
  && ok "delegate: ignored path names and bytes are not copied into evidence logs" \
  || no "delegate: ignored secret path/content leaked into the evidence log"
ignored_oid="$(cd "$dele" && git hash-object --no-filters ignored-secret.bin)"
( cd "$dele" && ! git cat-file -e "$ignored_oid" 2>/dev/null ) \
  && ok "delegate: ignored content is fingerprinted without writing it to Git objects" \
  || no "delegate: ignored secret content was copied into the Git object database"
( cd "$dele" && unset COLLAB_LOG_DIR && ! bash collab/log.sh verify "$irun" >/dev/null 2>&1 ) \
  && ok "delegate: incomplete ignored-path capture cannot verify clean" \
  || no "delegate: ignored-path omission still produced a clean integrity verdict"

# Git omits a top-level ignored FIFO from its ignored-file enumeration. The
# metadata-only fallback must still make the delegation evidence incomplete.
( cd "$dele" || exit
  rm -rf ignored-secret.bin ignored-fixture ignored-pipe
  mkfifo ignored-pipe
  printf 'ignored-pipe\ncollab/logs/\n' > .gitignore
  cat > bin/opencode <<'EOF'
#!/usr/bin/env bash
echo "no represented changes"
EOF
  chmod +x bin/opencode; export PATH="$PWD/bin:$PATH"; unset COLLAB_LOG_DIR
  COLLAB_RUN_ID="$(bash collab/log.sh new-run /collab:delegate)"; export COLLAB_RUN_ID
  run_bounded 10 bash collab/ask.sh --edit "top-level FIFO" >/dev/null 2>.top-fifo-err; frc=$?
  printf '%s\n%s' "$frc" "$COLLAB_RUN_ID" > .top-fifo-result )
tfrc="$(sed -n '1p' "$dele/.top-fifo-result")"; tfrun="$(sed -n '2p' "$dele/.top-fifo-result")"
tflog="$dele/collab/logs/$tfrun/calls.jsonl"
{ [ "$tfrc" -ne 124 ] && [ "$tfrc" -ne 125 ] \
  && [ "$(jq -rs '[.[]|select(.type=="delegate-diff")][0].capture_complete' "$tflog")" = false ] \
  && ( cd "$dele" && unset COLLAB_LOG_DIR && ! bash collab/log.sh verify "$tfrun" >/dev/null 2>&1 ); } \
  && ok "delegate: top-level ignored FIFO is nonblocking and forces incomplete evidence" \
  || { [ "$tfrc" -eq 125 ] && inc "delegate: top-level ignored FIFO fixture needs timeout/gtimeout" \
    || no "delegate: top-level ignored FIFO was omitted or blocked (rc=$tfrc)"; }

# Unsupported ignored entries are never opened. FIFO coverage is the deadlock
# regression; symlink-to-device covers device-like input without requiring mknod.
for kind in fifo device unreadable large-directory; do
  ( cd "$dele" || exit
    rm -rf ignored-secret.bin ignored-fixture
    mkdir ignored-fixture
    case "$kind" in
      fifo) mkfifo ignored-fixture/input ;;
      device) ln -s /dev/null ignored-fixture/input ;;
      unreadable) printf 'private\n' > ignored-fixture/input; chmod 000 ignored-fixture/input ;;
      large-directory) i=0; while [ "$i" -lt 1025 ]; do : > "ignored-fixture/f-$i"; i=$((i+1)); done ;;
    esac
    printf 'ignored-fixture/\nignored-secret.bin\ncollab/logs/\n' > .gitignore
    cat > bin/opencode <<'EOF'
#!/usr/bin/env bash
echo "no represented changes"
EOF
    chmod +x bin/opencode; export PATH="$PWD/bin:$PATH"; unset COLLAB_LOG_DIR
    COLLAB_RUN_ID="$(bash collab/log.sh new-run /collab:delegate)"; export COLLAB_RUN_ID
    run_bounded 10 bash collab/ask.sh --edit "ignored fixture" >/dev/null 2>.fixture-err; frc=$?
    printf '%s\n%s' "$frc" "$COLLAB_RUN_ID" > ".fixture-$kind" )
  frc="$(sed -n '1p' "$dele/.fixture-$kind")"; frun="$(sed -n '2p' "$dele/.fixture-$kind")"
  flog="$dele/collab/logs/$frun/calls.jsonl"
  { [ "$frc" -ne 124 ] && [ "$frc" -ne 125 ] && [ "$(jq -rs '[.[]|select(.type=="delegate-diff")][0].capture_complete' "$flog")" = false ]; } \
    && ok "delegate: ignored $kind is nonblocking/bounded and explicitly incomplete" \
    || { [ "$frc" -eq 125 ] && inc "delegate: ignored $kind fixture needs timeout/gtimeout" \
      || no "delegate: ignored $kind blocked or claimed complete (rc=$frc)"; }
done
rm -rf "$dele"

# A Git tree stores only a submodule gitlink, not dirty files inside its worktree.
# If local Git permits file:// fixtures, a dirty submodule must therefore force an
# incomplete delegation artifact even when the parent tree itself is unchanged.
subfix="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; subsrc="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
if ( cd "$subsrc" && git init -q && git config user.email t@t && git config user.name t \
     && git config commit.gpgsign false && printf 'base\n' > inner.txt && git add inner.txt && git commit -qm init ) \
   && ( cd "$subfix" && git init -q && git config user.email t@t && git config user.name t \
     && git config commit.gpgsign false && git -c protocol.file.allow=always submodule add -q "$subsrc" module \
     && mkdir -p collab .opencode/agent bin && cp "$ask" "$logsh" collab/ \
     && cp "$repo_root/.opencode/agent/collab-build.md" .opencode/agent/ \
     && printf 'allow *\n' > collab/models.policy && printf 'collab/logs/\n' > .gitignore \
     && git add -A && git commit -qm parent ); then
  ( cd "$subfix" || exit
    cat > bin/opencode <<'EOF'
#!/usr/bin/env bash
printf 'model dirtied submodule\n' >> module/inner.txt
echo done
EOF
    chmod +x bin/opencode; export PATH="$PWD/bin:$PATH"; unset COLLAB_LOG_DIR
    COLLAB_RUN_ID="$(bash collab/log.sh new-run /collab:delegate)"; export COLLAB_RUN_ID
    bash collab/ask.sh --edit "dirty submodule" >/dev/null 2>&1
    printf '%s' "$COLLAB_RUN_ID" > .runid )
  srun="$(cat "$subfix/.runid")"; slog="$subfix/collab/logs/$srun/calls.jsonl"
  { [ "$(jq -rs '[.[]|select(.type=="delegate-diff")][0].capture_complete' "$slog")" = false ] \
    && [ "$(jq -rs '[.[]|select(.type=="delegate-diff")][0].incomplete_reason' "$slog")" = submodule-worktree-unrepresentable ]; } \
    && ok "delegate: dirty submodule worktree cannot produce complete/no-change evidence" \
    || no "delegate: dirty submodule was invisible to the parent-tree artifact"
else
  inc "delegate: dirty-submodule fixture unavailable (local Git file transport or fixture setup failed)"
fi
rm -rf "$subfix" "$subsrc"

# claude-final (W0.5) — without it a watcher can audit dispositions but not the
# summary the developer actually read.
r="$(newrun)"
printf 'the summary the user saw' | COLLAB_RUN_ID="$r" bash "$logsh" final >/dev/null 2>&1
[ "$(entries "$r" | jq -rs '[.[]|select(.type=="claude-final")][0].text')" = "the summary the user saw" ] \
  && ok "log: claude-final records Claude's user-facing answer" \
  || no "log: claude-final entry missing or wrong"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED a claude-final-only run with zero model lifecycle calls" \
  || ok "log: verify rejects a run with zero expected/model lifecycle calls"

# claude-disposition (W0.8) — must be marked as a CLAIM, and the verdict vocabulary
# is fixed so a report can't invent a flattering one.
r="$(newrun)"
COLLAB_RUN_ID="$r" bash "$logsh" disposition --model m/x --point "p" --verdict Adopt >/dev/null 2>&1
[ "$(entries "$r" | jq -rs '[.[]|select(.type=="claude-disposition")][0].claim')" = "true" ] \
  && ok "log: claude-disposition is flagged claim:true (a claim to audit, not a fact)" \
  || no "log: claude-disposition not flagged as a claim"
entries "$r" | jq -e 'select(.type=="claude-disposition") | has("payload_hash") | not' >/dev/null \
  && ok "log: disposition relies on generic entry integrity, with no redundant payload_hash" \
  || no "log: disposition still carries an unvalidated payload_hash"
COLLAB_RUN_ID="$r" bash "$logsh" disposition --model m/x --point "p" --verdict Maybe >/dev/null 2>&1 \
  && no "log: disposition accepted a bogus verdict 'Maybe'" \
  || ok "log: disposition rejects a verdict outside Adopt|Adapt|Reject|Defer"
# A disposition can be the final line, so the chain has no successor to protect it.
# Generic entry_hash must cover its full payload directly.
rewrite_line "$COLLAB_LOG_DIR/$r/calls.jsonl" '$' '"Adopt"' '"Reject"'
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED a modified final disposition payload" \
  || ok "log: entry_hash protects final disposition payloads"

# subagent-voice (issue #5) — a Claude subagent's collab turn. It is a CLAIM, not
# captured evidence: its text is transcribed by Claude (claimed_response), never
# wrapper-captured (raw_response). It must record claim:true, captured:false, survive
# byte-exactly, and pass verify's hash-chain contract alongside a normal opencode call.
r="$(newrun)"; run_logged "$r" -m openai/gpt-5 "the panel question"
svresp="$fakedir/sv-resp.txt"
printf 'subagent says:\n  "quote", back\\slash, and a trailing newline\n' > "$svresp"
COLLAB_RUN_ID="$r" bash "$logsh" subagent-voice --model claude-opus-4-8 \
  --label "anthropic voice" --response-file "$svresp" >/dev/null 2>&1
sv="$(entries "$r" | jq -c 'select(.type=="subagent-voice")')"
{ [ "$(printf '%s' "$sv" | jq -r '.claim')" = "true" ] \
  && [ "$(printf '%s' "$sv" | jq -r '.captured')" = "false" ] \
  && [ "$(printf '%s' "$sv" | jq -r '.transport')" = "claude-subagent" ] \
  && [ "$(printf '%s' "$sv" | jq -r 'has("raw_response")')" = "false" ]; } \
  && ok "log: subagent-voice is claim:true, captured:false, and uses claimed_response not raw_response" \
  || no "log: subagent-voice flags wrong (got $sv)"
# Byte-exact: extract with `jq -sj` (no added newline) to a file and `cmp` against the
# source — NEVER a $(...) capture, which strips trailing newlines from BOTH sides and
# would make this "byte-exact" test pass no matter what (the trap AGENTS.md names).
entries "$r" | jq -sj '[.[]|select(.type=="subagent-voice")][0].claimed_response' > "$fakedir/sv-got.txt"
cmp -s "$fakedir/sv-got.txt" "$svresp" \
  && ok "log: subagent-voice claimed_response is byte-exact (newlines/quotes/backslashes survive)" \
  || no "log: subagent-voice claimed_response mangled"
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && ok "log: verify accepts a run mixing an opencode call and a subagent-voice claim" \
  || no "log: verify rejected a valid opencode+subagent-voice run"
# Tampering with the final subagent-voice text must be caught by the response_hash
# self-check (the chain cannot cover the tail).
rewrite_line "$COLLAB_LOG_DIR/$r/calls.jsonl" '$' 'subagent says' 'subagent LIED'
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && no "log: verify PASSED an edited final subagent-voice claimed_response" \
  || ok "log: response_hash catches an altered subagent-voice transcript"
# A collab that is ONLY a subagent voice (an all-Anthropic consult) is a real exchange,
# not an empty run — it must verify, unlike a claude-final-only run.
r="$(newrun)"; printf 'lone subagent reply' > "$svresp"
COLLAB_RUN_ID="$r" bash "$logsh" subagent-voice --model claude-opus-4-8 --response-file "$svresp" >/dev/null 2>&1
bash "$logsh" verify "$r" >/dev/null 2>&1 \
  && ok "log: verify accepts a subagent-voice-only run (all-Anthropic collab is not empty)" \
  || no "log: verify rejected a legitimate subagent-voice-only run"

# new-run must MINT a run, never hand back an ambient one — that would silently merge
# two workflows into a single audit unit.
r1="$(newrun)"; r2="$(COLLAB_RUN_ID="$r1" bash "$logsh" new-run /collab:panel)"
[ -n "$r2" ] && [ "$r1" != "$r2" ] \
  && ok "log: new-run mints a fresh id even when \$COLLAB_RUN_ID is set" \
  || no "log: new-run returned the ambient run id ($r1 == $r2)"

# `latest` — /collab:witness resolves the most recent run with it, and must not have to shell
# out to `readlink` (which it is not permitted to run, and whose flags differ on BSD).
r="$(newrun)"; run_logged "$r" -m m/x "q"
[ "$(bash "$logsh" latest 2>/dev/null)" = "$r" ] \
  && ok "log: 'latest' prints the most recent run id" \
  || no "log: 'latest' wrong (got '$(bash "$logsh" latest 2>&1)', expected $r)"

# Retention (W0.6): an unbounded log dir is an indefinite sensitive-data surface.
oldrun="$COLLAB_LOG_DIR/20200101T000000Z-deadbeef"; mkdir -p "$oldrun"
touch -d "60 days ago" "$oldrun" 2>/dev/null || touch -t 202001010000 "$oldrun" 2>/dev/null
bash "$logsh" prune --days 14 >/dev/null 2>&1
[ ! -d "$oldrun" ] && ok "log: prune removes runs past the retention window" \
                   || no "log: prune left a 60-day-old run in place"

# --- per-project log partitioning (COLLAB_LOG_PARTITION; opt-in) ---------------
# A future shared install keeps ONE collab/logs tree; partitioning gives each project
# its own subdir BELOW it so `latest`, retention and /collab:witness never cross
# projects. OFF by default = today's flat layout, byte-identical. The suite exports
# COLLAB_LOG_DIR globally, which DISABLES partitioning — so every case here runs with it
# unset in a subshell (mirroring the delegate-fixture pattern), or explicitly sets it to
# assert it wins.
# Canonicalize partroot: log.sh derives its base via `cd "$(dirname "$0")" && pwd`,
# which collapses the `//` a macOS TMPDIR (trailing slash) leaves in a bare mktemp path.
# base_logs must match that canonical form for the string comparisons below.
partroot="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")" && pwd)"; mkdir -p "$partroot/collab"
cp "$logsh" "$partroot/collab/log.sh"; plogsh="$partroot/collab/log.sh"
base_logs="$partroot/collab/logs"
projA="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; projB="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
# git-init each project so its key derives from a distinct git top-level — deterministic
# even if TMPDIR happens to sit inside another repo. (Falls back to CWD if git absent;
# the two paths still differ, so the keys still differ.)
if command -v git >/dev/null 2>&1; then
  ( cd "$projA" && git init -q ) 2>/dev/null || true
  ( cd "$projB" && git init -q ) 2>/dev/null || true
fi

# ON: a run lands under <base>/<project-key>/<run>. Resolve the dir under the same
# cwd+env so the key derivation matches the one new-run used.
rA="$( cd "$projA" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"
dirA="$( cd "$projA" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$rA" )"
rB="$( cd "$projB" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"
dirB="$( cd "$projB" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$rB" )"
keyA="${dirA#"$base_logs/"}"; keyA="${keyA%%/*}"
keyB="${dirB#"$base_logs/"}"; keyB="${keyB%%/*}"

# The run dir must sit UNDER the base collab/logs tree (a KEY segment, not flat), so the
# watch-scope check and the `**/collab/logs/**` glob still match.
{ case "$dirA" in "$base_logs/"*) true ;; *) false ;; esac; } \
  && [ -n "$keyA" ] && [ "$keyA" != "$rA" ] && [ "$dirA" = "$base_logs/$keyA/$rA" ] \
  && ok "log: PARTITION=1 places a run under <base>/<project-key>/<run>, below collab/logs" \
  || no "log: PARTITION=1 did not partition under the base (dirA=$dirA base=$base_logs key=$keyA)"

# Two project roots with DIFFERENT basenames get different keys. Weak on its own — the
# random mktemp basenames already differ, so this passes on the basename alone and would
# NOT notice the path-hash suffix being dropped. The shared-basename case below is the
# one that actually exercises the hash; this stays as a baseline.
{ [ -n "$keyA" ] && [ -n "$keyB" ] && [ "$keyA" != "$keyB" ]; } \
  && ok "log: PARTITION=1 gives two different-basename project roots different keys" \
  || no "log: two project roots collided on the same key (A=$keyA B=$keyB)"

# SHARED basename, different parents: the key prefix is identical ("proj"), so ONLY the
# path-hash suffix can distinguish the two. This is the property the hash exists for and
# the collision the basename-alone token would produce. It MUST fail if the hash suffix
# were dropped — both keys would collapse to "proj" and neither the inequality nor the
# `proj-*` shape check below would hold.
sharedA="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"; sharedB="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
mkdir -p "$sharedA/proj" "$sharedB/proj"
if command -v git >/dev/null 2>&1; then
  ( cd "$sharedA/proj" && git init -q ) 2>/dev/null || true
  ( cd "$sharedB/proj" && git init -q ) 2>/dev/null || true
fi
srA="$( cd "$sharedA/proj" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"
sdirA="$( cd "$sharedA/proj" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$srA" )"
srB="$( cd "$sharedB/proj" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"
sdirB="$( cd "$sharedB/proj" && unset COLLAB_LOG_DIR && COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$srB" )"
skeyA="${sdirA#"$base_logs/"}"; skeyA="${skeyA%%/*}"
skeyB="${sdirB#"$base_logs/"}"; skeyB="${skeyB%%/*}"
{ [ -n "$skeyA" ] && [ -n "$skeyB" ] && [ "$skeyA" != "$skeyB" ] \
  && case "$skeyA" in proj-*) true ;; *) false ;; esac \
  && case "$skeyB" in proj-*) true ;; *) false ;; esac; } \
  && ok "log: PARTITION=1 distinguishes two SAME-basename projects by the path-hash suffix" \
  || no "log: shared-basename projects collided (A=$skeyA B=$skeyB) — hash suffix not distinguishing"

# The "logging must never fail the call" invariant, at LOAD time: a failing git (or
# hasher) while deriving the project key must NOT abort. Shadow git with a stub that
# exits non-zero; the call must still exit 0 and create its run dir (key falls back to
# $PWD). This locks the invariant so a future edit dropping a `|| true` fails CI.
gitstub="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
printf '#!/usr/bin/env bash\nexit 127\n' > "$gitstub/git"; chmod +x "$gitstub/git"
grid="$( cd "$projA" && unset COLLAB_LOG_DIR && PATH="$gitstub:$PATH" COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"; grc=$?
gdir="$( cd "$projA" && unset COLLAB_LOG_DIR && PATH="$gitstub:$PATH" COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$grid" )"
{ [ "$grc" -eq 0 ] && [ -n "$grid" ] && [ -d "$gdir" ]; } \
  && ok "log: PARTITION=1 with git failing at load -> exit 0, run dir still created (never-fail invariant)" \
  || no "log: a failing git at load broke the partitioned call (rc=$grc, dir=$gdir)"

# OFF (default): the run lands DIRECTLY in the base logs dir — today's layout, unchanged.
rOff="$( cd "$projA" && unset COLLAB_LOG_DIR && bash "$plogsh" new-run /collab:consult )"
dirOff="$( cd "$projA" && unset COLLAB_LOG_DIR && bash "$plogsh" dir "$rOff" )"
[ "$dirOff" = "$base_logs/$rOff" ] \
  && ok "log: partitioning OFF -> run lands directly in the base logs dir (no key segment)" \
  || no "log: OFF changed the log layout (dirOff=$dirOff, expected $base_logs/$rOff)"

# An explicit COLLAB_LOG_DIR wins and DISABLES partitioning, even with PARTITION=1: the
# caller named exactly where logs go.
explicitld="$(mktemp -d "${TMPDIR:-/tmp}/collab.XXXXXX")"
rE="$( cd "$projA" && COLLAB_LOG_DIR="$explicitld" COLLAB_LOG_PARTITION=1 bash "$plogsh" new-run /collab:consult )"
dirE="$( cd "$projA" && COLLAB_LOG_DIR="$explicitld" COLLAB_LOG_PARTITION=1 bash "$plogsh" dir "$rE" )"
[ "$dirE" = "$explicitld/$rE" ] \
  && ok "log: explicit COLLAB_LOG_DIR beats PARTITION=1 (no per-project subdir)" \
  || no "log: PARTITION overrode an explicit COLLAB_LOG_DIR (dirE=$dirE, expected $explicitld/$rE)"
rm -rf "$partroot" "$projA" "$projB" "$explicitld" "$sharedA" "$sharedB" "$gitstub"

echo
printf 'wrapper + panel + lint + log tests: %d passed, %d failed, %d inconclusive\n' "$pass" "$fail" "$inconclusive"
[ "$fail" -eq 0 ]
