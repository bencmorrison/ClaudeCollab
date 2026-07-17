#!/usr/bin/env bash
#
# ask.sh — let Claude Code consult or delegate to another LLM via opencode.
#
# opencode handles model access and auth (subscription/OAuth — no API keys needed
# here). This script is the single entry point the /collab:consult, /collab:delegate,
# /collab:panel, /collab:workshop, /collab:review, /collab:research,
# /collab:collaborate, and /collab:witness slash commands shell out to.
#
# Usage:
#   collab/ask.sh [-m provider/model] [-a plan|build] [--edit|--research|--watch] <prompt...>
#
#   -m provider/model   Pick the model (run `opencode models` to list options).
#                       Defaults to $COLLAB_MODEL, else opencode's own default.
#   -a <agent>          opencode agent. Default `collab-read` (our hard-deny
#                       read-only agent: no bash/write/edit/grep/glob, but web allowed — see
#                       .opencode/agent/collab-read.md, proven by
#                       collab/verify-collab-read.sh). `collab-build` can edit files
#                       but denies task + tool-native web/search + secret reads;
#                       `collab-research` can read + reach the web but not mutate;
#                       `collab-watch` can read only collab/logs/** and has no other
#                       tools; it never falls back;
#                       `build` is opencode's unrestricted editor; `plan` is
#                       opencode's compliance-only read-only agent.
#   --edit              Shorthand for `-a collab-build` — let the other model change
#                       files (edit/write/patch/bash), but with task + tool-native web/search
#                       + secret reads denied at the tool layer. Falls back to the
#                       unrestricted `build` agent if the collab-build def is missing.
#   --watch             Shorthand for `-a collab-watch` — the OVERSIGHT path (/collab:witness).
#                       The agent can read collab/logs/** and nothing else: no shell,
#                       no search/glob, no egress, no other file. Used to audit whether
#                       Claude's account of an exchange matches what the models really
#                       said. Prefers $COLLAB_WATCH_MODEL, REFUSES a Claude model
#                       unless COLLAB_CONFIRMED=1 (exit 8 — Claude is the party under
#                       audit), and has NO fallback: a missing def is exit 5, because
#                       a weaker agent could read the source and "audit" that instead.
#   --research          Shorthand for `-a collab-research` — let the other model reach
#                       the WEB (webfetch/websearch) and read non-secret files, with
#                       mutation/bash/grep/glob/task denied. Read + egress together is
#                       an exfiltration channel by design (see the agent def); use it
#                       on repos whose non-secret contents you'd accept leaking. Falls
#                       back to `plan` (weaker) if the collab-research def is missing.
#   -s, --session <id>  Continue an existing opencode session (multi-turn dialogue).
#   --emit-session      Print "SESSION: <id>\n---\n<answer>" so a caller can capture
#                       the session id and continue with -s (used by /collab:collaborate,
#                       Option B: opencode carries the peer's turns, not Claude).
#                       Requires `jq`.
#   --dry-run           Print the exact opencode command that WOULD run (safely
#                       quoted) and exit 0 without calling any model. Token-free;
#                       use it to inspect model/agent selection or in tests.
#   --allow-dirty       Legacy no-op compatibility flag. Dirty worktrees are allowed.
#
# Examples:
#   collab/ask.sh "Critique this migration plan: ..."          # read-only opinion
#   collab/ask.sh -m google/gemini-2.5-pro "Second opinion..." # specific model
#   collab/ask.sh --edit "Add input validation to parser.c"    # delegate coding
#   collab/ask.sh --research "What changed in Swift 6 strict concurrency?"  # web
#
# Model policy: the requested -m model is checked against a deny/ask/allow policy.
# The policy file is resolved as: $COLLAB_POLICY if set, else a git-ignored personal
# collab/models.policy.local if present (written by /collab:configure), else the
# shipped collab/models.policy. A `deny` model is refused; an `ask` model requires
# $COLLAB_CONFIRMED=1 (Claude sets it only after confirming with the user).
#
# Config: your persistent default model lives in collab/collab.conf.local (git-ignored,
#      written by /collab:configure) as `COLLAB_MODEL=provider/model`. $COLLAB_CONF
#      overrides the file path. The env var $COLLAB_MODEL still works as a one-off
#      override for a single shell/call (precedence: -m flag > $COLLAB_MODEL > file).
#
# Logging: every call is recorded to a git-ignored collab/logs/<run_id>/calls.jsonl —
#      raw, untruncated, three entries per call (expected → started → completed).
#      This is the
#      evidence layer a watcher agent audits INSTEAD of Claude's own summary; see
#      collab/log.sh for the format, the knobs ($COLLAB_LOG, $COLLAB_LOG_PROMPTS,
#      $COLLAB_LOG_RETENTION_DAYS) and what it deliberately does not claim.
#      $COLLAB_RUN_ID groups several calls into one run (a /collab:panel or /collab:workshop sets it
#      once); $COLLAB_COMMAND records which slash command drove the call.
#
# Env: $COLLAB_MODEL (one-off default-model override), $COLLAB_TIMEOUT (seconds; unset = no timeout,
#      so long-running model/coding work is never cut off), $COLLAB_REQUIRE_HARDENED
#      (=1: hard-fail with exit 5 instead of falling back to a weaker/unrestricted
#      agent when the collab-read/collab-build/collab-research def is missing — for
#      automated/CI use),
#      $COLLAB_LOG / $COLLAB_LOG_DIR / $COLLAB_LOG_PROMPTS / $COLLAB_RUN_ID /
#      $COLLAB_COMMAND (see Logging above), $COLLAB_WATCH_MODEL (the model --watch
#      prefers; env or collab.conf.local), $COLLAB_AGENT_DIR (where the wrapper looks
#      for the collab-* agent DEFS to decide fallback; env or collab.conf.local;
#      default $(dirname "$0")/../.opencode/agent — governs ONLY the fallback check,
#      NOT how opencode resolves --agent; see the resolution note below).
#
# Exit codes: 3 = model denied by policy, 4 = model gated `ask` unconfirmed,
#      5 = required-hardened def missing (always, for --watch), 8 = --watch would run a
#      Claude model (Claude auditing Claude). (6 was a dirty-worktree refusal on the
#      write path; removed — delegating onto live uncommitted work is the point, and a
#      snapshot serves it better than a refusal. See the write-path block below.)
#
set -euo pipefail

