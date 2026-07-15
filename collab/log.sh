#!/usr/bin/env bash
#
# log.sh — the ClaudeCollab evidence layer (Phase W0 of the watcher design; see
# PLAN.md "Watcher agents").
#
# WHY THIS EXISTS. Today the only account a developer gets of whether Claude really
# engaged with another model is *Claude's own summary* — self-report by the party
# under scrutiny. This script is the independent record that makes a watcher agent
# possible at all: `ask.sh` writes every model call here, raw and untruncated, and a
# watcher (Phase W2, `/collab:witness`) reads THIS FILE rather than Claude's account. No
# watcher until the data source exists — a watcher reading Claude's summary is
# theatre.
#
# WHAT IT IS NOT. This is **not** tamper-proofing and makes no chain-of-custody
# claim. The hash chain (`response_hash`/`prev_hash`) is here from day one because
# retrofitting a log format later is painful and old logs would lack it, and because
# it catches accidental corruption cheaply — NOT as a defence against an adversarial
# Claude, which this project's trusted-repo threat model does not assume. Anything
# that can write the log can rewrite the chain.
#
# LAYOUT — one directory per run, so a run's entries, watcher reports and metadata
# have a home (a bare field wasn't enough; reports need somewhere to live):
#   collab/logs/<run_id>/calls.jsonl    the entries (append-only JSONL)
#   collab/logs/<run_id>/reports/       /collab:witness reports land here (Phase W2)
#   collab/logs/latest                  symlink to the most recent run dir
#
# ENTRIES. Every model call writes TWO lines with a status flip: `started` before the
# call and `completed` after. Integrity is defined as **every `started` has a matching
# `completed`** — without the pair, a crash mid-call reads as a clean log, a silent
# gap a watcher cannot detect. The two are paired by **`call_id`, never by
# run_id+turn**: retries and parallel panel calls (a /collab:panel or /collab:workshop round fires
# 2-3 concurrently) break turn-based pairing.
#
# Entry types:
#   started / completed   a model call, written by ask.sh
#   claude-final          Claude's final user-facing answer (W0.5). Without it a
#                         watcher can audit dispositions but NOT the summary the
#                         developer actually read — the thing most worth auditing.
#   claude-disposition    Claude's claimed Adopt/Adapt/Reject/Defer of a model's
#                         point. **These are CLAIMS TO AUDIT, NOT FACTS** — Claude
#                         writing its own disposition record is self-report in new
#                         clothes. A watcher must check each claim against the raw
#                         `completed` responses and the `claude-final` entry.
#
# Usage:
#   log.sh new-run [command]                 mint a run_id (mkdir + prune), print it
#   log.sh latest                            print the most recent run's id
#   log.sh dir  [run_id]                     print the run directory
#   log.sh path [run_id]                     print the calls.jsonl path
#   log.sh started   --call-id <id> --command <c> --model <m> --agent <a> \
#                    [--session <s>] [--prompt-file <f>]      prints the turn number
#   log.sh completed --call-id <id> --exit <n> [--turn <n>] [--session <s>] \
#                    [--command <c>] [--model <m>] [--agent <a>] [--response-file <f>]
#   log.sh final [--run <id>]                claude-final; text on stdin
#   log.sh disposition --model <m> --point <p> --verdict <Adopt|Adapt|Reject|Defer> \
#                    [--why <text>]          claude-disposition (a claim, not a fact)
#   log.sh verify [run_id]                   integrity: every started has a completed
#   log.sh prune [--days <n>]                delete run dirs older than n days
#
# Config: every knob below resolves as env override > collab/collab.conf.local (the
#   git-ignored per-user config; template in collab.conf.example) > default. Set them
#   in the FILE to make them stick: a Claude-driven session runs each command in a
#   subshell, so an `export` cannot durably change how your logging behaves.
#
# Env:
#   COLLAB_LOG=off               disable logging entirely (default: on)
#   COLLAB_LOG_DIR=<dir>         where runs live (default: <repo>/collab/logs)
#   COLLAB_RUN_ID=<id>           group several calls into one run (a slash command
#                                sets this once, so a whole /collab:panel or /collab:workshop is
#                                one auditable unit). Unset = a fresh run per call.
#   COLLAB_LOG_PROMPTS=full|hash|off   what to record of the prompt Claude SENT.
#                                Default `full`: the brief Claude wrote is itself
#                                prime audit material (a /collab:workshop brief that
#                                editorialised is exactly how one real bug was
#                                found), and the logs are git-ignored and local.
#                                But `full` means the log holds whatever private
#                                repo context Claude pasted into a prompt — use
#                                `hash` (record only a digest, enough to prove the
#                                prompt didn't change) or `off` on sensitive work.
#                                Responses are ALWAYS recorded in full: they are the
#                                evidence, and they are the other model's words, not
#                                yours.
#   COLLAB_LOG_RETENTION_DAYS=<n>  prune runs older than this on new-run (default 14).
#                                An unbounded log dir is an indefinite sensitive-data
#                                surface; 0 disables pruning.
#
# Exit codes: 0 ok; 2 usage; 7 integrity failure (`verify`).
#
set -euo pipefail

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-2}"
}

