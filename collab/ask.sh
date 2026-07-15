#!/usr/bin/env bash
#
# ask.sh — let Claude Code consult or delegate to another LLM via opencode.
#
# opencode handles model access and auth (subscription/OAuth — no API keys needed
# here). This script is the single entry point the /consult, /delegate and
# /consensus slash commands shell out to.
#
# Usage:
#   collab/ask.sh [-m provider/model] [-a plan|build] [--edit] <prompt...>
#
#   -m provider/model   Pick the model (run `opencode models` to list options).
#                       Defaults to $COLLAB_MODEL, else opencode's own default.
#   -a <agent>          opencode agent. Default `collab-read` (our hard-deny
#                       read-only agent: no bash/write/edit — see
#                       .opencode/agent/collab-read.md, proven by
#                       collab/verify-collab-read.sh). `collab-build` can edit files
#                       but denies task/webfetch/websearch + secret reads;
#                       `build` is opencode's unrestricted editor; `plan` is
#                       opencode's compliance-only read-only agent.
#   --edit              Shorthand for `-a collab-build` — let the other model change
#                       files (edit/write/patch/bash), but with task + network egress
#                       + secret reads denied at the tool layer. Falls back to the
#                       unrestricted `build` agent if the collab-build def is missing.
#   -s, --session <id>  Continue an existing opencode session (multi-turn dialogue).
#   --emit-session      Print "SESSION: <id>\n---\n<answer>" so a caller can capture
#                       the session id and continue with -s (used by /collaborate,
#                       Option B: opencode carries the peer's turns, not Claude).
#                       Requires `jq`.
#   --dry-run           Print the exact opencode command that WOULD run (safely
#                       quoted) and exit 0 without calling any model. Token-free;
#                       use it to inspect model/agent selection or in tests.
#
# Examples:
#   collab/ask.sh "Critique this migration plan: ..."          # read-only opinion
#   collab/ask.sh -m google/gemini-2.5-pro "Second opinion..." # specific model
#   collab/ask.sh --edit "Add input validation to parser.c"    # delegate coding
#
# Model policy: the requested -m model is checked against a deny/ask/allow policy
# (default collab/models.policy, override with $COLLAB_POLICY). A `deny` model is
# refused; an `ask` model requires $COLLAB_CONFIRMED=1 (Claude sets it only after
# confirming with the user). See that file for the format.
#
# Env: $COLLAB_MODEL (default model), $COLLAB_TIMEOUT (seconds; unset = no timeout,
#      so long-running model/coding work is never cut off), $COLLAB_REQUIRE_HARDENED
#      (=1: hard-fail with exit 5 instead of falling back to a weaker/unrestricted
#      agent when the collab-read/collab-build def is missing — for automated/CI use).
#
set -euo pipefail

usage() {
  # Print the header comment block (everything after the shebang, up to the
  # first non-comment line) with the leading "# " stripped. Range-independent
  # so it stays correct as the header grows or shrinks.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-1}"
}

policy_file="${COLLAB_POLICY:-$(dirname "$0")/models.policy}"

# policy_tier <model> — echo the deny/ask/allow tier for a model per the policy
# file (first matching glob wins). Defaults to allow: no file, no model id, or no
# match all mean "allowed", so the policy only ever restricts, never surprises.
policy_tier() {
  local model="$1" tier pat
  [ -n "$model" ] || { echo allow; return; }        # unknown default model: can't police
  [ -f "$policy_file" ] || { echo allow; return; }
  # `|| [ -n "$tier" ]` so a final line with no trailing newline is still read —
  # otherwise a policy file ending in `deny <model>` (no newline) drops that rule
  # and fails OPEN (the deny is silently ignored).
  while read -r tier pat _ || [ -n "$tier" ]; do
    case "$tier" in ''|'#'*) continue ;; esac        # skip blanks / comments
    case "$tier" in allow|ask|deny) ;; *) continue ;; esac
    # shellcheck disable=SC2254 # $pat is intentionally a glob pattern
    case "$model" in $pat) echo "$tier"; return ;; esac
  done < "$policy_file"
  echo allow
}

model="${COLLAB_MODEL:-}"
agent="collab-read"  # our read-only agent: denies mutation (bash/edit/write), secret
                     # reads (.env/keys/creds) and network egress (webfetch/websearch)
                     # at opencode's permission layer — read-only + no-egress by
                     # construction, not model compliance. Proven by
                     # collab/verify-collab-read.sh. Falls back to `plan` (weaker) if
                     # the def is missing — see below.
session=""      # opencode session id to continue (Option B multi-turn), forwarded via -s
emit_session="" # when set, emit "SESSION: <id>" + the extracted answer (for /collaborate)
dry_run=""      # when set, print the opencode command and exit without running it

