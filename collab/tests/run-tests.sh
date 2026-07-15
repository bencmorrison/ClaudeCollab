#!/usr/bin/env bash
# run-tests.sh — unit tests for collab/ask.sh using a fake `opencode` on PATH.
# No model is ever called; every assertion is about the argv / behaviour of the
# wrapper. Run:  bash collab/tests/run-tests.sh   (exit 0 = all pass).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
ask="$repo_root/collab/ask.sh"

# Put the fake opencode first on PATH so `command -v opencode` finds it.
fakedir="$(mktemp -d)"
cp "$here/fake-opencode" "$fakedir/opencode"
chmod +x "$fakedir/opencode"
export PATH="$fakedir:$PATH"

# Neutral permissive policy so policy logic doesn't interfere unless a test opts in.
allow_pol="$(mktemp)"; printf 'allow *\n' > "$allow_pol"

argsfile="$(mktemp)"; stdinfile="$(mktemp)"
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
  local errf; errf="$(mktemp)"
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

# 3. --edit switches to the build agent.
run_ask --edit "change a file"
args_has 'build' && ! args_has 'collab-read' \
  && ok "--edit -> --agent build" \
  || no "--edit did not select build (got: $(tr '\n' ' ' <"$argsfile"))"

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
deny_pol="$(mktemp)"; printf 'deny openai/gpt-5.5\n' > "$deny_pol"
: > "$argsfile"
OUT="$(COLLAB_POLICY="$deny_pol" bash "$ask" -m openai/gpt-5.5 "q" 2>/dev/null)"; RC=$?
{ [ "$RC" -eq 3 ] && ! [ -s "$argsfile" ]; } \
  && ok "policy deny -> exit 3, opencode never invoked" \
  || no "policy deny not enforced (rc=$RC, args present=$( [ -s "$argsfile" ] && echo yes || echo no))"
rm -f "$deny_pol"

# 12. Policy ask, unconfirmed -> exit 4, no call.
ask_pol="$(mktemp)"; printf 'ask openai/gpt-5.5\n' > "$ask_pol"
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
tmp_repo="$(mktemp -d)"; mkdir -p "$tmp_repo/collab"
cp "$ask" "$tmp_repo/collab/ask.sh"; cp "$repo_root/collab/models.policy" "$tmp_repo/collab/" 2>/dev/null || true
: > "$argsfile"
OUT="$(COLLAB_POLICY="$allow_pol" bash "$tmp_repo/collab/ask.sh" "q" 2>/dev/null)"; RC=$?
{ args_has 'plan' && ! args_has 'build'; } \
  && ok "missing collab-read def -> falls back to plan (not build)" \
  || no "fallback wrong (got: $(tr '\n' ' ' <"$argsfile"))"
rm -rf "$tmp_repo"

echo
printf 'ask.sh tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