here="$(cd "$(dirname "$0")" && pwd)"

# Config resolution mirrors ask.sh: env is a ONE-OFF override, the durable setting
# lives in the git-ignored collab/collab.conf.local. Env-only knobs would be a trap
# here — a Claude-driven session runs each command in a subshell, so a developer who
# wants prompts kept out of the log permanently has no way to say so with an export.
if [ -n "${COLLAB_CONF:-}" ]; then conf_file="$COLLAB_CONF"
elif [ -f "$here/collab.conf.local" ]; then conf_file="$here/collab.conf.local"
else conf_file=""; fi

conf_get() {  # value of KEY from $conf_file (last assignment wins), or empty
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

cfg() {  # cfg <KEY> <default> — env override > config file > default
  local v="${!1:-}"
  [ -n "$v" ] || v="$(conf_get "$1")"
  [ -n "$v" ] || v="$2"
  printf '%s\n' "$v"
}

# Logging is best-effort infrastructure, never a reason to fail a consult. If it
# can't run we say so once, loudly, and get out of the way — a missing log is
# visible to `verify` and `/collab:witness` refuses to audit one, so a silent gap can't be
# mistaken for a clean record.
LOG_DIR="$(cfg COLLAB_LOG_DIR "$here/logs")"
disabled() { [ "$(cfg COLLAB_LOG on)" = "off" ]; }

# jq builds every entry: hand-rolled JSON escaping of a model's full response (which
# contains quotes, newlines, backslashes and whatever else it felt like emitting) is
# a corruption bug waiting to happen. No jq, no log.
have_jq() { command -v jq >/dev/null 2>&1; }

_sha() {  # stdin -> sha256 hex, or "" if no hasher (BSD/macOS uses shasum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else printf ''; fi
}

_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_rand() {  # short random hex; /dev/urandom where available, else $RANDOM/$$
  if [ -r /dev/urandom ]; then od -An -tx1 -N4 /dev/urandom | tr -d ' \n'
  else printf '%04x%04x' "$RANDOM" "$$"; fi
}

# ---- run resolution ---------------------------------------------------------
# A run_id groups a whole workflow (all three calls of a /collab:panel round, both rounds
# of a /collab:workshop) so a watcher can audit the unit the developer actually asked for.
run_dir() { printf '%s\n' "$LOG_DIR/$1"; }
resolve_run() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"
  elif [ -n "${COLLAB_RUN_ID:-}" ]; then printf '%s\n' "$COLLAB_RUN_ID"
  else printf '%s\n' "$(_now | tr -d ':-')-$(_rand)"   # standalone call = its own run
  fi
}

