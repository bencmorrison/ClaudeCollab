#!/usr/bin/env bash
# install.sh — install (or remove) ClaudeCollab in ANY project.
#
# ClaudeCollab is three drop-in directories that let Claude Code shell out to
# other LLMs via opencode:
#   .claude/commands/   the slash commands (/consult, /panel, /review, /delegate, …)
#   .opencode/agent/    the hardened collab-read / collab-build agent defs
#   collab/             the ask.sh wrapper, panel/doctor/verify scripts, policy
# This script copies those into your project and adds the git-ignore entries the
# per-user config files need. It only ever touches files it installed — a file you
# already had at the same path is left alone (install skips it; uninstall never
# deletes it), so your own slash commands, opencode agents, and collab/ contents
# are safe.
#
# Usage:
#   bash install.sh [--dest <dir>]     install into <dir> (default: current dir)
#   bash install.sh --uninstall [--dest <dir>]   remove it again
#   bash install.sh --help
#
# Source of the files:
#   • Run from a clone: copies from the clone it lives in.
#   • Piped (curl … | bash): git-clones the repo into a temp dir first.
#     Override the URL with CLAUDECOLLAB_REPO=<git-url>.
set -euo pipefail

REPO_URL="${CLAUDECOLLAB_REPO:-https://github.com/bencmorrison/ClaudeCollab.git}"

# Directories that make up ClaudeCollab. All three are merged into a target you may
# already own files in, so install/uninstall operate per-file via the manifest —
# never wholesale on a directory.
PAYLOAD_DIRS=(".claude/commands" ".opencode/agent" "collab")

# Empty dirs we may create, deepest-first, pruned on uninstall (only if empty, so
# any file of yours keeps its parent dir alive).
PRUNE_DIRS=(".claude/commands" ".claude" ".opencode/agent" ".opencode" "collab/tests" "collab")

# git-ignore block we manage in the target's .gitignore (idempotent, fenced).
GITIGNORE_BEGIN="# >>> ClaudeCollab >>>"
GITIGNORE_END="# <<< ClaudeCollab <<<"
read -r -d '' GITIGNORE_BODY <<'EOF' || true
# >>> ClaudeCollab >>>
# Per-user config written by /configure-collab — never commit personal prefs.
collab/models.policy.local
collab/collab.conf.local
# Probe sentinels the verify scripts create (normally auto-cleaned).
.collab-*-probe.*
# <<< ClaudeCollab <<<
EOF

MANIFEST_REL="collab/.install-manifest"   # relative to dest; lists installed files

# ---- args -------------------------------------------------------------------
action="install"; dest="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) action="uninstall" ;;
    --dest) shift; dest="${1:?--dest needs a directory}" ;;
    --dest=*) dest="${1#--dest=}" ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$dest"; dest="$(cd "$dest" && pwd)"