usage() {
  # Print the header comment block (everything after the shebang, up to the
  # first non-comment line) with the leading "# " stripped. Range-independent
  # so it stays correct as the header grows or shrinks.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-1}"
}

# _has_rules <file> — true if the file has at least one complete tier + pattern rule.
# A bare `deny` is malformed, not a rule: it must not shadow the committed policy.
_has_rules() {
  [ -f "$1" ] && awk '
    /^[[:space:]]*(#|$)/ { next }
    $1 ~ /^(allow|ask|deny)$/ && NF >= 2 && $2 !~ /^#/ { found=1; exit }
    END { exit !found }' "$1" 2>/dev/null
}

# Policy file resolution: $COLLAB_POLICY wins if set; otherwise prefer a personal,
# git-ignored collab/models.policy.local (what /collab:configure writes) — but ONLY
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
  local model="$1" tier pat rest line line_no=0 matched=""
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
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no+1)); tier=""; pat=""; rest=""
    read -r tier pat rest <<< "$line"
    case "$tier" in ''|'#'*) continue ;; esac        # skip blanks / comments
    case "$tier" in
      allow|ask|deny)
        if [ -z "$pat" ] || [[ "$pat" = \#* ]] || { [ -n "$rest" ] && [[ "$rest" != \#* ]]; }; then
          echo "error: malformed model policy rule at ${policy_file}:${line_no}: expected '<allow|ask|deny> <glob-pattern> [# comment]' — refusing (fail-closed)." >&2
          echo deny; return
        fi ;;
      *)
        echo "error: malformed model policy rule at ${policy_file}:${line_no}: unknown tier '$tier' — refusing (fail-closed)." >&2
        echo deny; return ;;
    esac
    if [ -z "$matched" ] && [ -n "$model" ]; then
      # shellcheck disable=SC2254 # $pat is intentionally a glob pattern
      case "$model" in $pat) matched="$tier" ;; esac
    fi
  done < "$policy_file"
  # An unknown opencode default cannot be matched, but the policy is still parsed so
  # malformed active lines are never silently accepted merely because -m was omitted.
  echo "${matched:-allow}"
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

# Agent-def directory — where the wrapper looks for the collab-* defs to decide
# whether to FALL BACK to a weaker built-in agent. Resolved ONCE, here, with the
# precedence: $COLLAB_AGENT_DIR (env, one-off override) > collab.conf.local value >
# the sibling .opencode/agent (today's per-project layout). Unset/unconfigured yields
# exactly "$(dirname "$0")/../.opencode/agent", so existing installs are byte-identical.
#
# THIS GOVERNS ONLY THE WRAPPER'S FALLBACK DECISION. opencode itself resolves `--agent`
# INDEPENDENTLY, from its OWN config (the CWD project's .opencode/agent or opencode's
# global config dir) — nothing here changes how opencode is invoked. So whatever sets
# COLLAB_AGENT_DIR MUST point at the same directory the installer actually placed the
# defs in, or the wrapper's "def present" check and opencode's resolution disagree: the
# wrapper could believe a hardened def is enforced while opencode runs a different (or
# fallback) agent. For collab-watch, whose check is a no-fallback security gate, that is
# a silent oversight failure. (Reviewer finding — PLAN.md "Global install", change B.)
agent_def_dir="${COLLAB_AGENT_DIR:-$(conf_get COLLAB_AGENT_DIR)}"
[ -n "$agent_def_dir" ] || agent_def_dir="$(dirname "$0")/../.opencode/agent"

