#!/usr/bin/env bash
#
# ask.sh — let Claude Code consult or delegate to another LLM via opencode.
#
# opencode handles model access and auth (subscription/OAuth — no API keys needed
# here). This script is the single entry point the /consult, /delegate, /panel and
# /collaborate slash commands shell out to.
#
# Usage:
#   collab/ask.sh [-m provider/model] [-a plan|build] [--edit] [--allow-dirty] <prompt...>
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
#   --allow-dirty       Skip the clean-worktree guard on the write path. By default,
#                       when a write-capable agent (collab-build/build) is used, the
#                       wrapper refuses to run if `git status` shows uncommitted
#                       changes (so the model's edits stay attributable and your work
#                       isn't clobbered) and prints the pre-edit HEAD to diff against.
#                       --allow-dirty overrides the refusal. Read-only calls skip it.
#
# Examples:
#   collab/ask.sh "Critique this migration plan: ..."          # read-only opinion
#   collab/ask.sh -m google/gemini-2.5-pro "Second opinion..." # specific model
#   collab/ask.sh --edit "Add input validation to parser.c"    # delegate coding
#
# Model policy: the requested -m model is checked against a deny/ask/allow policy.
# The policy file is resolved as: $COLLAB_POLICY if set, else a git-ignored personal
# collab/models.policy.local if present (written by /configure-collab), else the
# shipped collab/models.policy. A `deny` model is refused; an `ask` model requires
# $COLLAB_CONFIRMED=1 (Claude sets it only after confirming with the user).
#
# Config: your persistent default model lives in collab/collab.conf.local (git-ignored,
#      written by /configure-collab) as `COLLAB_MODEL=provider/model`. $COLLAB_CONF
#      overrides the file path. The env var $COLLAB_MODEL still works as a one-off
#      override for a single shell/call (precedence: -m flag > $COLLAB_MODEL > file).
#
# Env: $COLLAB_MODEL (one-off default-model override), $COLLAB_TIMEOUT (seconds; unset = no timeout,
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

# _has_rules <file> — true if the file exists and has ≥1 allow/ask/deny rule line.
_has_rules() { [ -f "$1" ] && grep -qE '^[[:space:]]*(allow|ask|deny)([[:space:]]|$)' "$1" 2>/dev/null; }

# Policy file resolution: $COLLAB_POLICY wins if set; otherwise prefer a personal,
# git-ignored collab/models.policy.local (what /configure-collab writes) — but ONLY
# if it actually has rules, so an empty or comment-only .local (e.g. a half-written
# file from a crashed setup) can't silently VOID a committed/shared deny set. Else
# the shipped default.
if [ -n "${COLLAB_POLICY:-}" ]; then
  policy_file="$COLLAB_POLICY"
elif _has_rules "$(dirname "$0")/models.policy.local"; then
  policy_file="$(dirname "$0")/models.policy.local"
else
  policy_file="$(dirname "$0")/models.policy"
fi

