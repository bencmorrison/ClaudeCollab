#!/usr/bin/env bash
#
# panel-models.sh — resolve and sanity-check the model set for a /panel run.
#
# The panel asks the SAME question of several models and has Claude synthesize.
# This helper decides WHICH models and guards against "diversity theater" (a panel
# that's secretly one model, or all one provider). It calls no model and needs no
# opencode — pure string logic, so it's cheap and unit-testable.
#
# Usage:
#   collab/panel-models.sh [provider/model ...]
#     - With args: use those ids (in order).
#     - With no args: use $COLLAB_MODELS (space- OR comma-separated, ordered).
#
# Behaviour:
#   - de-duplicates, preserving first-seen order (warns about each dropped dup);
#   - warns if fewer than 2 distinct models (not really a panel);
#   - warns if every model shares one provider prefix (single-family, not diverse);
#   - prints the resolved model list to stdout, one id per line (for the caller to
#     loop `ask.sh -m <id>` over). Warnings go to stderr.
#   Exit 0 normally; exit 2 if no models were given at all.
#
# Note: this does NOT check the model policy — that's enforced per call by ask.sh
# (deny/ask tiers). This is only about the shape/diversity of the set.
set -uo pipefail

# Config file — persistent panel set (see ask.sh for why a file, not just env):
# $COLLAB_CONF if set, else git-ignored collab/collab.conf.local. KEY=value, not sourced.
if [ -n "${COLLAB_CONF:-}" ]; then conf_file="$COLLAB_CONF"
elif [ -f "$(dirname "$0")/collab.conf.local" ]; then conf_file="$(dirname "$0")/collab.conf.local"
else conf_file=""; fi
conf_get() {
  [ -n "$conf_file" ] && [ -f "$conf_file" ] || return 0
  awk -v k="$1" '
    { line=$0; sub(/^[[:space:]]+/,"",line) }
    line ~ /^#/ || line !~ /=/ { next }
    { eq=index(line,"="); lk=substr(line,1,eq-1); gsub(/[[:space:]]/,"",lk)
      if(lk!=k) next
      lv=substr(line,eq+1); sub(/^[[:space:]]+/,"",lv); sub(/[[:space:]]+$/,"",lv)
      gsub(/^"|"$/,"",lv); gsub(/^\047|\047$/,"",lv); val=lv }
    END{ if(val!="") print val }' "$conf_file"
}

# Source the list, in precedence order: explicit args > $COLLAB_MODELS (one-off env
# override) > the config file's COLLAB_MODELS. Commas -> spaces so both "a,b" and
# "a b" work.
if [ "$#" -gt 0 ]; then raw="$*"
else raw="${COLLAB_MODELS:-}"; [ -n "$raw" ] || raw="$(conf_get COLLAB_MODELS)"; fi
raw="${raw//,/ }"

seen=" "
models=()
for m in $raw; do
  [ -n "$m" ] || continue
  case "$seen" in
    *" $m "*) echo "warning: duplicate model '$m' dropped (a panel of the same model isn't diverse)." >&2; continue ;;
  esac
  # opencode ids are provider/model; a bare token (or empty side) is almost certainly
  # a typo that would only surface as an ask.sh failure later — flag it here.
  case "$m" in
    ?*/?*) ;;
    *) echo "warning: '$m' doesn't look like a provider/model id — ask.sh/opencode will likely reject it." >&2 ;;
  esac
  seen="$seen$m "
  models+=("$m")
done

if [ "${#models[@]}" -eq 0 ]; then
  echo "error: no models. Pass provider/model ids, set COLLAB_MODELS, or add a" >&2
  echo "       COLLAB_MODELS= line to collab/collab.conf.local (run /configure-collab)." >&2
  echo "       e.g. COLLAB_MODELS=\"openai/gpt-5 google/gemini-2.5-pro\"" >&2
  exit 2
fi

if [ "${#models[@]}" -lt 2 ]; then
  echo "warning: only ${#models[@]} model resolved — a panel wants 2-3 from different families for genuine diversity." >&2
fi

# Provider diversity: provider = the part before the first '/'. If every model
# shares one provider, the panel isn't cross-family.
provs=()
for m in "${models[@]}"; do provs+=("${m%%/*}"); done
nprov="$(printf '%s\n' "${provs[@]}" | sort -u | grep -c .)"
if [ "${#models[@]}" -ge 2 ] && [ "$nprov" -eq 1 ]; then
  echo "warning: all ${#models[@]} models are from provider '${provs[0]}' — that's single-family, not cross-provider diversity (risks 'diversity theater'). Consider models from different providers." >&2
fi

printf '%s\n' "${models[@]}"