ensure_run() {  # ensure_run <run_id> — create the dir tree, refresh `latest`
  local rd; rd="$(run_dir "$1")"
  mkdir -p "$rd/reports"
  ln -sfn "$1" "$LOG_DIR/latest" 2>/dev/null || true
  printf '%s\n' "$rd"
}

# ---- append -----------------------------------------------------------------
# Concurrency is real, not hypothetical: a /collab:panel fires 2-3 calls at once, each
# appending a line that is far larger than the PIPE_BUF write the kernel would keep
# atomic for us. So take a lock. mkdir is the portable atomic primitive (flock(1)
# doesn't exist on macOS/BSD, which we intend to support).
_lock_held=""
_release_lock() { [ -n "$_lock_held" ] && rmdir "$_lock_held" 2>/dev/null; _lock_held=""; return 0; }

_with_lock() {  # _with_lock <lockdir> <command...>
  local lock="$1"; shift
  local waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # A lock older than a minute is a crashed writer's, not a live one's — steal it
    # rather than wedge every future call behind a corpse.
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true; continue
    fi
    sleep 0.05; waited=$((waited+1))
    if [ "$waited" -gt 200 ]; then
      # ~10s. DROP the entry rather than append unlocked. An unlocked append of a
      # line far larger than PIPE_BUF can interleave with another writer's and
      # corrupt BOTH — taking out entries that were already safely recorded. A
      # missing entry is bounded and `verify` reports it as a gap; a torn line
      # silently poisons the record around it. Never trade the log's integrity for
      # one entry.
      echo "collab: log lock busy for 10s — DROPPING this entry rather than risk a torn append (verify will show the gap)." >&2
      return 0
    fi
  done
  # The path is held in a variable, never interpolated into the trap's source: a
  # single quote in $COLLAB_LOG_DIR would otherwise make the trap a syntax error and
  # strand the lock, wedging every later writer behind it for a minute.
  _lock_held="$lock"
  trap _release_lock EXIT
  "$@"
  _release_lock
  trap - EXIT
}

# _line_hash — sha256 of a log line's TEXT, newline excluded. Both the writer and
# `verify` must hash identically, so the newline is stripped in exactly one place.
_line_hash() { tr -d '\n' | _sha; }

# _append_locked <file> <entry-json-file> [turn-out-file] — chain onto the previous
# line and append. prev_hash is the sha256 of the previous LINE (empty for the
# first), so a corrupted/truncated middle entry is detectable.
#
# EVERYTHING that reads the file to decide what to write must happen in here, inside
# the lock: both the prev_hash read and the turn count. Computing either outside the
# lock is a race — and not a theoretical one. A /collab:panel fires 2-3 calls at once, and
# with the turn count taken outside the lock all three read "0 so far" and every one
# of them logged itself as turn 1.
_append_locked() {
  local file="$1" entry="$2" turn_out="${3:-}" prev="" turn=""
  [ -f "$file" ] && prev="$(tail -n1 "$file" 2>/dev/null | _line_hash)"
  if [ -n "$turn_out" ]; then
    turn=$(( $(grep -c '"status":"started"' "$file" 2>/dev/null || true) + 1 ))
    printf '%s\n' "$turn" > "$turn_out"
    jq -c --arg p "$prev" --argjson t "$turn" '. + {turn:$t, prev_hash:$p}' "$entry" >> "$file"
  else
    jq -c --arg p "$prev" '. + {prev_hash: $p}' "$entry" >> "$file"
  fi
}

# ---- entry construction -----------------------------------------------------
# Field set per PLAN W0.1. Optional values are recorded as JSON null rather than
# omitted, so a watcher can tell "absent" from "empty" without knowing our defaults.