# policy_tier <model> — echo the deny/ask/allow tier for a model per the policy
# file (first matching glob wins). Defaults to allow: no file, no model id, or no
# match all mean "allowed", so the policy only ever restricts, never surprises.
policy_tier() {
  local model="$1" tier pat
  [ -n "$model" ] || { echo allow; return; }        # unknown default model: can't police
  [ -f "$policy_file" ] || { echo allow; return; }  # no policy file: default-allow
  # Fail CLOSED if the policy exists but can't be read: we can't tell whether the
  # model is denied, so refuse rather than silently allow (the `done < file` redirect
  # would otherwise fail, the loop skip, and control fall through to `echo allow`).
  if [ ! -r "$policy_file" ]; then
    echo "error: policy file '$policy_file' exists but is unreadable — refusing (fail-closed)." >&2
    echo deny; return
  fi
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

# Config file — persistent per-user preferences. Env vars can't hold these durably
# for this tool (Claude's setup command runs in a subshell and can't export into your
# interactive shell), so the default model lives in a file instead. Resolution:
# $COLLAB_CONF if set, else a git-ignored collab/collab.conf.local. Simple KEY=value
# lines (`#` comments); it is NOT sourced (no code execution).
if [ -n "${COLLAB_CONF:-}" ]; then conf_file="$COLLAB_CONF"
elif [ -f "$(dirname "$0")/collab.conf.local" ]; then conf_file="$(dirname "$0")/collab.conf.local"
else conf_file=""; fi

# conf_get <KEY> — value of KEY from $conf_file (last assignment wins), or empty.
# Accepts only `KEY=value` lines; comments/blanks ignored; one layer of surrounding
# quotes stripped. Portable awk (octal \047 = single quote, for mawk/BSD).
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

# Default model precedence: -m flag (parsed below) > $COLLAB_MODEL (one-off override)
# > config file > opencode's own default (empty here).
model="${COLLAB_MODEL:-}"
[ -n "$model" ] || model="$(conf_get COLLAB_MODEL)"
agent="collab-read"  # our read-only agent: denies mutation (bash/edit/write), secret
                     # reads (.env/keys/creds) and network egress (webfetch/websearch)
                     # at opencode's permission layer — read-only + no-egress by
                     # construction, not model compliance. Proven by
                     # collab/verify-collab-read.sh. Falls back to `plan` (weaker) if
                     # the def is missing — see below.
session=""      # opencode session id to continue (Option B multi-turn), forwarded via -s
emit_session="" # when set, emit "SESSION: <id>" + the extracted answer (for /collaborate)
dry_run=""      # when set, print the opencode command and exit without running it
allow_dirty=""  # when set, skip the clean-worktree guard on the write (--edit) path

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
    --allow-dirty) allow_dirty=1; shift ;;
    --edit) agent="collab-build"; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

prompt="$*"
[ -z "$prompt" ] && { echo "error: no prompt given" >&2; usage; }

# Reject a model id starting with '-'. The -m flag already blocks this (need_arg),
# but a value from $COLLAB_MODEL or the config file bypasses that and would be emitted
# verbatim as `-m <value>`, injecting an unintended opencode flag. Not a shell/code
# risk (it's passed as a quoted argv element), but refuse it for a clean error.
case "$model" in
  -*) echo "error: model id '$model' starts with '-' (from env or config) — refusing to avoid injecting an opencode flag." >&2; exit 2 ;;
esac

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

# Clean-worktree guard for the WRITE path. When a write-capable agent (collab-build,
# or the built-in build) is about to edit files, protect the caller's uncommitted
# work and keep the delegated changes cleanly attributable: refuse a dirty tree
# unless --allow-dirty, and record the pre-delegation HEAD so the caller can review
# exactly what the model changed (`git diff <sha>`). Read-only agents skip this.
case "$agent" in
  collab-build|build)
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      dirty="$(git status --porcelain 2>/dev/null)"
      head_sha="$(git rev-parse --short HEAD 2>/dev/null || echo '(no commits yet)')"
      if [ -z "$allow_dirty" ] && [ -n "$dirty" ]; then
        {
          echo "error: refusing to delegate an edit on a DIRTY worktree — the model's changes would be"
          echo "indistinguishable from your uncommitted work and could overwrite it. Commit or stash"
          echo "first, or re-run with --allow-dirty to override."
          echo "  (git status --short:)"
          printf '%s\n' "$dirty"
        } >&2
        exit 6
      fi
      echo "collab: pre-delegation HEAD=${head_sha} — review the model's changes with: git diff ${head_sha}" >&2
      [ -n "$allow_dirty" ] && [ -n "$dirty" ] \
        && echo "collab: --allow-dirty — worktree already had uncommitted changes; the diff will mix them with the model's edits." >&2
    else
      echo "warning: not a git worktree — cannot protect uncommitted work or record a diff baseline for this delegated edit." >&2
    fi ;;
esac

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