# need_arg <flag> <next-token> — reject a value-taking flag whose value is missing
# or looks like another flag (a common "-m -a build" typo would otherwise swallow
# the next flag as the value). Model/agent/session ids never start with '-'.
need_arg() {
  case "${2:-__MISSING__}" in
    __MISSING__|-*) echo "error: $1 requires a value (got '${2:-}')." >&2; usage ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -m) need_arg -m "${2:-}"; model="$2"; shift 2 ;;
    -a) need_arg -a "${2:-}"; agent="$2"; shift 2 ;;
    -s|--session) need_arg "$1" "${2:-}"; session="$2"; shift 2 ;;
    --emit-session) emit_session=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --edit) agent="collab-build"; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

prompt="$*"
[ -z "$prompt" ] && { echo "error: no prompt given" >&2; usage; }

# Soft-validate the agent: collab-read|plan|build are the ones this repo ships and
# reasons about. A custom agent is allowed (opencode may define others), but flag it
# so a typo like '-a paln' doesn't silently run an unintended/again-fallback agent.
case "$agent" in
  collab-read|collab-build|plan|build) ;;
  *) echo "note: '-a $agent' is not one of collab-read|collab-build|plan|build; using it as-is." >&2 ;;
esac

if ! command -v opencode >/dev/null 2>&1; then
  echo "error: opencode not found. Install with: npm install -g opencode-ai" >&2
  exit 127
fi

# Resolve a timeout binary for $COLLAB_TIMEOUT: GNU coreutils `timeout`, or
# `gtimeout` on macOS (brew coreutils). If a timeout was requested but neither
# exists, warn and run UNCAPPED rather than crashing (macOS ships neither).
timeout_bin=""
if command -v timeout >/dev/null 2>&1; then timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then timeout_bin="gtimeout"; fi
if [ -n "${COLLAB_TIMEOUT:-}" ] && [ -z "$timeout_bin" ]; then
  echo "warning: \$COLLAB_TIMEOUT set but no 'timeout'/'gtimeout' on PATH; running without a cap." >&2
fi

# If we default to collab-read but its definition isn't present (e.g. wrapper run
# from outside the repo), fall back to opencode's built-in `plan` rather than let
# opencode silently drop to the full-access `build` agent. `plan` is a WEAKER
# read-only: it denies `edit` but NOT `bash`, and does not deny secret reads or
# network — so its read-only-ness is compliance, not construction. It's still a
# safer fallback than `build` (which grants everything), but it is not equivalent
# to collab-read; warn loudly so the weaker guarantee is visible.
#
# COLLAB_REQUIRE_HARDENED=1 turns the (loud but easy-to-miss) downgrade into a hard
# error: for automated/CI use, refuse to run at all rather than silently drop to a
# weaker/unrestricted agent. Off by default so interactive use still degrades.
if [ "$agent" = "collab-read" ] && [ ! -f "$(dirname "$0")/../.opencode/agent/collab-read.md" ]; then
  if [ -n "${COLLAB_REQUIRE_HARDENED:-}" ]; then
    echo "error: collab-read agent def not found and COLLAB_REQUIRE_HARDENED=1 — refusing to fall back to a weaker agent." >&2
    exit 5
  fi
  echo "warning: collab-read agent def not found; falling back to opencode's 'plan' — WEAKER (compliance-only; does not deny bash, secret reads, or network)." >&2
  agent="plan"
fi

# Same idea for the --edit path: if the collab-build def is missing, fall back to
# opencode's built-in `build` — the only write-capable built-in — rather than fail.
# `build` is UNRESTRICTED (no task/egress/secret-read denies), so warn loudly: the
# delegated edit still works, but without collab-build's hardening.
if [ "$agent" = "collab-build" ] && [ ! -f "$(dirname "$0")/../.opencode/agent/collab-build.md" ]; then
  if [ -n "${COLLAB_REQUIRE_HARDENED:-}" ]; then
    echo "error: collab-build agent def not found and COLLAB_REQUIRE_HARDENED=1 — refusing to fall back to the unrestricted 'build' agent." >&2
    exit 5
  fi
  echo "warning: collab-build agent def not found; falling back to opencode's 'build' — UNRESTRICTED (no task/webfetch/websearch or secret-read denies)." >&2
  agent="build"
fi

# Enforce the model policy as a hard backstop (independent of Claude's own check).
case "$(policy_tier "$model")" in
  deny)
    echo "error: model '$model' is denied by ${policy_file} (deny rule). Refusing to run." >&2
    exit 3 ;;
  ask)
    if [ -z "${COLLAB_CONFIRMED:-}" ]; then
      echo "error: model '$model' is gated 'ask' by ${policy_file}." >&2
      echo "Confirm with the user first, then re-run with COLLAB_CONFIRMED=1." >&2
      exit 4
    fi ;;
