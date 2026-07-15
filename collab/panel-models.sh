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

# Source the list: explicit args win, else $COLLAB_MODELS. Commas -> spaces so both
# "a,b" and "a b" work.
if [ "$#" -gt 0 ]; then raw="$*"; else raw="${COLLAB_MODELS:-}"; fi
raw="${raw//,/ }"

seen=" "
models=()
for m in $raw; do
  [ -n "$m" ] || continue
  case "$seen" in
    *" $m "*) echo "warning: duplicate model '$m' dropped (a panel of the same model isn't diverse)." >&2; continue ;;
  esac
  seen="$seen$m "
  models+=("$m")
done

if [ "${#models[@]}" -eq 0 ]; then
  echo "error: no models. Pass provider/model ids, or set COLLAB_MODELS (space- or comma-separated)." >&2
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