# _entry <run_id> <type> <status> — prints a base entry JSON to stdout.
_entry() {
  jq -cn --arg ts "$(_now)" --arg run "$1" --arg type "$2" --arg status "$3" \
    '{timestamp:$ts, run_id:$run, type:$type, status:(if $status=="" then null else $status end)}'
}

_prompt_mode() { cfg COLLAB_LOG_PROMPTS full; }

# ---- subcommands -------------------------------------------------------------

# new-run always mints a FRESH id and deliberately ignores an ambient $COLLAB_RUN_ID:
# asking for a new run and being handed the current one back would silently merge two
# workflows into one audit unit. (ask.sh only calls this when COLLAB_RUN_ID is unset.)
cmd_new_run() {
  disabled && { printf '\n'; return 0; }
  local rid rd; rid="$(_now | tr -d ':-')-$(_rand)"
  rd="$(ensure_run "$rid")"
  have_jq && jq -cn --arg r "$rid" --arg c "${1:-ask}" --arg ts "$(_now)" \
    '{run_id:$r, command:$c, started_at:$ts}' > "$rd/meta.json" 2>/dev/null || true
  # Retention: an unbounded log directory is an indefinite sensitive-data surface.
  cmd_prune --days "$(cfg COLLAB_LOG_RETENTION_DAYS 14)" >/dev/null 2>&1 || true
  printf '%s\n' "$rid"
}

# latest — the most recent run's id. /collab:witness needs this and must not have to shell
# out to `readlink` (which it isn't permitted to run, and whose flags differ on BSD).
cmd_latest() {
  local l="$LOG_DIR/latest"
  [ -L "$l" ] || { echo "log.sh latest: no runs logged yet ($LOG_DIR)" >&2; return 1; }
  basename "$(readlink "$l")"
}

cmd_dir()  { printf '%s\n' "$(run_dir "$(resolve_run "${1:-}")")"; }
cmd_path() { printf '%s\n' "$(run_dir "$(resolve_run "${1:-}")")/calls.jsonl"; }

cmd_started() {
  local call_id="" command="" model="" agent="" session="" prompt_file="" run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --call-id) call_id="${2:?}"; shift 2 ;;
      --command) command="${2:?}"; shift 2 ;;
      --model)   model="${2:?}";   shift 2 ;;
      --agent)   agent="${2:?}";   shift 2 ;;
      --session) session="${2:?}"; shift 2 ;;
      --prompt-file) prompt_file="${2:?}"; shift 2 ;;
      --run)     run="${2:?}";     shift 2 ;;
      *) echo "log.sh started: unknown arg '$1'" >&2; exit 2 ;;
    esac
  done
  disabled && return 0
  have_jq || return 0
  local rid rd file; rid="$(resolve_run "$run")"; rd="$(ensure_run "$rid")"; file="$rd/calls.jsonl"

  # `off` means off: no text AND no digest. A hash is not the prompt, but a knob
  # called "off" that still fingerprints every prompt is a lie to the person who set
  # it. `hash` is the middle ground — proves the prompt didn't change, reveals none
  # of it.
  local prompt_txt="" prompt_hash="" mode; mode="$(_prompt_mode)"
  if [ -n "$prompt_file" ] && [ -f "$prompt_file" ] && [ "$mode" != "off" ]; then
    prompt_hash="$(_sha < "$prompt_file")"
    [ "$mode" = "full" ] && prompt_txt="$(cat "$prompt_file")"
  fi
  local entry turn_out; entry="$(mktemp)"; turn_out="$(mktemp)"
  # turn = position within the run. Recorded because it reads naturally in a report
  # ("turn 3 of the workshop"), NOT as the pairing key — call_id is (W0.3). It is
  # stamped inside the lock by _append_locked.
  _entry "$rid" call started | jq -c \
    --arg call_id "$call_id" --arg command "$command" --arg model "$model" \
    --arg agent "$agent" --arg session "$session" \
    --arg pmode "$mode" --arg ptxt "$prompt_txt" --arg phash "$prompt_hash" \
    '. + {call_id:$call_id, command:$command, model:(if $model=="" then null else $model end),
          agent:$agent, session_id:(if $session=="" then null else $session end),
          prompt_mode:$pmode,
          prompt:(if $pmode=="full" then $ptxt else null end),
          prompt_hash:(if $phash=="" then null else $phash end)}' > "$entry"
  _with_lock "$file.lock" _append_locked "$file" "$entry" "$turn_out"
  cat "$turn_out"
  rm -f "$entry" "$turn_out"
}

