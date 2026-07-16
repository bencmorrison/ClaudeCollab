#!/usr/bin/env bash
# install.sh — install (or remove) ClaudeCollab in ANY project.
#
# ClaudeCollab is three drop-in directories that let Claude Code shell out to
# other LLMs via opencode:
#   .claude/commands/collab/  the slash commands (/collab:consult, /collab:panel, …)
#   .opencode/agent/    the hardened collab-read / collab-build / collab-research / collab-watch agent defs
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

# The install surface is explicit. Do not replace this with a directory walk:
# source clones can contain ignored personal config, logs, stale manifests, and
# arbitrary untracked files. This list is also the no-source uninstall inventory.
PAYLOAD_FILES=(
  ".claude/commands/collab/collaborate.md"
  ".claude/commands/collab/configure.md"
  ".claude/commands/collab/consult.md"
  ".claude/commands/collab/delegate.md"
  ".claude/commands/collab/panel.md"
  ".claude/commands/collab/research.md"
  ".claude/commands/collab/review.md"
  ".claude/commands/collab/witness.md"
  ".claude/commands/collab/workshop.md"
  ".opencode/agent/collab-build.md"
  ".opencode/agent/collab-read.md"
  ".opencode/agent/collab-research.md"
  ".opencode/agent/collab-watch.md"
  "collab/ask.sh"
  "collab/collab.conf.example"
  "collab/doctor.sh"
  "collab/log.sh"
  "collab/models.policy"
  "collab/panel-models.sh"
  "collab/tests/check-agent-permissions.sh"
  "collab/tests/check-docs.sh"
  "collab/tests/check-frontmatter.sh"
  "collab/tests/check-shebangs.sh"
  "collab/tests/fake-opencode"
  "collab/tests/run-tests.sh"
  "collab/tests/test-install.sh"
  "collab/verify-collab-build.sh"
  "collab/verify-collab-read.sh"
  "collab/verify-collab-research.sh"
  "collab/verify-collab-watch.sh"
)

# Empty dirs we may create, deepest-first, pruned on uninstall (only if empty, so
# any file of yours keeps its parent dir alive).
# `collab/logs` is listed so an empty log dir is tidied up, but it is rmdir-only like
# the rest: if you have audit logs, they survive an uninstall. They are yours.
PRUNE_DIRS=(".claude/commands/collab" ".claude/commands" ".claude" ".opencode/agent" ".opencode" "collab/tests" "collab/logs" "collab")

# git-ignore block we manage in the target's .gitignore (idempotent, fenced).
GITIGNORE_BEGIN="# >>> ClaudeCollab >>>"
GITIGNORE_END="# <<< ClaudeCollab <<<"
read -r -d '' GITIGNORE_BODY <<'EOF' || true
# >>> ClaudeCollab >>>
# Per-user config written by /collab:configure — never commit personal prefs.
collab/models.policy.local
collab/collab.conf.local
# Probe sentinels the verify scripts create (normally auto-cleaned).
.collab-*-probe.*
# The evidence layer: raw prompts/responses of every model call (collab/log.sh).
collab/logs/
# <<< ClaudeCollab <<<
EOF

MANIFEST_REL="collab/.install-manifest"   # paths, retained for doctor.sh compatibility
HASHES_REL="collab/.install-hashes"       # sha256<TAB>path ownership records
STATE_REL="collab/.install-state"         # installer-owned destination state

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