agent="collab-read"  # our read-only agent: denies mutation (bash/edit/write), grep/glob,
                     # subagents, and secret reads (.env/keys/creds) at opencode's
                     # permission layer; webfetch/websearch are allowed, so this is
                     # not an exfiltration boundary. Proven by
                     # collab/verify-collab-read.sh. Falls back to `plan` (weaker) if
                     # the def is missing — see below.
session=""      # opencode session id to continue (Option B multi-turn), forwarded via -s
emit_session="" # when set, emit "SESSION: <id>" + the extracted answer (for /collab:collaborate)
dry_run=""      # when set, print the opencode command and exit without running it
model_explicit="" # set when -m was passed, so --watch won't override a deliberate choice

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
    -m) need_arg -m "${2:-}"; model="$2"; model_explicit=1; shift 2 ;;
    -a) need_arg -a "${2:-}"; agent="$2"; shift 2 ;;
    -s|--session) need_arg "$1" "${2:-}"; session="$2"; shift 2 ;;
    --emit-session) emit_session=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --allow-dirty) shift ;; # legacy no-op: dirty worktrees are allowed
    --edit) agent="collab-build"; shift ;;
    --research) agent="collab-research"; shift ;;
    --watch) agent="collab-watch"; shift ;;
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

# Soft-validate the agent: these are the ones this repo ships and reasons about. A
# custom agent is allowed (opencode may define others), but flag it so a typo like
# '-a paln' doesn't silently run an unintended/again-fallback agent.
case "$agent" in
  collab-read|collab-build|collab-research|collab-watch|plan|build) ;;
  *) echo "note: '-a $agent' is not one of collab-read|collab-build|collab-research|collab-watch|plan|build; using it as-is." >&2 ;;
esac

# ---- the oversight path (--watch / /collab:witness) --------------------------------
# Three rules apply here that apply nowhere else, because this agent's job is to
# check up on Claude and each exists to stop that check quietly becoming worthless.
#
# The def check comes FIRST: if the def is missing AND the model is a Claude one,
# "reinstall the def" is the actionable error, and the model complaint would just
# send the user chasing the wrong thing.
if [ "$agent" = "collab-watch" ] && [ ! -f "$agent_def_dir/collab-watch.md" ]; then
  echo "error: collab-watch agent def not found. Refusing to fall back — any weaker agent can read the" >&2
  echo "repo's source and would 'audit' that instead of the log, which is not oversight. Reinstall it." >&2
  exit 5
fi