cmd_completed() {
  local call_id="" exit_code="0" turn="" session="" command="" model="" agent="" response_file="" run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --call-id) call_id="${2:?}"; shift 2 ;;
      --exit)    exit_code="${2:?}"; shift 2 ;;
      --turn)    turn="${2:?}";    shift 2 ;;
      --session) session="${2:?}"; shift 2 ;;
      --command) command="${2:?}"; shift 2 ;;
      --model)   model="${2:?}";   shift 2 ;;
      --agent)   agent="${2:?}";   shift 2 ;;
      --response-file) response_file="${2:?}"; shift 2 ;;
      --run)     run="${2:?}";     shift 2 ;;
      *) echo "log.sh completed: unknown arg '$1'" >&2; exit 2 ;;
    esac
  done
  disabled && return 0
  have_jq || return 0
  local rid rd file; rid="$(resolve_run "$run")"; rd="$(ensure_run "$rid")"; file="$rd/calls.jsonl"

  # raw_response is recorded in FULL, always. It is the evidence — a truncated
  # response lets "the model only said X" survive contact with the log.
  # raw_response is recorded byte-for-byte via jq --rawfile. A `$(cat "$f")` capture
  # strips trailing newlines, which would make "verbatim, untruncated" a false claim
  # AND hash the truncated value — so `verify` would happily confirm the copy it
  # already lost bytes from. An empty file stands in when there's no response.
  local rfile="$response_file" rhash="" tmp_empty=""
  if [ -z "$rfile" ] || [ ! -f "$rfile" ]; then
    tmp_empty="$(mktemp)"; rfile="$tmp_empty"
  else
    rhash="$(_sha < "$rfile")"
  fi
  local entry; entry="$(mktemp)"
  _entry "$rid" call completed | jq -c \
    --arg call_id "$call_id" --arg command "$command" --arg model "$model" \
    --arg agent "$agent" --arg session "$session" --arg turn "$turn" \
    --argjson exit_code "${exit_code:-0}" --rawfile resp "$rfile" --arg rhash "$rhash" \
    '. + {call_id:$call_id, command:$command, model:(if $model=="" then null else $model end),
          agent:$agent, session_id:(if $session=="" then null else $session end),
          turn:(if $turn=="" then null else ($turn|tonumber) end),
          exit_code:$exit_code, raw_response:$resp,
          response_hash:(if $rhash=="" then null else $rhash end)}' > "$entry"
  [ -n "$tmp_empty" ] && rm -f "$tmp_empty"
  _with_lock "$file.lock" _append_locked "$file" "$entry"
  rm -f "$entry"
}

cmd_final() {
  local run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) run="${2:?}"; shift 2 ;;
      *) echo "log.sh final: unknown arg '$1'" >&2; exit 2 ;;
    esac
  done
  disabled && return 0
  have_jq || { echo "log.sh: jq not found — cannot log." >&2; return 0; }
  local rid rd file; rid="$(resolve_run "$run")"; rd="$(ensure_run "$rid")"; file="$rd/calls.jsonl"
  local txtf; txtf="$(mktemp)"; cat > "$txtf"
  local entry; entry="$(mktemp)"
  _entry "$rid" claude-final "" | jq -c --rawfile t "$txtf" --arg h "$(_sha < "$txtf")" \
    '. + {text:$t, response_hash:(if $h=="" then null else $h end)}' > "$entry"
  rm -f "$txtf"
  _with_lock "$file.lock" _append_locked "$file" "$entry"
  rm -f "$entry"
  printf '%s\n' "$file"
}

