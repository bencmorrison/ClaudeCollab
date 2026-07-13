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
set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

model="${COLLAB_MODEL:-}"
agent="plan"   # default to the read-only agent so a consult can never mutate files

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

# --auto auto-approves permissions that aren't explicitly denied. With the plan
# agent this stays read-only; with build it lets the model apply edits without
# blocking on interactive prompts (that's the point of delegating).
args=(run --agent "$agent" --auto)
[ -n "$model" ] && args+=(-m "$model")

exec opencode "${args[@]}" "$prompt"