esac

# --auto auto-approves permissions that aren't explicitly denied. With collab-read
# the mutating tools (bash/write/edit/patch) are DENIED, so --auto can't approve
# them into existence; with build it lets the model apply edits without blocking on
# prompts (that's the point of delegating). A denied tool stays denied under --auto.
args=(run --agent "$agent" --auto)
[ -n "$model" ] && args+=(-m "$model")
[ -n "$session" ] && args+=(-s "$session")

# --dry-run: show the faithful command (timeout prefix + stdin redirect included, so
# what's printed is exactly what would execute) and stop. No model is called.
if [ -n "$dry_run" ]; then
  dry=()
  [ -n "${COLLAB_TIMEOUT:-}" ] && [ -n "$timeout_bin" ] && dry+=("$timeout_bin" "$COLLAB_TIMEOUT")
  dry+=(opencode "${args[@]}")
  [ -n "$emit_session" ] && dry+=(--format json)
  dry+=("$prompt")
  printf '%q ' "${dry[@]}"; printf '</dev/null\n'
  exit 0
fi

# Echo the resolved selection to stderr (stdout carries only the model's answer /
# the SESSION payload). Cheap observability into what actually ran.
echo "collab: model=${model:-<opencode default>} agent=${agent}${session:+ session=$session}" >&2

# run_opencode: invoke opencode with stdin redirected from /dev/null and an optional
# timeout. stdin MUST be /dev/null: `opencode run` blocks waiting on stdin when stdin
# is a non-TTY pipe (exactly what Claude Code's Bash tool provides), so without this
# the call hangs until killed. Interactive terminals are a TTY and don't hit it —
# which is why it only bit us when Claude invoked the wrapper. This is the real fix.
#
# Timeout is OPT-IN and OFF by default: legitimate work — deep reasoning, or a --edit
# task running many tool iterations — can take a long time, and a hard cap would kill
# it. Set $COLLAB_TIMEOUT (seconds) only if you want a backstop against a stuck call.
run_opencode() {
  if [ -n "${COLLAB_TIMEOUT:-}" ] && [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$COLLAB_TIMEOUT" opencode "$@" </dev/null
  else
    opencode "$@" </dev/null
  fi
}

status=0
if [ -n "$emit_session" ]; then
  # Option B (multi-turn): run in JSON mode, then extract the session id and the
  # assistant's answer. The caller (/collaborate) captures the id from the SESSION:
  # line and threads it back with -s on later turns, so opencode — not Claude —
  # carries the peer's prior words (fidelity by construction, not by Claude's
  # discipline). Two-stage jq tolerates any stray non-JSON line before slurping.
  command -v jq >/dev/null 2>&1 || { echo "error: --emit-session needs 'jq' (not found)." >&2; exit 127; }
  raw="$(run_opencode "${args[@]}" --format json "$prompt")" || status=$?
  if [ "$status" -eq 124 ]; then
    echo "error: opencode hit \$COLLAB_TIMEOUT=${COLLAB_TIMEOUT:-}s with no response." >&2
    exit "$status"
  elif [ "$status" -ne 0 ]; then
    echo "error: opencode exited $status (model '${model:-opencode default}', agent '${agent}')." >&2
  fi
  valid="$(printf '%s\n' "$raw" | jq -rR 'fromjson? // empty' 2>/dev/null)"
  sid="$(printf '%s\n' "$valid" | jq -rs '[.[].sessionID] | map(select(. != null)) | .[0] // ""' 2>/dev/null)"
  text="$(printf '%s\n' "$valid" | jq -rs '[.[] | select(.type=="text") | .part.text] | add // ""' 2>/dev/null)"
  if [ -z "$text" ] && [ "$status" -eq 0 ]; then
    echo "warning: opencode returned no answer text (session '${sid:-?}', model '${model:-opencode default}')." >&2
  fi
  printf 'SESSION: %s\n---\n%s\n' "$sid" "$text"
  exit "$status"
else
  run_opencode "${args[@]}" "$prompt" || status=$?
  if [ "$status" -eq 124 ]; then
    echo "error: opencode hit \$COLLAB_TIMEOUT=${COLLAB_TIMEOUT:-}s with no response (model '${model:-opencode default}', agent '${agent}'). Raise \$COLLAB_TIMEOUT or re-run." >&2
  elif [ "$status" -ne 0 ]; then
    echo "error: opencode exited $status (model '${model:-opencode default}', agent '${agent}')." >&2
  fi
  exit "$status"
fi