cmd_disposition() {
  local model="" point="" verdict="" why="" run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)   model="${2:?}";   shift 2 ;;
      --point)   point="${2:?}";   shift 2 ;;
      --verdict) verdict="${2:?}"; shift 2 ;;
      --why)     why="${2:?}";     shift 2 ;;
      --run)     run="${2:?}";     shift 2 ;;
      *) echo "log.sh disposition: unknown arg '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$point" ] && [ -n "$verdict" ] || { echo "log.sh disposition: --point and --verdict are required" >&2; exit 2; }
  case "$verdict" in Adopt|Adapt|Reject|Defer) ;; *) echo "log.sh disposition: --verdict must be Adopt|Adapt|Reject|Defer (got '$verdict')" >&2; exit 2 ;; esac
  disabled && return 0
  have_jq || return 0
  local rid rd file; rid="$(resolve_run "$run")"; rd="$(ensure_run "$rid")"; file="$rd/calls.jsonl"
  local entry; entry="$(mktemp)"
  # `claim: true` is not decoration. This entry is Claude describing its own
  # behaviour; a watcher must treat it as an assertion to check against the raw
  # `completed` responses, never as a record of what happened.
  _entry "$rid" claude-disposition "" | jq -c \
    --arg m "$model" --arg p "$point" --arg v "$verdict" --arg w "$why" \
    '. + {claim:true, model:(if $m=="" then null else $m end), point:$p, verdict:$v,
          why:(if $w=="" then null else $w end)}' > "$entry"
  _with_lock "$file.lock" _append_locked "$file" "$entry"
  rm -f "$entry"
}