say()  { printf '\033[36m•\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# The directory this script lives in — the payload source when run from a clone
# (empty/irrelevant when piped, where have_payload just returns false).
self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || self_dir=""
have_payload() {  # true if $1 holds all payload dirs
  local s="$1" d; [ -n "$s" ] || return 1
  for d in "${PAYLOAD_DIRS[@]}"; do [ -d "$s/$d" ] || return 1; done
}

# ---- gitignore block management --------------------------------------------
# Strip our fenced block, but ONLY when BOTH markers are present — a lone begin
# marker (e.g. the end line got hand-deleted) must not swallow the rest of the
# file. Trailing blank lines left behind are trimmed. Single awk, atomic replace.
strip_gitignore_block() {
  local gi="$1"; [ -f "$gi" ] || return 0
  grep -qF "$GITIGNORE_BEGIN" "$gi" && grep -qF "$GITIGNORE_END" "$gi" || return 0
  local tmp="$gi.cctmp"
  if awk -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" '
       $0==b {skip=1; next}
       skip  {if($0==e) skip=0; next}
       {lines[++n]=$0}
       END{ while(n>0 && lines[n]=="") n--; for(i=1;i<=n;i++) print lines[i] }
     ' "$gi" > "$tmp"; then mv "$tmp" "$gi"; else rm -f "$tmp"; fi
}
add_gitignore_block() {
  local gi="$dest/.gitignore"
  strip_gitignore_block "$gi"           # keep it idempotent — never double-add
  [ -s "$gi" ] && printf '\n' >> "$gi"
  printf '%s\n' "$GITIGNORE_BODY" >> "$gi"
}

prune_empty_dirs() {  # rmdir the payload dirs we may have created, only if empty
  local d
  for d in "${PRUNE_DIRS[@]}"; do
    [ -d "$dest/$d" ] && rmdir "$dest/$d" 2>/dev/null || true
  done
}

# =============================== UNINSTALL ====================================
if [ "$action" = "uninstall" ]; then
  say "Uninstalling ClaudeCollab from: $dest"
  removed=0
  if [ -f "$dest/$MANIFEST_REL" ]; then
    # Authoritative: remove exactly what this install recorded. A manifest entry is
    # always a payload-relative path; reject anything absolute or with '..' as a
    # tamper guard (a corrupted manifest must not delete outside $dest).
    while IFS= read -r rel || [ -n "$rel" ]; do
      [ -n "$rel" ] || continue
      case "$rel" in /*|*..*) warn "skipping suspicious manifest entry: $rel"; continue ;; esac
      if [ -e "$dest/$rel" ]; then rm -f "$dest/$rel"; removed=$((removed+1)); fi
    done < "$dest/$MANIFEST_REL"
    rm -f "$dest/$MANIFEST_REL"
  elif have_payload "$self_dir"; then
    # No manifest (deleted/corrupted) but we can see the source payload — derive the
    # exact file list from it, so newly-added commands/agents are covered too.
    warn "no install manifest — deriving the file list from the ClaudeCollab source at $self_dir"
    while IFS= read -r rel; do
      [ -e "$dest/$rel" ] && { rm -f "$dest/$rel"; removed=$((removed+1)); }
    done < <(cd "$self_dir" && find "${PAYLOAD_DIRS[@]}" -type f)
  else
    # Last resort: no manifest and no source. Remove only files we can name; some
    # may remain, but we never blow away a directory (your files stay).
    warn "no manifest and no source payload — removing only the known ClaudeCollab files (any others must be removed by hand)"
    rm -f "$dest/.claude/commands/"{consult,panel,workshop,review,research,delegate,collaborate,configure-collab}.md
    rm -f "$dest/.opencode/agent/"{collab-read,collab-build,collab-research}.md
    for k in ask.sh panel-models.sh doctor.sh verify-collab-read.sh verify-collab-build.sh \
             verify-collab-research.sh models.policy collab.conf.example .install-manifest \
             tests/run-tests.sh tests/check-agent-permissions.sh tests/check-frontmatter.sh \
             tests/test-install.sh tests/fake-opencode; do
      rm -f "$dest/collab/$k"
    done
    removed=1
  fi
  prune_empty_dirs
  strip_gitignore_block "$dest/.gitignore"
  [ -f "$dest/.gitignore" ] && [ ! -s "$dest/.gitignore" ] && rm -f "$dest/.gitignore"
  ok "Removed ClaudeCollab (${removed} file(s)). Files you added yourself were left untouched."
  say "Note: any Claude Code permission grants you added to .claude/settings*.json are yours to remove."
  exit 0
fi

# =============================== INSTALL ======================================
# Locate the payload: the clone this script lives in, else clone the repo.
src="$self_dir"
tmp_src=""
if ! have_payload "$src"; then
  command -v git >/dev/null 2>&1 || die "git is required to fetch ClaudeCollab when piped. Install git, or run from a clone."
  tmp_src="$(mktemp -d)"; say "Fetching ClaudeCollab from $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$tmp_src" >/dev/null 2>&1 || die "git clone failed: $REPO_URL"
  src="$tmp_src"
fi
cleanup() { [ -n "$tmp_src" ] && rm -rf "$tmp_src"; }
trap cleanup EXIT

# Refuse to install onto the source itself (would be a no-op that self-clobbers).
if [ "$src" = "$dest" ]; then
  die "Destination is the ClaudeCollab source itself. cd into your project first, or pass --dest <your-project>."
fi

say "Installing ClaudeCollab"
say "  from: $src"
say "  into: $dest"
[ -d "$dest/.git" ] || warn "$dest is not a git repo — install works, but you won't be able to review /delegate diffs with git."

# A path is "ours" (safe to overwrite on re-install/upgrade) iff the PREVIOUS
# manifest listed it. Anything else already present is the user's — we skip it.
is_owned() { [ -f "$dest/$MANIFEST_REL" ] && grep -qxF "$1" "$dest/$MANIFEST_REL"; }

manifest_tmp="$(mktemp)"
count=0; skipped=0
copy_one() {  # copy_one <relpath> ; records it in the new manifest (unless skipped)
  local rel="$1"
  if [ -e "$dest/$rel" ] && ! is_owned "$rel"; then
    warn "skipping $rel — a file you already have is there; leaving it untouched"
    skipped=$((skipped+1)); return
  fi
  mkdir -p "$dest/$(dirname "$rel")"
  cp "$src/$rel" "$dest/$rel"
  printf '%s\n' "$rel" >> "$manifest_tmp"
  count=$((count+1))
}
# Walk each payload dir (relative, since we cd into src) and copy every file.
while IFS= read -r rel; do
  copy_one "$rel"
done < <(cd "$src" && find "${PAYLOAD_DIRS[@]}" -type f)

# Make the shell scripts executable.
find "$dest/collab" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
chmod +x "$dest/collab/tests/fake-opencode" 2>/dev/null || true

# Persist the manifest inside collab/ so --uninstall is exact.
printf '%s\n' "$MANIFEST_REL" >> "$manifest_tmp"   # the manifest lists itself too
sort -u "$manifest_tmp" > "$dest/$MANIFEST_REL"
rm -f "$manifest_tmp"

add_gitignore_block
ok "Installed ${count} file(s)$( [ "$skipped" -gt 0 ] && printf ', skipped %d already-present file(s)' "$skipped")."
say "Next steps:"
say "  1. Authenticate opencode to your providers:  opencode auth login"
say "  2. Check the setup:                          bash collab/doctor.sh"
say "  3. (optional) Set default models:            run /configure-collab in Claude Code"
say "  4. Use it in Claude Code:                     /consult, /panel, /review, /delegate"