say()  { printf '\033[36m•\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Reject symlinks in an existing destination path before mkdir/cd can follow
# them. Relative '..' components are resolved lexically but never bypass checks.
reject_dest_symlinks() {
  local input="$1" cur part rest last
  case "$input" in /*) cur="/" ;; *) cur="$(pwd -P)" ;; esac
  rest="$input"
  while :; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/}; last=false ;;
      *) part=$rest; last=true ;;
    esac
    case "$part" in
      ""|.) ;;
      ..) cur="${cur%/*}"; [ -n "$cur" ] || cur="/" ;;
      *)
        [ "$cur" = "/" ] && cur="/$part" || cur="$cur/$part"
        [ -L "$cur" ] && die "refusing destination with symlink path component: $cur"
        ;;
    esac
    $last && break
  done
  return 0
}

reject_dest_symlinks "$dest"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd -P)"

valid_rel() {
  local rel="$1" part rest last
  [ -n "$rel" ] || return 1
  case "$rel" in /*) return 1 ;; esac
  rest="$rel"
  while :; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/}; last=false ;;
      *) part=$rest; last=true ;;
    esac
    [ -n "$part" ] && [ "$part" != ".." ] || return 1
    $last && break
  done
  return 0
}

# Validate every existing component, including the final destination file.
safe_dest_rel() {
  local rel="$1" cur="$dest" part rest last
  valid_rel "$rel" || die "refusing unsafe destination path: $rel"
  rest="$rel"
  while :; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/}; last=false ;;
      *) part=$rest; last=true ;;
    esac
    cur="$cur/$part"
    [ -L "$cur" ] && die "refusing destination symlink: $rel"
    $last && break
  done
  return 0
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    die "sha256sum or shasum is required"
  fi
}

# The directory this script lives in — the payload source when run from a clone
# (empty/irrelevant when piped, where have_payload just returns false).
self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || self_dir=""
have_payload() {  # true if $1 holds the complete explicit payload
  local s="$1" rel; [ -n "$s" ] || return 1
  for rel in "${PAYLOAD_FILES[@]}"; do
    [ -f "$s/$rel" ] && [ ! -L "$s/$rel" ] || return 1
  done
}

payload_files() {
  printf '%s\n' "${PAYLOAD_FILES[@]}"
}

is_payload_rel() {
  local candidate="$1" rel
  for rel in "${PAYLOAD_FILES[@]}"; do
    [ "$candidate" = "$rel" ] && return 0
  done
  return 1
}

valid_hash() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

# Existing reserved metadata is replaceable only when each file independently has
# an installer format. Valid records still permit recovery from partially corrupt
# files, while one valid metadata file cannot authorize an unrelated reserved path.
recognize_manifest() {
  local manifest="$dest/$MANIFEST_REL" rel recognized=0
  [ ! -e "$manifest" ] && return 0
  [ -f "$manifest" ] || return 1
  [ ! -s "$manifest" ] && return 0
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    if is_payload_rel "$rel"; then recognized=1
    else warn "ignoring non-payload install manifest entry: $rel"
    fi
  done < "$manifest"
  [ "$recognized" -eq 1 ]
}

recognize_hashes() {
  local hashes="$dest/$HASHES_REL" rel hash extra recognized=0
  [ ! -e "$hashes" ] && return 0
  [ -f "$hashes" ] || return 1
  [ ! -s "$hashes" ] && return 0
  while IFS=$'\t' read -r hash rel extra || [ -n "$hash$rel$extra" ]; do
    if valid_hash "$hash" && is_payload_rel "$rel" && [ -z "$extra" ]; then
      recognized=1
    elif [ -n "$hash$rel$extra" ]; then
      warn "ignoring invalid or non-payload install hash entry"
    fi
  done < "$hashes"
  [ "$recognized" -eq 1 ]
}

recognize_state() {
  local state="$dest/$STATE_REL"
  [ ! -e "$state" ] && return 0
  [ -f "$state" ] || return 1
  case "$(cat "$state")" in gitignore_preexisting=0|gitignore_preexisting=1) return 0 ;; *) return 1 ;; esac
}

recognize_metadata() {
  recognize_manifest && recognize_hashes && recognize_state
}

reserved_metadata_exists() {
  [ -e "$dest/$MANIFEST_REL" ] || [ -e "$dest/$HASHES_REL" ] || [ -e "$dest/$STATE_REL" ]
}

# ---- gitignore block management --------------------------------------------
# Strip our fenced block, but ONLY when BOTH markers are present — a lone begin
# marker (e.g. the end line got hand-deleted) must not swallow the rest of the
# file. The one separator inserted before the block is removed; all pre-existing
# and trailing blank lines are preserved. Single awk, atomic replace.
strip_gitignore_block() {
  local gi="$1"; [ -f "$gi" ] || return 0
  local begins ends begin_line end_line tmp
  [ "$gi" = "$dest/.gitignore" ] || die "refusing unsafe .gitignore path: $gi"
  safe_dest_rel ".gitignore"
  begins="$(grep -cxF "$GITIGNORE_BEGIN" "$gi" || true)"
  ends="$(grep -cxF "$GITIGNORE_END" "$gi" || true)"
  [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] || return 0
  begin_line="$(grep -nxF "$GITIGNORE_BEGIN" "$gi" | cut -d: -f1)"
  end_line="$(grep -nxF "$GITIGNORE_END" "$gi" | cut -d: -f1)"
  [ "$begin_line" -lt "$end_line" ] || return 0
  tmp="$(mktemp "$dest/.gitignore.cctmp.XXXXXX")" || die "could not create a secure .gitignore temporary file"
  cp -p "$gi" "$tmp" || { rm -f "$tmp"; die "could not prepare .gitignore temporary file"; }
  if awk -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" '
        $0==b {if(n>0 && lines[n]=="") n--; skip=1; next}
        skip  {if($0==e) skip=0; next}
        {lines[++n]=$0}
        END{for(i=1;i<=n;i++) print lines[i]}
      ' "$gi" > "$tmp"; then mv -f "$tmp" "$gi"; else rm -f "$tmp"; fi
}
add_gitignore_block() {
  local gi="$dest/.gitignore" tmp
  safe_dest_rel ".gitignore"
  if [ -e "$gi" ] && [ ! -f "$gi" ]; then
    die "refusing non-file .gitignore path"
  fi
  strip_gitignore_block "$gi"           # keep it idempotent — never double-add
  if [ -f "$gi" ] && { grep -qF "$GITIGNORE_BEGIN" "$gi" || grep -qF "$GITIGNORE_END" "$gi"; }; then
    warn "malformed ClaudeCollab .gitignore fences found — leaving .gitignore untouched"
    return
  fi
  tmp="$(mktemp "$dest/.gitignore.cctmp.XXXXXX")" || die "could not create a secure .gitignore temporary file"
  if [ -f "$gi" ]; then
    cp -p "$gi" "$tmp" || { rm -f "$tmp"; die "could not prepare .gitignore temporary file"; }
  else
    chmod 0644 "$tmp"
  fi
  [ -s "$tmp" ] && printf '\n' >> "$tmp"
  printf '%s\n' "$GITIGNORE_BODY" >> "$tmp"
  mv -f "$tmp" "$gi"
}

prune_empty_dirs() {  # rmdir the payload dirs we may have created, only if empty
  local d
  for d in "${PRUNE_DIRS[@]}"; do
    safe_dest_rel "$d"
    if [ -d "$dest/$d" ]; then rmdir "$dest/$d" 2>/dev/null || true; fi
  done
}

recorded_hash() {
  local rel="$1" hashes="$dest/$HASHES_REL" found
  is_payload_rel "$rel" || return 1
  [ -f "$hashes" ] || return 1
  found="$(awk -F '\t' -v p="$rel" '$2==p && NF==2 {print $1; found=1; exit} END{if(!found) exit 1}' "$hashes")" || return 1
  valid_hash "$found" || return 1
  printf '%s\n' "$found"
}

remove_if_owned() {
  local rel="$1" expected="$2" actual
  safe_dest_rel "$rel"
  [ -e "$dest/$rel" ] || return 0
  if [ ! -f "$dest/$rel" ]; then
    warn "keeping changed/non-file path: $rel"
    return 0
  fi
  actual="$(sha256_file "$dest/$rel")"
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    rm -f "$dest/$rel"
    removed=$((removed+1))
  else
    warn "keeping changed or unverified file: $rel"
  fi
}

# =============================== UNINSTALL ====================================
if [ "$action" = "uninstall" ]; then
  safe_dest_rel "$MANIFEST_REL"
  safe_dest_rel "$HASHES_REL"
  safe_dest_rel "$STATE_REL"
  safe_dest_rel ".gitignore"
  if reserved_metadata_exists && ! recognize_metadata; then
    die "refusing to use or replace unrecognized installer metadata under collab/"
  fi
  say "Uninstalling ClaudeCollab from: $dest"
  removed=0
  if [ -f "$dest/$MANIFEST_REL" ]; then
    # A path-only manifest is an index, not ownership proof. Remove only files whose
    # current bytes match the hash recorded when this installer wrote them.
    while IFS= read -r rel || [ -n "$rel" ]; do
      [ -n "$rel" ] || continue
      if ! valid_rel "$rel"; then warn "skipping suspicious manifest entry: $rel"; continue; fi
      if ! is_payload_rel "$rel"; then warn "skipping non-payload manifest entry: $rel"; continue; fi
      expected="$(recorded_hash "$rel" 2>/dev/null || true)"
      if [ -z "$expected" ] && have_payload "$self_dir"; then
        expected="$(sha256_file "$self_dir/$rel" 2>/dev/null || true)"
      fi
      remove_if_owned "$rel" "$expected"
    done < "$dest/$MANIFEST_REL"
    rm -f "$dest/$MANIFEST_REL"
    rm -f "$dest/$HASHES_REL"
  elif [ -f "$dest/$HASHES_REL" ] || have_payload "$self_dir"; then
    # Surviving hashes remain ownership proof even if the path index was lost.
    warn "no install manifest — removing only files verified by surviving hashes or the current payload"
    while IFS= read -r rel; do
      expected="$(recorded_hash "$rel" 2>/dev/null || true)"
      if [ -z "$expected" ] && have_payload "$self_dir"; then
        expected="$(sha256_file "$self_dir/$rel")"
      fi
      remove_if_owned "$rel" "$expected"
    done < <(payload_files)
    rm -f "$dest/$HASHES_REL"
  else
    warn "no manifest and no source payload — refusing to delete files without ownership proof"
    warn "known ClaudeCollab paths that may require manual review:"
    while IFS= read -r rel; do warn "    $rel"; done < <(payload_files)
  fi
  prune_empty_dirs
  strip_gitignore_block "$dest/.gitignore"
  gitignore_preexisting=1
  if [ -f "$dest/$STATE_REL" ]; then
    case "$(cat "$dest/$STATE_REL")" in gitignore_preexisting=0) gitignore_preexisting=0 ;; esac
    rm -f "$dest/$STATE_REL"
  fi
  [ "$gitignore_preexisting" -eq 0 ] && [ -f "$dest/.gitignore" ] && [ ! -s "$dest/.gitignore" ] && rm -f "$dest/.gitignore"
  prune_empty_dirs
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
cleanup() {
  [ -n "$tmp_src" ] && rm -rf "$tmp_src"
  [ -n "${skipped_list:-}" ] && rm -f "$skipped_list"
  [ -n "${manifest_tmp:-}" ] && rm -f "$manifest_tmp"
  [ -n "${hashes_tmp:-}" ] && rm -f "$hashes_tmp"
  return 0
}
trap cleanup EXIT

# Refuse to install onto the source itself (would be a no-op that self-clobbers).
if [ "$src" = "$dest" ]; then
  die "Destination is the ClaudeCollab source itself. cd into your project first, or pass --dest <your-project>."
fi

safe_dest_rel "$MANIFEST_REL"
safe_dest_rel "$HASHES_REL"
safe_dest_rel "$STATE_REL"
if reserved_metadata_exists && ! recognize_metadata; then
  die "refusing to use or replace unrecognized installer metadata under collab/"
fi

if [ -f "$dest/$STATE_REL" ]; then
  gitignore_state="$(cat "$dest/$STATE_REL")"
elif [ -e "$dest/.gitignore" ]; then
  gitignore_state="gitignore_preexisting=1"
else
  gitignore_state="gitignore_preexisting=0"
fi

say "Installing ClaudeCollab"
say "  from: $src"
say "  into: $dest"
[ -d "$dest/.git" ] || warn "$dest is not a git repo — install works, but you won't be able to review /collab:delegate diffs with git."

# A path is ours only while its current bytes match the prior install record.
is_owned() {
  local rel="$1" expected actual
  expected="$(recorded_hash "$rel" 2>/dev/null || true)"
  [ -f "$dest/$rel" ] || return 1
  actual="$(sha256_file "$dest/$rel")"
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    return 0
  fi
  # A legacy path-only manifest can be migrated when the installed bytes still
  # match this payload. A differing file is ambiguous and must remain untouched.
  [ -f "$dest/$MANIFEST_REL" ] && grep -qxF "$rel" "$dest/$MANIFEST_REL" &&
    [ "$actual" = "$(sha256_file "$src/$rel")" ]
}

manifest_tmp="$(mktemp)"
hashes_tmp="$(mktemp)"
skipped_list="$(mktemp)"
count=0; skipped=0
copy_one() {  # copy_one <relpath> ; records it in the new manifest (unless skipped)
  local rel="$1" old_hash parent tmp
  safe_dest_rel "$rel"
  if [ -e "$dest/$rel" ] && ! is_owned "$rel"; then
    warn "skipping $rel — a file you already have is there; leaving it untouched"
    printf '%s\n' "$rel" >> "$skipped_list"
    # Keep unresolved legacy paths and orphaned hashes available for a later
    # version that can verify them; never turn a partial migration into no record.
    if [ -f "$dest/$MANIFEST_REL" ] && grep -qxF "$rel" "$dest/$MANIFEST_REL"; then
      printf '%s\n' "$rel" >> "$manifest_tmp"
    fi
    old_hash="$(recorded_hash "$rel" 2>/dev/null || true)"
    [ -n "$old_hash" ] && printf '%s\t%s\n' "$old_hash" "$rel" >> "$hashes_tmp"
    skipped=$((skipped+1)); return
  fi
  parent="$dest/$(dirname "$rel")"
  mkdir -p "$parent"
  tmp="$(mktemp "$parent/.cc-payload.XXXXXX")" || die "could not create a secure payload temporary file"
  cp -p "$src/$rel" "$tmp" || { rm -f "$tmp"; die "could not prepare payload file: $rel"; }
  case "$rel" in collab/*.sh|collab/tests/fake-opencode) chmod +x "$tmp" ;; esac
  mv -f "$tmp" "$dest/$rel"
  printf '%s\n' "$rel" >> "$manifest_tmp"
  printf '%s\t%s\n' "$(sha256_file "$dest/$rel")" "$rel" >> "$hashes_tmp"
  count=$((count+1))
}
# Walk each payload dir (relative, since we cd into src) and copy every file.
while IFS= read -r rel; do
  copy_one "$rel"
done < <(payload_files)

# Persist paths, hashes, and destination state using replacement rather than
# truncation, so a hardlinked reserved path cannot modify an outside inode.
metadata_tmp="$(mktemp "$dest/collab/.cc-manifest.XXXXXX")"
sort -u "$manifest_tmp" > "$metadata_tmp"
mv -f "$metadata_tmp" "$dest/$MANIFEST_REL"
metadata_tmp="$(mktemp "$dest/collab/.cc-hashes.XXXXXX")"
sort -u "$hashes_tmp" > "$metadata_tmp"
mv -f "$metadata_tmp" "$dest/$HASHES_REL"
metadata_tmp="$(mktemp "$dest/collab/.cc-state.XXXXXX")"
printf '%s\n' "$gitignore_state" > "$metadata_tmp"
mv -f "$metadata_tmp" "$dest/$STATE_REL"
rm -f "$manifest_tmp"
rm -f "$hashes_tmp"

add_gitignore_block
ok "Installed ${count} file(s)$( [ "$skipped" -gt 0 ] && printf ', skipped %d already-present file(s)' "$skipped")."
if [ "$skipped" -gt 0 ]; then
  # Repeat the skips as a summary. Inline warnings scroll away, and a skipped
  # command is INVISIBLE afterwards: the file is there, it's just not ours, so
  # nothing later looks wrong. Name them and say what it means.
  warn "These ClaudeCollab files were NOT installed because you already had a file at that path:"
  while IFS= read -r rel; do warn "    $rel"; done < "$skipped_list"
  warn "Your files were left untouched — that part is deliberate. But the ClaudeCollab version of"
  warn "each is absent: if it's a slash command, that command is YOURS, not ours, and will not do"
  warn "what our docs describe. Rename or remove yours and re-run, or accept that it's shadowed."
  warn "'bash collab/doctor.sh' re-reports this, so you don't have to remember it from here."
fi
say "Next steps:"
say "  1. Authenticate opencode to your providers:  opencode auth login"
say "  2. Check the setup:                          bash collab/doctor.sh"
say "  3. (optional) Set default models:            run /collab:configure in Claude Code"
say "  4. Use it in Claude Code:                     /collab:consult, /collab:panel, /collab:review, /collab:delegate"