if [ "$agent" = "collab-watch" ]; then
  # The watch agent's read map permits only collab/logs/**. Validate the effective
  # configured evidence root itself; prompt wording cannot widen a tool permission.
  # Resolve symlinks and `..` without GNU realpath (not shipped by macOS/BSD).
  # Resolve the deepest existing directory physically, then normalize any missing
  # suffix lexically; no files or directories are created by this check.
  _canonical_dir_path() {
    local input="$1" probe parent base canon part
    local -a suffix=()
    case "$input" in /*) probe="$input" ;; *) probe="$PWD/$input" ;; esac
    while [ "$probe" != "/" ] && [ ! -d "$probe" ]; do
      while [ "$probe" != "/" ] && [[ "$probe" = */ ]]; do probe="${probe%/}"; done
      # `${suffix[@]+"${suffix[@]}"}` guards the empty case: under `set -u`, bash 3.2
      # (stock macOS) treats an empty array's [@] expansion as unbound and aborts.
      # Both sites below hit it — this one on the first iteration (suffix still
      # empty), and the loop below whenever the input is an existing directory, so
      # the while loop never runs. That made this function fail on macOS either way.
      base="${probe##*/}"; suffix=("$base" ${suffix[@]+"${suffix[@]}"})
      parent="${probe%/*}"; [ -n "$parent" ] || parent="/"; probe="$parent"
    done
    [ -d "$probe" ] || return 1
    canon="$(cd -P -- "$probe" 2>/dev/null && pwd -P)" || return 1
    for part in ${suffix[@]+"${suffix[@]}"}; do
      case "$part" in
        ''|.) ;;
        ..) canon="${canon%/*}"; [ -n "$canon" ] || canon="/" ;;
        *) canon="${canon%/}/$part" ;;
      esac
    done
    printf '%s\n' "$canon"
  }
  watch_log_dir="${COLLAB_LOG_DIR:-$(conf_get COLLAB_LOG_DIR)}"
  [ -n "$watch_log_dir" ] || watch_log_dir="$(dirname "$0")/logs"
  watch_log_dir_abs="$(_canonical_dir_path "$watch_log_dir" || true)"
  watch_scope_abs="$(_canonical_dir_path "$(dirname "$0")/logs" || true)"
  case "$watch_log_dir_abs" in
    "$watch_scope_abs"|"$watch_scope_abs"/*) [ -n "$watch_scope_abs" ] ;;
    *) false ;;
  esac || {
    echo "error: --watch cannot read the effective COLLAB_LOG_DIR '$watch_log_dir'." >&2
    echo "The collab-watch agent is mechanically scoped to $(dirname "$0")/logs/**; use that root or a child of it." >&2
    exit 5
  }

  # 1. Model: prefer $COLLAB_WATCH_MODEL (env or config) so the auditor can be pinned
  #    to a different model from the one doing the work, without disturbing the
  #    default used by /collab:consult and friends. An explicit -m still wins.
  if [ -z "$model_explicit" ]; then
    watch_model="${COLLAB_WATCH_MODEL:-$(conf_get COLLAB_WATCH_MODEL)}"
    [ -n "$watch_model" ] && model="$watch_model"
  fi

  # 2. The watcher model must be PINNED. With no -m, no $COLLAB_WATCH_MODEL and no
  #    $COLLAB_MODEL, `model` is empty: no -m reaches opencode, opencode falls back to
  #    ITS OWN configured default — and the Claude check below never fires, because an
  #    empty string matches no pattern. If that default is a Claude model, Claude
  #    audits Claude and nothing says a word. The refusal below is worthless unless we
  #    know what we're refusing, and we only know that if the id is explicit.
  #    (Found by dogfooding /collab:review on this very commit — the guarantee held only in
  #    the case that had been tested.)
  if [ -z "$model" ]; then
    {
      echo "error: the watcher model must be named explicitly. With no model id, opencode would fall back"
      echo "to its own default — which may be a Claude model, and Claude is the party under audit. This"
      echo "wrapper cannot check a model it hasn't been told about."
      echo "Set COLLAB_WATCH_MODEL (env or collab/collab.conf.local), or pass -m <provider/model>."
    } >&2
    exit 8
  fi

  # 3. Refuse to let Claude audit Claude unless the user explicitly says so. An
  #    auditor from the same family as the party under audit is not the independent
  #    view /collab:witness claims to provide — and the developer would have no way to tell
  #    from the report. This is a fail-CLOSED heuristic on the model id, not a
  #    policy tier: the policy ships default-allow and Anthropic is never denied
  #    there (see AGENTS.md), so the check has to live here.
  case "$model" in
    anthropic/*|*claude*|*Claude*)
      if [ -z "${COLLAB_CONFIRMED:-}" ]; then
        {
          echo "error: refusing to run the watcher on '$model' — that is a Claude model, and Claude is the"
          echo "party under audit. An auditor from the same family is not the independent check /collab:witness"
          echo "reports itself to be. Pick a non-Claude model (COLLAB_WATCH_MODEL, or -m), or, if you"
          echo "genuinely want this, confirm with the user and re-run with COLLAB_CONFIRMED=1."
        } >&2
        exit 8
      fi
      echo "warning: watcher model '$model' is a Claude model — Claude is auditing Claude (you confirmed this)." >&2 ;;
  esac
fi

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
if [ "$agent" = "collab-read" ] && [ ! -f "$agent_def_dir/collab-read.md" ]; then
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
if [ "$agent" = "collab-build" ] && [ ! -f "$agent_def_dir/collab-build.md" ]; then
  if [ -n "${COLLAB_REQUIRE_HARDENED:-}" ]; then
    echo "error: collab-build agent def not found and COLLAB_REQUIRE_HARDENED=1 — refusing to fall back to the unrestricted 'build' agent." >&2
    exit 5
  fi
  echo "warning: collab-build agent def not found; falling back to opencode's 'build' — UNRESTRICTED (no task/webfetch/websearch or secret-read denies)." >&2
  agent="build"
fi

# Same idea for the --research path: if the collab-research def is missing, fall back
# to `plan` (never `build`) — it's read-capable and web-capable enough for research,
# but it's compliance-only: it does not deny bash, secret reads, or grep/glob. Since
# this path has network egress, a downgrade here means secrets could be both read AND
# exfiltrated, so the warning matters more than on the collab-read path.
if [ "$agent" = "collab-research" ] && [ ! -f "$agent_def_dir/collab-research.md" ]; then
  if [ -n "${COLLAB_REQUIRE_HARDENED:-}" ]; then
    echo "error: collab-research agent def not found and COLLAB_REQUIRE_HARDENED=1 — refusing to fall back to a weaker agent." >&2
    exit 5
  fi
  echo "warning: collab-research agent def not found; falling back to opencode's 'plan' — WEAKER (compliance-only; does not deny bash, secret reads, or grep/glob) and this path has network egress." >&2
  agent="plan"
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

# Baseline snapshot for the WRITE path — NOT a guard.
#
# There used to be a clean-worktree refusal here (exit 6). It has been removed: it was
# unjustified asymmetry. Spinning up an Anthropic subagent to edit these same files
# gets no worktree guard, no snapshot, no quarantine — and a delegated model is the
# same class of actor: an LLM editing files a human then reviews. Demanding a commit
# first blocked the actual use case (collaborating on live, uncommitted work) for a
# reason that a subagent doesn't equally trigger. (The one real asymmetry is `--auto`,
# which auto-approves tool calls with no human in the loop — that's a harness
# difference, and it's answered by the agent permission maps, not by this.)
#
# What replaces it costs the caller nothing and never blocks: snapshot the worktree as
# a git tree BEFORE the model runs. `git write-tree` against a throwaway index records
# tracked edits AND untracked files without touching the worktree or the caller's real
# index. That buys two things a HEAD baseline can't:
#   * exact attribution on a dirty tree — the diff afterwards is the model's changes
#     only, with the caller's in-progress work excluded rather than blended in;
#   * recovery — the tree is in the object database, so work the model overwrites can
#     be restored (`git checkout <tree> -- <path>`). The old guard didn't offer that;
#     it just refused.
# `git add -A` honours .gitignore, so .env / collab/logs stay out of the snapshot.
_snapshot_tree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local idx tree; idx="$(mktemp -u)" || return 1
  GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null || GIT_INDEX_FILE="$idx" git read-tree --empty 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git add -A 2>/dev/null || true
  tree="$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null || true)"
  rm -f "$idx"
  [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

write_base_tree=""
case "$agent" in
  collab-build|build)
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      write_base_tree="$(_snapshot_tree || true)"
      if [ -n "$write_base_tree" ]; then
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
          echo "collab: worktree has uncommitted changes — proceeding. The model may edit the same files;" >&2
          echo "collab: your current state is snapshotted as tree ${write_base_tree}. Restore a clobbered file with:" >&2
          echo "collab:   git checkout ${write_base_tree} -- <path>" >&2
        fi
      else
        echo "warning: could not snapshot the worktree — the recorded diff may mix your changes with the model's." >&2
      fi
    else
      echo "warning: not a git worktree — no baseline snapshot, and no diff will be recorded for this delegated edit." >&2
    fi ;;
esac

# Echo the resolved selection to stderr (stdout carries only the model's answer /
# the SESSION payload). Cheap observability into what actually ran.
echo "collab: model=${model:-<opencode default>} agent=${agent}${session:+ session=$session}" >&2

# ---- evidence layer (W0) -----------------------------------------------------
# Record this call to collab/logs/ so a watcher agent can later audit what the other
# model ACTUALLY said, independently of Claude's summary of it. Three writes
# (expected → started → completed) paired by call_id ensure setup failure and a call
# that dies mid-flight both leave an integrity gap. See collab/log.sh.
#
# Logging is best-effort and must NEVER fail the call it is recording: every hook is
# `|| true`. A missing entry is not silently benign — `log.sh verify` catches the
# unpaired `started`, and /collab:witness refuses to audit a failed-integrity log.
log_sh="$(dirname "$0")/log.sh"
log_enabled=""
call_id=""
turn=""
prompt_file=""
log_setting="${COLLAB_LOG:-$(conf_get COLLAB_LOG)}"
if [ "${log_setting:-on}" != "off" ] && [ -f "$log_sh" ] && command -v jq >/dev/null 2>&1; then
  # Resolve the run ONCE and export it. A slash command that groups several calls
  # (/collab:panel, /collab:workshop) sets $COLLAB_RUN_ID itself so the whole workflow is one
  # auditable unit; a standalone call mints its own run here. Without pinning it,
  # each `log.sh` invocation below would mint a *different* run id and scatter one
  # call across three directories.
  COLLAB_RUN_ID="${COLLAB_RUN_ID:-$(bash "$log_sh" new-run "${COLLAB_COMMAND:-ask}" 2>/dev/null || true)}"
  # Every step here is guarded, including the mktemps. `set -e` is on, so an
  # unguarded `prompt_file="$(mktemp)"` on a full or unwritable TMPDIR would abort
  # ask.sh outright — the audit log killing the very call it exists to record. If any
  # of this fails we silently run without logging; the call is what matters, and the
  # missing entry surfaces in `log.sh verify`, not as a false success.
  if [ -n "$COLLAB_RUN_ID" ]; then
    export COLLAB_RUN_ID
    call_id="c-$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x%04x' "$RANDOM" "$$")"
    if bash "$log_sh" expect --call-id "$call_id" --command "${COLLAB_COMMAND:-ask}" \
         --model "$model" --agent "$agent" >/dev/null 2>&1; then
      log_enabled=1
    fi
    prompt_file="$(mktemp 2>/dev/null || true)"
    if [ -n "$log_enabled" ] && [ -n "$prompt_file" ] && printf '%s' "$prompt" > "$prompt_file" 2>/dev/null; then
      turn="$(bash "$log_sh" started \
                --call-id "$call_id" --command "${COLLAB_COMMAND:-ask}" --model "$model" \
                --agent "$agent" ${session:+--session "$session"} --prompt-file "$prompt_file" 2>/dev/null || true)"
      echo "collab: log=$(bash "$log_sh" path 2>/dev/null || echo '?') call_id=${call_id}" >&2
    elif [ -n "$log_enabled" ]; then
      echo "warning: could not open the evidence log (no writable temp dir?); continuing WITHOUT a record of this call." >&2
      prompt_file=""
    fi
  fi
fi

# Fingerprint a bounded set of ignored regular files without retaining names or bytes.
# Non-regular/unreadable files and limit overruns are explicitly INCOMPLETE before any
# content open, so FIFOs/devices cannot block this path and huge ignored trees cannot
# trigger unbounded hashing. The aggregate digest is ephemeral and is never logged.
_ignored_fingerprint() {
  local max_files=1024 max_bytes=16777216 max_walk=16384 count=0 total=0 p size digest
  local manifest status_file walk_status_file list_status="" walk_status="" incomplete=""
  manifest="$(mktemp 2>/dev/null || true)"; status_file="$(mktemp 2>/dev/null || true)"
  walk_status_file="$(mktemp 2>/dev/null || true)"
  if [ -z "$manifest" ] || [ -z "$status_file" ] || [ -z "$walk_status_file" ]; then
    rm -f "$manifest" "$status_file" "$walk_status_file" 2>/dev/null || true
    printf 'incomplete:setup-unavailable\n'; return 0
  fi
  # Git's ignored-file listing omits special files such as FIFOs. Its porcelain
  # ignored view does report a matching ignored directory, so treat any such
  # directory as unmonitorable rather than walking it or opening its contents.
  while IFS= read -r -d '' p; do
    case "$p" in
      '!! collab/logs/'*) continue ;;
      '!! '*/ ) incomplete="ignored-directory"; break ;;
    esac
    count=$((count+1))
    if [ "$count" -gt "$max_files" ]; then incomplete="file-limit"; break; fi
  done < <(git status --porcelain=1 --ignored=matching --untracked-files=all -z 2>/dev/null)
  # Git omits FIFOs and some other special files from both ignored-file listings.
  # Walk metadata only, with a hard entry cap, and ask Git whether each special path
  # is ignored. No path is opened and no name is retained in the evidence record.
  count=0
  while [ -z "$incomplete" ] && IFS= read -r -d '' p; do
    count=$((count+1))
    if [ "$count" -gt "$max_walk" ]; then incomplete="walk-limit"; break; fi
    [ -d "$p" ] && continue
    if { [ -L "$p" ] || [ ! -f "$p" ]; } && git check-ignore -q -- "$p" 2>/dev/null; then
      incomplete="unsupported-path"; break
    fi
  done < <(find . -xdev -path ./.git -prune -o -path ./collab/logs -prune -o -print0 2>/dev/null; printf '%s' "$?" > "$walk_status_file")
  walk_status="$(cat "$walk_status_file" 2>/dev/null || true)"
  if [ -z "$incomplete" ] && [ "$walk_status" != 0 ]; then incomplete="walk-failed"; fi
  count=0
  while [ -z "$incomplete" ] && IFS= read -r -d '' p; do
    # The logger's own ignored output is evidence infrastructure, not delegated work.
    case "$p" in collab/logs/*) continue ;; esac
    count=$((count+1))
    if [ "$count" -gt "$max_files" ]; then incomplete="file-limit"; break; fi
    # Test type before readability/open. Symlinks, FIFOs, sockets and devices cannot
    # be represented by the patch and are never opened here.
    if [ -L "$p" ] || [ ! -f "$p" ]; then incomplete="unsupported-path"; break; fi
    if [ ! -r "$p" ]; then incomplete="unreadable-path"; break; fi
    size="$(stat -c %s -- "$p" 2>/dev/null || stat -f %z -- "$p" 2>/dev/null || true)"
    case "$size" in ''|*[!0-9]*) incomplete="metadata-unavailable"; break ;; esac
    if [ "$size" -gt $((max_bytes-total)) ]; then incomplete="byte-limit"; break; fi
    total=$((total+size))
    digest="$(git hash-object --no-filters -- "$p" 2>/dev/null || true)"
    if [ -z "$digest" ]; then incomplete="read-failed"; break; fi
    printf '%s\0%s\0' "$p" "$digest" >> "$manifest"
  done < <(git ls-files --others --ignored --exclude-standard -z 2>/dev/null; printf '%s' "$?" > "$status_file")
  list_status="$(cat "$status_file" 2>/dev/null || true)"
  if [ -n "$incomplete" ] || [ "$list_status" != 0 ]; then
    printf 'incomplete:%s\n' "${incomplete:-enumeration-failed}"
  else
    digest="$(git hash-object --stdin < "$manifest" 2>/dev/null || true)"
    if [ -n "$digest" ]; then printf 'complete:%s\n' "$digest"
    else printf 'incomplete:digest-unavailable\n'; fi
  fi
  rm -f "$manifest" "$status_file" "$walk_status_file"
}
ignored_before=""
submodules_before="clean"
_submodule_state() {
  local key path state
  [ -f .gitmodules ] || { printf 'clean\n'; return; }
  git submodule status --recursive >/dev/null 2>&1 || { printf 'unavailable\n'; return; }
  state="$(git status --porcelain=v2 --ignore-submodules=none 2>/dev/null)" || {
    printf 'unavailable\n'; return
  }
  if printf '%s\n' "$state" | awk '$1=="1" && $3 ~ /^S/ && $3 != "S..." { found=1 } END { exit !found }'; then
    printf 'dirty\n'; return
  fi
  while read -r key path; do
    [ -n "$key" ] && [ -n "$path" ] || continue
    # Parent Git marks a dirty submodule gitlink even though write-tree records only
    # its committed object id. Check that signal before inspecting nested status.
    if ! git diff-files --quiet --ignore-submodules=none -- "$path" 2>/dev/null; then
      printf 'dirty\n'; return
    fi
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    state="$(git -C "$path" status --porcelain --untracked-files=normal 2>/dev/null)" || {
      printf 'unavailable\n'; return
    }
    [ -z "$state" ] || { printf 'dirty\n'; return; }
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  printf 'clean\n'
}
case "$agent" in
  collab-build|build)
    if [ -n "$write_base_tree" ]; then
      ignored_before="$(_ignored_fingerprint || true)"
      submodules_before="$(_submodule_state)"
    fi ;;
esac
delegate_capture_failed=""

# record_delegate_diff — capture what the model ACTUALLY changed, into the evidence log.
#
# This is not containment; it is the record. `/collab:witness` can only read
# collab/logs/**, so without this a delegation is auditable only through the model's own
# report of what it did — the watcher could check whether Claude relayed the model's
# CLAIMS faithfully, while the thing worth auditing (does the diff match the report?)
# stayed invisible. PLAN W0.4 promised these snapshots a home; this fills it.
#
# It also fixes a real blind spot in the review itself: `git diff <sha>` does NOT show
# files the model CREATED, so a delegation that adds a file produced an empty diff.
# `git add -A` into a throwaway index makes created files part of the tree, so the
# recorded patch is complete regardless of what the model did.
record_delegate_diff() {
  [ -n "$log_enabled" ] || return 0
  case "$agent" in collab-build|build) ;; *) return 0 ;; esac
  local after="" patch rd ignored_after submodules_after complete=true reason=""
  rd="$(bash "$log_sh" dir 2>/dev/null || true)"
  if [ -z "$rd" ]; then
    delegate_capture_failed=1
    echo "warning: delegated-change capture failed: evidence run directory unavailable." >&2
    return 0
  fi
  patch="$rd/diff-${call_id}.patch"
  if [ -z "$write_base_tree" ]; then
    complete=false; reason="baseline-tree-unavailable"
  else
    after="$(_snapshot_tree || true)"
    [ -n "$after" ] || { complete=false; reason="after-tree-unavailable"; }
  fi
  ignored_after="$(_ignored_fingerprint || true)"
  if [ "$complete" = true ] && { [ -z "$ignored_before" ] || [ -z "$ignored_after" ] \
      || [[ "$ignored_before" = incomplete:* ]] || [[ "$ignored_after" = incomplete:* ]]; }; then
    complete=false; reason="ignored-state-incomplete"
  elif [ "$complete" = true ] && [ "$ignored_before" != "$ignored_after" ]; then
    complete=false; reason="ignored-paths-changed"
  fi
  submodules_after="$(_submodule_state)"
  # Porcelain v2's submodule field is explicit (`S.M.`, `S..U`, etc.). Keep this
  # parent-level check at capture time as the authoritative guard; it does not rely
  # on nested-shell propagation from `git submodule foreach`.
  if git status --porcelain=v2 --ignore-submodules=none 2>/dev/null \
      | grep -Eq '^1 .. S[^ ]*[MU?]'; then
    submodules_after="dirty"
  fi
  if [ "$submodules_before" != clean ] || [ "$submodules_after" != clean ]; then
    complete=false; reason="submodule-worktree-unrepresentable"
  fi
  if [ -n "$write_base_tree" ] && [ -n "$after" ]; then
    if ! git diff-tree --binary -p "$write_base_tree" "$after" > "$patch" 2>/dev/null; then
      : > "$patch"; complete=false; reason="diff-generation-failed"
    fi
  else
    : > "$patch"
  fi
  if [ ! -s "$patch" ] && [ "$complete" = true ]; then
    rm -f "$patch"
    echo "collab: the model changed no tracked files (nothing to review)." >&2
    return 0
  fi
  if ! bash "$log_sh" diff --call-id "$call_id" --patch-file "$patch" \
      --base "$write_base_tree" --after "$after" --complete "$complete" --reason "$reason" >/dev/null 2>&1; then
    delegate_capture_failed=1
  fi
  if [ "$complete" = true ]; then
    echo "collab: the model's changes (complete, incl. created files and binary data) => $patch" >&2
  else
    echo "warning: delegated-change capture is INCOMPLETE ($reason); the log will fail integrity. Ignored names/content were not recorded." >&2
    echo "collab: reviewable non-ignored subset => $patch" >&2
  fi
  echo "collab: review them with:  git apply --stat '$patch'  /  cat '$patch'" >&2
}

# log_complete <exit-status> <response-file> [session-id] — the second half of the
# pair. The session id is passed in because on a NEW session opencode only reveals it
# in the response, so the `started` entry couldn't know it.
log_complete() {
  [ -n "$log_enabled" ] || return 0
  local sid="${3:-$session}" capture_state=failed
  [ -n "${2:-}" ] && [ -f "$2" ] && capture_state=complete
  [ -n "$delegate_capture_failed" ] && capture_state=failed
  bash "$log_sh" completed --call-id "$call_id" --exit "$1" \
    ${turn:+--turn "$turn"} ${sid:+--session "$sid"} \
    --command "${COLLAB_COMMAND:-ask}" --model "$model" --agent "$agent" \
    --capture-state "$capture_state" ${2:+--response-file "$2"} >/dev/null 2>&1 || true
  rm -f "$prompt_file" 2>/dev/null || true
}

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
  # assistant's answer. The caller (/collab:collaborate) captures the id from the SESSION:
  # line and threads it back with -s on later turns, so opencode — not Claude —
  # carries the peer's prior words (fidelity by construction, not by Claude's
  # discipline). Two-stage jq tolerates any stray non-JSON line before slurping.
  command -v jq >/dev/null 2>&1 || { echo "error: --emit-session needs 'jq' (not found)." >&2; exit 127; }
  raw="$(run_opencode "${args[@]}" --format json "$prompt")" || status=$?
  if [ "$status" -eq 124 ]; then
    echo "error: opencode hit \$COLLAB_TIMEOUT=${COLLAB_TIMEOUT:-}s with no response." >&2
    log_complete "$status" ""
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
  # Log the EXTRACTED answer, not the JSON envelope: `text` is precisely what Claude
  # receives, so an audit of Claude's engagement must compare against the same bytes.
  record_delegate_diff
  resp_file="$(mktemp 2>/dev/null || true)"
  if [ -n "$resp_file" ] && printf '%s' "$text" > "$resp_file" 2>/dev/null; then
    log_complete "$status" "$resp_file" "$sid"
    rm -f "$resp_file"
  else
    log_complete "$status" "" "$sid"
  fi
  printf 'SESSION: %s\n---\n%s\n' "$sid" "$text"
  exit "$status"
else
  # tee, not a plain capture: the answer still reaches stdout as it arrives, and the
  # evidence layer gets the full untruncated copy.
  #
  # Read the MODEL's status out of PIPESTATUS[0] rather than the pipeline's. Under
  # `pipefail` the pipeline reports the rightmost non-zero status, so a tee that
  # failed (TMPDIR full, unwritable) would make a perfectly good model call exit
  # non-zero — logging breaking the very call it exists to record, which is the one
  # thing this layer must never do. A failed tee costs us the log entry (and `verify`
  # will show it as a gap), never the answer.
  if [ -n "$log_enabled" ]; then
    resp_file="$(mktemp 2>/dev/null || true)"
  fi
  if [ -n "$log_enabled" ] && [ -n "$resp_file" ]; then
    set +e
    run_opencode "${args[@]}" "$prompt" | tee "$resp_file"
    pipe_status=("${PIPESTATUS[@]}")
    set -e
    status="${pipe_status[0]}"
    if [ "${pipe_status[1]:-0}" -ne 0 ]; then
      echo "warning: could not write the response to the evidence log (tee exited ${pipe_status[1]}); the answer is unaffected, but this call's record is incomplete." >&2
      rm -f "$resp_file"; resp_file=""
    fi
  else
    resp_file=""
    run_opencode "${args[@]}" "$prompt" || status=$?
  fi
  if [ "$status" -eq 124 ]; then
    echo "error: opencode hit \$COLLAB_TIMEOUT=${COLLAB_TIMEOUT:-}s with no response (model '${model:-opencode default}', agent '${agent}'). Raise \$COLLAB_TIMEOUT or re-run." >&2
  elif [ "$status" -ne 0 ]; then
    echo "error: opencode exited $status (model '${model:-opencode default}', agent '${agent}')." >&2
  fi
  record_delegate_diff
  log_complete "$status" "$resp_file"
  [ -n "$resp_file" ] && rm -f "$resp_file" || true
  exit "$status"
fi