# verify — the integrity contract: every `started` has a matching `completed`. A gap
# means a call crashed, timed out or was killed, and its response never reached the
# log. `/collab:witness` (W2) refuses to audit a failed-integrity log rather than report
# "clean" over a hole.
cmd_verify() {
  local rid rd file; rid="$(resolve_run "${1:-}")"; rd="$(run_dir "$rid")"; file="$rd/calls.jsonl"
  if [ ! -f "$file" ]; then
    echo "log.sh verify: no log at $file" >&2; exit 7
  fi
  have_jq || { echo "log.sh verify: needs jq" >&2; exit 2; }
  local bad=0

  # 1. Every line is valid JSON (catches a torn/interleaved append).
  local n_lines n_json
  n_lines="$(wc -l < "$file" | tr -d ' ')"
  n_json="$(jq -s 'length' "$file" 2>/dev/null || echo -1)"
  if [ "$n_json" != "$n_lines" ]; then
    echo "INTEGRITY FAIL: $file is not clean JSONL ($n_lines lines, $n_json parsed)." >&2
    bad=1
  else
    # 2. Unpaired entries, by call_id — checked in BOTH directions.
    #
    #    A `started` with no `completed` is the obvious gap: the call died mid-flight
    #    and its response never reached the log. But the inverse is just as much a
    #    silent loss and was missed at first: if the `started` write fails while the
    #    call itself succeeds, the log keeps the answer and loses the PROMPT and the
    #    turn — and a one-directional check prints "every started has a completed"
    #    over it, which is precisely the reassuring-but-false verdict this contract
    #    exists to prevent. Integrity is a *pairing* property, so verify the pair.
    local orphan_started orphan_completed
    orphan_started="$(jq -rs '
      [.[] | select(.type=="call")] as $c
      | ($c | map(select(.status=="started")   | .call_id)) as $s
      | ($c | map(select(.status=="completed") | .call_id)) as $d
      | $s - $d | .[]' "$file")"
    orphan_completed="$(jq -rs '
      [.[] | select(.type=="call")] as $c
      | ($c | map(select(.status=="started")   | .call_id)) as $s
      | ($c | map(select(.status=="completed") | .call_id)) as $d
      | $d - $s | .[]' "$file")"
    if [ -n "$orphan_started" ]; then
      echo "INTEGRITY FAIL: started with no completed (the call died mid-flight; its response is NOT in this log):" >&2
      printf '  call_id %s\n' $orphan_started >&2
      bad=1
    fi
    if [ -n "$orphan_completed" ]; then
      echo "INTEGRITY FAIL: completed with no started (the pre-call entry was lost; this call's PROMPT and turn are NOT in this log):" >&2
      printf '  call_id %s\n' $orphan_completed >&2
      bad=1
    fi
    # 3. Hash chain + per-entry self-check — accidental corruption only; this is not
    #    tamper-proofing (whatever can rewrite the log can rewrite the hashes).
    #
    #    Both checks are needed, because the chain alone has a blind spot: it links
    #    each line to its predecessor, so it cannot protect the LAST line — there is
    #    no successor holding its hash. That is not a corner case: a truncated or
    #    half-flushed final write is the single most likely accidental corruption
    #    here. So each entry ALSO carries response_hash over its own payload, which
    #    is verifiable standalone and covers the tail.
    local i=0 prev="" line got rh
    while IFS= read -r line; do
      i=$((i+1))
      got="$(printf '%s' "$line" | jq -r '.prev_hash // ""')"
      if [ "$got" != "$prev" ]; then
        echo "INTEGRITY FAIL: prev_hash mismatch at line $i (log corrupted or rewritten)." >&2
        bad=1; break
      fi
      rh="$(printf '%s' "$line" | jq -r '.response_hash // ""')"
      if [ -n "$rh" ]; then
        if [ "$(printf '%s' "$line" | jq -j 'if .type=="claude-final" then (.text // "") else (.raw_response // "") end' | _sha)" != "$rh" ]; then
          echo "INTEGRITY FAIL: response_hash mismatch at line $i (the recorded answer does not match its digest)." >&2
          bad=1; break
        fi
      fi
      prev="$(printf '%s' "$line" | _line_hash)"
    done < "$file"
  fi
  [ "$bad" -eq 0 ] || exit 7
  echo "ok: $file — $n_lines entries, every call paired (started↔completed), hashes intact."
}

cmd_prune() {
  local days; days="$(cfg COLLAB_LOG_RETENTION_DAYS 14)"
  while [ $# -gt 0 ]; do
    case "$1" in --days) days="${2:?}"; shift 2 ;; *) echo "log.sh prune: unknown arg '$1'" >&2; exit 2 ;; esac
  done
  [ "$days" -gt 0 ] 2>/dev/null || return 0     # 0/invalid = pruning disabled
  [ -d "$LOG_DIR" ] || return 0
  local d
  # Only ever touch directories that look like a run id we minted, never the whole
  # log dir and never a stray file a developer parked here.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rm -rf "$d"; echo "pruned $d"
  done < <(find "$LOG_DIR" -maxdepth 1 -type d -name '[0-9]*Z-*' -mtime "+$days" 2>/dev/null)
}

# ---- dispatch ---------------------------------------------------------------
[ $# -gt 0 ] || usage 2
sub="$1"; shift
case "$sub" in
  new-run)     cmd_new_run "$@" ;;
  latest)      cmd_latest "$@" ;;
  dir)         cmd_dir "$@" ;;
  path)        cmd_path "$@" ;;
  started)     cmd_started "$@" ;;
  completed)   cmd_completed "$@" ;;
  final)       cmd_final "$@" ;;
  disposition) cmd_disposition "$@" ;;
  verify)      cmd_verify "$@" ;;
  prune)       cmd_prune "$@" ;;
  -h|--help)   usage 0 ;;
  *) echo "log.sh: unknown subcommand '$sub'" >&2; usage 2 ;;
esac
