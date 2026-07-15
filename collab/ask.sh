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
#   -a plan|build       opencode agent. `plan` is read-only (default); `build`
#                       can edit files in this repo.
#   --edit              Shorthand for `-a build` — let the other model change files.
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
#      so long-running model/coding work is never cut off).
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
  while read -r tier pat _; do
    case "$tier" in ''|'#'*) continue ;; esac        # skip blanks / comments
    case "$tier" in allow|ask|deny) ;; *) continue ;; esac
    # shellcheck disable=SC2254 # $pat is intentionally a glob pattern
    case "$model" in $pat) echo "$tier"; return ;; esac
  done < "$policy_file"
  echo allow
}

model="${COLLAB_MODEL:-}"
agent="plan"   # default to opencode's read-only plan agent (see PLAN.md: enforced by
               # plan-mode + model compliance, not a hard sandbox)

while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="${2:-}"; shift 2 ;;
    -a) agent="${2:-}"; shift 2 ;;
    --edit) agent="build"; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

prompt="$*"
[ -z "$prompt" ] && { echo "error: no prompt given" >&2; usage; }

if ! command -v opencode >/dev/null 2>&1; then
  echo "error: opencode not found. Install with: npm install -g opencode-ai" >&2
  exit 127
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

# --auto auto-approves permissions that aren't explicitly denied. With the plan
# agent this relies on plan-mode staying read-only; with build it lets the model
# apply edits without blocking on prompts (that's the point of delegating).
args=(run --agent "$agent" --auto)
[ -n "$model" ] && args+=(-m "$model")

# stdin MUST be redirected from /dev/null: `opencode run` blocks waiting on stdin
# when stdin is a non-TTY pipe (exactly what Claude Code's Bash tool provides), so
# without this the call hangs until it is killed. Interactive terminals are a TTY
# and don't hit this — which is why it only bit us when Claude invoked the wrapper.
# This redirect is the actual fix for the "hangs forever" behavior.
#
# Timeout is OPT-IN and OFF by default: legitimate work — deep reasoning, or a
# --edit coding task running many tool iterations — can take a long time, and a
# hard cap would kill it. Set $COLLAB_TIMEOUT (seconds) only if you want a backstop
# against a genuinely stuck call.
status=0
if [ -n "${COLLAB_TIMEOUT:-}" ]; then
  timeout "$COLLAB_TIMEOUT" opencode "${args[@]}" "$prompt" </dev/null || status=$?
  if [ "$status" -eq 124 ]; then
    echo "error: opencode hit \$COLLAB_TIMEOUT=${COLLAB_TIMEOUT}s with no response (model '${model:-opencode default}', agent '${agent}'). Raise \$COLLAB_TIMEOUT or re-run." >&2
  fi
else
  opencode "${args[@]}" "$prompt" </dev/null || status=$?
fi
exit "$status"
